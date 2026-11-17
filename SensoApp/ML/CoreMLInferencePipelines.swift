// CoreMLInferencePipelines.swift
// Turns microphone audio into Stage 1 readings ("is liquid pouring right now?") and, while pouring,
// Stage 3 fill estimates from the cup's resonance (AcousticFillTracker, see FillEstimator.swift).
//
// Two interchangeable Stage 1 classifiers behind one protocol:
//   • SoundAnalysisClassifier: a trained Create ML model, used when the app bundle contains one
//     (the highest-numbered SensoSoundClassifier_v*, see MLTraining/README.md).
//   • DSPAcousticClassifier: a hand-tuned Accelerate heuristic, used when no model is bundled. Its
//     readings are labelled `.dspFallback`, which the UI shows as "DSP Mode (Uncalibrated)".
//
// The camera and Watch classifiers come with the Vision and Watch milestones.

import Accelerate
import AVFoundation
import CoreML
import Observation
import os
import SoundAnalysis
import Synchronization

nonisolated private let log = Logger(subsystem: "com.senso.app", category: "ml")

/// Feeds microphone buffers in, delivers readings through the handler it was created with.
/// `analyze` is only called from the audio processing queue, one buffer at a time.
nonisolated protocol AcousticClassifierProtocol: AnyObject, Sendable {
    var source: EstimateSource { get }
    func analyze(_ buffer: AVAudioPCMBuffer)
}

typealias ReadingHandler = @Sendable (SensorReading) -> Void

// MARK: - Session owner (main actor)

/// Picks the classifier, starts the mic feeding it and the fill tracker, and publishes the newest results.
/// PourEstimationEngine consumes them.
@Observable
final class AcousticPipeline {
    /// Newest reading of the running session. nil when stopped or before the first result.
    private(set) var latest: SensorReading?
    /// Newest fill estimate. nil while there is none (not pouring yet, or the cup can't be heard).
    private(set) var fill: FillReading?
    /// What the current session runs on. `.none` until the first start.
    private(set) var source: EstimateSource = .none

    @ObservationIgnored private var trainedModel: (model: MLModel, version: String)?
    @ObservationIgnored private var didLookForModel = false
    /// Bumped on every start and stop, so readings still in flight from an old session are dropped.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var fillTracker: AcousticFillTracker?

    /// `calibration` is the chosen cup's, if any. With `calibrating`, the pour is also recorded so
    /// `finishCalibration()` can measure the cup.
    func start(with audio: AudioCaptureService, calibration: FillCalibration? = nil, calibrating: Bool = false) async {
        if !didLookForModel {
            trainedModel = await SoundModelLocator.loadBundledModel()
            didLookForModel = true
        }
        session += 1
        let current = session
        latest = nil
        fill = nil
        let fillTracker = AcousticFillTracker(calibration: calibration, calibrating: calibrating) { [weak self] reading in
            Task { @MainActor in
                guard let self, self.session == current else { return }
                self.fill = reading
            }
        }
        self.fillTracker = fillTracker
        let deliver: ReadingHandler = { [weak self] reading in
            fillTracker.setPouring(reading.pouringConfidence >= 0.5)
            Task { @MainActor in
                guard let self, self.session == current else { return }
                self.latest = reading
            }
        }
        let classifier = makeClassifier(deliver)
        source = classifier.source
        await audio.start { buffer, _ in
            classifier.analyze(buffer)
            fillTracker.analyze(buffer)
        }
    }

    func stop(_ audio: AudioCaptureService, releaseSession: Bool = true) {
        audio.stop(releaseSession: releaseSession)
        session += 1
        latest = nil
        fill = nil
    }

    /// What the calibration pour measured so far. Call before `stop`. nil if under 2 s of pouring was heard.
    func finishCalibration() -> FillCalibration? {
        fillTracker?.finishCalibration()
    }

    private func makeClassifier(_ deliver: @escaping ReadingHandler) -> any AcousticClassifierProtocol {
        if let trainedModel {
            do {
                return try SoundAnalysisClassifier(model: trainedModel.model, version: trainedModel.version, onReading: deliver)
            } catch {
                log.error("Model \(trainedModel.version, privacy: .public) unusable, using DSP: \(error.localizedDescription, privacy: .public)")
            }
        }
        return DSPAcousticClassifier(onReading: deliver)
    }
}

// MARK: - Trained model

nonisolated enum SoundModelLocator {
    static let prefix = "SensoSoundClassifier_v"

    /// The highest version among model names, so _v10 beats _v2.
    static func latest(in names: [String]) -> String? {
        names
            .compactMap { name -> (name: String, version: Int)? in
                guard name.hasPrefix(prefix), let version = Int(name.dropFirst(prefix.count)) else { return nil }
                return (name, version)
            }
            .max { $0.version < $1.version }?
            .name
    }

    /// Xcode compiles a dragged-in .mlmodel or .mlpackage into a .mlmodelc folder in the app bundle.
    static func loadBundledModel(from bundle: Bundle = .main) async -> (model: MLModel, version: String)? {
        let urls = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        guard let version = latest(in: urls.map { $0.deletingPathExtension().lastPathComponent }),
              let url = urls.first(where: { $0.deletingPathExtension().lastPathComponent == version })
        else {
            log.info("No bundled SensoSoundClassifier: using DSP fallback")
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            let model = try await MLModel.load(contentsOf: url, configuration: configuration)
            log.info("Loaded \(version, privacy: .public)")
            return (model, version)
        } catch {
            log.error("Loading \(version, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Runs the trained model through SoundAnalysis, the same framework the training script evaluates with.
/// `@unchecked Sendable`: mutable state is touched only from `analyze`, on the audio processing queue.
/// The observer callbacks read only constants.
nonisolated final class SoundAnalysisClassifier: NSObject, AcousticClassifierProtocol, SNResultsObserving, @unchecked Sendable {
    let source: EstimateSource
    private let model: MLModel
    private let onReading: ReadingHandler
    private var analyzer: SNAudioStreamAnalyzer?
    private var sampleRate = 0.0
    private var framePosition: AVAudioFramePosition = 0

    /// Throws if the model isn't a sound classifier, so the caller can fall back to DSP.
    init(model: MLModel, version: String, onReading: @escaping ReadingHandler) throws {
        _ = try SNClassifySoundRequest(mlModel: model)
        self.model = model
        self.source = .trainedModel(version: version)
        self.onReading = onReading
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        // A route change can change the sample rate; the analyzer is tied to one format.
        if analyzer == nil || buffer.format.sampleRate != sampleRate {
            let analyzer = SNAudioStreamAnalyzer(format: buffer.format)
            do {
                let request = try SNClassifySoundRequest(mlModel: model)
                request.overlapFactor = 0.75  // same as training
                try analyzer.add(request, withObserver: self)
            } catch {
                log.error("Sound request failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            self.analyzer = analyzer
            sampleRate = buffer.format.sampleRate
            framePosition = 0
        }
        analyzer?.analyze(buffer, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(buffer.frameLength)
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let pouring = result.classification(forIdentifier: SoundClass.pouring.rawValue)?.confidence ?? 0
        onReading(SensorReading(sensor: .microphone, timestamp: .now, status: .active, source: source,
                                pouringConfidence: pouring, fillStage: nil, fillFraction: nil))
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        log.error("Sound analysis failed: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Fill level (Stage 3)

/// Slices the mic stream into half-overlapping frames for the resonance tracker and turns its pitch into
/// fill estimates while the classifier says liquid is pouring. All state sits behind one lock: `analyze`
/// runs on the audio processing queue, classifier results may arrive on another thread, and
/// `finishCalibration` is called from the main actor.
nonisolated final class AcousticFillTracker: Sendable {
    typealias Handler = @Sendable (FillReading?) -> Void

    private struct State {
        var tracker: ResonanceTracker?
        var estimator: FillEstimator
        var recorder: CalibrationRecorder?
        var pending: [Float] = []
        var time = 0.0
        var isPouring = false
        var frameCount = 0
        var lastSent: FillReading?
    }

    private let state: Mutex<State>
    private let onFill: Handler

    init(calibration: FillCalibration?, calibrating: Bool, onFill: @escaping Handler) {
        state = Mutex(State(estimator: FillEstimator(calibration: calibration), recorder: calibrating ? CalibrationRecorder() : nil))
        self.onFill = onFill
    }

    func setPouring(_ isPouring: Bool) {
        state.withLock { $0.isPouring = isPouring }
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        let sampleRate = buffer.format.sampleRate
        let readings: [FillReading?] = state.withLock { state in
            if state.tracker?.sampleRate != sampleRate {
                // A route change can change the sample rate: start the pour's estimate over.
                state.tracker = ResonanceTracker(sampleRate: sampleRate)
                state.estimator.reset()
                state.pending = []
            }
            guard let tracker = state.tracker else { return [] }
            state.pending.append(contentsOf: samples)
            let frameSeconds = Double(ResonanceTracker.hopSize) / sampleRate
            var readings: [FillReading?] = []
            while state.pending.count >= ResonanceTracker.frameSize {
                let frame = Array(state.pending.prefix(ResonanceTracker.frameSize))
                state.pending.removeFirst(ResonanceTracker.hopSize)
                state.time += frameSeconds
                // Track every frame so fixed room resonances are learned before the pour starts.
                let pitch = tracker.track(frame)
                let usablePitch = state.isPouring ? pitch : nil
                state.recorder?.update(pitch: usablePitch, isPouring: state.isPouring, time: state.time, frameSeconds: frameSeconds)
                let reading = state.estimator.update(pitch: usablePitch, isPouring: state.isPouring, time: state.time, frameSeconds: frameSeconds)
                state.frameCount += 1
                // About 11 updates a second is plenty for the UI and alerts.
                if state.frameCount.isMultiple(of: 2) || (reading == nil) != (state.lastSent == nil) {
                    state.lastSent = reading
                    readings.append(reading)
                }
            }
            return readings
        }
        readings.forEach(onFill)
    }

    func finishCalibration() -> FillCalibration? {
        state.withLock { $0.recorder?.finish() }
    }
}

// MARK: - DSP fallback

/// Pouring sounds broadband, noise-like and louder than the room, mostly between 1 and 8 kHz. As a cup
/// fills, the air above the liquid gets shorter, so its resonance pitch rises. This scores each
/// ~85 ms frame on those cues. The score is a deterministic 0...1 heuristic, not a probability.
/// `@unchecked Sendable`: all mutable state is touched only from `analyze`, on the audio processing queue.
nonisolated final class DSPAcousticClassifier: AcousticClassifierProtocol, @unchecked Sendable {
    struct Features {
        var levelDB: Float
        /// Share of 0.1–12 kHz power that falls in 1–8 kHz.
        var bandRatio: Float
        /// Spectral flatness over 0.1–12 kHz: near 0 for a tone, about 0.5 for white noise.
        var flatness: Float
        /// Strongest frequency between 300 Hz and 5 kHz.
        var peakHz: Double
    }

    let source = EstimateSource.dspFallback
    private let onReading: ReadingHandler
    private let fftSize = 4096
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    private var pending: [Float] = []
    private var elapsed = 0.0
    private var noiseFloorDB: Float?
    private var smoothedScore = 0.0
    private var peakHistory: [(x: Double, y: Double)] = []

    init(onReading: @escaping ReadingHandler) {
        self.onReading = onReading
        fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        let sampleRate = buffer.format.sampleRate
        while pending.count >= fftSize {
            let frame = Array(pending.prefix(fftSize))
            pending.removeFirst(fftSize)
            let frameSeconds = Double(fftSize) / sampleRate
            elapsed += frameSeconds
            let score = score(features(of: frame, sampleRate: sampleRate), frameSeconds: frameSeconds)
            onReading(SensorReading(sensor: .microphone, timestamp: .now, status: .lowConfidence, source: source,
                                    pouringConfidence: score, fillStage: nil, fillFraction: nil))
        }
    }

    func features(of frame: [Float], sampleRate: Double) -> Features {
        let rms = vDSP.rootMeanSquare(frame)
        let levelDB = rms > 0 ? max(20 * log10(rms), -160) : -160

        let windowed = vDSP.multiply(frame, window)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                let input = split  // same memory: vDSP transforms in place
                fft.forward(input: input, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }

        let binHz = sampleRate / Double(fftSize)
        func bins(_ low: Double, _ high: Double) -> Range<Int> {
            let lower = max(1, Int(low / binHz))
            return lower..<max(lower + 1, min(power.count, Int(high / binHz)))
        }
        let analysisBand = power[bins(100, 12_000)]
        let total = vDSP.sum(analysisBand)
        let bandRatio = total > 0 ? vDSP.sum(power[bins(1_000, 8_000)]) / total : 0
        let geometricMean = exp(vDSP.mean(vForce.log(vDSP.add(1e-12, analysisBand))))
        let flatness = total > 0 ? geometricMean / (total / Float(analysisBand.count)) : 0
        let peakBand = bins(300, 5_000)
        let peakIndex = vDSP.indexOfMaximum(power[peakBand]).0
        return Features(levelDB: levelDB, bandRatio: bandRatio, flatness: flatness,
                        peakHz: Double(peakBand.lowerBound + Int(peakIndex)) * binHz)
    }

    private func score(_ features: Features, frameSeconds: Double) -> Double {
        // Noise floor drops at once and rises 0.5 dB/s, so a steady pour isn't absorbed into it quickly.
        let floor = min(features.levelDB, (noiseFloorDB ?? features.levelDB) + Float(0.5 * frameSeconds))
        noiseFloorDB = floor
        let snr = Double(features.levelDB - floor)

        // shortcut: these thresholds are hand-picked guesses (hence "Uncalibrated"); tune them on recorded clips.
        let loud = clamp((snr - 6) / 12)
        let broadband = clamp((Double(features.bandRatio) - 0.3) / 0.4)
        let noiseLike = clamp((Double(features.flatness) - 0.1) / 0.3)

        // Rising resonance pitch while sound is present: a small extra hint that a cup is filling.
        if snr > 6 { peakHistory.append((elapsed, features.peakHz)) }
        peakHistory.removeAll { elapsed - $0.x > 2 }
        let rising = peakHistory.count >= 6 ? clamp(linearSlope(peakHistory) / 200) : 0

        let raw = min(1, loud * ((broadband * noiseLike).squareRoot() + 0.2 * rising))
        smoothedScore += 0.35 * (raw - smoothedScore)
        return smoothedScore
    }
}

nonisolated func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

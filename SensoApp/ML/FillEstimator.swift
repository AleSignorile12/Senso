// FillEstimator.swift
// Stage 3, from physics instead of a trained model.
//
// While you pour, the air above the liquid rings like a pipe closed at one end. Its pitch is
// f = c / (4 · (air length + 0.62 · radius))   (Bagad et al., "The Sound of Water", ICASSP 2025).
// As the cup fills, the air column shortens, so the period 1/f falls in a straight line with liquid height:
//   fill height = (1/f_empty − 1/f) / (1/f_empty − 1/f_full)
// The speed of sound cancels out. One calibration pour (start with an empty cup, tap "full")
// measures f_empty and f_full for that cup. Without calibration, f_full is guessed from a typical
// cup radius, so the estimate is rougher and flagged as such.
//
// Pure Accelerate + Foundation (plus FillCalibration from SharedModels) so
// MLTraining/EvaluateFillEstimator.swift compiles this same file on a Mac.

import Accelerate
import Foundation

nonisolated enum FillMethod: String, Codable, Sendable {
    case pitchCalibrated, pitchUncalibrated, timeCalibrated
}

nonisolated struct FillReading: Sendable, Equatable {
    /// 0...1 of the cup's height (equals volume for straight-sided cups).
    var fraction: Double
    /// Rough ± on `fraction`.
    var uncertainty: Double
    /// Fill speed in fraction per second, for timing the warning.
    var ratePerSecond: Double
    var method: FillMethod
}

// MARK: - Pitch tracking

/// The air-column resonance at one moment.
nonisolated struct ResonancePitch: Sendable, Equatable {
    var hz: Double
    /// How fast the pitch rises: d(ln f)/dt, per second. Always > 0 (cups only fill up).
    var riseRate: Double
    /// Average salience along the trajectory, in dB above the local spectrum. Higher is clearer.
    var strength: Double
}

/// Finds the air-column resonance by searching trajectories instead of single frames.
///
/// A pour rings at fixed frequencies too (the jug, the room, the stream) and splashes put random
/// peaks everywhere, so the strongest peak in one frame is usually wrong. The cup's resonance is the
/// only peak that keeps rising along the path physics predicts: with steady flow the period falls in a
/// straight line, P(t) = P_now · (1 + rate · age). For every current pitch and rise rate, the tracker
/// adds up spectral salience along that path over the last 2 s and keeps the best. Peaks that sit
/// still are also subtracted, using a slow per-frequency memory.
nonisolated final class ResonanceTracker {
    static let frameSize = 4096
    /// Frames must arrive this many samples apart (half a frame).
    static let hopSize = 2048
    static let minHz = 250.0
    static let maxHz = 6_000.0
    private static let pointsPerOctave = 48.0
    private static let historySeconds = 2.0
    /// How long a peak must sit still to be ignored.
    private static let persistenceSeconds = 3.0
    /// Rise rates searched, d(ln f)/dt from 0.03/s (a slow pour into a tall glass) to 1.5/s (the last moment in a small cup).
    private static let riseRates = (0..<24).map { 0.03 * pow(50, Double($0) / 23) }
    /// Below this, nothing rises clearly enough to call it the cup.
    static let minimumStrength = 2.5

    let sampleRate: Double
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let gridHz: [Double]
    private let hopSeconds: Double
    private let historyLength: Int
    /// offsets[rate][age]: how many grid points lower the path was `age` frames ago.
    private let offsets: [[Int]]
    private var history: [[Float]] = []
    private var persistence: [Float]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.frameSize, isHalfWindow: false)
        let octaves = log2(Self.maxHz / Self.minHz)
        gridHz = (0...Int(octaves * Self.pointsPerOctave)).map { Self.minHz * pow(2, Double($0) / Self.pointsPerOctave) }
        hopSeconds = Double(Self.hopSize) / sampleRate
        historyLength = Int(Self.historySeconds / hopSeconds)
        let hop = hopSeconds
        offsets = Self.riseRates.map { rate in
            (0..<Int(Self.historySeconds / hop)).map { age in Int((Self.pointsPerOctave * log2(1 + rate * Double(age) * hop)).rounded()) }
        }
        persistence = Array(repeating: 0, count: gridHz.count)
    }

    func reset() {
        history = []
        persistence = Array(repeating: 0, count: gridHz.count)
    }

    /// Feed every frame, `hopSize` samples apart. Returns nil until 1 s of history exists, or when no
    /// rising resonance is clear.
    func track(_ frame: [Float]) -> ResonancePitch? {
        precondition(frame.count == Self.frameSize)
        let power = powerSpectrum(frame)
        let binHz = sampleRate / Double(Self.frameSize)

        // Spectrum in dB on the log grid (linear interpolation between FFT bins).
        let grid = gridHz.map { hz -> Double in
            let position = hz / binHz
            let lower = min(Int(position), power.count - 2)
            let fraction = position - Double(lower)
            return 10 * log10(1e-12 + Double(power[lower]) * (1 - fraction) + Double(power[lower + 1]) * fraction)
        }
        // Salience: peak height above a ±1/6-octave average, minus how long a peak has sat at that frequency.
        let prominence = zip(movingAverage(grid, radius: 1), movingAverage(grid, radius: 8)).map { Float($0 - $1) }
        let salience = zip(prominence, persistence).map { max(0, $0 - $1) }
        let rate = Float(min(1, hopSeconds / Self.persistenceSeconds))
        for index in persistence.indices { persistence[index] += rate * (max(0, prominence[index]) - persistence[index]) }

        history.append(salience)
        if history.count > historyLength { history.removeFirst() }
        guard history.count >= historyLength / 2 else { return nil }

        // Score every (current pitch, rise rate) path through the history.
        let count = gridHz.count
        var best: (score: Float, index: Int, rate: Int, scores: [Float]) = (-1, 0, 0, [])
        for (rateIndex, rateOffsets) in offsets.enumerated() {
            var scores = [Float](repeating: 0, count: count)
            for age in 0..<history.count {
                let offset = rateOffsets[age]
                guard offset < count else { break }
                let row = history[history.count - 1 - age]
                // scores[k] += row[k - offset] for k >= offset
                scores.withUnsafeMutableBufferPointer { output in
                    row.withUnsafeBufferPointer { input in
                        vDSP_vadd(output.baseAddress! + offset, 1, input.baseAddress!, 1,
                                  output.baseAddress! + offset, 1, vDSP_Length(count - offset))
                    }
                }
            }
            let (index, value) = vDSP.indexOfMaximum(scores)
            if value > best.score { best = (value, Int(index), rateIndex, scores) }
        }
        let strength = Double(best.score) / Double(history.count)
        // The slowest rate is nearly flat: that's a fixed ring, not a filling cup.
        guard strength >= Self.minimumStrength, best.rate > 0 else { return nil }

        // Parabolic interpolation between grid points for sub-point accuracy.
        var position = Double(best.index)
        if best.index > 0, best.index < count - 1 {
            let (a, b, c) = (Double(best.scores[best.index - 1]), Double(best.scores[best.index]), Double(best.scores[best.index + 1]))
            let denominator = a - 2 * b + c
            if denominator != 0 { position += max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) }
        }
        return ResonancePitch(hz: Self.minHz * pow(2, position / Self.pointsPerOctave),
                              riseRate: Self.riseRates[best.rate], strength: strength)
    }

    private func powerSpectrum(_ frame: [Float]) -> [Float] {
        let half = Self.frameSize / 2
        let windowed = vDSP.multiply(frame, window)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                let input = split  // same memory: vDSP transforms in place
                fft.forward(input: input, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        return power
    }

    private func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { index in
            let range = max(0, index - radius)...min(values.count - 1, index + radius)
            return values[range].reduce(0, +) / Double(range.count)
        }
    }
}

// MARK: - Fill estimation for one pour

/// Turns resonance pitches into a fill estimate.
/// Feed it every frame with `isPouring` from the Stage 1 classifier; call `reset()` between pours.
nonisolated final class FillEstimator {
    /// Typical mug radius, for the uncalibrated guess of the "full" pitch: 343 / (4 · 0.62 · 0.035) ≈ 3.95 kHz.
    static let uncalibratedFullHz = 343.0 / (4 * 0.62 * 0.035)
    /// Pitch history needed before the fill line can be extrapolated through gaps.
    static let minimumTrackedSeconds = 2.0

    var calibration: FillCalibration?
    private var pouringSeconds = 0.0
    /// Empty-cup period estimates: each early pitch extrapolated back to the pour start along its rise rate.
    private var emptyPeriods: [Double] = []
    private var recentFractions: [Double] = []
    /// Every pitch-based fill estimate this pour, against pouring time (pauses don't count), for the
    /// straight line used when the pitch is lost.
    private var tracked: [(time: Double, fraction: Double)] = []
    private var lastPitchReading: (time: Double, reading: FillReading)?
    private var best = 0.0
    /// While paused the level doesn't rise, so the reported rate is 0.
    private var isPouringNow = false

    init(calibration: FillCalibration?) { self.calibration = calibration }

    func reset() {
        pouringSeconds = 0
        emptyPeriods = []
        recentFractions = []
        tracked = []
        lastPitchReading = nil
        best = 0
    }

    /// `time` in seconds since the session began, `frameSeconds` the time since the previous frame.
    func update(pitch: ResonancePitch?, isPouring: Bool, time: Double, frameSeconds: Double) -> FillReading? {
        guard isPouring || pouringSeconds > 0 else { return nil }
        isPouringNow = isPouring
        if isPouring { pouringSeconds += frameSeconds }

        var reading: FillReading?
        if let pitch, isPouring, let pitchReading = pitchFraction(pitch) {
            lastPitchReading = (pouringSeconds, pitchReading)
            tracked.append((pouringSeconds, pitchReading.fraction))
            reading = pitchReading
        } else if let extrapolated = extrapolatedFraction(atPouringTime: pouringSeconds) {
            // Read at pouring time, so the line holds still while the pour is paused.
            // Near the brim the resonance often fades; flow is steady enough to carry the line on.
            reading = extrapolated
        } else if let calibration {
            reading = FillReading(fraction: pouringSeconds / calibration.fillSeconds, uncertainty: 0.2,
                                  ratePerSecond: isPouring ? 1 / calibration.fillSeconds : 0, method: .timeCalibrated)
        }
        guard var reading else { return nil }
        // A cup only fills: never report less than before (small dips are noise).
        reading.fraction = min(max(reading.fraction, best - 0.02, 0), 1.2)
        best = max(best, reading.fraction)
        return reading
    }

    /// Straight line through this pour's pitch estimates (refit without outliers), read at `time` seconds of pouring.
    private func extrapolatedFraction(atPouringTime time: Double) -> FillReading? {
        guard let first = tracked.first?.time, let last = lastPitchReading,
              last.time - first >= Self.minimumTrackedSeconds, tracked.count >= 20
        else { return nil }
        var points = tracked
        var fit = straightLine(points)
        points = points.filter { abs($0.fraction - fit.value(at: $0.time)) < 0.1 }
        guard points.count >= 10 else { return nil }
        fit = straightLine(points)
        guard fit.slope > 0 else { return nil }
        // Uncertainty grows the further the line is carried past the last pitch.
        let gap = time - last.time
        return FillReading(fraction: fit.value(at: time), uncertainty: last.reading.uncertainty + 0.05 * gap,
                           ratePerSecond: isPouringNow ? fit.slope : 0, method: last.reading.method)
    }

    private func pitchFraction(_ pitch: ResonancePitch) -> FillReading? {
        let period = 1 / pitch.hz
        // Pouring time: the cup doesn't fill during a pause, and a false start mustn't use up these 3 s.
        if pouringSeconds <= 3 { emptyPeriods.append(period * (1 + pitch.riseRate * pouringSeconds)) }
        let pitchCalibration = calibration?.hasPitch == true ? calibration : nil
        let fullPeriod = 1 / (pitchCalibration?.fullHz ?? Self.uncalibratedFullHz)
        guard let emptyPeriod = pitchCalibration?.emptyHz.map({ 1 / $0 }) ?? (emptyPeriods.isEmpty ? nil : median(emptyPeriods)),
              emptyPeriod > fullPeriod * 1.2
        else { return nil }

        // Median of the last ~0.4 s: one wrong frame can't jump the estimate.
        recentFractions.append((emptyPeriod - period) / (emptyPeriod - fullPeriod))
        if recentFractions.count > 9 { recentFractions.removeFirst() }
        let calibrated = pitchCalibration != nil
        return FillReading(fraction: median(recentFractions), uncertainty: calibrated ? 0.1 : 0.25,
                           ratePerSecond: pitch.riseRate * period / (emptyPeriod - fullPeriod),
                           method: calibrated ? .pitchCalibrated : .pitchUncalibrated)
    }
}

// MARK: - The start of a pour

/// The frames just heard, so the start of a pour isn't lost.
///
/// The classifier first says "pouring" about 0.6 s after the water starts (median on the held-out pours), and
/// the engine may wait longer for a confident reading. Counting only from then would make the level read low
/// and the stop alert come late.
nonisolated struct PourLookback {
    struct Frame: Equatable {
        var pitch: ResonancePitch?
        var time: Double
        var seconds: Double
    }

    static let classifierDelaySeconds = 0.6
    /// Limits how much sound before the confirmation can count, in case it was room noise and not the pour.
    static let maximumSeconds = 3.0

    private var frames: [Frame] = []
    private var soundStart: Double?

    mutating func add(pitch: ResonancePitch?, isPouring: Bool, time: Double, frameSeconds: Double) {
        soundStart = isPouring ? soundStart ?? time : nil
        frames.append(Frame(pitch: pitch, time: time, seconds: frameSeconds))
        frames.removeAll { $0.time <= time - Self.maximumSeconds }
    }

    /// The frames from shortly before the classifier first heard the current sound.
    func framesOfThisPour(now: Double) -> [Frame] {
        let start = max((soundStart ?? now) - Self.classifierDelaySeconds, now - Self.maximumSeconds)
        return frames.filter { $0.time > start }
    }
}

// MARK: - Calibration

/// Collects pitches during a calibration pour into an empty cup; `finish()` when the user says "full".
nonisolated final class CalibrationRecorder {
    private var pourStart: Double?
    private var lastPouringTime = 0.0
    private var pouringSeconds = 0.0
    private var samples: [(time: Double, period: Double, riseRate: Double)] = []

    func update(pitch: ResonancePitch?, isPouring: Bool, time: Double, frameSeconds: Double) {
        guard isPouring else { return }
        if pourStart == nil { pourStart = time }
        lastPouringTime = time
        pouringSeconds += frameSeconds
        if let pitch { samples.append((time, 1 / pitch.hz, pitch.riseRate)) }
    }

    /// The pour's length, plus the empty pitch (first 3 s) and full pitch (last 1 s) when they were audible,
    /// each extrapolated to the pour's start or end along the measured rise rate.
    /// nil if less than 2 s of pouring was heard.
    func finish() -> FillCalibration? {
        guard let pourStart, lastPouringTime - pourStart >= 2 else { return nil }
        var calibration = FillCalibration(emptyHz: nil, fullHz: nil, fillSeconds: pouringSeconds)
        let early = samples.filter { $0.time - pourStart <= 3 }.map { $0.period * (1 + $0.riseRate * ($0.time - pourStart)) }
        let late = samples.filter { lastPouringTime - $0.time <= 1 }.map { $0.period * max(0.2, 1 - $0.riseRate * (lastPouringTime - $0.time)) }
        // The pitch must clearly rise as the cup fills, or it wasn't the cup.
        if early.count >= 5, late.count >= 5, median(late) > 0, median(early) > median(late) * 1.3 {
            calibration.emptyHz = 1 / median(early)
            calibration.fullHz = 1 / median(late)
        }
        return calibration
    }
}

// MARK: - Helpers

nonisolated struct StraightLine {
    var slope: Double
    var intercept: Double
    func value(at time: Double) -> Double { intercept + slope * time }
}

nonisolated func straightLine(_ points: [(time: Double, fraction: Double)]) -> StraightLine {
    let slope = linearSlope(points.map { (x: $0.time, y: $0.fraction) })
    let meanX = points.reduce(0) { $0 + $1.time } / Double(points.count)
    let meanY = points.reduce(0) { $0 + $1.fraction } / Double(points.count)
    return StraightLine(slope: slope, intercept: meanY - slope * meanX)
}

/// Least-squares slope of y over x (for example Hz per second). 0 for fewer than 2 points.
nonisolated func linearSlope(_ points: [(x: Double, y: Double)]) -> Double {
    guard points.count >= 2 else { return 0 }
    let count = Double(points.count)
    let meanX = points.reduce(0) { $0 + $1.x } / count
    let meanY = points.reduce(0) { $0 + $1.y } / count
    let covariance = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
    let variance = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
    return variance > 0 ? covariance / variance : 0
}

nonisolated func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
}

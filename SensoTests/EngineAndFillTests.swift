import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Senso

// MARK: - Fill from resonance

struct FillEstimationTests {
    let rate = 48_000.0

    /// A synthetic pour: white noise (the splash) plus a resonance whose period falls in a straight line
    /// from `emptyHz` to `fullHz` over `seconds`, plus a fixed 2 kHz ring that must be ignored.
    func syntheticPour(emptyHz: Double, fullHz: Double, seconds: Double) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        var phase = 0.0
        return (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            let period = 1 / emptyHz + (1 / fullHz - 1 / emptyHz) * time / seconds
            phase += 2 * .pi / period / rate
            let ring = sin(2 * .pi * 2_000 * time)
            return Float(0.25 * sin(phase) + 0.25 * ring + 0.3 * Double.random(in: -1...1, using: &generator))
        }
    }

    /// Runs samples through the tracker at the app's hop; returns (time, pitch) pairs.
    func track(_ samples: [Float]) -> [(time: Double, pitch: ResonancePitch?)] {
        let tracker = ResonanceTracker(sampleRate: rate)
        var result: [(Double, ResonancePitch?)] = []
        var start = 0
        while start + ResonanceTracker.frameSize <= samples.count {
            let pitch = tracker.track(Array(samples[start..<(start + ResonanceTracker.frameSize)]))
            result.append((Double(start + ResonanceTracker.frameSize) / rate, pitch))
            start += ResonanceTracker.hopSize
        }
        return result
    }

    @Test func `tracker follows a rising resonance and ignores a fixed ring`() {
        let seconds = 10.0
        let frames = track(syntheticPour(emptyHz: 500, fullHz: 2_500, seconds: seconds))
        let found = frames.compactMap { frame in frame.pitch.map { (frame.time, $0) } }
        #expect(Double(found.count) > Double(frames.count) * 0.6)
        let close = found.filter { time, pitch in
            let expected = 1 / (1 / 500 + (1 / 2_500 - 1 / 500) * time / seconds)
            return abs(log2(pitch.hz / expected)) < 1.0 / 12
        }
        #expect(Double(close.count) > Double(found.count) * 0.8, "pitch within a semitone of the true resonance")
    }

    @Test func `calibrated estimate rises with the pour and ends near full`() throws {
        let seconds = 10.0
        let frames = track(syntheticPour(emptyHz: 500, fullHz: 2_500, seconds: seconds))
        let estimator = FillEstimator(calibration: FillCalibration(emptyHz: 500, fullHz: 2_500, fillSeconds: seconds))
        let hop = Double(ResonanceTracker.hopSize) / rate
        var readings: [(time: Double, reading: FillReading)] = []
        for frame in frames {
            if let reading = estimator.update(pitch: frame.pitch, isPouring: true, time: frame.time, frameSeconds: hop) {
                readings.append((frame.time, reading))
            }
        }
        let halfway = try #require(readings.first { $0.time >= seconds / 2 })
        #expect(abs(halfway.reading.fraction - 0.5) < 0.12)
        #expect(halfway.reading.method == .pitchCalibrated)
        let last = try #require(readings.last)
        #expect(last.reading.fraction > 0.85)
        // A cup only fills: the estimate never drops by more than the allowed jitter.
        for (previous, next) in zip(readings, readings.dropFirst()) {
            #expect(next.reading.fraction >= previous.reading.fraction - 0.021)
        }
    }

    @Test func `calibration pour measures the cup's pitch range`() throws {
        let seconds = 8.0
        let recorder = CalibrationRecorder()
        let hop = Double(ResonanceTracker.hopSize) / rate
        for frame in track(syntheticPour(emptyHz: 600, fullHz: 2_400, seconds: seconds)) {
            recorder.update(pitch: frame.pitch, isPouring: true, time: frame.time, frameSeconds: hop)
        }
        let calibration = try #require(recorder.finish())
        #expect(calibration.hasPitch)
        #expect(abs(log2(try #require(calibration.emptyHz) / 600)) < 0.25)
        #expect(abs(log2(try #require(calibration.fullHz) / 2_400)) < 0.25)
        #expect(abs(calibration.fillSeconds - seconds) < 1)
    }

    @Test func `calibration without audible pitch keeps the pour time`() throws {
        let recorder = CalibrationRecorder()
        for index in 0..<100 { recorder.update(pitch: nil, isPouring: true, time: Double(index) * 0.05, frameSeconds: 0.05) }
        let calibration = try #require(recorder.finish())
        #expect(!calibration.hasPitch)
        #expect(abs(calibration.fillSeconds - 5) < 0.01)
    }

    @Test func `a pour too short to measure gives no calibration`() {
        let recorder = CalibrationRecorder()
        for index in 0..<20 { recorder.update(pitch: nil, isPouring: true, time: Double(index) * 0.05, frameSeconds: 0.05) }
        #expect(recorder.finish() == nil)
    }

    @Test func `a false start long before the pour doesn't cost it its level`() {
        let estimator = FillEstimator(calibration: nil)
        let hop = 0.05
        for index in 0..<20 { _ = estimator.update(pitch: nil, isPouring: true, time: Double(index) * hop, frameSeconds: hop) }
        for index in 20..<120 { _ = estimator.update(pitch: nil, isPouring: false, time: Double(index) * hop, frameSeconds: hop) }
        let pitch = ResonancePitch(hz: 1_000, riseRate: 0.1, strength: 5)
        #expect(estimator.update(pitch: pitch, isPouring: true, time: 6, frameSeconds: hop) != nil)
    }

    @Test func `the lookback starts just before the sound and ignores older noise`() throws {
        var lookback = PourLookback()
        for index in 0..<200 {
            let time = Double(index) * 0.05
            lookback.add(pitch: nil, isPouring: time >= 8, time: time, frameSeconds: 0.05)
        }
        let first = try #require(lookback.framesOfThisPour(now: 9.95).first)
        #expect(abs(first.time - (8 - PourLookback.classifierDelaySeconds)) < 0.06)
    }

    @Test func `the lookback never reaches further back than its limit`() throws {
        var lookback = PourLookback()
        for index in 0..<200 { lookback.add(pitch: nil, isPouring: true, time: Double(index) * 0.05, frameSeconds: 0.05) }
        let first = try #require(lookback.framesOfThisPour(now: 9.95).first)
        #expect(abs(first.time - (9.95 - PourLookback.maximumSeconds)) < 0.06)
    }

    /// Feeds silence, so no pitch is found and the level comes from pour time alone.
    private func feed(_ tracker: AcousticFillTracker, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try #require(buffer.floatChannelData)[0].update(repeating: 0, count: Int(frames))
        tracker.analyze(buffer)
    }

    private nonisolated final class LastLevel: @unchecked Sendable {
        var fraction: Double?
    }

    @Test func `confirming a pour keeps the water poured before it was noticed`() throws {
        let last = LastLevel()
        let tracker = AcousticFillTracker(calibration: FillCalibration(emptyHz: nil, fullHz: nil, fillSeconds: 10), calibrating: false) { reading, _ in
            last.fraction = reading?.fraction
        }
        try feed(tracker, seconds: 2)   // The room before the pour must not count.
        tracker.setPouringConfidence(0.8)
        try feed(tracker, seconds: 0.1)
        _ = tracker.restartPour()
        try feed(tracker, seconds: 1)
        let expected = (PourLookback.classifierDelaySeconds + 0.1 + 1) / 10
        #expect(abs(try #require(last.fraction) - expected) < 0.025)
    }
}

// MARK: - Engine

@MainActor
struct PourEngineTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)

    func reading(_ confidence: Double, at seconds: Double) -> SensorReading {
        SensorReading(sensor: .microphone, timestamp: start.addingTimeInterval(seconds), status: .active,
                      source: .trainedModel(version: "test"), pouringConfidence: confidence)
    }

    func fill(_ fraction: Double, rate: Double = 0.1, uncertainty: Double = 0.1) -> FillReading {
        FillReading(fraction: fraction, uncertainty: uncertainty, ratePerSecond: rate, method: .pitchCalibrated)
    }

    func makeEngine() -> (PourEstimationEngine, () -> [PourEvent]) {
        let engine = PourEstimationEngine()
        var events: [PourEvent] = []
        engine.onEvent = { events.append($0) }
        return (engine, { events })
    }

    /// Enough confident sound for the start to count as a real pour.
    func confirmPour(_ engine: PourEstimationEngine) {
        engine.ingest(reading(0.9, at: 0))
        engine.ingest(reading(0.9, at: PourEstimationEngine.confirmPourSeconds))
    }

    @Test func `a sound that isn't confirmed as a pour can't say the glass is full`() {
        let (engine, events) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
        engine.ingest(fill(0.95))
        #expect(engine.state == .pouring)
        #expect(events() == [.listening, .pouringDetected])
    }

    @Test func `a false start that fades is forgotten, so the real pour starts from 0`() {
        let (engine, _) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
        engine.ingest(fill(0.6))
        #expect(engine.fillPercent == 60)
        engine.ingest(reading(0.1, at: 0.25))
        engine.ingest(reading(0.1, at: 2))
        #expect(engine.state == .preparing)
        #expect(!engine.pourStarted)
        #expect(engine.fillPercent == nil)
        engine.ingest(fill(0.6))
        #expect(engine.fillPercent == nil, "the old estimate no longer counts")
        engine.ingest(reading(0.9, at: 20))
        #expect(engine.pourStarted, "a new start restarts the level")
    }

    @Test func `a confirmed pour keeps its level through a pause`() {
        let (engine, _) = makeEngine()
        engine.begin()
        confirmPour(engine)
        engine.ingest(fill(0.4, rate: 0))
        engine.ingest(reading(0.1, at: 1.25))
        engine.ingest(reading(0.1, at: 2.8))
        #expect(engine.state == .preparing)
        #expect(engine.pourStarted)
        #expect(engine.fillPercent == 40)
    }

    @Test func `a long weak pour is still confirmed and can stop`() {
        let (engine, events) = makeEngine()
        engine.targetPercent = 90
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
        for second in stride(from: 0.25, through: PourEstimationEngine.confirmPourAnySeconds, by: 0.25) {
            engine.ingest(reading(0.45, at: second))
        }
        engine.ingest(fill(0.95))
        #expect(engine.state == .complete)
        #expect(events().last == .complete)
    }

    @Test func `a pour starts by sound alone, with no camera`() {
        let (engine, events) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.95, at: 0))
        #expect(engine.state == .pouring)
        #expect(events() == [.listening, .pouringDetected])
    }

    @Test func `a cup in view lets a slightly weaker sound start the pour`() {
        let (engine, events) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.67, at: 0))
        #expect(engine.state == .preparing, "0.67 alone isn't enough")
        engine.cupSeen()
        engine.cupSeen()
        engine.ingest(reading(0.67, at: 0.25))
        #expect(engine.state == .pouring)
        #expect(events() == [.listening, .cupFound, .pouringDetected], "cup found is said once")
        engine.end()
        engine.begin()
        #expect(!engine.cupFound, "every pour looks for the cup again")
    }

    @Test func `the level stays at nothing until the pour is heard`() {
        let (engine, _) = makeEngine()
        engine.begin()
        engine.ingest(fill(0.6))
        #expect(engine.fillPercent == nil, "noise before the pour isn't a level")
        engine.ingest(reading(0.9, at: 0))
        engine.ingest(fill(0.1))
        #expect(engine.fillPercent == 10)
    }

    @Test func `the stop alert fires during a pause if the level still climbs`() {
        let (engine, events) = makeEngine()
        engine.targetPercent = 90
        engine.begin()
        confirmPour(engine)
        engine.ingest(reading(0.1, at: 1.25))
        engine.ingest(reading(0.1, at: 2.8))
        #expect(engine.state == .preparing, "the classifier lost the pour")
        engine.ingest(fill(0.95))
        #expect(engine.state == .complete)
        #expect(events().last == .complete)
    }

    @Test func `pouring with no level estimate is said out loud, once per gap`() {
        let (engine, events) = makeEngine()
        engine.begin()
        for second in stride(from: 0.0, through: 3.5, by: 0.25) { engine.ingest(reading(0.9, at: second)) }
        #expect(events().filter { $0 == .levelUnknown }.count == 1)
        engine.ingest(fill(0.3, rate: 0))
        engine.ingest(reading(0.9, at: 3.75))
        engine.ingest(nil, at: .now.addingTimeInterval(2))
        for second in stride(from: 4.0, through: 7.5, by: 0.25) { engine.ingest(reading(0.9, at: second)) }
        #expect(events().filter { $0 == .levelUnknown }.count == 2, "warned again after the level came back and was lost")
    }

    @Test func `a false start doesn't make the real pour warn at once`() {
        let (engine, events) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
        engine.ingest(reading(0.1, at: 0.25))
        engine.ingest(reading(0.1, at: 2))
        #expect(engine.state == .preparing)
        engine.ingest(reading(0.9, at: 20))
        engine.ingest(reading(0.9, at: 20.25))
        #expect(!events().contains(.levelUnknown))
    }

    @Test func `sounds Senso is unsure about must last longer before the level warning`() {
        let (engine, events) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
        for second in stride(from: 0.25, through: 3.75, by: 0.25) { engine.ingest(reading(0.45, at: second)) }
        #expect(engine.state == .pouring)
        #expect(!events().contains(.levelUnknown), "3.75 s of weak sound isn't enough")
        engine.ingest(reading(0.45, at: 4))
        #expect(events().filter { $0 == .levelUnknown }.count == 1, "but a pour with no level must still be warned about")
    }

    @Test func `a jump past several milestones says only the highest`() {
        let (engine, events) = makeEngine()
        engine.begin()
        confirmPour(engine)
        engine.ingest(fill(0.55, rate: 0))
        #expect(events().filter { if case .milestone = $0 { true } else { false } } == [.milestone(50)])
    }

    @Test func `pouring needs a confident reading and pauses only after a quiet stretch`() {
        let (engine, events) = makeEngine()
        engine.begin()
        #expect(engine.state == .preparing)
        engine.ingest(reading(0.5, at: 0))
        #expect(engine.state == .preparing, "0.5 is below the start threshold")
        engine.ingest(reading(0.7, at: 0.25))
        #expect(engine.state == .pouring)
        engine.ingest(reading(0.45, at: 0.5))
        #expect(engine.state == .pouring, "above the keep threshold")
        engine.ingest(reading(0.1, at: 1))
        engine.ingest(reading(0.1, at: 2))
        #expect(engine.state == .pouring, "quiet for only 1 s")
        engine.ingest(reading(0.1, at: 2.6))
        #expect(engine.state == .preparing)
        #expect(events() == [.listening, .pouringDetected, .pouringPaused])
    }

    @Test func `milestones are announced once and the alert band starts at 70`() {
        let (engine, events) = makeEngine()
        engine.begin()
        confirmPour(engine)
        for fraction in [0.2, 0.26, 0.3, 0.26, 0.51, 0.72] { engine.ingest(fill(fraction, rate: 0)) }
        #expect(engine.fillPercent == 72)
        #expect(engine.state == .approachingTarget)
        #expect(events() == [.listening, .pouringDetected, .milestone(25), .milestone(50), .approachingTarget])
    }

    @Test func `stop fires early by the fill rate, reaction time and uncertainty`() {
        let (engine, events) = makeEngine()
        engine.targetPercent = 90
        engine.begin()
        confirmPour(engine)
        // 0.75 + 0.1 × 0.9 + 0.1 / 2 = 0.89: not yet.
        engine.ingest(fill(0.75))
        #expect(engine.state == .approachingTarget)
        // 0.77 + 0.09 + 0.05 = 0.91: stop now, 13 points before the target is actually reached.
        engine.ingest(fill(0.77))
        #expect(engine.state == .complete)
        #expect(events().last == .complete)
    }

    @Test func `a lost estimate shows no number instead of a stale one`() {
        let (engine, _) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
        engine.ingest(fill(0.4, rate: 0), at: start)
        #expect(engine.fillPercent == 40)
        engine.ingest(nil, at: start.addingTimeInterval(0.5))
        #expect(engine.fillPercent == 40, "brief gap")
        engine.ingest(nil, at: start.addingTimeInterval(1.5))
        #expect(engine.fillPercent == nil)
    }

    @Test func `an interruption makes the state uncertain and says so`() {
        let (engine, events) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
        engine.microphoneChanged(.interrupted)
        #expect(engine.state == .uncertain)
        engine.ingest(reading(0.9, at: 1))
        #expect(engine.state == .uncertain, "readings don't override an interrupted microphone")
        engine.microphoneChanged(.running)
        #expect(engine.state == .preparing)
        #expect(events().contains(.lostMicrophone))
    }

    @Test func `a calibration pour never shows a number or stops on its own`() {
        let (engine, events) = makeEngine()
        engine.calibrating = true
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
        engine.ingest(fill(0.99))
        #expect(engine.fillPercent == nil)
        #expect(engine.state == .pouring)
        #expect(!events().contains(.complete))
    }
}

// MARK: - Haptics

struct HapticTests {
    @Test(arguments: [
        (PourState.ready, PourState.preparing, SensoryFeedback?.some(.start)),
        (.complete, .preparing, .start),
        (.pouring, .complete, .success),
        (.approachingTarget, .ready, .stop),
        (.complete, .ready, .impact(weight: .light)),
        (.pouring, .uncertain, .warning),
        (.preparing, .unavailable, .error),
        // The microphone is measuring: no vibration.
        (.preparing, .pouring, nil),
        (.pouring, .approachingTarget, nil),
        (.pouring, .preparing, nil),
        (.uncertain, .preparing, nil),
    ] as [(PourState, PourState, SensoryFeedback?)])
    func `the iPhone vibrates only when the microphone isn't measuring`(old: PourState, new: PourState, expected: SensoryFeedback?) {
        #expect(PourFeedback.haptic(from: old, to: new) == expected)
    }
}

// MARK: - Camera framing

struct FramingCueTests {
    @Test(arguments: [
        (false, CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), FramingCue.noCup),
        (true, nil, .noCup),
        (true, CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.2), .moveLeft),
        (true, CGRect(x: 0.75, y: 0.4, width: 0.2, height: 0.2), .moveRight),
        (true, CGRect(x: 0.4, y: 0.75, width: 0.2, height: 0.2), .moveUp),
        (true, CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.2), .moveDown),
        (true, CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), .moveCloser),
        (true, CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), .moveBack),
        (true, CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3), .centered),
    ] as [(Bool, CGRect?, FramingCue)])
    func `framing cue points the phone toward the cup`(cupSeen: Bool, box: CGRect?, expected: FramingCue) {
        #expect(CameraCapture.cue(cupSeen: cupSeen, box: box) == expected)
    }
}

struct FillPauseTests {
    @Test func `a paused pour holds its level instead of extrapolating`() throws {
        let estimator = FillEstimator(calibration: FillCalibration(emptyHz: 500, fullHz: 2_500, fillSeconds: 10))
        let frame = 0.05
        // 4 s of pitch rising along the calibrated line, then the pour pauses for 3 s.
        var last: FillReading?
        for index in 0..<80 {
            let time = Double(index) * frame
            let period = 1.0 / 500 + (1.0 / 2_500 - 1.0 / 500) * time / 10
            last = estimator.update(pitch: ResonancePitch(hz: 1 / period, riseRate: 0.1, strength: 5), isPouring: true, time: time, frameSeconds: frame)
        }
        let before = try #require(last)
        var paused: FillReading?
        for index in 80..<140 {
            paused = estimator.update(pitch: nil, isPouring: false, time: Double(index) * frame, frameSeconds: frame)
        }
        let held = try #require(paused)
        #expect(abs(held.fraction - before.fraction) < 0.03)
        #expect(held.ratePerSecond == 0)
    }
}

// MARK: - Camera background colours

struct SceneColorTests {
    /// A 12 × 9 landscape BGRA buffer where `paint(x, y)` gives each pixel's RGB (0…255).
    func buffer(_ paint: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        (0..<9).flatMap { y in (0..<12).flatMap { x -> [UInt8] in
            let (r, g, b) = paint(x, y)
            return [b, g, r, 255]
        } }
    }

    func grid(_ pixels: [UInt8]) -> [SIMD3<Float>] {
        pixels.withUnsafeBytes { CameraCapture.portraitGrid(bgra: $0, width: 12, height: 9, bytesPerRow: 48, step: 1) }
    }

    @Test func `the sensor's left edge is the top of the upright picture`() {
        let colors = grid(buffer { x, _ in x < 4 ? (255, 0, 0) : (0, 0, 0) })
        #expect(colors[0...2].allSatisfy { $0 == SIMD3(1, 0, 0) }, "top row red")
        #expect(colors[3...].allSatisfy { $0 == .zero })
    }

    @Test func `the sensor's top edge is the right side of the upright picture`() {
        let colors = grid(buffer { _, y in y < 3 ? (0, 0, 255) : (0, 0, 0) })
        #expect([2, 5, 8].allSatisfy { colors[$0] == SIMD3(0, 0, 1) }, "right column blue")
        #expect([0, 1, 3, 4, 6, 7].allSatisfy { colors[$0] == .zero })
    }

    @Test func `bright colours are darkened so white text keeps 7 to 1, keeping their hue`() {
        let white = CameraCapture.capped(SIMD3(1, 1, 1))
        #expect(white.max() <= CameraCapture.maxChannel + 1e-6)
        // WCAG contrast of white text on the brightest allowed background.
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(white.x) + 0.7152 * linear(white.y) + 0.0722 * linear(white.z)
        #expect((1.05 / (luminance + 0.05)) >= 7)
        let orange = CameraCapture.capped(SIMD3(1, 0.5, 0))
        #expect(abs(orange.y / orange.x - 0.5) < 1e-6, "same hue")
        let dark = SIMD3<Float>(0.1, 0.2, 0.3)
        #expect(CameraCapture.capped(dark) == dark, "dark colours are untouched")
    }
}

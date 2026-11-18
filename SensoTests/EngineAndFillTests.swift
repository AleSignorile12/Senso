import Foundation
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
        engine.ingest(reading(0.6, at: 0))
        #expect(engine.state == .preparing, "0.6 alone isn't enough")
        engine.cupSeen()
        engine.cupSeen()
        engine.ingest(reading(0.6, at: 0.25))
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
        engine.ingest(reading(0.9, at: 0))
        engine.ingest(reading(0.1, at: 1))
        engine.ingest(reading(0.1, at: 2.6))
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

    @Test func `a jump past several milestones says only the highest`() {
        let (engine, events) = makeEngine()
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
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
        engine.ingest(reading(0.9, at: 0))
        for fraction in [0.2, 0.26, 0.3, 0.26, 0.51, 0.72] { engine.ingest(fill(fraction, rate: 0)) }
        #expect(engine.fillPercent == 72)
        #expect(engine.state == .approachingTarget)
        #expect(events() == [.listening, .pouringDetected, .milestone(25), .milestone(50), .approachingTarget])
    }

    @Test func `stop fires early by the fill rate, reaction time and uncertainty`() {
        let (engine, events) = makeEngine()
        engine.targetPercent = 90
        engine.begin()
        engine.ingest(reading(0.9, at: 0))
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

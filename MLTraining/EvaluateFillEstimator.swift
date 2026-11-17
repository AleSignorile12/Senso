// EvaluateFillEstimator.swift
// Replays the Sound of Water recordings (External/sound-of-water) through the app's own fill code
// (SensoApp/ML/FillEstimator.swift) and reports how full the container really was when Senso would
// have warned, assuming each audio file (trimmed to the pour) ends when the container is full and the
// flow is roughly constant, so true fill ≈ t / duration.
//
// CAVEAT: the dataset never says pours end at "full", and pours into the same cup range from 3.5 s to 17 s,
// so many clearly don't. Treat these numbers as a rough sanity check, not as accuracy. Measuring fill
// accuracy needs recordings with a known level at the end (Data Collection mode, ground truth "measured").
// Also reports how often the tracked pitch matches the pitch physics predicts from the container's
// measured height and top diameter (cylinder approximation, so conical cups score lower).
//
//   cd MLTraining
//   xcrun swiftc -O -parse-as-library ../SharedModels/SensoModels.swift ../SensoApp/ML/FillEstimator.swift EvaluateFillEstimator.swift -o evaluate-fill
//   ./evaluate-fill [--target 0.9]

import AVFoundation
import Foundation

struct Clip {
    var id: String
    var file: URL
    var start = 0.0
    var end: Double
    var container: String
    var heightMeters: Double?
    var radiusMeters: Double?
}

struct PourTrace {
    var clip: Clip
    var times: [Double] = []
    var pitches: [ResonancePitch?] = []
    var frameSeconds = 0.0
}

@main
struct EvaluateFillEstimator {
    static let root = URL(fileURLWithPath: "External/sound-of-water")

    static func main() throws {
        let args = CommandLine.arguments
        let target = args.firstIndex(of: "--target").flatMap { Double(args[$0 + 1]) } ?? 0.9
        let clips = try loadClips()
        print("Clips with constant flow and audio: \(clips.count) from \(Set(clips.map(\.container)).count) containers")

        let traces = try clips.map(trace)
        let byContainer = Dictionary(grouping: traces, by: \.clip.container)

        var uncalibrated: [Double?] = []
        var calibrated: [Double?] = []
        var timeOnly: [Double?] = []
        var firstOfBoth: [Double?] = []
        var calibrationFailures = 0
        for (_, group) in byContainer.sorted(by: { $0.key < $1.key }) {
            for trace in group {
                uncalibrated.append(trueFillAtWarning(trace, calibration: nil, target: target))
            }
            // Calibrate on one pour of the container, test on the others: what a user would experience.
            guard group.count >= 2 else { continue }
            let calibrationTrace = group[0]
            let pitchCalibration = calibrate(calibrationTrace).flatMap { $0.hasPitch ? $0 : nil }
            if pitchCalibration == nil { calibrationFailures += 1 }
            let calibrationSeconds = calibrationTrace.clip.end - calibrationTrace.clip.start
            for trace in group.dropFirst() {
                // Time needs no pitch: just how long the calibration pour took.
                let pourSeconds = trace.clip.end - trace.clip.start
                let warnAt = target * calibrationSeconds
                let byTime = warnAt <= pourSeconds ? warnAt / pourSeconds : nil
                timeOnly.append(byTime)
                guard let pitchCalibration else { continue }
                let byPitch = trueFillAtWarning(trace, calibration: pitchCalibration, target: target)
                calibrated.append(byPitch)
                firstOfBoth.append([byPitch, byTime].compactMap { $0 }.min())
            }
        }

        print("\nTrue fill when Senso would say \"\(Int(target * 100))%\" (nil = never warned before the cup was full)")
        report("Pitch, uncalibrated (no setup)", uncalibrated)
        report("Pitch, calibrated on another pour of the same cup", calibrated)
        report("Time only (one timed pour per cup, no pitch needed)", timeOnly)
        report("Whichever warns first: calibrated pitch or time", firstOfBoth)
        print("\nCalibration pours that failed (too little pitch): \(calibrationFailures)")
        reportTracking(traces)
    }

    // MARK: - Data

    static func loadClips() throws -> [Clip] {
        var clips: [Clip] = []
        for split in ["train", "test_I", "test_II", "test_III"] {
            let text = try String(contentsOf: root.appending(path: "splits/\(split).csv"), encoding: .utf8)
            let rows = parseCSV(text)
            guard let header = rows.first else { continue }
            func column(_ name: String) -> Int { header.firstIndex(of: name)! }
            for row in rows.dropFirst() where row.count == header.count {
                guard row[column("flow_rate_appx")] == "constant",
                      let start = Double(row[column("start_time")]), let end = Double(row[column("end_time")]), end - start > 3
                else { continue }
                let file = root.appending(path: "audios/\(row[column("file_name")].split(separator: "/").last!.replacingOccurrences(of: ".mp4", with: ".wav"))")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let measurements = row[column("measurements")]
                clips.append(Clip(id: row[column("video_id")], file: file, end: end - start, container: row[column("container_id")],
                                  heightMeters: number("net_height", in: measurements).map { $0 / 100 },
                                  radiusMeters: number("diameter_top", in: measurements).map { $0 / 200 }))
            }
        }
        // Splits can overlap; keep each recording once.
        var seen = Set<String>()
        return clips.filter { seen.insert($0.id).inserted }
    }

    /// Reads `'key': 12.5` out of the measurements column (a Python dict literal).
    static func number(_ key: String, in text: String) -> Double? {
        guard let range = text.range(of: "'\(key)': ") else { return nil }
        return Double(text[range.upperBound...].prefix { "0123456789.".contains($0) })
    }

    /// Minimal CSV parser that understands quoted fields (the measurements column contains commas).
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        for character in text {
            switch character {
            case "\"": quoted.toggle()
            case "," where !quoted: row.append(field); field = ""
            case "\n" where !quoted, "\r\n" where !quoted: row.append(field); rows.append(row); row = []; field = ""  // Swift reads CRLF as one Character
            case "\r": break
            default: field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func samples(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channel = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return (Array(channel), file.processingFormat.sampleRate)
    }

    // MARK: - Replay

    /// Pitch for every frame, frames hop by half a frame like the app.
    static func trace(_ clip: Clip) throws -> PourTrace {
        let (audio, rate) = try samples(clip.file)
        let tracker = ResonanceTracker(sampleRate: rate)
        let hop = ResonanceTracker.hopSize
        var trace = PourTrace(clip: clip, frameSeconds: Double(hop) / rate)
        var index = 0
        while index + ResonanceTracker.frameSize <= audio.count {
            let time = Double(index + ResonanceTracker.frameSize) / rate
            let inPour = time >= clip.start && time <= clip.end
            if !inPour { tracker.reset() }
            let pitch = inPour ? tracker.track(Array(audio[index..<(index + ResonanceTracker.frameSize)])) : nil
            trace.times.append(time)
            trace.pitches.append(pitch)
            index += hop
        }
        return trace
    }

    static func calibrate(_ trace: PourTrace) -> FillCalibration? {
        let recorder = CalibrationRecorder()
        for (time, pitch) in zip(trace.times, trace.pitches) {
            let inPour = time >= trace.clip.start && time <= trace.clip.end
            recorder.update(pitch: pitch, isPouring: inPour, time: time, frameSeconds: trace.frameSeconds)
        }
        return recorder.finish()
    }

    /// True fill at the first moment the estimate reaches `target`; nil if it never did before full.
    static func trueFillAtWarning(_ trace: PourTrace, calibration: FillCalibration?, target: Double) -> Double? {
        let estimator = FillEstimator(calibration: calibration)
        let duration = trace.clip.end - trace.clip.start
        for (time, pitch) in zip(trace.times, trace.pitches) where time >= trace.clip.start {
            let inPour = time <= trace.clip.end
            if !inPour { return nil }
            let reading = estimator.update(pitch: pitch, isPouring: true, time: time, frameSeconds: trace.frameSeconds)
            if let reading, reading.fraction >= target {
                return (time - trace.clip.start) / duration
            }
        }
        return nil
    }

    // MARK: - Report

    /// Share of frames, per fill decile, where the tracked pitch is within a quarter octave of physics.
    static func reportTracking(_ traces: [PourTrace]) {
        var hits = Array(repeating: 0, count: 10)
        var tracked = Array(repeating: 0, count: 10)
        var frames = Array(repeating: 0, count: 10)
        for trace in traces {
            guard let height = trace.clip.heightMeters, let radius = trace.clip.radiusMeters else { continue }
            for (time, pitch) in zip(trace.times, trace.pitches) where time <= trace.clip.end {
                let fill = time / trace.clip.end
                let decile = min(9, Int(fill * 10))
                let expected = 343 / (4 * (height * (1 - fill) + 0.62 * radius))
                frames[decile] += 1
                guard let pitch else { continue }
                tracked[decile] += 1
                if abs(log2(pitch.hz / expected)) < 0.25 { hits[decile] += 1 }
            }
        }
        print("\nPitch tracking vs physics (cylinder approximation), by true fill:")
        for decile in 0..<10 where frames[decile] > 0 {
            print(String(format: "  %3d–%3d%%  pitch found %3.0f%% of frames, within ¼ octave of physics %3.0f%%",
                         decile * 10, decile * 10 + 10,
                         Double(tracked[decile]) / Double(frames[decile]) * 100, Double(hits[decile]) / Double(frames[decile]) * 100))
        }
    }

    static func report(_ name: String, _ results: [Double?]) {
        let warned = results.compactMap { $0 }.sorted()
        let missed = results.count - warned.count
        func percentile(_ p: Double) -> String {
            warned.isEmpty ? "n/a" : String(format: "%.0f%%", warned[min(warned.count - 1, Int(Double(warned.count) * p))] * 100)
        }
        let early = warned.filter { $0 < 0.7 }.count
        print("""

        \(name): \(results.count) pours
          warned before full: \(warned.count), never warned (overflow risk): \(missed) (\(String(format: "%.0f%%", Double(missed) / Double(max(1, results.count)) * 100)))
          true fill at warning: 10th pct \(percentile(0.1)) · median \(percentile(0.5)) · 90th pct \(percentile(0.9))
          warned too early (true fill under 70%): \(early)
        """)
    }
}

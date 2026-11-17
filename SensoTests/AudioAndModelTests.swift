// AudioAndModelTests.swift

import AVFoundation
import CoreML
import Foundation
import Synchronization
import Testing
@testable import Senso

/// A 440 Hz sine at the given amplitude, 48 kHz mono float.
private func sine(amplitude: Float, seconds: Double = 1) throws -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(48_000 * seconds)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)[0]
    for i in 0..<Int(frames) { samples[i] = amplitude * sin(2 * .pi * 440 * Float(i) / 48_000) }
    return buffer
}

struct AudioBufferTests {
    @Test func `deep copy is independent of the original`() throws {
        let original = try sine(amplitude: 0.5)
        let copy = try #require(original.deepCopy())
        #expect(copy.frameLength == original.frameLength)
        #expect(copy.floatChannelData![0][1234] == original.floatChannelData![0][1234])
        original.floatChannelData![0][1234] = 0.99
        #expect(copy.floatChannelData![0][1234] != 0.99)
    }

    @Test func `RMS level of a known sine`() throws {
        // A sine of amplitude A has RMS A/√2, so 0.5 → 20·log10(0.3536) ≈ -9.03 dBFS.
        let level = try sine(amplitude: 0.5).rmsDecibels
        #expect(abs(level - (-9.03)) < 0.05)
    }

    @Test func `silence reports the floor`() throws {
        #expect(try sine(amplitude: 0).rmsDecibels == -160)
    }
}

struct WatchSyncTests {
    @Test func `watch messages survive the WCSession dictionary round trip`() throws {
        let sent = WatchToPhoneMessage.motion(.init(isTilting: true, tiltConfidence: 0.8, source: .dspFallback))
        let received = WatchSync.decode(WatchToPhoneMessage.self, from: try WatchSync.message(sent))
        #expect(received == sent)
    }
}

struct DatasetTests {
    let root = URL.temporaryDirectory.appending(path: "senso-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func metadata(_ label: SoundClass, seconds: Double) -> RecordingMetadata {
        RecordingMetadata(label: label, containerType: .mug, material: .ceramic, liquidType: .water,
                          pouringSpeed: .slow, groundTruthType: .estimated, recordedAt: .now,
                          durationSeconds: seconds, sampleRate: 48_000)
    }

    /// Writes a 1.5 s clip the way a recording does and returns it.
    private func recordClip() throws -> URL {
        let writer = WAVWriter(url: .temporaryDirectory.appending(path: "\(UUID().uuidString).wav"))
        writer.write(try sine(amplitude: 0.5, seconds: 1.5))
        let result = writer.finish()
        #expect(result.error == nil)
        #expect(abs(result.seconds - 1.5) < 0.001)
        return writer.url
    }

    @Test func `writer produces a 16-bit WAV with every frame`() throws {
        let file = try AVAudioFile(forReading: try recordClip())
        #expect(file.length == 72_000)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    @Test func `writer refuses a format change mid-recording`() throws {
        let writer = WAVWriter(url: .temporaryDirectory.appending(path: "\(UUID().uuidString).wav"))
        writer.write(try sine(amplitude: 0.5))
        let format44 = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let other = try #require(AVAudioPCMBuffer(pcmFormat: format44, frameCapacity: 441))
        other.frameLength = 441
        writer.write(other)
        #expect(writer.finish().error is DatasetError)
    }

    @MainActor @Test func `saved clip lands in its class folder with a sidecar`() throws {
        let store = DatasetRecorderService(audio: AudioCaptureService(), root: root)
        let saved = try store.save(recordingAt: try recordClip(), metadata: metadata(.pouring, seconds: 1.5))
        #expect(saved.url.deletingLastPathComponent().lastPathComponent == "pouring")
        #expect(FileManager.default.fileExists(atPath: saved.url.deletingPathExtension().appendingPathExtension("json").path))
        #expect(store.recordings == [saved])
    }

    @MainActor @Test func `relabel and rename move the clip and its sidecar`() throws {
        let store = DatasetRecorderService(audio: AudioCaptureService(), root: root)
        let saved = try store.save(recordingAt: try recordClip(), metadata: metadata(.pouring, seconds: 1.5))
        try store.update(saved, name: "kettle click/1", metadata: metadata(.notPouring, seconds: 1.5))

        let moved = try #require(store.recordings.first)
        #expect(store.recordings.count == 1)
        #expect(moved.name == "kettle_click_1")
        #expect(moved.url.deletingLastPathComponent().lastPathComponent == "not_pouring")
        #expect(moved.metadata.label == .notPouring)
        #expect(!FileManager.default.fileExists(atPath: saved.url.path))
        #expect(!FileManager.default.fileExists(atPath: saved.url.deletingPathExtension().appendingPathExtension("json").path))
    }

    @MainActor @Test func `delete removes the clip and its sidecar`() throws {
        let store = DatasetRecorderService(audio: AudioCaptureService(), root: root)
        let saved = try store.save(recordingAt: try recordClip(), metadata: metadata(.backgroundNoise, seconds: 1.5))
        store.delete(saved)
        #expect(store.recordings.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder(.backgroundNoise).path).isEmpty)
    }

    @MainActor @Test func `export zips the dataset folder`() throws {
        let store = DatasetRecorderService(audio: AudioCaptureService(), root: root)
        try store.save(recordingAt: try recordClip(), metadata: metadata(.pouring, seconds: 1.5))
        let zip = try DatasetArchive(root: root).makeZip()
        let size = try #require(try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 1_000)
    }

    @Test(arguments: [("../etc/passwd", "___etc_passwd"), ("  my clip  ", "my_clip"), ("tè-1_ok", "tè-1_ok")])
    func `file names are made safe`(input: String, expected: String) {
        #expect(sanitizedFileName(input) == expected)
    }
}

/// Deterministic noise, so the DSP tests give the same numbers on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

struct AcousticPipelineTests {
    private let rate = 48_000.0

    private func noise(_ amplitude: Float, seconds: Double, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(state: seed)
        return (0..<Int(rate * seconds)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    private func tone(_ amplitude: Float, hz: Float, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * sin(2 * .pi * hz * Float($0) / Float(rate)) }
    }

    /// Feeds samples in ~100 ms buffers, like the engine does, and returns every score.
    private func scores(for samples: [Float]) throws -> [Double] {
        let collected = Mutex<[Double]>([])
        let classifier = DSPAcousticClassifier { reading in
            #expect(reading.source == .dspFallback)
            #expect(reading.fillFraction == nil)
            collected.withLock { $0.append(reading.pouringConfidence) }
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        for start in stride(from: 0, to: samples.count, by: 4_800) {
            let chunk = samples[start..<min(start + 4_800, samples.count)]
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)))
            buffer.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
            classifier.analyze(buffer)
        }
        return collected.withLock { $0 }
    }

    @Test func `broadband noise after a quiet room scores as pouring`() throws {
        let result = try scores(for: noise(0.001, seconds: 1, seed: 1) + noise(0.2, seconds: 2, seed: 2))
        #expect(try #require(result.last) > 0.6)
    }

    @Test func `a loud steady tone does not score as pouring`() throws {
        let result = try scores(for: noise(0.001, seconds: 1, seed: 3) + tone(0.2, hz: 440, seconds: 2))
        #expect(try #require(result.max()) < 0.2)
    }

    @Test func `silence scores zero`() throws {
        #expect(try scores(for: [Float](repeating: 0, count: 48_000)).allSatisfy { $0 == 0 })
    }

    @Test func `slope of a rising line`() {
        #expect(abs(linearSlope([(0, 100), (1, 300), (2, 500)]) - 200) < 1e-9)
        #expect(linearSlope([(0, 5)]) == 0)
    }

    @Test(arguments: [
        (["SensoSoundClassifier_v2", "SensoSoundClassifier_v10", "SensoSoundClassifier_vX", "Other_v99"], "SensoSoundClassifier_v10"),
        (["Other_v1"], nil),
    ])
    func `highest bundled model version wins`(names: [String], expected: String?) {
        #expect(SoundModelLocator.latest(in: names) == expected)
    }

    @MainActor @Test func `the bundled trained model loads and is a sound classifier`() async throws {
        let loaded = try #require(await SoundModelLocator.loadBundledModel())
        #expect(loaded.version == "SensoSoundClassifier_v3")
        _ = try SoundAnalysisClassifier(model: loaded.model, version: loaded.version) { _ in }
    }

    /// Runs the synthetic fixture model (noise = "pouring", tones = "not_pouring") through
    /// SoundAnalysisClassifier, the same path a real bundled model takes.
    private func trainedScores(for samples: [Float]) async throws -> [SensorReading] {
        let testBundle = try #require(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
        let url = try #require(testBundle.url(forResource: "SyntheticToneVsNoise", withExtension: "mlmodelc"))
        let collected = Mutex<[SensorReading]>([])
        let classifier = try SoundAnalysisClassifier(model: try MLModel(contentsOf: url), version: "synthetic") { reading in
            collected.withLock { $0.append(reading) }
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        for start in stride(from: 0, to: samples.count, by: 4_800) {
            let chunk = samples[start..<min(start + 4_800, samples.count)]
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)))
            buffer.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
            classifier.analyze(buffer)
        }
        try await Task.sleep(for: .milliseconds(500))  // results may arrive just after the last buffer
        return collected.withLock { $0 }
    }

    @Test func `trained model readings carry the model version and its confidence`() async throws {
        let noiseReadings = try await trainedScores(for: noise(0.2, seconds: 3, seed: 4))
        let toneReadings = try await trainedScores(for: tone(0.2, hz: 600, seconds: 3))
        #expect(!noiseReadings.isEmpty && !toneReadings.isEmpty)
        #expect(noiseReadings.allSatisfy { $0.source == .trainedModel(version: "synthetic") && $0.status == .active })
        let noiseMean = noiseReadings.map(\.pouringConfidence).reduce(0, +) / Double(noiseReadings.count)
        let toneMean = toneReadings.map(\.pouringConfidence).reduce(0, +) / Double(toneReadings.count)
        #expect(noiseMean > 0.5)
        #expect(toneMean < 0.5)
    }
}

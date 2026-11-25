// DatasetRecorderService.swift
// Records labelled training clips into Documents/Dataset/<class>/<name>.wav, the exact layout
// MLTraining/TrainSensoModels.swift reads, with a <name>.json metadata file next to each clip.
// Clips use the same microphone setup as live pouring (AudioCaptureService), so training audio
// sounds like what the app will hear.

import AVFoundation
import CoreTransferable
import Observation
import UniformTypeIdentifiers

/// One saved clip. Its folder is its label, because that's what the training script trusts.
struct Recording: Identifiable, Equatable {
    var url: URL
    var metadata: RecordingMetadata
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@Observable
final class DatasetRecorderService {
    /// One Create ML analysis window is ~0.975 s, so anything shorter can't train anything.
    static let minimumSeconds = 1.0

    private(set) var recordings: [Recording] = []
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var playingURL: URL?
    /// The last problem to show the user. The view clears it.
    var message: String?

    let audio: AudioCaptureService
    let root: URL

    @ObservationIgnored private var writer: WAVWriter?
    @ObservationIgnored private var pendingMetadata: RecordingMetadata?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let playerDelegate = PlayerDelegate()

    init(audio: AudioCaptureService, root: URL = .documentsDirectory.appending(path: "Dataset", directoryHint: .isDirectory)) {
        self.audio = audio
        self.root = root
        for label in SoundClass.allCases {
            try? FileManager.default.createDirectory(at: folder(label), withIntermediateDirectories: true)
        }
        playerDelegate.onFinish = { [weak self] in self?.playingURL = nil }
        reload()
    }

    func folder(_ label: SoundClass) -> URL {
        root.appending(path: label.rawValue, directoryHint: .isDirectory)
    }

    var counts: [SoundClass: Int] {
        Dictionary(grouping: recordings, by: \.metadata.label).mapValues(\.count)
    }

    // MARK: - Recording

    func startRecording(_ metadata: RecordingMetadata) async {
        guard !isRecording else { return }
        stopPlayback()
        message = nil
        let writer = WAVWriter(url: .temporaryDirectory.appending(path: "\(UUID().uuidString).wav"))
        await audio.start { buffer, _ in writer.write(buffer) }
        guard audio.state == .running else {
            message = audio.state == .permissionDenied
                ? String(localized: "Microphone access is off. Turn it on in Settings › Sensow.")
                : String(localized: "The microphone isn't available right now.")
            return
        }
        var metadata = metadata
        metadata.recordedAt = .now
        self.writer = writer
        pendingMetadata = metadata
        recordingStartedAt = metadata.recordedAt
        isRecording = true
    }

    func stopRecording() {
        guard isRecording, let writer, var metadata = pendingMetadata else { return }
        // stop() drains the audio queue, so from here on nothing else touches the writer.
        audio.stop()
        isRecording = false
        recordingStartedAt = nil
        self.writer = nil
        pendingMetadata = nil

        let result = writer.finish()
        do {
            if let error = result.error { throw error }
            guard result.seconds >= Self.minimumSeconds else { throw DatasetError.tooShort }
            metadata.durationSeconds = result.seconds
            metadata.sampleRate = result.sampleRate
            try save(recordingAt: writer.url, metadata: metadata)
        } catch {
            try? FileManager.default.removeItem(at: writer.url)
            message = error.localizedDescription
        }
    }

    /// Moves a finished temporary WAV into its class folder and writes its metadata.
    @discardableResult
    func save(recordingAt temporary: URL, metadata: RecordingMetadata) throws -> Recording {
        let url = uniqueURL(defaultName(metadata), label: metadata.label)
        try FileManager.default.moveItem(at: temporary, to: url)
        try writeSidecar(metadata, for: url)
        reload()
        // Return what's on disk: the JSON date drops fractions of a second.
        return recordings.first { $0.url == url } ?? Recording(url: url, metadata: metadata)
    }

    // MARK: - Editing

    /// Renames and/or relabels a clip. A new label moves it to that class folder.
    func update(_ recording: Recording, name: String, metadata: RecordingMetadata) throws {
        let clean = sanitizedFileName(name)
        guard !clean.isEmpty else { throw DatasetError.invalidName }
        let target = folder(metadata.label).appending(path: clean + ".wav")
        if target.path != recording.url.path {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw DatasetError.nameTaken }
            if playingURL == recording.url { stopPlayback() }
            try FileManager.default.moveItem(at: recording.url, to: target)
            try? FileManager.default.removeItem(at: sidecarURL(for: recording.url))
        }
        try writeSidecar(metadata, for: target)
        reload()
    }

    func delete(_ recording: Recording) {
        if playingURL == recording.url { stopPlayback() }
        do {
            try FileManager.default.removeItem(at: recording.url)
            try? FileManager.default.removeItem(at: sidecarURL(for: recording.url))
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    func reload() {
        recordings = SoundClass.allCases.flatMap { label in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder(label), includingPropertiesForKeys: nil)) ?? []
            return files
                .filter { $0.pathExtension.lowercased() == "wav" }
                .map { url in
                    var metadata = readSidecar(for: url) ?? fallbackMetadata(for: url, label: label)
                    metadata.label = label  // a clip moved in the Files app keeps its new folder's label
                    return Recording(url: url, metadata: metadata)
                }
        }
        .sorted { $0.metadata.recordedAt > $1.metadata.recordedAt }
    }

    // MARK: - Playback

    func togglePlayback(_ recording: Recording) {
        guard !isRecording else { return }
        if playingURL == recording.url {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            // AudioCaptureService sets its own category again on the next start.
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: recording.url)
            player.delegate = playerDelegate
            player.play()
            self.player = player
            playingURL = recording.url
        } catch {
            message = error.localizedDescription
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    // MARK: - Files

    private func defaultName(_ metadata: RecordingMetadata) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return [metadata.label.rawValue, metadata.containerType.rawValue, metadata.liquidType.rawValue,
                stamp.string(from: metadata.recordedAt)].joined(separator: "_")
    }

    private func uniqueURL(_ name: String, label: SoundClass) -> URL {
        var url = folder(label).appending(path: name + ".wav")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder(label).appending(path: "\(name)-\(counter).wav")
            counter += 1
        }
        return url
    }

    private func sidecarURL(for clip: URL) -> URL {
        clip.deletingPathExtension().appendingPathExtension("json")
    }

    private func writeSidecar(_ metadata: RecordingMetadata, for clip: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: sidecarURL(for: clip), options: .atomic)
    }

    private func readSidecar(for clip: URL) -> RecordingMetadata? {
        guard let data = try? Data(contentsOf: sidecarURL(for: clip)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingMetadata.self, from: data)
    }

    /// For a WAV added from the Files app without a .json next to it.
    private func fallbackMetadata(for clip: URL, label: SoundClass) -> RecordingMetadata {
        let modified = (try? clip.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return RecordingMetadata(label: label, containerType: .other, material: .other, liquidType: .other,
                                 pouringSpeed: .medium, groundTruthType: .unlabelled,
                                 recordedAt: modified ?? .distantPast, durationSeconds: 0, sampleRate: 0)
    }
}

/// Letters, digits, "-" and "_" only, so names are safe on iPhone, Mac and in zip files.
nonisolated func sanitizedFileName(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
    return String(String.UnicodeScalarView(scalars.map { allowed.contains($0) ? $0 : "_" }))
}

nonisolated enum DatasetError: LocalizedError {
    case tooShort, formatChanged, noAudio, invalidName, nameTaken

    var errorDescription: String? {
        switch self {
        case .tooShort: String(localized: "The recording was shorter than 1 second, so it wasn't saved.")
        case .formatChanged: String(localized: "The audio route changed during recording (for example, AirPods connected), so it wasn't saved. Record again.")
        case .noAudio: String(localized: "No audio arrived from the microphone.")
        case .invalidName: String(localized: "Use letters, numbers, - or _ in the name.")
        case .nameTaken: String(localized: "A recording with that name and label already exists.")
        }
    }
}

// MARK: - WAV writing (off the main actor)

/// Writes microphone buffers to a 16-bit PCM WAV file.
/// `@unchecked Sendable`: `write` runs only on the audio processing queue, and `finish` runs only after
/// AudioCaptureService.stop() has drained that queue.
nonisolated final class WAVWriter: @unchecked Sendable {
    struct Result {
        var seconds: Double
        var sampleRate: Double
        var error: (any Error)?
    }

    let url: URL
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var failure: (any Error)?

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard failure == nil else { return }
        do {
            if file == nil {
                // The file takes the mic's own rate and channel count, so nothing is resampled.
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: buffer.format.sampleRate,
                    AVNumberOfChannelsKey: buffer.format.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            guard let file,
                  buffer.format.sampleRate == file.processingFormat.sampleRate,
                  buffer.format.channelCount == file.processingFormat.channelCount
            else { throw DatasetError.formatChanged }
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            failure = error
        }
    }

    /// Closes the file and reports what was written.
    func finish() -> Result {
        let sampleRate = file?.processingFormat.sampleRate ?? 0
        file = nil  // releasing the AVAudioFile closes it
        guard sampleRate > 0 else { return Result(seconds: 0, sampleRate: 0, error: failure ?? DatasetError.noAudio) }
        return Result(seconds: Double(frames) / sampleRate, sampleRate: sampleRate, error: failure)
    }
}

// MARK: - Export

/// The whole Dataset folder as one .zip, built only when the user actually shares it.
/// Unzipped on a Mac it gives Dataset/<class>/…, ready for MLTraining.
nonisolated struct DatasetArchive: Transferable {
    let root: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { archive in
            SentTransferredFile(try archive.makeZip())
        }
    }

    func makeZip() throws -> URL {
        let destination = URL.temporaryDirectory.appending(path: "Senso-Dataset.zip")
        try? FileManager.default.removeItem(at: destination)
        var coordinatorError: NSError?
        var copyError: (any Error)?
        // .forUploading hands back a zip of the folder that only exists inside this block, so copy it out.
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinatorError) { zip in
            do { try FileManager.default.copyItem(at: zip, to: destination) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
        return destination
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }
}

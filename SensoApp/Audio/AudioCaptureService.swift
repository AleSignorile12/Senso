// AudioCaptureService.swift
// Owns the microphone: AVAudioSession setup, the AVAudioEngine tap, and route/interruption handling.
//
// Threading: UI state lives on the main actor. Audio buffers never touch it. The engine's tap hands a
// copy of each buffer to `AudioTapProcessor`, which runs every consumer on one private serial queue.

import Accelerate
import AVFoundation
import Observation
import os

/// Receives every microphone buffer on the audio processing queue, never on the main thread.
/// `buffer.format` can change after a route change (for example AirPods connecting), so compare it
/// and rebuild anything format-dependent. Must not block on the main thread.
typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

nonisolated private let log = Logger(subsystem: "com.senso.app", category: "audio")

@Observable
final class AudioCaptureService {
    enum State: Equatable {
        case idle
        case running
        case interrupted       // a phone call or Siri took the mic; resumes when the system allows
        case permissionDenied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Loudness of the mic in dBFS, refreshed about 10 times a second. -160 means silence.
    private(set) var inputLevelDB: Float = -160
    /// For example "iPhone Microphone → AirPods Pro".
    private(set) var routeDescription = ""
    /// True when guidance plays in headphones or AirPods instead of the speaker.
    private(set) var isHeadphoneOutput = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let session = AVAudioSession.sharedInstance()
    @ObservationIgnored private var processor: AudioTapProcessor?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        observeSystemEvents()
        updateRoute()
    }

    /// Asks for mic permission if needed, then starts listening. `onBuffer` runs off the main thread.
    func start(onBuffer: @escaping AudioBufferHandler) async {
        guard state != .running else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .permissionDenied
            return
        }
        processor = AudioTapProcessor(handler: onBuffer) { [weak self] decibels in
            Task { @MainActor in self?.inputLevelDB = decibels }
        }
        do {
            try configureSession()
            try startEngine()
            state = .running
        } catch {
            log.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops listening. When this returns, `onBuffer` has finished its last call and won't be called again.
    /// `releaseSession: false` keeps the audio session for a moment, so a spoken alert isn't cut off;
    /// call `releaseSession()` once it has played.
    func stop(releaseSession: Bool = true) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processor?.drain()
        processor = nil
        inputLevelDB = -160
        state = .idle
        if releaseSession { self.releaseSession() }
    }

    /// Lets music the user was playing come back to full volume. Does nothing while capturing.
    func releaseSession() {
        guard state == .idle else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Session and engine

    private func configureSession() throws {
        // .measurement turns off iOS voice processing and automatic gain, which would
        // otherwise treat pouring sounds as noise and filter them out.
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
        )
        try session.setActive(true)
        preferBuiltInMic()
        updateRoute()
    }

    /// The phone lies next to the cup, so listen with the phone's own mic even when AirPods are
    /// connected. AirPods then stay an output for spoken guidance.
    private func preferBuiltInMic() {
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        do {
            try session.setPreferredInput(builtIn)
        } catch {
            log.error("Could not select built-in mic: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startEngine() throws {
        guard let processor else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        input.removeTap(onBus: 0)
        processor.installTap(on: input, format: format)
        engine.prepare()
        try engine.start()
    }

    private func restartEngine() {
        engine.stop()
        do {
            try startEngine()
            state = .running
        } catch {
            log.error("Audio restart failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        // Each block runs on the main queue (queue: .main), so assumeIsolated is safe and traps if not.
        observers = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                MainActor.assumeIsolated { self?.handleRouteChange(reason) }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let began = rawType == AVAudioSession.InterruptionType.began.rawValue
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                MainActor.assumeIsolated { self?.handleInterruption(began: began, shouldResume: shouldResume) }
            },
            // The engine stops itself when the hardware format changes (new route, new sample rate).
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .running else { return }
                    self.restartEngine()
                }
            },
        ]
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        // AirPods connecting would otherwise move input to the AirPods mic, far from the cup.
        if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable { preferBuiltInMic() }
        updateRoute()
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            // The system has already stopped the engine.
            if state == .running { state = .interrupted }
        } else if state == .interrupted, shouldResume {
            do {
                try session.setActive(true)
                restartEngine()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        // Ended without shouldResume: stay .interrupted, so the user decides when to start again.
    }

    private func updateRoute() {
        let route = session.currentRoute
        let input = route.inputs.first?.portName ?? String(localized: "No microphone")
        let output = route.outputs.first?.portName ?? String(localized: "No speaker")
        routeDescription = "\(input) → \(output)"
        let headphonePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        isHeadphoneOutput = route.outputs.contains { headphonePorts.contains($0.portType) }
    }
}

enum CaptureError: LocalizedError {
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .noMicrophone: String(localized: "No microphone input is available.")
        }
    }
}

// MARK: - Off-main-actor processing

/// Installs the engine tap and runs consumers on one serial queue.
/// `@unchecked Sendable`: its only mutable state (`lastLevelReport`) is touched only on `queue`.
nonisolated final class AudioTapProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.senso.audio.processing", qos: .userInteractive)
    private let handler: AudioBufferHandler
    private let reportLevel: @Sendable (Float) -> Void
    private var lastLevelReport: TimeInterval = 0

    init(handler: @escaping AudioBufferHandler, reportLevel: @escaping @Sendable (Float) -> Void) {
        self.handler = handler
        self.reportLevel = reportLevel
    }

    /// Lives here, not in the main-actor service: the tap block is non-Sendable, and a closure written
    /// inside main-actor code would be main-actor isolated and trap when the audio thread calls it.
    func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let tap: AVAudioNodeTapBlock = { [self] buffer, time in
            // Don't keep the engine's buffer past this callback: hand our queue a copy.
            guard let copy = buffer.deepCopy() else { return }
            let box = BufferBox(buffer: copy, time: time)
            queue.async { self.process(box) }
        }
        // shortcut: iOS often ignores bufferSize and delivers ~100 ms buffers; fine for ~1 s analysis windows.
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
    }

    /// Waits for queued buffers to finish. Call after removing the tap.
    func drain() { queue.sync {} }

    private func process(_ box: BufferBox) {
        handler(box.buffer, box.time)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelReport >= 0.1 {
            lastLevelReport = now
            reportLevel(box.buffer.rmsDecibels)
        }
    }
}

/// Carries one copied buffer to the processing queue.
/// `@unchecked Sendable`: after the copy, only the processing queue ever touches it.
nonisolated private struct BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime
}

nonisolated extension AVAudioPCMBuffer {
    /// Independent copy of a float PCM buffer (the input node always delivers float).
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let source = floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength),
              let destination = copy.floatChannelData
        else { return nil }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        // Interleaved audio keeps every channel in buffer 0.
        let buffers = format.isInterleaved ? 1 : channels
        let samples = format.isInterleaved ? Int(frameLength) * channels : Int(frameLength)
        for index in 0..<buffers {
            destination[index].update(from: source[index], count: samples)
        }
        return copy
    }

    /// Loudness of the first channel in dBFS. -160 means silence.
    var rmsDecibels: Float {
        guard frameLength > 0, let data = floatChannelData else { return -160 }
        let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: data[0], count: Int(frameLength)))
        return rms > 0 ? max(20 * log10(rms), -160) : -160
    }
}

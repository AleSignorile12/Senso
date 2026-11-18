// PourFeedback.swift
// What the user hears while pouring. One voice at a time: VoiceOver announcements when VoiceOver is on,
// otherwise the app's own speech synthesizer, never both. Short earcons mark the high-alert band and the stop.
//
// The iPhone vibrates only when the microphone isn't measuring (start, stop, done, errors): vibration
// travels through the table into the cup and the microphone. While pouring, the Watch's taps carry the level.

import AVFoundation
import Observation
import SwiftUI
import UIKit

@Observable
final class PourFeedback {
    /// Off in Settings for users who prefer the Watch alone. Urgent alerts still speak.
    var speechEnabled = true

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var players: [Earcon: AVAudioPlayer] = [:]
    @ObservationIgnored private var lastFramingCue: FramingCue?
    @ObservationIgnored private var lastFramingTime = Date.distantPast

    func handle(_ event: PourEvent) {
        switch event {
        case .listening:
            // Each pour starts the aiming tips afresh.
            lastFramingCue = nil
            say(String(localized: "Listening. Start pouring when you're ready."))
        case .cupFound: say(String(localized: "Cup found."))
        case .levelUnknown:
            say(String(localized: "I can't hear the level. I can't warn you in time. Check with your finger."), urgent: true)
        case .pouringDetected: say(String(localized: "Pouring."))
        case .pouringPaused: say(String(localized: "Paused."))
        case .milestone(let percent): say(String(localized: "\(percent) percent."))
        case .approachingTarget:
            play(.approaching)
            say(String(localized: "Almost full."))
        case .complete:
            play(.stop)
            say(String(localized: "Stop! Glass is full."), urgent: true)
        case .lostMicrophone: say(String(localized: "Microphone interrupted. Stop pouring."), urgent: true)
        case .unavailable: say(String(localized: "The microphone isn't available."), urgent: true)
        }
    }

    /// Camera tips before the pour. Only changes are spoken, at most every 3 s.
    func framing(_ cue: FramingCue) {
        guard cue != lastFramingCue, Date.now.timeIntervalSince(lastFramingTime) >= 3 else { return }
        lastFramingCue = cue
        lastFramingTime = .now
        let text = switch cue {
        case .noCup: String(localized: "Camera can't see a cup.")
        case .centered: String(localized: "Cup centred.")
        case .moveLeft: String(localized: "Move the phone left.")
        case .moveRight: String(localized: "Move the phone right.")
        case .moveUp: String(localized: "Tilt the phone up.")
        case .moveDown: String(localized: "Tilt the phone down.")
        case .moveCloser: String(localized: "Move closer.")
        case .moveBack: String(localized: "Move back.")
        }
        say(text)
    }

    /// After a calibration pour: say what was learned, since the screen just changed.
    func announceCalibration(_ calibration: FillCalibration?) {
        let text = switch calibration {
        case nil: String(localized: "That pour was too short to measure. Try again with an empty cup.")
        case let calibration? where calibration.hasPitch: String(localized: "Cup calibrated.")
        case _?: String(localized: "Saved the pour time. Senso couldn't hear this cup's pitch, so the level will be rough.")
        }
        say(text, urgent: true)
    }

    /// Back on screen after iOS stopped a pour in the background.
    func announceStoppedInBackground() {
        say(String(localized: "Senso stopped listening when it left the screen. Tap Fill up to start again."), urgent: true)
    }

    // MARK: Haptics

    /// The iPhone haptic for a change of pour state, or nil. One pattern per meaning, Apple's own:
    ///   listening starts → start · you stopped it → stop · glass full → success
    ///   microphone interrupted → warning · no microphone → error · back to the start screen → light tap
    /// Nothing while the pour is being measured (pouring, almost full, paused): the microphone would hear it.
    nonisolated static func haptic(from old: PourState, to new: PourState) -> SensoryFeedback? {
        switch (old, new) {
        case (_, .complete) where old != .complete: .success
        case (_, .unavailable) where old != .unavailable: .error
        case (_, .uncertain) where old != .uncertain: .warning
        case (_, .preparing) where !old.isActive: .start
        case (.complete, .ready): .impact(weight: .light)
        case (_, .ready) where old.isActive: .stop
        default: nil
        }
    }

    // MARK: Speech

    private func say(_ text: String, urgent: Bool = false) {
        guard speechEnabled || urgent else { return }
        if UIAccessibility.isVoiceOverRunning {
            // VoiceOver speaks it in the user's own voice and rate; high priority interrupts other speech.
            var announcement = AttributedString(text)
            announcement.accessibilitySpeechAnnouncementPriority = urgent ? .high : .default
            AccessibilityNotification.Announcement(announcement).post()
            return
        }
        if urgent { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }

    // MARK: Earcons

    enum Earcon: CaseIterable {
        case approaching, stop

        /// Tone frequencies in Hz, played one after another.
        var notes: [Double] {
            switch self {
            case .approaching: [660, 880]
            case .stop: [1320, 990, 1320]
            }
        }
    }

    private func play(_ earcon: Earcon) {
        if players[earcon] == nil {
            players[earcon] = try? AVAudioPlayer(data: Self.wav(earcon.notes))
            players[earcon]?.volume = 1
        }
        players[earcon]?.currentTime = 0
        players[earcon]?.play()
    }

    /// A few short sine notes as 16-bit mono WAV data, so no sound files ship with the app.
    nonisolated static func wav(_ notes: [Double], noteSeconds: Double = 0.12, sampleRate: Double = 44_100) -> Data {
        let perNote = Int(noteSeconds * sampleRate)
        var samples: [Int16] = []
        for frequency in notes {
            for index in 0..<perNote {
                let time = Double(index) / sampleRate
                // 10 ms fade in and out, so the notes don't click.
                let envelope = min(1, time / 0.01, (noteSeconds - time) / 0.01)
                samples.append(Int16(sin(2 * .pi * frequency * time) * envelope * 0.6 * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        samples.forEach { append($0) }
        return data
    }
}

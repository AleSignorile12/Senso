// PhoneWatchLink.swift
// iPhone side of WatchConnectivity. Sends the pour state to the Watch (which turns it into haptics) and
// receives the Watch's commands, Digital Crown target and wrist tilt.
// Payloads are the shared Codable types in SharedModels, sent as JSON (WatchSync).

import Foundation
import Observation
import os
import WatchConnectivity

nonisolated private let log = Logger(subsystem: "com.senso.app", category: "watch")

// Explicit: the delegate conformance would otherwise make the class nonisolated.
@MainActor @Observable
final class PhoneWatchLink: NSObject, WCSessionDelegate {
    /// The Senso Watch app is installed and can be messaged right now.
    private(set) var isReachable = false
    /// Latest wrist motion, and when it arrived (the Watch's clock may differ, so the iPhone stamps it).
    private(set) var motion: (state: WatchMotionState, receivedAt: Date)?

    @ObservationIgnored var onCommand: (WatchCommand) -> Void = { _ in }
    @ObservationIgnored var onTargetChanged: (Int) -> Void = { _ in }
    @ObservationIgnored private var lastSent: PhoneToWatchMessage?

    func activate() {
        guard WCSession.isSupported(), WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ message: PhoneToWatchMessage) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isWatchAppInstalled,
              message != lastSent, let payload = try? WatchSync.message(message)
        else { return }
        lastSent = message
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { log.error("Send failed: \($0.localizedDescription, privacy: .public)") }
        }
        // Also the latest state for whenever the Watch app opens next.
        try? session.updateApplicationContext(payload)
    }

    // MARK: WCSessionDelegate (called on a background queue)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        if let error { log.error("Activation failed: \(error.localizedDescription, privacy: .public)") }
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if reachable { self.lastSent = nil }  // resend the current state
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The user switched Watches: reconnect to the new one.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = WatchSync.decode(WatchToPhoneMessage.self, from: message) else { return }
        Task { @MainActor in self.handle(decoded) }
    }

    private func handle(_ message: WatchToPhoneMessage) {
        switch message {
        case .command(let command): onCommand(command)
        case .targetChanged(let percent): onTargetChanged(min(max(percent, PourThresholds.targetRange.lowerBound), PourThresholds.targetRange.upperBound))
        case .motion(let state): motion = (state, .now)
        }
    }
}

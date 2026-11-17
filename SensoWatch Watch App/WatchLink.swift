// WatchLink.swift
// Watch side of WatchConnectivity, the haptics ladder, the extended runtime session and wrist tilt.

import CoreMotion
import Foundation
import Observation
import WatchConnectivity
import WatchKit

// Explicit: the delegate conformances would otherwise make the class nonisolated.
@MainActor @Observable
final class WatchLink: NSObject, WCSessionDelegate {
    private(set) var message = PhoneToWatchMessage(
        state: .ready, fillPercent: nil, targetPercent: PourThresholds.defaultTargetPercent, containerLocked: false
    )
    private(set) var isReachable = false

    @ObservationIgnored private let haptics = HapticLadder()
    @ObservationIgnored private let runtime = PourRuntimeSession()
    @ObservationIgnored private let tilt = TiltDetector()

    func activate() {
        guard WCSession.isSupported(), WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        tilt.onChange = { [weak self] state in self?.send(.motion(state)) }
    }

    func send(_ value: WatchToPhoneMessage) {
        guard WCSession.default.activationState == .activated, let payload = try? WatchSync.message(value) else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil)
        }
    }

    /// The Crown target is shown at once; the iPhone confirms it in its next message.
    func setTarget(_ percent: Int) {
        message.targetPercent = percent
        send(.targetChanged(percent: percent))
    }

    private func apply(_ new: PhoneToWatchMessage) {
        let old = message
        message = new
        haptics.update(from: old, to: new)
        if new.state.isActive, !old.state.isActive {
            runtime.start()
            tilt.start()
        } else if !new.state.isActive, old.state.isActive {
            runtime.stop()
            tilt.stop()
        }
    }

    // MARK: WCSessionDelegate (called on a background queue)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let reachable = session.isReachable
        let context = WatchSync.decode(PhoneToWatchMessage.self, from: session.receivedApplicationContext)
        Task { @MainActor in
            self.isReachable = reachable
            // A pour can't still be running from an old context; only take the settings from it.
            if let context { self.message.targetPercent = context.targetPercent }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = WatchSync.decode(PhoneToWatchMessage.self, from: message) else { return }
        Task { @MainActor in self.apply(decoded) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let decoded = WatchSync.decode(PhoneToWatchMessage.self, from: context) else { return }
        Task { @MainActor in self.apply(decoded) }
    }
}

// MARK: - Haptics

/// The pour as taps on the wrist, faster as the cup fills:
///   container locked → one click
///   50–69 % → "up" every 1.2 s, 70–89 % → every 0.6 s, 90–99 % → "retry" every 0.3 s
///   complete → "stop", then "notification" 0.15 s later
final class HapticLadder {
    private var loop: Task<Void, Never>?
    private var interval: (seconds: Double, haptic: WKHapticType)?

    func update(from old: PhoneToWatchMessage, to new: PhoneToWatchMessage) {
        let device = WKInterfaceDevice.current()
        if new.containerLocked, !old.containerLocked, new.state.isActive { device.play(.click) }

        if new.state == .complete, old.state != .complete {
            stopLoop()
            device.play(.stop)
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                device.play(.notification)
            }
            return
        }
        guard new.state.isActive, let percent = new.fillPercent else {
            stopLoop()
            return
        }
        let next: (Double, WKHapticType)? = switch percent {
        case 90...: (0.3, .retry)
        case 70..<90: (0.6, .directionUp)
        case 50..<70: (1.2, .directionUp)
        default: nil
        }
        guard next?.0 != interval?.seconds || next?.1 != interval?.haptic else { return }
        stopLoop()
        guard let (seconds, haptic) = next else { return }
        interval = (seconds, haptic)
        loop = Task {
            while !Task.isCancelled {
                device.play(haptic)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
        interval = nil
    }
}

// MARK: - Extended runtime

/// Keeps the Watch app running, and its haptics playing, when the wrist turns down mid-pour.
/// Needs the "self-care" background mode (SensoWatch-Info.plist).
@MainActor
final class PourRuntimeSession: NSObject, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?

    func start() {
        guard session == nil else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        self.session = session
    }

    func stop() {
        session?.invalidate()
        session = nil
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: (any Error)?) {
        Task { @MainActor in self.session = nil }
    }
}

// MARK: - Tilt

/// Wrist tilt from the pour's starting pose. A heuristic, so it is labelled `.dspFallback`; the iPhone
/// only uses it to accept a slightly weaker sound as pouring.
final class TiltDetector {
    var onChange: (WatchMotionState) -> Void = { _ in }
    private let manager = CMMotionManager()
    private var baseline: (roll: Double, pitch: Double)?
    private var last: WatchMotionState?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        baseline = nil
        manager.deviceMotionUpdateInterval = 1.0 / 10
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            let baseline = self.baseline ?? (attitude.roll, attitude.pitch)
            self.baseline = baseline
            // Pouring rotates the wrist; whichever axis moved most counts.
            let degrees = max(abs(attitude.roll - baseline.roll), abs(attitude.pitch - baseline.pitch)) * 180 / .pi
            let confidence = min(1, max(0, (degrees - 20) / 30))
            let state = WatchMotionState(isTilting: confidence >= 0.5, tiltConfidence: (confidence * 10).rounded() / 10,
                                         source: .dspFallback)
            if state != self.last {
                self.last = state
                self.onChange(state)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        baseline = nil
        last = nil
    }
}

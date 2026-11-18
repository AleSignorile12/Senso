// PourEstimationEngine.swift
// Fuses the sensors into one PourState, one fill number and the moments to speak or buzz.
//
// Inputs: Stage 1 readings (is liquid pouring?), Stage 3 fill estimates (how full, how fast, how sure),
// and the microphone's state. The stop alert fires early enough that the liquid actually stops in time:
//   projected fill = fill + rate × reaction time + half the estimate's uncertainty
// and "Stop" happens when that reaches the target. Reaction time covers the alert starting, the person
// reacting and the stream's tail; the Watch's haptic starts sooner than speech, so it gets less.
// Pure logic on the main actor: no audio, no UI. Feedback (speech, earcons, Watch) reacts to `onEvent`.

import Foundation
import Observation

/// Moments the feedback layer reacts to.
nonisolated enum PourEvent: Sendable, Equatable {
    case listening             // session started
    case cupFound              // the optional camera saw a cup: pouring sounds are trusted a little sooner
    case pouringDetected
    case levelUnknown          // pouring, but no level estimate for a while: the stop alert can't come
    case pouringPaused         // flow stopped before the target
    case milestone(Int)        // fill crossed 25, 50, 75 or 85 %
    case approachingTarget     // entered the high-alert band
    case complete              // stop now
    case lostMicrophone        // interrupted (a call, Siri)
    case unavailable           // no microphone at all
}

@Observable
final class PourEstimationEngine {
    private(set) var state: PourState = .ready
    /// 0...100, nil while no estimate is trustworthy enough to show.
    private(set) var fillPercent: Int?
    /// How the current fill number was made, for the on-screen badge.
    private(set) var fillMethod: FillMethod?
    var targetPercent = PourThresholds.defaultTargetPercent
    /// Seconds from the alert starting to the liquid stopping. Lower when the Watch's haptic leads.
    var reactionSeconds = PourEstimationEngine.speechReactionSeconds
    /// During a calibration pour the user decides when it's full: no number, no alerts.
    var calibrating = false
    /// The Watch feels the wrist tilted as if pouring: a slightly weaker sound is enough to start.
    var watchTilting = false
    /// The optional camera has seen a cup this session. Not required: Senso works by sound alone.
    private(set) var cupFound = false
    /// The first pour sound of this session was heard. Until then the level stays at 0, so room noise
    /// before the pour can't raise it (the pipeline restarts its estimate at this moment).
    private(set) var pourStarted = false

    static let speechReactionSeconds = 0.9
    static let watchReactionSeconds = 0.75
    /// Classifier hysteresis, so the state doesn't flicker on one ambiguous window.
    /// 0.7 suits model v3: on held-out FSD50K clips it keeps 83% of pour time detected (0.6 gave 84%) with
    /// 1.4 false starts per minute of other sounds (0.6 gave 2.0). See MLTraining/README.md.
    static let startPouringConfidence = 0.7
    static let startPouringConfidenceWithTilt = 0.45
    /// A cup in the camera's view makes a pour more likely: a slightly weaker sound is enough to start.
    /// On held-out clips 0.65 found as many pours as 0.55, with 1.65 false starts per minute instead of 2.4.
    static let startPouringConfidenceWithCup = 0.65
    static let keepPouringConfidence = 0.4
    /// How long the classifier must say "not pouring" before the pour counts as paused.
    static let pauseSeconds = 1.5
    /// Fill estimates older than this are ignored.
    static let staleFillSeconds = 1.0
    /// Confident pouring for this long without a level estimate: say so, the stop alert can't come.
    static let levelUnknownSeconds = 3.0
    static let levelUnknownConfidence = 0.55
    /// Weaker sounds must last longer, as many aren't pours. On held-out clips this cut the warnings during
    /// other sounds from 0.33 to 0.25 a minute, and no pour without a level lost its warning.
    static let levelUnknownUnsureSeconds = 4.0

    @ObservationIgnored var onEvent: (PourEvent) -> Void = { _ in }
    @ObservationIgnored private var announced: Set<Int> = []
    @ObservationIgnored private var quietSince: Date?
    @ObservationIgnored private var lastFill: (reading: FillReading, time: Date)?
    @ObservationIgnored private var levelMissingSince: Date?
    @ObservationIgnored private var lastLevelMissingReading: Date?
    @ObservationIgnored private var confidentSecondsWithoutLevel = 0.0
    @ObservationIgnored private var warnedLevelMissing = false

    // MARK: Session

    func begin() {
        state = .preparing
        fillPercent = nil
        fillMethod = nil
        announced = []
        quietSince = nil
        lastFill = nil
        cupFound = false
        pourStarted = false
        levelMissingSince = nil
        lastLevelMissingReading = nil
        confidentSecondsWithoutLevel = 0
        warnedLevelMissing = false
        onEvent(.listening)
    }

    /// The camera recognised a cup (or glass, mug…). Once per session.
    func cupSeen() {
        guard state.isActive, !cupFound else { return }
        cupFound = true
        onEvent(.cupFound)
    }

    func end() {
        state = .ready
        fillPercent = nil
        fillMethod = nil
    }

    // MARK: Inputs

    func microphoneChanged(_ microphone: AudioCaptureService.State) {
        guard state.isActive else { return }
        switch microphone {
        case .running:
            if state == .uncertain { state = .preparing }
        case .interrupted:
            state = .uncertain
            onEvent(.lostMicrophone)
        case .permissionDenied, .failed:
            state = .unavailable
            onEvent(.unavailable)
        case .idle:
            break
        }
    }

    func ingest(_ reading: SensorReading) {
        guard state.isActive, state != .uncertain else { return }
        let startThreshold = min(Self.startPouringConfidence,
                                 watchTilting ? Self.startPouringConfidenceWithTilt : 1,
                                 cupFound ? Self.startPouringConfidenceWithCup : 1)
        let flowing = state == .preparing
            ? reading.pouringConfidence >= startThreshold
            : reading.pouringConfidence >= Self.keepPouringConfidence
        if flowing {
            quietSince = nil
            if state == .preparing {
                pourStarted = true
                state = isHighAlert ? .approachingTarget : .pouring
                onEvent(.pouringDetected)
            }
        } else if state == .pouring || state == .approachingTarget {
            let since = quietSince ?? reading.timestamp
            quietSince = since
            if reading.timestamp.timeIntervalSince(since) >= Self.pauseSeconds {
                state = .preparing
                onEvent(.pouringPaused)
            }
        }
        // Without a level the stop alert can't come, so the user must hear that.
        if (state == .pouring || state == .approachingTarget), fillPercent == nil, !calibrating {
            let since = levelMissingSince ?? reading.timestamp
            levelMissingSince = since
            if let last = lastLevelMissingReading, reading.pouringConfidence >= Self.levelUnknownConfidence {
                confidentSecondsWithoutLevel += reading.timestamp.timeIntervalSince(last)
            }
            lastLevelMissingReading = reading.timestamp
            let waitedLongEnough = confidentSecondsWithoutLevel >= Self.levelUnknownSeconds
                || reading.timestamp.timeIntervalSince(since) >= Self.levelUnknownUnsureSeconds
            if waitedLongEnough, !warnedLevelMissing {
                warnedLevelMissing = true
                onEvent(.levelUnknown)
            }
        } else {
            // Only unbroken pouring counts, or a brief false start would warn the moment the real pour begins.
            levelMissingSince = nil
            lastLevelMissingReading = nil
            confidentSecondsWithoutLevel = 0
            if fillPercent != nil { warnedLevelMissing = false }
        }
    }

    /// Ignored until the first pour sound: the level starts from 0 then.
    func ingest(_ fill: FillReading?, at time: Date = .now) {
        guard state.isActive, pourStarted else { return }
        if let fill {
            lastFill = (fill, time)
        } else if let last = lastFill, time.timeIntervalSince(last.time) > Self.staleFillSeconds {
            lastFill = nil
        }
        guard let (reading, _) = lastFill, !calibrating else {
            fillPercent = nil
            fillMethod = nil
            return
        }
        let percent = Int((min(max(reading.fraction, 0), 1) * 100).rounded())
        fillPercent = percent
        fillMethod = reading.method

        // Only the highest milestone just crossed: a jump from 20 to 55 says "50", not "25" then "50" late.
        let crossed = PourThresholds.voiceOverMilestones.filter { $0 < targetPercent && percent >= $0 && !announced.contains($0) }
        if let highest = crossed.max() {
            announced.formUnion(crossed)
            onEvent(.milestone(highest))
        }
        if state == .pouring, isHighAlert {
            state = .approachingTarget
            onEvent(.approachingTarget)
        }

        // Any active state: the classifier can lose the pour (a pause) while the level still climbs, and
        // the stop alert must come regardless.
        let projected = reading.fraction + reading.ratePerSecond * reactionSeconds + reading.uncertainty / 2
        if state.isActive, projected * 100 >= Double(targetPercent) {
            state = .complete
            onEvent(.complete)
        }
    }

    private var isHighAlert: Bool {
        (fillPercent ?? 0) >= PourThresholds.highAlertPercent
    }
}

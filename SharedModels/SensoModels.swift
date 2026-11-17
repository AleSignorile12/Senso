// SensoModels.swift
// Types shared by the iPhone app and the Watch app.
// Everything here is `nonisolated` so audio, motion and connectivity code can use it off the main actor
// (the targets default to main-actor isolation).

import Foundation

// MARK: - Pour state

/// The states the whole app (iPhone and Watch) agrees on.
nonisolated enum PourState: String, Codable, Sendable, CaseIterable {
    case ready              // idle, waiting for the user to start
    case preparing          // sensors starting, permission prompts, camera framing
    case pouring            // liquid detected flowing
    case approachingTarget  // estimated fill is inside the high-alert band
    case uncertain          // confidence too low to guide; tell the user, don't guess
    case complete           // target reached: user told to stop
    case unavailable        // no usable sensor (mic denied or interrupted)

    /// True while a pour session is running: sensors on, screen kept awake.
    var isActive: Bool {
        switch self {
        case .preparing, .pouring, .approachingTarget, .uncertain: true
        case .ready, .complete, .unavailable: false
        }
    }
}

/// Where a number came from. The UI shows it, so a heuristic is never mistaken for a trained model.
nonisolated enum EstimateSource: Codable, Sendable, Equatable {
    case trainedModel(version: String)  // for example "SensoSoundClassifier_v3"
    case dspFallback                    // Accelerate heuristic: "DSP Mode (Uncalibrated)"
    case none
}

nonisolated enum SensorKind: String, Codable, Sendable, CaseIterable {
    case microphone, camera, watch
}

nonisolated enum SensorStatus: String, Codable, Sendable {
    case active         // producing readings with usable confidence
    case lowConfidence  // producing readings, but too weak to rely on alone
    case unavailable    // off, denied, occluded, or disconnected
}

/// Coarse fill level (Stage 2). Only produced by a model trained on fill-stage recordings.
nonisolated enum FillStage: Int, Codable, Sendable, Comparable {
    case empty, low, mid, high, full

    static func < (lhs: FillStage, rhs: FillStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One reading from one sensor. A field stays nil when that sensor cannot know it.
nonisolated struct SensorReading: Sendable, Equatable {
    var sensor: SensorKind
    var timestamp: Date
    var status: SensorStatus
    var source: EstimateSource
    /// Stage 1: chance that liquid is flowing, 0...1. Must come from a real computation.
    var pouringConfidence: Double
    /// Stage 2: nil until a fill-stage model exists.
    var fillStage: FillStage?
    /// Stage 3: fraction full, 0...1. nil until a calibrated estimator exists.
    var fillFraction: Double?
}

/// Product rules from the spec, in one place.
nonisolated enum PourThresholds {
    static let highAlertPercent = 70
    static let defaultTargetPercent = 90
    static let targetRange = 70...100
    static let voiceOverMilestones = [25, 50, 75, 85, 100]
}

// MARK: - Containers and dataset labels

nonisolated enum ContainerType: String, Codable, Sendable, CaseIterable {
    case mug, glass, cup, paperCup = "paper_cup", thermos, bowl, other
}

nonisolated enum ContainerMaterial: String, Codable, Sendable, CaseIterable {
    case ceramic, glass, plastic, paper, metal, other
}

nonisolated enum LiquidType: String, Codable, Sendable, CaseIterable {
    case water, tea, coffee, milk, juice, other
}

nonisolated enum PouringSpeed: String, Codable, Sendable, CaseIterable {
    case slow, medium, fast
}

/// How the recording's fill level is known. Only `measured` data may train Stage 3.
nonisolated enum GroundTruthType: String, Codable, Sendable, CaseIterable {
    case measured, estimated, unlabelled
}

/// What one calibration pour measured for a cup (see SensoApp/ML/FillEstimator.swift).
nonisolated struct FillCalibration: Codable, Sendable, Hashable {
    /// Resonance just after liquid starts hitting the empty cup. nil when the cup's pitch wasn't audible.
    var emptyHz: Double?
    /// Resonance when the user said "full". nil when the cup's pitch wasn't audible.
    var fullHz: Double?
    /// How long that pour took. Used when the pitch can't be heard.
    var fillSeconds: Double

    var hasPitch: Bool { emptyHz != nil && fullHz != nil }
}

/// A cup the user has set up. Without a calibration, fill estimates are rougher.
nonisolated struct ContainerProfile: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var type: ContainerType = .mug
    var material: ContainerMaterial = .ceramic
    var calibration: FillCalibration?
}

/// Sound classifier labels. Raw values are the dataset folder names that
/// MLTraining/TrainSensoModels.swift reads. Don't rename them.
nonisolated enum SoundClass: String, Codable, Sendable, CaseIterable {
    case pouring
    case notPouring = "not_pouring"
    case backgroundNoise = "background_noise"
    case ambiguous
}

/// Sidecar JSON saved next to every recording from Data Collection mode.
nonisolated struct RecordingMetadata: Codable, Sendable, Equatable {
    var label: SoundClass
    var containerType: ContainerType
    var material: ContainerMaterial
    var liquidType: LiquidType
    var pouringSpeed: PouringSpeed
    var groundTruthType: GroundTruthType
    var recordedAt: Date
    var durationSeconds: Double
    var sampleRate: Double
    var notes: String = ""
}

// MARK: - Watch sync payloads

/// iPhone → Watch: what to show and which haptics to play.
nonisolated struct PhoneToWatchMessage: Codable, Sendable, Equatable {
    var state: PourState
    /// nil when there is no trustworthy fill estimate. The Watch then shows the state, not a number.
    var fillPercent: Int?
    var targetPercent: Int
    var containerLocked: Bool
}

nonisolated enum WatchCommand: String, Codable, Sendable {
    case startPour, stop, pourAgain
}

/// Wrist motion summary computed on the Watch. The iPhone stamps the receive time for freshness,
/// because the two devices' clocks are not guaranteed to match.
nonisolated struct WatchMotionState: Codable, Sendable, Equatable {
    var isTilting: Bool
    var tiltConfidence: Double  // 0...1
    var source: EstimateSource
}

/// Watch → iPhone.
nonisolated enum WatchToPhoneMessage: Codable, Sendable, Equatable {
    case command(WatchCommand)
    case targetChanged(percent: Int)
    case motion(WatchMotionState)
}

/// WCSession sends `[String: Any]` dictionaries. Each payload travels as JSON under one key.
nonisolated enum WatchSync {
    static let payloadKey = "senso"

    static func message(_ value: some Encodable) throws -> [String: Any] {
        [payloadKey: try JSONEncoder().encode(value)]
    }

    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message[payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

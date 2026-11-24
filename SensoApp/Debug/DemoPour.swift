// DemoPour.swift
// Debug builds only: plays one steady pour through the real engine and screens, for a screen recording in the
// simulator (it can't hear a real pour). Launch with `-SensoDemo YES -senso.onboardingSeen YES`, for example:
//   xcrun simctl launch booted com.alessandrosignorile.Senso -SensoDemo YES -senso.onboardingSeen YES

#if DEBUG
import Foundation

enum DemoPour {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "SensoDemo") }

    /// Ready, then listening, then a pour that fills 10% a second until the stop alert.
    static func run(_ engine: PourEstimationEngine) async {
        try? await Task.sleep(for: .seconds(4.5))
        engine.targetPercent = 90
        engine.begin()
        try? await Task.sleep(for: .seconds(2))
        let rate = 0.1, step = 0.1
        var fraction = 0.0
        while engine.state.isActive {
            engine.ingest(SensorReading(sensor: .microphone, timestamp: .now, status: .active,
                                        source: .trainedModel(version: "demo"), pouringConfidence: 0.9))
            engine.ingest(FillReading(fraction: fraction, uncertainty: 0.05, ratePerSecond: rate, method: .pitchCalibrated))
            try? await Task.sleep(for: .seconds(step))
            fraction += rate * step
        }
    }
}
#endif

// StartPouringIntent.swift
// "Start pouring with Sensow": opens the app and starts listening. Siri, Shortcuts, the Action Button and
// the Control Center control all run this. It's compiled into the app and the SensoControls extension
// (the control needs the type), but because it opens the app, `perform` always runs in the app.

import AppIntents
import Observation

nonisolated struct StartPouringIntent: AppIntent {
    static let title: LocalizedStringResource = "Start pouring"
    static let description = IntentDescription("Opens Sensow and starts listening for the pour.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await PourLaunchRequest.shared.request()
        return .result()
    }
}

/// The app's root view watches `count` and starts a pour when it changes, including on a cold launch.
@Observable
final class PourLaunchRequest {
    static let shared = PourLaunchRequest()
    private(set) var count = 0

    func request() { count += 1 }
}

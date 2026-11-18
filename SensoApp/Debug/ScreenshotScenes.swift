// ScreenshotScenes.swift
// Debug builds only: opens one screen with sample values, for App Store screenshots taken in the simulator
// (it can't hear a real pour). Launch with `-SensoScreenshot <scene>`, for example:
//   xcrun simctl launch booted com.alessandrosignorile.Senso -SensoScreenshot pouring
// AppStore/README.md has the full commands.

#if DEBUG
import SwiftUI

enum ScreenshotScene: String {
    case onboarding, ready, findingCup, pouring, alert, done, settings

    static var current: ScreenshotScene? {
        UserDefaults.standard.string(forKey: "SensoScreenshot").flatMap(Self.init)
    }

    @ViewBuilder var view: some View {
        switch self {
        case .onboarding:
            // As on first launch: the welcome sheet over the home screen.
            ReadyView(onStart: {}, onOpenCups: {})
                .sheet(isPresented: .constant(true)) { OnboardingView().interactiveDismissDisabled() }
        case .ready:
            ReadyView(onStart: {}, cupName: "Blue mug", onOpenCups: {})
        case .findingCup:
            PouringView(state: .preparing, cupFound: false, fillPercent: nil, source: .none,
                        sensors: [.microphone: .active, .camera: .lowConfidence, .watch: .active], onStop: {})
                .preferredColorScheme(.dark)
        case .pouring:
            PouringView(state: .pouring, fillPercent: 62, fillMethod: .pitchCalibrated,
                        source: .trainedModel(version: "SensoSoundClassifier_v3"),
                        sensors: [.microphone: .active, .camera: .unavailable, .watch: .active], onStop: {})
                .preferredColorScheme(.dark)
        case .alert:
            PouringView(state: .approachingTarget, fillPercent: 86, fillMethod: .pitchCalibrated,
                        source: .trainedModel(version: "SensoSoundClassifier_v3"),
                        sensors: [.microphone: .active, .camera: .unavailable, .watch: .active], onStop: {})
                .preferredColorScheme(.dark)
        case .done:
            CompleteView(targetPercent: 90, onAgain: {}, onHome: {})
        case .settings:
            CupsView(store: Self.sampleCups(), onCalibrate: { _ in })
        }
    }

    /// Two sample cups in their own defaults suite, so the user's real cups are never touched.
    private static func sampleCups() -> CupStore {
        let suite = "senso.screenshots"
        UserDefaults().removePersistentDomain(forName: suite)
        let store = CupStore(defaults: UserDefaults(suiteName: suite)!)
        let glass = store.add(named: "Tall glass")
        store.setCalibration(FillCalibration(emptyHz: nil, fullHz: nil, fillSeconds: 6), for: glass.id)
        let mug = store.add(named: "Blue mug")
        store.setCalibration(FillCalibration(emptyHz: 620, fullHz: 2_300, fillSeconds: 8), for: mug.id)
        return store
    }
}
#endif

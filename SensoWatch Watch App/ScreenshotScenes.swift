// ScreenshotScenes.swift
// Debug builds only: opens one Watch screen with sample values, for App Store screenshots taken in the
// simulator. Launch with `-SensoScreenshot ready|low|pouring|done` (see AppStore/README.md).

#if DEBUG
import SwiftUI

enum ScreenshotScene: String {
    case ready, low, pouring, done

    static var current: ScreenshotScene? {
        UserDefaults.standard.string(forKey: "SensoScreenshot").flatMap(Self.init)
    }

    @ViewBuilder var view: some View {
        switch self {
        case .ready: WatchReadyView(targetPercent: 90, onStart: {})
        case .low: WatchPouringView(fillPercent: 12)
        case .pouring: WatchPouringView(fillPercent: 52)
        case .done: WatchCompleteView(targetPercent: 100) {}
        }
    }
}
#endif

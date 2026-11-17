// Onboarding.swift
// The first-launch introduction, as a self-contained module (this folder only depends on SensoDesign).
//
//   • `.onboardingOnFirstLaunch()` on the root view shows OnboardingView once, as a sheet.
//   • Present `OnboardingView()` in a sheet anywhere else (Settings › How Senso works) to show it again;
//     its Continue button closes the sheet.
//
// Remove the modifier to turn onboarding off. The "seen" flag lives in UserDefaults under `seenKey`.

import SwiftUI

struct OnboardingGate: ViewModifier {
    static let seenKey = "senso.onboardingSeen"
    @AppStorage(OnboardingGate.seenKey) private var seen = false

    func body(content: Content) -> some View {
        // A sheet that can't be swiped away, like Apple's own welcome screens: it ends with Continue (or
        // VoiceOver's escape gesture), and closing it in any way marks it seen.
        content.sheet(isPresented: Binding(get: { !seen }, set: { if !$0 { seen = true } })) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
    }
}

extension View {
    /// Shows the introduction the first time Senso opens.
    func onboardingOnFirstLaunch() -> some View { modifier(OnboardingGate()) }
}

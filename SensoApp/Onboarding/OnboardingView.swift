// OnboardingView.swift
// The introduction in Apple's own welcome-screen style: system fonts and colours, a large centred title,
// feature rows (symbol, bold title, secondary subtitle) and a prominent Continue button. Text styles
// follow Dynamic Type. One scrolling screen rather than swipeable pages, because page swipes clash with
// VoiceOver gestures. VoiceOver starts on the title; each row reads as one element.

import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var titleFocused: Bool
    @ScaledMetric(relativeTo: .title) private var iconColumn = 44

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                Text("Welcome to Senso")
                    .font(.senso(.largeTitle, .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)

                VStack(alignment: .leading, spacing: 28) {
                    row("iphone.gen3", "Place your iPhone by the cup",
                        "Bottom edge facing the cup: that’s where the microphone is.")
                    row("drop.fill", "Tap Fill up and pour",
                        "Senso tells you how full the cup is and says “Stop!” in time to stop.")
                    row("cup.and.saucer.fill", "Calibrate your cups",
                        "Do it once per cup in Settings for a more accurate level.")
                    row("hand.raised.fill", "Private by design",
                        "Senso will ask to use the microphone. Sound is analysed on your iPhone and never saved.")
                    row("exclamationmark.triangle.fill", "An aid, not a guarantee",
                        "Take extra care with hot drinks.")
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 56)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: {
                Text("Continue")
                    .font(.senso(.headline, .bold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
        }
        .tint(SensoColor.water)
        .font(.senso(.body))
        .background(Color(.systemBackground))
        .accessibilityAction(.escape) { dismiss() }
        .onAppear { titleFocused = true }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.senso(.headline, .bold))
                Text(detail)
                    .font(.senso(.subheadline))
                    // Darker than .secondary (about 4.5:1) to keep Senso's 7:1 contrast target.
                    .foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) { OnboardingView().interactiveDismissDisabled() }
}

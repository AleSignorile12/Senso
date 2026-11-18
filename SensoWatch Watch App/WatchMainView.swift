// WatchMainView.swift
// Watch UI from the blue "water" design: Ready → fill % → done. The iPhone runs the sensing; the Watch
// shows its state, taps the wrist (WatchLink) and sets the stop target with the Digital Crown.

import SwiftUI

@main
struct SensoWatchApp: App {
    @State private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let scene = ScreenshotScene.current { scene.view } else { root }
            #else
            root
            #endif
        }
    }

    private var root: some View {
        WatchRootView(link: link)
            .onAppear { link.activate() }
    }
}

struct WatchRootView: View {
    let link: WatchLink

    var body: some View {
        switch link.message.state {
        case .ready, .unavailable:
            WatchReadyView(targetPercent: link.message.targetPercent, phoneReachable: link.isReachable,
                           onTargetChange: link.setTarget) { link.send(.command(.startPour)) }
        case .complete:
            WatchCompleteView(targetPercent: link.message.targetPercent) { link.send(.command(.pourAgain)) }
        default:
            WatchPouringView(fillPercent: link.message.fillPercent)
                .accessibilityAction(named: "Stop") { link.send(.command(.stop)) }
        }
    }
}

struct WatchReadyView: View {
    let targetPercent: Int
    var phoneReachable = true
    var onTargetChange: (Int) -> Void = { _ in }
    let onStart: () -> Void

    @State private var crown = Double(PourThresholds.defaultTargetPercent)
    @ScaledMetric(relativeTo: .footnote) private var targetSize = 13

    @ScaledMetric(relativeTo: .headline) private var titleSize = 15
    @ScaledMetric(relativeTo: .largeTitle) private var buttonSize = 58

    var body: some View {
        VStack(spacing: 10) {
            Text("Ready to pour?")
                .font(.senso(titleSize))
                .foregroundStyle(SensoColor.water)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Button(action: onStart) {
                // Two Texts with negative spacing: SwiftUI ignores negative lineSpacing.
                VStack(alignment: .leading, spacing: -buttonSize * 0.36) {
                    Text("FILL")
                    Text("UP!")
                }
                .font(.senso(buttonSize))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SensoColor.water, in: .rect(cornerRadius: 44))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fill up")
            .accessibilityValue(phoneReachable ? Text("Stop alert at \(targetPercent) percent") : Text("iPhone not connected"))
            .accessibilityHint("Starts listening on your iPhone. Turn the Digital Crown to change the stop alert.")
            Text(phoneReachable ? "Stop at \(targetPercent)%" : "Open Senso on iPhone")
                .font(.senso(targetSize, .regular))
                .foregroundStyle(SensoColor.water)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
        // Digital Crown: stop target 70–100 % in steps of 5, with a detent tick per step.
        .focusable()
        .digitalCrownRotation($crown, from: Double(PourThresholds.targetRange.lowerBound),
                              through: Double(PourThresholds.targetRange.upperBound), by: 5,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear { crown = Double(targetPercent) }
        .onChange(of: crown) { _, value in
            let percent = Int((value / 5).rounded()) * 5
            if percent != targetPercent { onTargetChange(percent) }
        }
    }
}

struct WatchPouringView: View {
    let fillPercent: Int?

    @ScaledMetric(relativeTo: .largeTitle) private var percentSize = 56

    var body: some View {
        GeometryReader { proxy in
            Text(fillText(fillPercent))
                .font(.senso(percentSize))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .contentTransition(.numericText(value: Double(fillPercent ?? 0)))
                .animation(.smooth(duration: 0.6), value: fillPercent)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 10)
                .background(MovingLiquid(amplitude: 4, wavelength: 55, color: SensoColor.water))
                .frame(height: proxy.size.height * 0.62)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .background(.white)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fillPercent.map { Text("\($0) percent full") } ?? Text("No fill estimate yet"))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct WatchCompleteView: View {
    /// The stop level the iPhone used, so the Watch says the same number (not a flat 100%).
    var targetPercent = 100
    let onPourAgain: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var percentSize = 52
    @ScaledMetric(relativeTo: .headline) private var actionSize = 17

    var body: some View {
        Button(action: onPourAgain) {
            VStack(spacing: 18) {
                Text(verbatim: fillText(targetPercent))
                    .font(.senso(percentSize))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text("Tap to pour again")
                    .font(.senso(actionSize))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MovingLiquid(amplitude: 4, wavelength: 55, color: SensoColor.water).padding(.top, 6))
            .background(.white)
        }
        .buttonStyle(.plain)
        .ignoresSafeArea()
        .accessibilityLabel("Done. \(targetPercent) percent full.")
        .accessibilityHint("Tap to pour again.")
    }
}

// MARK: - Previews (design fixtures, not sensor data)

#Preview("Ready") { WatchReadyView(targetPercent: 90) {} }
#Preview("72%") { WatchPouringView(fillPercent: 72) }
#Preview("100%") { WatchCompleteView {} }

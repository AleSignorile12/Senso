// SensoMainViews.swift
// iPhone UI from the "Almost Purple" design: Ready → Pouring (normal / high alert) → Done.
// PourEstimationEngine decides the state and the number; PourFeedback speaks; the views only show.

import SwiftUI

@main
struct SensoApp: App {
    @State private var audio: AudioCaptureService
    @State private var recorder: DatasetRecorderService
    @State private var pipeline = AcousticPipeline()
    @State private var engine = PourEstimationEngine()
    @State private var feedback = PourFeedback()
    @State private var cups = CupStore()
    @State private var watch = PhoneWatchLink()
    @State private var camera = CameraFraming()

    init() {
        let audio = AudioCaptureService()
        _audio = State(initialValue: audio)
        _recorder = State(initialValue: DatasetRecorderService(audio: audio))
    }

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
        SensoRootView(audio: audio, recorder: recorder, pipeline: pipeline, engine: engine, feedback: feedback,
                      cups: cups, watch: watch, camera: camera)
            .onboardingOnFirstLaunch()
    }
}

// MARK: - Root

struct SensoRootView: View {
    let audio: AudioCaptureService
    let recorder: DatasetRecorderService
    let pipeline: AcousticPipeline
    let engine: PourEstimationEngine
    let feedback: PourFeedback
    let cups: CupStore
    let watch: PhoneWatchLink
    let camera: CameraFraming
    @State private var showingDataCollection = false
    @State private var showingCups = false
    /// The cup being calibrated, while a calibration pour runs.
    @State private var calibratingCup: ContainerProfile?
    /// A pour was running when Senso went to the background; say so when it's back.
    @State private var stoppedInBackground = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private let launchRequest = PourLaunchRequest.shared

    private var state: PourState { engine.state }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The three screens; animations run when this changes, not on every pour-state change.
    private enum Screen { case ready, pouring, done }
    private var screen: Screen {
        switch state {
        case .ready, .unavailable: .ready
        case .complete: .done
        case .preparing, .pouring, .approachingTarget, .uncertain: .pouring
        }
    }

    /// Data Collection is a developer tool for recording training clips: Debug builds run from Xcode only,
    /// never the App Store or TestFlight build.
    private static let dataCollectionEnabled: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    var body: some View {
        // ZStack with a fixed order (Ready < Pouring < Done), so a screen that rises in or drains away
        // always passes in front of the one underneath.
        ZStack {
            switch state {
            case .ready, .unavailable:
                ReadyView(problem: state == .unavailable ? micProblem : nil, onStart: { start() },
                          cupName: cups.selected?.name, onOpenCups: { showingCups = true },
                          onOpenDataCollection: Self.dataCollectionEnabled ? { showingDataCollection = true } : nil)
                    .transition(.opacity)
                    .zIndex(0)
            case .preparing, .pouring, .approachingTarget, .uncertain:
                PouringView(state: state, fillPercent: engine.fillPercent, fillMethod: engine.fillMethod,
                            source: pipeline.source, sensors: sensors, sceneColors: camera.sceneColors,
                            calibrating: calibratingCup != nil, onStop: calibratingCup == nil ? stop : finishCalibration)
                    // The liquid rises in; stopping fades back to the start.
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
                    .zIndex(1)
            case .complete:
                CompleteView(targetPercent: engine.targetPercent, onAgain: { start() }, onHome: engine.end)
                    // Rises over the pour as the glass fills; drains away on HOME or AGAIN.
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.6), value: screen)
        .sheet(isPresented: $showingDataCollection) {
            DataCollectionView(recorder: recorder)
        }
        .sheet(isPresented: $showingCups) {
            CupsView(store: cups) { cup in start(calibrating: cup) }
        }
        .onAppear {
            engine.onEvent = { [feedback] event in feedback.handle(event) }
            watch.onCommand = { command in
                switch command {
                case .startPour, .pourAgain: if !state.isActive { start() }
                case .stop: if state.isActive { stop() }
                }
            }
            watch.onTargetChanged = { percent in
                cups.targetPercent = percent
                engine.targetPercent = percent
            }
            watch.activate()
        }
        .onChange(of: watchMessage, initial: true) { watch.send(watchMessage) }
        // Framing tips only before the pour: moving the phone mid-pour would be worse than no tip.
        .onChange(of: camera.cue) {
            if state == .preparing, let cue = camera.cue { feedback.framing(cue) }
        }
        .onChange(of: state.isActive) { _, active in
            if !active { camera.stop() }
        }
        .onChange(of: watch.motion?.receivedAt) {
            // Tilt older than a second says nothing about now.
            guard let motion = watch.motion else { return }
            engine.watchTilting = motion.state.isTilting && Date.now.timeIntervalSince(motion.receivedAt) < 1
        }
        // Pouring has a dark background, the other screens a light one; this sets the status bar to match.
        .preferredColorScheme(state.isActive ? .dark : .light)
        // VoiceOver two-finger double-tap: start, stop, or pour again.
        .accessibilityAction(.magicTap) { state.isActive ? stop() : start() }
        .onChange(of: state, initial: true) {
            // Keep the screen, and with it the microphone, on while pouring.
            UIApplication.shared.isIdleTimerDisabled = state.isActive
        }
        .onChange(of: pipeline.latest) {
            if let reading = pipeline.latest { engine.ingest(reading) }
        }
        .onChange(of: pipeline.fill) {
            engine.ingest(pipeline.fill)
        }
        .onChange(of: audio.state) {
            engine.microphoneChanged(audio.state)
        }
        // Siri, the Action Button or the Control Center control asked for a pour.
        .onChange(of: launchRequest.count, initial: true) { _, count in
            if count > 0, !state.isActive { start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background where state.isActive:
                // iOS cuts off the microphone in the background, so the pour can't go on. End it cleanly
                // (a calibration pour is dropped, not saved) instead of leaving a frozen level on screen.
                calibratingCup = nil
                stop()
                stoppedInBackground = true
            case .active:
                if stoppedInBackground {
                    stoppedInBackground = false
                    feedback.announceStoppedInBackground()
                }
                if cups.autoStart, state == .ready { start() }
            default:
                break
            }
        }
        .onChange(of: state) { _, new in
            guard new == .complete || new == .unavailable else { return }
            // Keep the audio session a moment so the spoken "Stop!" isn't cut off.
            pipeline.stop(audio, releaseSession: false)
            Task {
                try? await Task.sleep(for: .seconds(3))
                audio.releaseSession()
            }
        }
    }

    private func start(calibrating cup: ContainerProfile? = nil) {
        if audio.state == .permissionDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
            openURL(settings)
            return
        }
        calibratingCup = cup
        engine.targetPercent = cups.targetPercent
        engine.calibrating = cup != nil
        // The Watch's tap reaches the wrist sooner than speech reaches the ear.
        engine.reactionSeconds = watch.isReachable ? PourEstimationEngine.watchReactionSeconds : PourEstimationEngine.speechReactionSeconds
        feedback.speechEnabled = cups.speechEnabled
        engine.begin()
        if cups.cameraHelp, cup == nil { Task { await camera.start() } }
        Task {
            await pipeline.start(with: audio, calibration: cup == nil ? cups.selected?.calibration : nil, calibrating: cup != nil)
            if audio.state != .running { engine.microphoneChanged(audio.state) }
        }
    }

    private func stop() {
        pipeline.stop(audio)
        engine.end()
    }

    /// The user tapped Full on a calibration pour: save what was measured.
    private func finishCalibration() {
        guard let cup = calibratingCup else { return }
        let calibration = pipeline.finishCalibration()
        pipeline.stop(audio, releaseSession: false)
        calibratingCup = nil
        engine.calibrating = false
        engine.end()
        if let calibration {
            cups.setCalibration(calibration, for: cup.id)
            cups.selectedID = cup.id
        }
        feedback.announceCalibration(calibration)
        Task {
            try? await Task.sleep(for: .seconds(4))
            audio.releaseSession()
        }
    }

    private var sensors: [SensorKind: SensorStatus] {
        let microphone: SensorStatus = switch audio.state {
        case .running: .active
        case .interrupted: .lowConfidence
        default: .unavailable
        }
        return [.microphone: microphone, .camera: camera.status, .watch: watch.isReachable ? .active : .unavailable]
    }

    /// What the Watch shows and buzzes.
    private var watchMessage: PhoneToWatchMessage {
        PhoneToWatchMessage(state: state, fillPercent: engine.fillPercent,
                            targetPercent: state.isActive ? engine.targetPercent : cups.targetPercent,
                            containerLocked: [.pouring, .approachingTarget, .complete].contains(state))
    }

    private var micProblem: LocalizedStringKey {
        switch audio.state {
        case .permissionDenied: "Microphone access is off. Tap Fill up to open Settings."
        case .failed(let message): "Can't use the microphone: \(message)"
        default: "The microphone isn't available right now."
        }
    }
}

// MARK: - Ready

struct ReadyView: View {
    /// Replaces the subtitle when the last attempt failed.
    var problem: LocalizedStringKey?
    let onStart: () -> Void
    var cupName: String?
    var onOpenCups: (() -> Void)?
    var onOpenDataCollection: (() -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 64
    @ScaledMetric(relativeTo: .title3) private var subtitleSize = 22
    @ScaledMetric(relativeTo: .largeTitle) private var buttonSize = 96
    @ScaledMetric(relativeTo: .title3) private var settingsSize = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Settings is a big labelled button in the layout (not a small icon floating over the title),
            // so it's easy to hit and large text can't overlap it. VoiceOver reads it last (sort priority).
            HStack(spacing: 8) {
                Spacer()
                if let onOpenDataCollection {
                    // Developer tool, Debug builds only.
                    Button(action: onOpenDataCollection) {
                        Image(systemName: "waveform")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Data collection")
                    .accessibilityHint("Records labelled sound clips for training.")
                }
                if let onOpenCups {
                    Button(action: onOpenCups) {
                        Label("Settings", systemImage: "gearshape.fill")
                            .font(.senso(min(settingsSize, 34), .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 20)
                            .frame(minHeight: 64)
                            .overlay(Capsule().stroke(SensoColor.crimson, lineWidth: 3))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(cupName ?? String(localized: "No cup chosen"))
                    .accessibilityHint("Your cups, calibration, stop level and voice.")
                }
            }

            // Explicit break: iOS would otherwise move "to" down to avoid a lone "pour?".
            Text("Ready to\npour?")
                .font(.senso(titleSize))
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(3)
            Text(problem ?? "Tap to start. We’ll guide you.")
                .font(.senso(subtitleSize, .regular))
                .minimumScaleFactor(0.6)
                .accessibilitySortPriority(2)

            Button(action: onStart) {
                // Two Texts with negative spacing: SwiftUI ignores negative lineSpacing.
                VStack(alignment: .leading, spacing: -fillUpSize * 0.36) {
                    Text("FILL")
                    Text("UP!")
                }
                .font(.senso(fillUpSize))
                .foregroundStyle(SensoColor.sky)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                // The label bleeds off the bottom edge, as in the design.
                .offset(y: fillUpSize * 0.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .background(SensoColor.crimson)
                .clipShape(.rect(cornerRadius: 56))
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
            .accessibilityLabel("Fill up")
            .accessibilityHint("Starts listening. Put the phone next to your cup.")
            .accessibilitySortPriority(1)
        }
        .accessibilityElement(children: .contain)
        .foregroundStyle(SensoColor.crimson)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
    }

    /// Display text is already huge; capping it keeps the bleed offset in step with what's drawn.
    private var fillUpSize: CGFloat { min(buttonSize, 120) }
}

// MARK: - Pouring

struct PouringView: View {
    let state: PourState
    let fillPercent: Int?
    var fillMethod: FillMethod?
    let source: EstimateSource
    let sensors: [SensorKind: SensorStatus]
    /// Live colours from the camera (3 × 3, row by row), when camera help is on.
    var sceneColors: [SIMD3<Float>]? = nil
    /// Calibration pour: the button says "Full" and saves the cup's measurements.
    var calibrating = false
    let onStop: () -> Void

    @AccessibilityFocusState private var percentFocused: Bool
    @ScaledMetric(relativeTo: .title) private var headlineSize = 36
    @ScaledMetric(relativeTo: .title2) private var detailSize = 30
    @ScaledMetric(relativeTo: .largeTitle) private var percentSize = 88
    @ScaledMetric(relativeTo: .title3) private var stopSize = 22

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                SensorBadge(source: source, sensors: sensors, fillMethod: fillMethod)
                Spacer()
                Text(headline)
                    .font(.senso(headlineSize, .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(.senso(detailSize, .regular))
                        .padding(.top, 40)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // "Listening…" → "Keep pouring" → "Until you hear the alert." fade into each other.
            .animation(.easeInOut(duration: 0.35), value: state)

            VStack(spacing: 0) {
                Spacer()
                Text(fillText(fillPercent))
                    .font(.senso(percentSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    // The digits roll from one value to the next instead of jumping.
                    .contentTransition(.numericText(value: Double(fillPercent ?? 0)))
                    .animation(.smooth(duration: 0.6), value: fillPercent)
                    .accessibilityLabel(fillPercent.map { Text("About \($0) percent full") } ?? Text("No fill estimate yet"))
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityFocused($percentFocused)
                Spacer()
                Button(action: onStop) {
                    Text(calibrating ? "Full" : "Stop")
                        .font(.senso(stopSize, .semibold))
                        .padding(.horizontal, 44)
                        .frame(minHeight: 56)
                        .overlay(Capsule().stroke(.white, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityHint(calibrating ? "Saves this pour as the cup's full level." : "Stops listening and goes back to the start.")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { height, _ in height * 0.44 }
            .background {
                MovingLiquid(amplitude: 7, wavelength: 100, color: SensoColor.crimson)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .background { PourBackdrop(colors: sceneColors).ignoresSafeArea() }
        // Smart Invert would turn the crimson warning cyan.
        .accessibilityIgnoresInvertColors()
        // When the pour starts, VoiceOver moves to the number that matters.
        .onChange(of: state) { _, new in
            if new == .pouring { percentFocused = true }
        }
    }

    private var headline: LocalizedStringKey {
        switch state {
        case _ where calibrating: "Calibrating"
        case .preparing: "Listening…"
        case .uncertain: "Can’t hear the pour"
        default: "Keep pouring"
        }
    }

    private var detail: LocalizedStringKey? {
        switch state {
        case _ where calibrating: "Pour into the empty cup until it’s full, then tap Full."
        case .preparing: "Start pouring when you’re ready."
        case .approachingTarget: "Until you hear the alert."
        case .uncertain: "Keep the phone next to the cup."
        case .pouring where fillPercent == nil: "Can’t hear the level yet. Check with your finger."
        default: nil
        }
    }
}

/// The design's blurred camera feed. With camera help on, the 3 × 3 colours come from the live image
/// (CameraCapture.sceneColors), so the background follows whatever the camera sees, like an extremely
/// blurred preview. Those colours are capped in brightness, so white text keeps 7:1 contrast. With the
/// camera off, a still palette stands in.
struct PourBackdrop: View {
    var colors: [SIMD3<Float>]?

    private static let still: [Color] = [
        .rgb(0x57, 0x54, 0x4F), .rgb(0x4A, 0x45, 0x3F), .rgb(0x2E, 0x2C, 0x29),
        .rgb(0x55, 0x52, 0x4D), .rgb(0x5A, 0x52, 0x46), .rgb(0x3A, 0x38, 0x34),
        .rgb(0x2E, 0x2C, 0x29), .rgb(0x4A, 0x45, 0x3F), .rgb(0x5C, 0x54, 0x40),
    ]

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.5, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: colors?.count == 9 ? colors!.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) } : Self.still
        )
        // About 10 new colour sets a second; easing between them keeps it fluid rather than flickery.
        .animation(.easeInOut(duration: 0.35), value: colors)
    }
}

private extension Color {
    static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

/// Which sensors are on and where the estimate comes from. Not in the mock-up; required so a
/// heuristic is never mistaken for a trained model.
struct SensorBadge: View {
    let source: EstimateSource
    let sensors: [SensorKind: SensorStatus]
    var fillMethod: FillMethod?

    var body: some View {
        // One row normally; icons above the text at large Dynamic Type sizes.
        VStack(spacing: 4) {
            ViewThatFits {
                HStack(spacing: 10) { icons; Text(sourceText) }
                VStack(spacing: 6) { icons; Text(sourceText).multilineTextAlignment(.center) }
            }
            if let fillMethod {
                Text(methodText(fillMethod))
                    .font(.system(.caption, weight: .medium).width(.expanded))
                    .multilineTextAlignment(.center)
            }
        }
        .font(.system(.footnote, weight: .semibold).width(.expanded))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var icons: some View {
        HStack(spacing: 10) {
            ForEach(SensorKind.allCases, id: \.self) { kind in
                Image(systemName: symbol(kind))
            }
        }
    }

    private func status(_ kind: SensorKind) -> SensorStatus { sensors[kind] ?? .unavailable }

    private func symbol(_ kind: SensorKind) -> String {
        let off = status(kind) == .unavailable
        switch kind {
        case .microphone: return off ? "mic.slash.fill" : "mic.fill"
        case .camera: return off ? "video.slash.fill" : "video.fill"
        case .watch: return off ? "applewatch.slash" : "applewatch"
        }
    }

    private var sourceText: LocalizedStringKey {
        switch source {
        case .trainedModel(let version): "Model \(version)"
        case .dspFallback: "DSP Mode (Uncalibrated)"
        case .none: "No estimate yet"
        }
    }

    private func methodText(_ method: FillMethod) -> LocalizedStringKey {
        switch method {
        case .pitchCalibrated: "Level from pitch, calibrated cup"
        case .pitchUncalibrated: "Level from pitch, rough (cup not calibrated)"
        case .timeCalibrated: "Level from pour time, rough"
        }
    }

    private var accessibilityText: Text {
        let parts = SensorKind.allCases.map { kind -> Text in
            let name: Text = switch kind {
            case .microphone: Text("Microphone")
            case .camera: Text("Camera")
            case .watch: Text("Watch")
            }
            let state: Text = switch status(kind) {
            case .active: Text("on")
            case .lowConfidence: Text("weak")
            case .unavailable: Text("off")
            }
            return Text("\(name) \(state). ")
        }
        let method = fillMethod.map { Text(". ") + Text(methodText($0)) } ?? Text("")
        return parts.reduce(Text(""), +) + Text(sourceText) + method
    }
}

// MARK: - Done

struct CompleteView: View {
    var targetPercent = 100
    let onAgain: () -> Void
    let onHome: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 38
    @ScaledMetric(relativeTo: .title2) private var subtitleSize = 27
    @ScaledMetric(relativeTo: .largeTitle) private var percentSize = 88
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Done!")
                .font(.senso(titleSize))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .onAppear { titleFocused = true }
            Text("Your glass is full")
                .font(.senso(subtitleSize, .regular))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Spacer(minLength: 16)
            Text("\(targetPercent)%")
                .font(.senso(percentSize))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(targetPercent) percent full")
            Spacer(minLength: 16)
            VStack(spacing: 24) {
                SlabButton(title: "AGAIN", systemImage: "arrow.counterclockwise", background: .white, bleeds: false, action: onAgain)
                    .accessibilityHint("Starts a new pour.")
                SlabButton(title: "HOME", systemImage: "arrow.left", background: SensoColor.sky, bleeds: true, action: onHome)
                    .accessibilityHint("Goes back to the start screen.")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .padding(.bottom, 8)
        .background {
            // The glass is full: liquid right up to just under the status bar.
            MovingLiquid(amplitude: 4, wavelength: 100, color: SensoColor.crimson)
                .ignoresSafeArea(edges: .bottom)
        }
        .background {
            LinearGradient(colors: [.white, SensoColor.skyMist], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        }
    }
}

/// The big AGAIN / HOME buttons: icon top-right, oversized label bottom-left.
struct SlabButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let background: Color
    /// Push the label past the bottom edge, as the design does for HOME.
    let bleeds: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var size = 68

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemImage)
                    .font(.system(size: labelSize * 0.95, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                Text(title)
                    .font(.senso(labelSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .offset(y: bleeds ? labelSize * 0.2 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, bleeds ? 0 : 16)
            .padding(.top, bleeds ? 16 : 0)
            .foregroundStyle(SensoColor.crimson)
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 175)
            .background(background)
            .clipShape(.rect(cornerRadius: 34))
        }
        .buttonStyle(.plain)
    }

    /// Already display-sized; past this the label would run into the icon.
    private var labelSize: CGFloat { min(size, 70) }
}

// MARK: - Previews (design fixtures, not sensor data)

#Preview("Ready") { ReadyView(onStart: {}) }

#Preview("Pouring 45%") {
    PouringView(state: .pouring, fillPercent: 45, source: .dspFallback,
                sensors: [.microphone: .active], onStop: {})
}

#Preview("High alert 72%") {
    PouringView(state: .approachingTarget, fillPercent: 72, source: .dspFallback,
                sensors: [.microphone: .active, .watch: .active], onStop: {})
}

#Preview("Listening") {
    PouringView(state: .preparing, fillPercent: nil, source: .none, sensors: [.microphone: .active], onStop: {})
}

#Preview("Done") { CompleteView(onAgain: {}, onHome: {}) }

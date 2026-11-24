// SensoMainViews.swift
// iPhone UI, built to the final design ("FINAL DES. Almost Purple"): Ready → Pouring → Done.
// PourEstimationEngine decides the state and the number; PourFeedback speaks; the views only show.

import CoreText
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
            #if DEBUG
            .task { if DemoPour.isOn { await DemoPour.run(engine) } }
            #endif
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
    /// never the App Store or TestFlight build. Hidden in the demo, so a recording shows what users see.
    private static let dataCollectionEnabled: Bool = {
        #if DEBUG
        !DemoPour.isOn
        #else
        false
        #endif
    }()

    var body: some View {
        // ZStack with a fixed order (Ready < Pouring < Done). Every screen is white, so a screen sliding over
        // another would seem to cut it in half: the pour pushes the start screen up and out, and Done fades in
        // over the pour, whose glass sits in the same place.
        ZStack {
            switch state {
            case .ready, .unavailable:
                ReadyView(problem: state == .unavailable ? micProblem : nil, onStart: { start() },
                          cupName: cups.selected?.name, onOpenCups: { showingCups = true },
                          onOpenDataCollection: Self.dataCollectionEnabled ? { showingDataCollection = true } : nil)
                    // Pushed up and away as the pour rises in; fades back in afterwards.
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .push(from: .bottom)))
                    .zIndex(0)
            case .preparing, .pouring, .approachingTarget, .uncertain:
                PouringView(state: state, fillPercent: engine.fillPercent, sceneColors: camera.sceneColors,
                            calibrating: calibratingCup != nil, onStop: calibratingCup == nil ? stop : finishCalibration)
                    // Rises in; fades out. (Moving it out would also make the rolling number jump.)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .push(from: .bottom), removal: .opacity))
                    .zIndex(1)
            case .complete:
                CompleteView(targetPercent: engine.targetPercent, onAgain: { start() }, onHome: engine.end)
                    // The same glass, now full: fades in over the pour, and away on HOME or AGAIN.
                    .transition(.opacity)
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
        // A cup confirmed in view lets the pour start; the engine keeps saying when there's none.
        // Optional camera: a cup in view lets a slightly weaker pour sound count. It never holds the pour up.
        .onChange(of: camera.cupConfirmed) { _, confirmed in
            if confirmed { engine.cupSeen() }
        }
        // The level counts from the first pour sound, so noise heard before it can't raise the counter.
        .onChange(of: engine.pourStarted) { _, started in
            if started { pipeline.restartFill() }
        }
        // Aiming tips are the optional camera help, once the cup is found. None mid-pour: moving the
        // phone then would be worse than no tip.
        .onChange(of: camera.cue) {
            guard state == .preparing, let cue = camera.cue else { return }
            feedback.framing(cue)
        }
        .onChange(of: state.isActive) { _, active in
            if !active { camera.stop() }
        }
        .onChange(of: watch.motion?.receivedAt) {
            // Tilt older than a second says nothing about now.
            guard let motion = watch.motion else { return }
            engine.watchTilting = motion.state.isTilting && Date.now.timeIntervalSince(motion.receivedAt) < 1
        }
        // Every screen is white, as designed; this keeps the status bar dark on it.
        .preferredColorScheme(.light)
        // VoiceOver two-finger double-tap: start, stop, or pour again.
        .accessibilityAction(.magicTap) { state.isActive ? stop() : start() }
        .sensoryFeedback(trigger: state) { old, new in PourFeedback.haptic(from: old, to: new) }
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
        // The camera is an option (Settings): it runs alongside the microphone and never delays the pour.
        // Without permission or a camera, Senso simply works by sound.
        if cups.cameraHelp {
            Task {
                await camera.start()
                if !state.isActive { camera.stop() }
            }
        }
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

    /// What the Watch shows and buzzes.
    private var watchMessage: PhoneToWatchMessage {
        PhoneToWatchMessage(state: state, fillPercent: engine.fillPercent,
                            targetPercent: state.isActive ? engine.targetPercent : cups.targetPercent,
                            containerLocked: [.pouring, .approachingTarget, .complete].contains(state))
    }

    private var micProblem: AttributedString {
        switch audio.state {
        case .permissionDenied: AttributedString(localized: "Microphone access is off. Tap Fill up to open Settings.")
        case .failed(let message): AttributedString(localized: "Can't use the microphone: \(message)")
        default: AttributedString(localized: "The microphone isn't available right now.")
        }
    }
}

// MARK: - Ready

struct ReadyView: View {
    /// Replaces the subtitle when the last attempt failed.
    var problem: AttributedString?
    let onStart: () -> Void
    var cupName: String?
    var onOpenCups: (() -> Void)?
    var onOpenDataCollection: (() -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 63
    @ScaledMetric(relativeTo: .title2) private var subtitleSize = 25
    @ScaledMetric(relativeTo: .largeTitle) private var fillLabelSize = 88
    @ScaledMetric(relativeTo: .title3) private var settingsSize = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Settings is a big labelled button above the title (not a small icon over it), so it's easy to
            // hit and large text can't overlap it. VoiceOver reads it last (sort priority).
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
                            .frame(minHeight: 56)
                            .overlay(Capsule().strokeBorder(SensoColor.ink, lineWidth: 3))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(cupName ?? String(localized: "No cup chosen"))
                    .accessibilityHint("Your cups, calibration, stop level and voice.")
                }
            }
            .padding(.vertical, 3)
            // The space above the design's title, so the title stays where it was drawn.
            .frame(minHeight: 62)

            // Two Texts, as SwiftUI ignores negative line spacing: the design sets the lines 60 pt apart.
            VStack(alignment: .leading, spacing: titleSize * (60 / 63 - sfLineHeight)) {
                Text("Ready to")
                Text("pour?")
            }
            .font(.senso(titleSize, .heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.leading, 25)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ready to pour?")
            .accessibilityAddTraits(.isHeader)
            .accessibilitySortPriority(3)

            designSubtitle(problem ?? AttributedString(localized: "**Tap** to start. We’ll **guide** you."), size: subtitleSize)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .padding(.top, 15)
                .accessibilitySortPriority(2)

            Button(action: onStart) {
                // Two Texts with negative spacing: SwiftUI ignores negative lineSpacing.
                VStack(spacing: fillSize * -0.4239) {
                    Text("FILL")
                        .font(.senso(fillSize, .heavy))
                    Text("UP!")
                        .font(.senso(fillSize * 103 / 88, .heavy))
                        .tracking(fillSize * 103 / 88 * 0.0173)
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(24)
                // As drawn, the words sit a little below the middle.
                .offset(y: fillSize * 6 / 88)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SensoColor.water, in: .rect(cornerRadius: 55, style: .circular))
                .overlay(RoundedRectangle(cornerRadius: 55, style: .circular).strokeBorder(SensoColor.rim, lineWidth: 8))
            }
            .buttonStyle(.plain)
            .padding(.top, 28)
            .accessibilityLabel("Fill up")
            .accessibilityHint("Starts listening. Put the phone next to your cup.")
            .accessibilitySortPriority(1)
        }
        .accessibilityElement(children: .contain)
        .foregroundStyle(SensoColor.ink)
        .padding(.horizontal, 8)
        .padding(.bottom, 21)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
    }

    /// Display text is already huge; capping it keeps the words inside the button.
    private var fillSize: CGFloat { min(fillLabelSize, 110) }
}

/// SF Pro's line height as a share of the font size (ascender 0.952 + descender 0.241). The design gives
/// baselines; SwiftUI lays out line boxes, so spacings between Texts are worked out with this.
private let sfLineHeight: CGFloat = 1.1934

/// The design's subtitles: SF Pro medium, with the words marked **like this** in bold, and 0.5% tracking.
/// Fonts are set run by run because SwiftUI's own Markdown bold is lost once a font sets its weight.
private func designSubtitle(_ text: AttributedString, size: CGFloat) -> some View {
    var text = text
    for run in text.runs {
        let bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        text[run.range].font = .system(size: size, weight: bold ? .bold : .medium)
        text[run.range].inlinePresentationIntent = nil
    }
    return Text(text).tracking(size * 0.005)
}

/// SF Pro at its widest (width 150), which the design uses for the numbers and AGAIN; `.expanded` is 132.
private func widestFont(_ size: CGFloat, weight: CGFloat) -> Font {
    // Variation axes as four-character tags: "wdth", "wght", and "opsz" (optical size, as the system sets it).
    let axes: [NSNumber: NSNumber] = [0x7764_7468: 150, 0x7767_6874: NSNumber(value: Double(weight)),
                                      0x6F70_737A: NSNumber(value: Double(min(max(size, 17), 96)))]
    let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
        .addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes])
    return Font(UIFont(descriptor: descriptor, size: size))
}

// MARK: - Pouring

struct PouringView: View {
    let state: PourState
    let fillPercent: Int?
    /// Live colours from the camera (3 × 3, row by row), when camera help is on.
    var sceneColors: [SIMD3<Float>]? = nil
    /// Calibration pour: a Full button replaces the number, and saves the cup's measurements.
    var calibrating = false
    let onStop: () -> Void

    @AccessibilityFocusState private var percentFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var percentSize = 80
    @ScaledMetric(relativeTo: .title) private var fullSize = 34
    /// The last known level, so the water holds its height when an estimate drops out.
    @State private var level = 0

    /// The counter starts at 0 before the pour and holds the level during a pause; mid-pour without an
    /// estimate it shows a dash, never a made-up number.
    private var shownPercent: Int? {
        fillPercent ?? (state == .preparing && !calibrating ? level : nil)
    }

    var body: some View {
        GlassLayout(subtitle: detail, subtitleGap: 13.56) {
            Text(headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: calibrating ? "Full" : "Stop", onStop)
                // "Listening…" → "Keep Pouring" fade into each other.
                .animation(.easeInOut(duration: 0.35), value: state)
        } glass: {
            // The water is the level: it starts at the bottom and rises with the glass.
            PourGlass(waterLine: GlassWater.line(percent: level), waveHeight: 3.72, sceneColors: sceneColors)
                .animation(.smooth(duration: 0.6), value: level)
        } bottom: {
            if calibrating {
                Button(action: onStop) {
                    Text("Full")
                        .font(.senso(min(fullSize, 48), .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(SensoColor.water, in: .capsule)
                        .overlay(Capsule().strokeBorder(SensoColor.rim, lineWidth: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .accessibilityHint("Saves this pour as the cup's full level.")
            } else {
                Text(fillText(shownPercent))
                    .font(widestFont(percentSize, weight: 1000))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    // Changes at once, without rolling digits: the level updates several times a second, so a
                    // rolling digit would be blurred most of the time and hard to read.
                    .accessibilityLabel(shownPercent.map { Text("About \($0) percent full") } ?? Text("No fill estimate yet"))
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityFocused($percentFocused)
                    .accessibilityAction(named: "Stop", onStop)
            }
        }
        .contentShape(.rect)
        // No Stop button, as designed: swipe down, the VoiceOver Stop action, Magic Tap or the Watch stop.
        // A calibration pour ends only with Full, never by an accidental swipe.
        .gesture(swipeDown(onStop), isEnabled: !calibrating)
        .onChange(of: fillPercent, initial: true) { _, percent in
            if let percent { level = percent }
        }
        // When the pour starts, VoiceOver moves to the number that matters.
        .onChange(of: state) { _, new in
            if new == .pouring { percentFocused = true }
        }
    }

    private var headline: LocalizedStringKey {
        switch state {
        case _ where calibrating: "Calibrating"
        case .preparing where level > 0: "Paused"
        case .preparing: "Listening…"
        case .uncertain: "Can’t hear the pour"
        default: "Keep Pouring"
        }
    }

    private var detail: AttributedString {
        switch state {
        case _ where calibrating: AttributedString(localized: "Pour into the empty cup until it’s full, then tap Full.")
        case .preparing where level > 0: AttributedString(localized: "Pour again when you’re ready.")
        case .preparing: AttributedString(localized: "Start pouring when you’re ready.")
        case .uncertain: AttributedString(localized: "Keep the phone next to the cup.")
        case .pouring where fillPercent == nil: AttributedString(localized: "Can’t hear the level yet.")
        default: AttributedString(localized: "Until you hear the **alert**!")
        }
    }
}

/// The Pouring and Done layout from the design: title, subtitle, the glass, and the big number below.
/// Spacings are the design's, measured between line boxes on the 402 × 874 pt screen; the glass takes
/// whatever height is left, so smaller and larger iPhones keep the same look.
private struct GlassLayout<Title: View, Glass: View, Bottom: View>: View {
    var subtitle: AttributedString
    /// Title to subtitle. The two screens differ by 3 pt in the design; the glass stays put.
    var subtitleGap: CGFloat
    @ViewBuilder var title: Title
    @ViewBuilder var glass: Glass
    @ViewBuilder var bottom: Bottom

    @ScaledMetric(relativeTo: .title) private var titleSize = 40
    @ScaledMetric(relativeTo: .title2) private var subtitleSize = 25

    var body: some View {
        VStack(spacing: 0) {
            title
                .font(.senso(titleSize, .bold))
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 16)
                .padding(.top, 67.92)
            designSubtitle(subtitle, size: subtitleSize)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 16)
                .padding(.top, subtitleGap)
            glass
                .padding(.horizontal, 8)
                .padding(.top, 64.53 - subtitleGap)
                .frame(maxHeight: .infinity)
            bottom
                .padding(.top, 14.84)
                .padding(.bottom, 25.72)
        }
        .foregroundStyle(SensoColor.ink)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }
}

/// The design's glass: the camera's view inside a pale rim and a hand-drawn blue one, with the water up to
/// `waterLine` (the wave's resting line, as a share of the glass's height from the bottom).
struct PourGlass<Content: View>: View {
    var waterLine: CGFloat
    /// How far the wave rises and dips from its resting line, in points.
    var waveHeight: CGFloat
    var sceneColors: [SIMD3<Float>]? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            // Blue behind the picture, which stays inside the hand-drawn rim: in the design, water hides the
            // strip between the two rims, and an empty glass must look the same.
            RoundedRectangle(cornerRadius: 55, style: .circular)
                .fill(SensoColor.water)
            PourBackdrop(colors: sceneColors)
                .clipShape(.rect(cornerRadius: 55, style: .circular))
                .padding(.leading, 9)
                .padding(.trailing, 6)
                .clipShape(HandDrawnRim())
            // Inside the hand-drawn rim too: shallow water has small corners, which would poke out of the glass.
            // Outside that rim it's blue anyway, so the design's look is unchanged.
            MovingWater(line: waterLine, waveHeight: waveHeight)
                .clipShape(HandDrawnRim())
            RoundedRectangle(cornerRadius: 55, style: .circular)
                .strokeBorder(SensoColor.rim, lineWidth: 9)
            // As drawn: an 18 pt stroke clipped to the inside of the shape, so 9 pt shows.
            HandDrawnRim()
                .stroke(SensoColor.water, lineWidth: 18)
                .clipShape(HandDrawnRim())
            content
        }
        // Smart Invert would turn the blue water orange and the picture into a negative.
        .accessibilityIgnoresInvertColors()
    }
}

extension PourGlass where Content == EmptyView {
    init(waterLine: CGFloat, waveHeight: CGFloat, sceneColors: [SIMD3<Float>]? = nil) {
        self.init(waterLine: waterLine, waveHeight: waveHeight, sceneColors: sceneColors) { EmptyView() }
    }
}

/// The water in the glass, alive like MovingLiquid: the wave drifts one wavelength every 3 s and gently
/// swells. Still when Reduce Motion is on, and then exactly as drawn.
struct MovingWater: View {
    var line: CGFloat
    var waveHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GlassWater(line: line, amplitude: waveHeight,
                       phase: CGFloat(time.truncatingRemainder(dividingBy: 3) / 3 * 2 * .pi),
                       swell: CGFloat(1 + 0.15 * sin(time.truncatingRemainder(dividingBy: 5) / 5 * 2 * .pi)))
                .fill(SensoColor.water)
        }
    }
}

/// The water's outline, as drawn: a wave on top that rises from the left edge, 30 pt rounded corners at the
/// bottom and the top left, from the picture's left edge to just inside the rims.
nonisolated struct GlassWater: Shape {
    /// The wave's resting line, as a share of the glass's height from the bottom.
    var line: CGFloat
    var amplitude: CGFloat
    /// Shifts the wave sideways, in radians (2π = one wavelength).
    var phase: CGFloat = 0
    /// Scales the wave's height around its resting line; 1 is the design's wave.
    var swell: CGFloat = 1

    static let wavelength: CGFloat = 91.79
    /// The Done screen's full glass.
    static let fullLine: CGFloat = 0.8947

    /// Where the water rests for a fill level. Through the design's two drawings (42% at 0.4543, and the
    /// full glass at 100%), so the pour ends where the Done screen's glass begins.
    static func line(percent: Int) -> CGFloat {
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100
        let drawn: CGFloat = 0.4543
        return fraction <= 0.42 ? fraction / 0.42 * drawn : drawn + (fraction - 0.42) / 0.58 * (fullLine - drawn)
    }

    var animatableData: CGFloat {
        get { line }
        set { line = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + 9, right = rect.maxX - 8, bottom = rect.maxY - 8
        let rest = rect.maxY - rect.height * line
        let wave = amplitude * swell
        let top = rest - wave
        guard top < bottom, left < right else { return Path() }
        func surface(_ x: CGFloat) -> CGPoint {
            CGPoint(x: x, y: rest - wave * sin(2 * .pi * (x - left) / Self.wavelength + phase))
        }
        var water = Path()
        water.move(to: surface(left))
        for x in stride(from: left + 1, to: right, by: 1) { water.addLine(to: surface(x)) }
        water.addLine(to: surface(right))
        water.addLine(to: CGPoint(x: right, y: rect.maxY))
        water.addLine(to: CGPoint(x: left, y: rect.maxY))
        water.closeSubpath()
        let corners = UnevenRoundedRectangle(topLeadingRadius: 30, bottomLeadingRadius: 30, bottomTrailingRadius: 30,
                                             topTrailingRadius: 0, style: .circular)
        return water.intersection(corners.path(in: CGRect(x: left, y: top, width: right - left, height: bottom - top)))
    }
}

/// The design's hand-drawn blue rim: a slightly uneven rounded square. Points are the design's, in points
/// from the nearest corner of the 386 × 432 pt glass, so a taller or shorter glass keeps the same corners.
nonisolated struct HandDrawnRim: Shape {
    func path(in rect: CGRect) -> Path {
        func topLeft(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x, y: rect.minY + y) }
        func topRight(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x, y: rect.minY + y) }
        func bottomRight(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x, y: rect.maxY - y) }
        func bottomLeft(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x, y: rect.maxY - y) }
        var path = Path()
        path.move(to: topLeft(62.26, 6))
        path.addLine(to: topRight(61.50, 6))
        path.addCurve(to: topRight(6.51, 61.50), control1: topRight(30.93, 6), control2: topRight(6.23, 30.93))
        path.addLine(to: bottomRight(9.33, 60.45))
        path.addCurve(to: bottomRight(64.72, 5.95), control1: bottomRight(9.61, 30.12), control2: bottomRight(34.39, 5.74))
        path.addLine(to: bottomLeft(63.35, 7.78))
        path.addCurve(to: bottomLeft(8.74, 62.51), control1: bottomLeft(33.23, 7.99), control2: bottomLeft(8.88, 32.39))
        path.addLine(to: topLeft(7.26, 61.26))
        path.addCurve(to: topLeft(62.26, 6), control1: topLeft(7.12, 30.79), control2: topLeft(31.79, 6))
        path.closeSubpath()
        return path
    }
}

/// The camera's view inside the glass. With camera help on, the 3 × 3 colours come from the live image
/// (CameraCapture.sceneColors), like an extremely blurred preview. With the camera off, the design's
/// blurred photo stands in.
struct PourBackdrop: View {
    var colors: [SIMD3<Float>]?

    var body: some View {
        if let colors, colors.count == 9 {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.5, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                colors: colors.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) }
            )
            // About 10 new colour sets a second; easing between them keeps it fluid rather than flickery.
            .animation(.easeInOut(duration: 0.35), value: colors)
        } else {
            Image(decorative: "CameraStill")
                .resizable()
        }
    }
}

// MARK: - Done

struct CompleteView: View {
    var targetPercent = 100
    let onAgain: () -> Void
    let onHome: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var percentSize = 80
    @ScaledMetric(relativeTo: .largeTitle) private var againLabelSize = 67
    @AccessibilityFocusState private var titleFocused: Bool

    /// Display-sized already; capped so the icon and label still fit the glass at the largest text sizes.
    private var againSize: CGFloat { min(againLabelSize, 80) }

    var body: some View {
        GlassLayout(subtitle: AttributedString(localized: "Your glass is **full**"), subtitleGap: 10.56) {
            Text("Done!")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .accessibilityAction(named: "Home", onHome)
                .onAppear { titleFocused = true }
        } glass: {
            Button(action: onAgain) {
                // The glass is full, and the whole glass is the AGAIN button.
                PourGlass(waterLine: GlassWater.fullLine, waveHeight: 7.49) {
                    VStack(spacing: againSize * -0.0163) {
                        Text(Image(systemName: "arrow.counterclockwise"))
                            .font(.system(size: againSize * 80 / 67, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("AGAIN")
                            .font(widestFont(againSize, weight: 870))
                            .tracking(againSize * 0.0137)
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(24)
                    // As drawn, a little below the middle of the glass.
                    .offset(y: againSize * 0.112)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Starts a new pour.")
            .accessibilityAction(named: "Home", onHome)
        } bottom: {
            Text("\(targetPercent)%")
                .font(widestFont(percentSize, weight: 1000))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .accessibilityLabel("\(targetPercent) percent full")
        }
        // No Home button, as designed: swipe down (or the VoiceOver Home action) goes back to the start.
        .contentShape(.rect)
        .gesture(swipeDown(onHome))
    }
}

/// Leaving a full-screen step by swiping down, as people dismiss a sheet. It needs a deliberate, mostly
/// vertical drag, so a hand near the screen while pouring doesn't stop the pour.
private func swipeDown(_ action: @escaping () -> Void) -> some Gesture {
    DragGesture(minimumDistance: 30).onEnded { drag in
        if drag.translation.height > 150, abs(drag.translation.width) < drag.translation.height / 2 { action() }
    }
}

// MARK: - Previews (design fixtures, not sensor data)

#Preview("Ready") { ReadyView(onStart: {}) }

#Preview("Pouring 42%") {
    PouringView(state: .pouring, fillPercent: 42, onStop: {})
}

#Preview("High alert 72%") {
    PouringView(state: .approachingTarget, fillPercent: 72, onStop: {})
}

#Preview("Listening") {
    PouringView(state: .preparing, fillPercent: nil, onStop: {})
}

#Preview("Calibrating") {
    PouringView(state: .pouring, fillPercent: nil, calibrating: true, onStop: {})
}

#Preview("Done") { CompleteView(onAgain: {}, onHome: {}) }

// WatchMainView.swift
// Watch UI, built to the final Watch design ("FINAL WATCH Almost Purple"): Ready → fill % → Done.
// The iPhone runs the sensing; the Watch shows its state, taps the wrist (WatchLink) and sets the stop
// target with the Digital Crown.
//
// Numbers are the design's points on the 46 mm Watch (208 × 248 pt), scaled to the screen: across by its
// width, down by its height. The design's SF Pro Expanded isn't available on watchOS, so the text is Archivo,
// sized and spaced to cover the same area as the design's text.

import SwiftUI
import CoreText

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
            WatchPouringView(fillPercent: link.message.fillPercent, preparing: link.message.state == .preparing)
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
    /// True for a moment after the Digital Crown changes the stop target: the title shows the new target.
    @State private var showsTarget = false

    // Not in the design: the title also tells you when the iPhone isn't reachable, or the new stop target.
    private var title: Text {
        if !phoneReachable { Text("Open Senso on iPhone") }
        else if showsTarget { Text("Stop at \(targetPercent)%") }
        else { Text("Ready to pour?") }
    }

    var body: some View {
        GeometryReader { proxy in
            let x = proxy.size.width / 208, y = proxy.size.height / 248
            ZStack(alignment: .top) {
                title
                    .font(.senso(21.35 * x))
                    .tracking(-2.16 * x)
                    .foregroundStyle(SensoColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 8 * x)
                    .accessibilityAddTraits(.isHeader)
                    .baseline(47 * y)
                Button(action: onStart) {
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 49 * x, style: .circular).fill(SensoColor.water)
                        RoundedRectangle(cornerRadius: 49 * x, style: .circular)
                            .strokeBorder(SensoColor.rim, lineWidth: 8 * x)
                        Text("FILL").font(.senso(56.73 * x, .heavy)).tracking(0.55 * x).baseline((145 - 59) * y)
                        Text("UP!").font(.senso(71.75 * x, .heavy)).tracking(0.91 * x).baseline((201 - 59) * y)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 59 * y)
                .accessibilityLabel("Fill up")
                .accessibilityValue(phoneReachable ? Text("Stop alert at \(targetPercent) percent") : Text("iPhone not connected"))
                .accessibilityHint("Starts listening on your iPhone. Turn the Digital Crown to change the stop alert.")
            }
        }
        .background(.white)
        .ignoresSafeArea()
        // Digital Crown: stop target 70–100 % in steps of 5, with a detent tick per step.
        .focusable()
        .digitalCrownRotation($crown, from: Double(PourThresholds.targetRange.lowerBound),
                              through: Double(PourThresholds.targetRange.upperBound), by: 5,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear { crown = Double(targetPercent) }
        .onChange(of: crown) { _, value in
            let percent = Int((value / 5).rounded()) * 5
            guard percent != targetPercent else { return }
            onTargetChange(percent)
            showsTarget = true
        }
        .task(id: showsTarget) {
            guard showsTarget else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { showsTarget = false }
        }
    }
}

struct WatchPouringView: View {
    let fillPercent: Int?
    /// Before the pour (or paused): the counter shows the last level, starting at 0.
    var preparing = false

    /// The last known level, so the water holds its height when an estimate drops out.
    @State private var level = 0

    private var shownPercent: Int? { fillPercent ?? (preparing ? level : nil) }

    var body: some View {
        GeometryReader { proxy in
            let x = proxy.size.width / 208, y = proxy.size.height / 248
            ZStack(alignment: .top) {
                // The design has 12 % at y 195.65 and 52 % at y 111.65: 2.1 pt per percent.
                Water(shape: WatchWater(surface: (220.85 - 2.1 * CGFloat(level)) * y, amplitude: 4.65,
                                        corner: .pouring, scale: x))
                    .animation(.smooth(duration: 0.6), value: level)
                OutlinedPercent(text: fillText(shownPercent), size: 47 * x)
                    .baseline(187 * y)
            }
        }
        .background(.white)
        .ignoresSafeArea()
        .onChange(of: fillPercent, initial: true) { _, percent in
            if let percent { level = percent }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shownPercent.map { Text("\($0) percent full") } ?? Text("No fill estimate yet"))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct WatchCompleteView: View {
    /// The stop level the iPhone used, so the Watch says the same number (not a flat 100%).
    var targetPercent = 100
    let onPourAgain: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let x = proxy.size.width / 208, y = proxy.size.height / 248
            Button(action: onPourAgain) {
                ZStack(alignment: .top) {
                    // The design draws this water 1 pt past the left edge.
                    Water(shape: WatchWater(surface: 21.99 * y, amplitude: 2.99, corner: .done, scale: x))
                        .padding(.leading, -x)
                    Text("Tap to").font(.senso(20.37 * x)).tracking(-0.3 * x).baseline(93 * y)
                    Text("pour again").font(.senso(20.37 * x)).tracking(-0.3 * x).baseline(117 * y)
                    OutlinedPercent(text: fillText(targetPercent), size: 47 * x)
                        .baseline(187 * y)
                }
                .foregroundStyle(.white.opacity(0.9))
                .background(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done. \(targetPercent) percent full.")
            .accessibilityHint("Tap to pour again.")
        }
        .ignoresSafeArea()
    }
}

// MARK: - Design pieces

private extension View {
    /// Puts this line of text centred across the screen, with its baseline `y` points from the top.
    func baseline(_ y: CGFloat) -> some View {
        Color.clear
            .frame(height: y)
            .overlay(alignment: .bottom) { self.alignmentGuide(.bottom) { $0[.lastTextBaseline] } }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The design's water: blue, with a pale 8 pt band just inside its edge.
private struct Water: View {
    let shape: WatchWater

    var body: some View {
        shape.fill(SensoColor.water)
            .overlay { shape.stroke(SensoColor.rim, lineWidth: 16 * shape.scale).clipShape(shape) }
    }
}

/// The design's water outline: a wave on top that curves down into the left edge, and rounded bottom corners.
nonisolated struct WatchWater: Shape {
    /// The wave's middle line, in points from the top.
    var surface: CGFloat
    /// The wave's height above and below its middle line, in design points.
    var amplitude: CGFloat
    var corner: Corner
    /// Screen points per design point.
    var scale: CGFloat

    /// The curve from the left edge up into the wave, in design points below (+) the middle line.
    struct Corner {
        /// Where the left edge meets the curve.
        var drop: CGFloat
        /// The curve's first control point, straight above that.
        var lift: CGFloat
        /// How far left of the wave's start its second control point sits, along the wave.
        var handle: CGFloat

        static let pouring = Corner(drop: 13.16, lift: -0.08, handle: 10.73)
        static let done = Corner(drop: 16.43, lift: 3.19, handle: 12.01)
    }

    var animatableData: CGFloat {
        get { surface }
        set { surface = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = scale, middle = rect.minY + surface
        let left = rect.minX, right = rect.maxX, bottom = rect.maxY
        // Each half wave is a cubic Bézier with its control points a third of the way in, 4/3 × amplitude
        // off the middle line. The first half dips; the last one ends 1.45 pt before the right edge.
        let start = CGPoint(x: left + 25.74 * s, y: middle)
        let end = right - 1.45 * s
        let halves = max(1, Int(((end - start.x) / (25.745 * s)).rounded()))
        let half = (end - start.x) / CGFloat(halves)
        let bulge = amplitude * s * 4 / 3

        let wallTop = middle + corner.drop * s
        var path = Path()
        path.move(to: CGPoint(x: left, y: wallTop))
        path.addCurve(to: start, control1: CGPoint(x: left, y: middle + corner.lift * s),
                      control2: CGPoint(x: start.x - corner.handle * s,
                                        y: middle - corner.handle * s * bulge / (half / 3)))
        var x = start.x
        for index in 0..<halves {
            let y = middle + (index.isMultiple(of: 2) ? bulge : -bulge)
            path.addCurve(to: CGPoint(x: x + half, y: middle), control1: CGPoint(x: x + half / 3, y: y),
                          control2: CGPoint(x: x + half * 2 / 3, y: y))
            x += half
        }
        path.addLine(to: CGPoint(x: right, y: middle))
        // Bottom corners: 49 pt, smaller when the water is too shallow for that.
        let rightRadius = min(49 * s, max(0, bottom - middle))
        path.addLine(to: CGPoint(x: right, y: bottom - rightRadius))
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - rightRadius, y: bottom),
                    radius: rightRadius)
        let leftRadius = min(49 * s, max(0, bottom - wallTop))
        path.addLine(to: CGPoint(x: left + leftRadius, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - leftRadius),
                    radius: leftRadius)
        path.closeSubpath()
        return path
    }
}

/// The design's percentage: white digits with a 2 pt blue outline (a 4 pt blue stroke under the white fill),
/// so they read on white and on the water.
private struct OutlinedPercent: View {
    let text: String
    let size: CGFloat

    var body: some View {
        let glyphs = GlyphText(text, font: archivo(size, .black), tracking: size * 0.3 / 47)
        ZStack {
            glyphs.stroke(SensoColor.water, style: StrokeStyle(lineWidth: size * 4 / 47, miterLimit: 5))
            glyphs.fill(.white)
        }
        .offset(x: size * 2.5 / 47)  // the design's numbers sit 2.5 pt right of centre
    }
}

/// A line of text as a shape, so it can be outlined. Its frame ends at the baseline.
nonisolated struct GlyphText: Shape {
    private let glyphs: Path
    private let width: CGFloat
    private let ascent: CGFloat

    init(_ string: String, font: CTFont, tracking: CGFloat = 0) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTKernAttributeName as NSAttributedString.Key: tracking,
        ]))
        var ascent: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
        self.ascent = ascent
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count), points = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &ids)
            CTRunGetPositions(run, CFRange(), &points)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont  // every Core Text run carries its font
            for (id, point) in zip(ids, points) {
                // Glyphs are drawn y-up from the baseline; flip them onto a y-down frame whose bottom is the baseline.
                var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: point.x, ty: ascent - point.y)
                if let glyph = CTFontCreatePathForGlyph(runFont, id, &transform) { path.addPath(glyph) }
            }
        }
        glyphs = Path(path)
    }

    func path(in rect: CGRect) -> Path {
        glyphs.offsetBy(dx: rect.minX + (rect.width - width) / 2, dy: rect.minY + rect.height - ascent)
    }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        CGSize(width: width, height: ascent)
    }
}

// MARK: - Previews (design fixtures, not sensor data)

#Preview("Ready") { WatchReadyView(targetPercent: 90) {} }
#Preview("12%") { WatchPouringView(fillPercent: 12) }
#Preview("52%") { WatchPouringView(fillPercent: 52) }
#Preview("100%") { WatchCompleteView {} }

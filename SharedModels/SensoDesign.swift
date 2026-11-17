// SensoDesign.swift
// Colours, type and the liquid shape from the "Almost Purple" design, shared by iPhone and Watch.
// The design's typeface is SF Pro Expanded, which is the system font at `.expanded` width, so no font
// files are bundled and Dynamic Type keeps working.
//
// WCAG contrast (AAA needs 7:1): white on crimson 10.3:1, crimson on white 10.3:1,
// sky on crimson 7.9:1, blush on crimson 7.3:1.

import SwiftUI

nonisolated enum SensoColor {
    /// Brand red: buttons, liquid, titles. Sampled from the design (#840E08).
    static let crimson = Color(red: 0x84 / 255, green: 0x0E / 255, blue: 0x08 / 255)
    /// Light blue: "FILL UP!" text and the HOME button (#C9E7F6).
    static let sky = Color(red: 0xC9 / 255, green: 0xE7 / 255, blue: 0xF6 / 255)
    /// The empty part of the glass at the top of the Done screen (#D9F1FD).
    static let skyMist = Color(red: 0xD9 / 255, green: 0xF1 / 255, blue: 0xFD / 255)
    /// Watch "Tap to pour again". The design's pink only reached 4:1, so it's lightened to pass 7:1.
    static let blush = Color(red: 0xEE / 255, green: 0xD3 / 255, blue: 0xD4 / 255)
}

extension Font {
    /// SF Pro Expanded. Pass a size from `@ScaledMetric` so it follows Dynamic Type.
    static func senso(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
}

/// A liquid surface: a sine-wave top edge, filled down to the bottom of the rect.
nonisolated struct LiquidShape: Shape {
    var amplitude: CGFloat
    var wavelength: CGFloat
    /// Shifts the wave sideways, in radians (2π = one wavelength).
    var phase: CGFloat = 0
    /// Scales the wave's height around its resting line; 1 is the design's wave.
    var swell: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func surface(_ x: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x,
                    y: rect.minY + amplitude + amplitude * swell * sin(2 * .pi * x / wavelength + phase))
        }
        path.move(to: surface(0))
        for x in stride(from: 1, through: rect.width, by: 1) { path.addLine(to: surface(x)) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The design's liquid, alive: the wave drifts one wavelength every `period` seconds and gently swells,
/// so the liquid keeps moving while the level holds. Still when Reduce Motion is on.
struct MovingLiquid: View {
    var amplitude: CGFloat
    var wavelength: CGFloat
    var color: Color
    var period: Double = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            LiquidShape(amplitude: amplitude, wavelength: wavelength,
                        phase: CGFloat(time.truncatingRemainder(dividingBy: period) / period * 2 * .pi),
                        swell: CGFloat(1 + 0.15 * sin(time.truncatingRemainder(dividingBy: 5) / 5 * 2 * .pi)))
                .fill(color)
        }
    }
}

/// Text for a fill estimate. No estimate shows a dash, never a made-up number.
nonisolated func fillText(_ percent: Int?) -> String {
    percent.map { "\($0)%" } ?? "—"
}

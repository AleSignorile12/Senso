// SensoDesign.swift
// Colours, type and the liquid shape from the blue "water" design, shared by iPhone and Watch.
// The iPhone's typeface is SF Pro Expanded, the system font at `.expanded` width. watchOS has no expanded
// system font, so the Watch bundles Archivo at its widest (SIL Open Font License, see Archivo-OFL.txt).
//
// WCAG contrast: white on #009EF8 is 2.9:1, below Apple's 4.5:1, so with Increase Contrast on (iPhone)
// the blue deepens to #1A66D1, 5.4:1.

import SwiftUI
#if os(watchOS)
import CoreText
#endif

nonisolated enum SensoColor {
    /// Brand blue: buttons, liquid, titles (#009EF8, from the design).
    #if os(iOS)
    static let water = Color(UIColor { traits in
        traits.accessibilityContrast == .high
            ? UIColor(red: 0x1A / 255, green: 0x66 / 255, blue: 0xD1 / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x9E / 255, blue: 0xF8 / 255, alpha: 1)
    })
    #else
    static let water = Color(red: 0x00 / 255, green: 0x9E / 255, blue: 0xF8 / 255)
    #endif
    /// Text on white (#006BA1, from the design): 5.8:1 contrast.
    static let ink = Color(red: 0x00 / 255, green: 0x6B / 255, blue: 0xA1 / 255)
    /// The pale rim around the Fill up button and the glass (#D7F0FF, from the design).
    static let rim = Color(red: 0xD7 / 255, green: 0xF0 / 255, blue: 0xFF / 255)
}

extension Font {
    /// The design's wide typeface. Pass a size from `@ScaledMetric` so it follows Dynamic Type.
    static func senso(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        #if os(watchOS)
        // Archivo's variation axes, as four-character tags: "wght" (weight) and "wdth" (125 is its widest).
        let wght: CGFloat = weight == .regular ? 400 : weight == .semibold ? 600 : 800
        var font = CTFontDescriptorCreateWithNameAndSize("Archivo-SemiBold" as CFString, size)
        font = CTFontDescriptorCreateCopyWithVariation(font, 0x7767_6874 as CFNumber, wght)
        font = CTFontDescriptorCreateCopyWithVariation(font, 0x7764_7468 as CFNumber, 125)
        return Font(CTFontCreateWithFontDescriptor(font, size, nil))
        #else
        return .system(size: size, weight: weight).width(.expanded)
        #endif
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

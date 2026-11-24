// SensoDesign.swift
// Colours and type from the blue "water" design, shared by iPhone and Watch.
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
        return Font(archivo(size, weight))
        #else
        return .system(size: size, weight: weight).width(.expanded)
        #endif
    }
}

#if os(watchOS)
/// Archivo at its widest. SF Pro's weights (bold 760, heavy 870, black 1000) map onto Archivo's axis, which
/// tops out at 900: bold 700, heavy 790, black 900.
nonisolated func archivo(_ size: CGFloat, _ weight: Font.Weight) -> CTFont {
    let wght: CGFloat = switch weight {
    case .regular: 400
    case .semibold: 600
    case .heavy: 790
    case .black: 900
    default: 700
    }
    // Archivo's variation axes, as four-character tags: "wght" (weight) and "wdth" (125 is its widest).
    var font = CTFontDescriptorCreateWithNameAndSize("Archivo-SemiBold" as CFString, size)
    font = CTFontDescriptorCreateCopyWithVariation(font, 0x7767_6874 as CFNumber, wght)
    font = CTFontDescriptorCreateCopyWithVariation(font, 0x7764_7468 as CFNumber, 125)
    return CTFontCreateWithFontDescriptor(font, size, nil)
}
#endif

/// Text for a fill estimate. No estimate shows a dash, never a made-up number.
nonisolated func fillText(_ percent: Int?) -> String {
    percent.map { "\($0)%" } ?? "—"
}

// SensoDesign.swift
// Colours and type from the blue "water" design, shared by iPhone and Watch.
// The typeface is Atkinson Hyperlegible Next (Braille Institute, SIL Open Font License, see
// SharedModels/Fonts): its letters are drawn to be told apart (I l 1, O 0, b d p q), which helps low-vision
// and dyslexic readers. Bundled and registered in both apps' Info.plist (UIAppFonts).
//
// WCAG contrast: white on #009EF8 is 2.9:1, below Apple's 4.5:1, so with Increase Contrast on (iPhone)
// the blue deepens to #1A66D1, 5.4:1.

import CoreText
import SwiftUI

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
    /// Atkinson Hyperlegible Next at a size already scaled for Dynamic Type (pass an `@ScaledMetric`).
    static func senso(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom(atkinsonName(weight), fixedSize: size)
    }

    /// Atkinson Hyperlegible Next that grows with Dynamic Type like the system text style.
    static func senso(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .custom(atkinsonName(weight), size: style.baseSize, relativeTo: style)
    }

}

/// The font's named weights (200–800); black, heavier than the font goes, falls back to ExtraBold.
nonisolated func atkinsonName(_ weight: Font.Weight) -> String {
    let suffix = switch weight {
    case .ultraLight, .thin: "_ExtraLight"
    case .light: "_Light"
    case .medium: "_Medium"
    case .semibold: "_SemiBold"
    case .bold: "_Bold"
    case .heavy, .black: "_ExtraBold"
    default: ""
    }
    return "AtkinsonHyperlegibleNext-Regular" + suffix
}

/// The same font for Core Text, where glyph outlines are drawn by hand (the Watch's outlined number).
nonisolated func atkinson(_ size: CGFloat, _ weight: Font.Weight) -> CTFont {
    CTFontCreateWithName(atkinsonName(weight) as CFString, size, nil)
}

/// Atkinson's line height as a share of the font size (ascender 0.984 + descender 0.316). Designs give
/// baselines; SwiftUI lays out line boxes, so spacings between Texts are worked out with this.
let sensoLineHeight: CGFloat = 1.3

private extension Font.TextStyle {
    /// The default-size point sizes of Apple's text styles.
    var baseSize: CGFloat {
        switch self {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}

/// Text for a fill estimate. No estimate shows a dash, never a made-up number.
nonisolated func fillText(_ percent: Int?) -> String {
    percent.map { "\($0)%" } ?? "—"
}

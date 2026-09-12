import SwiftUI
import AppKit

/// User-configurable appearance of the SwiftUI subtitle layer (mpv's own
/// subtitle rendering is hidden, so this is the only place they are drawn).
public final class SubtitleStyle: ObservableObject {
    public static let shared = SubtitleStyle()

    /// Empty string means the default system font (rounded, semibold).
    @Published public var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Keys.fontFamily) }
    }
    @Published public var textColor: Color {
        didSet { defaults.set(textColor.hexString, forKey: Keys.textColor) }
    }
    @Published public var outlineWidth: Double {
        didSet { defaults.set(outlineWidth, forKey: Keys.outlineWidth) }
    }
    @Published public var outlineColor: Color {
        didSet { defaults.set(outlineColor.hexString, forKey: Keys.outlineColor) }
    }

    public static let defaultTextColor = Color.white
    public static let defaultOutlineColor = Color.black
    public static let defaultOutlineWidth = 0.0

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let fontFamily = "VPlayer.subFontFamily"
        static let textColor = "VPlayer.subTextColor"
        static let outlineWidth = "VPlayer.subOutlineWidth"
        static let outlineColor = "VPlayer.subOutlineColor"
    }

    private init() {
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? ""
        textColor = Color(hexString: defaults.string(forKey: Keys.textColor)) ?? Self.defaultTextColor
        outlineWidth = defaults.object(forKey: Keys.outlineWidth) as? Double ?? Self.defaultOutlineWidth
        outlineColor = Color(hexString: defaults.string(forKey: Keys.outlineColor)) ?? Self.defaultOutlineColor
    }

    public func reset() {
        fontFamily = ""
        textColor = Self.defaultTextColor
        outlineWidth = Self.defaultOutlineWidth
        outlineColor = Self.defaultOutlineColor
    }

    /// Font families installed on this Mac that can actually render
    /// subtitles: hidden system faces, symbol/emoji/ornament fonts and fonts
    /// without Latin glyphs are left out.
    public static var availableFontFamilies: [String] {
        // Latin only: CoreText falls back to another font for missing Cyrillic glyphs.
        let required = "AaQgKkWwéñüÉ?"
        return NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard !family.hasPrefix("."),
                      let font = NSFont(name: family, size: 12)
                        ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)
                else { return false }
                let charset = font.coveredCharacterSet
                return required.unicodeScalars.allSatisfy { charset.contains($0) }
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func font(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if fontFamily.isEmpty {
            return .system(size: size, weight: weight, design: .rounded)
        }
        return Font.custom(fontFamily, size: size).weight(weight)
    }
}

/// Text drawn with an outline. SwiftUI has no text stroke, so the outline is
/// the same text in the outline colour, offset in eight directions underneath.
public struct OutlinedText: View {
    let text: String
    let font: Font
    let color: Color
    let outlineColor: Color
    let outlineWidth: CGFloat

    public init(_ text: String, font: Font, color: Color, outlineColor: Color, outlineWidth: CGFloat) {
        self.text = text
        self.font = font
        self.color = color
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
    }

    public var body: some View {
        ZStack {
            if outlineWidth > 0 {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, offset in
                    Text(text)
                        .font(font)
                        .foregroundColor(outlineColor)
                        .offset(x: offset.x, y: offset.y)
                }
            }
            Text(text)
                .font(font)
                .foregroundColor(color)
        }
    }

    private var offsets: [CGPoint] {
        // Two rings for thick outlines so the corners do not show gaps.
        let radii: [CGFloat] = outlineWidth > 2 ? [outlineWidth, outlineWidth / 2] : [outlineWidth]
        let diagonal = CGFloat(1 / 2.0.squareRoot())
        return radii.flatMap { r in
            [
                CGPoint(x: r, y: 0), CGPoint(x: -r, y: 0),
                CGPoint(x: 0, y: r), CGPoint(x: 0, y: -r),
                CGPoint(x: r * diagonal, y: r * diagonal), CGPoint(x: -r * diagonal, y: r * diagonal),
                CGPoint(x: r * diagonal, y: -r * diagonal), CGPoint(x: -r * diagonal, y: -r * diagonal)
            ]
        }
    }
}

// MARK: - Color <-> hex persistence

extension Color {
    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFFFF" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = Int(round(rgb.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

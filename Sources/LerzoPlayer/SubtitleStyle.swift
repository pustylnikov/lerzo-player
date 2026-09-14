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
    /// Opacity of the box behind the subtitles, 0...1. Zero removes the box
    /// (and its border and shadow) entirely, leaving bare text on the video.
    @Published public var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
    }
    /// Distance from the edge of the video area (top or bottom, whichever a
    /// line is placed at) to the subtitle box, as a fraction of the area's
    /// height (0.03...0.4), so it looks the same in a window and in fullscreen.
    @Published public var edgeInset: Double {
        didSet { defaults.set(edgeInset, forKey: Keys.edgeInset) }
    }
    /// Edge of the video the original-language subtitles sit at.
    @Published public var originalPosition: Position {
        didSet { defaults.set(originalPosition.rawValue, forKey: Keys.originalPosition) }
    }
    /// Edge of the video the translation line sits at. When it shares an
    /// edge with the original, the original stays next to the edge and the
    /// translation goes on the inner side: the two tracks' cues come and go
    /// on their own timings, and this keeps the line the user reads (and
    /// clicks words in) from jumping whenever the translation appears.
    @Published public var translationPosition: Position {
        didSet { defaults.set(translationPosition.rawValue, forKey: Keys.translationPosition) }
    }
    /// How the subtitles stay clear of the playback controls bar, which
    /// would otherwise cover them at the default inset in most window sizes.
    @Published public var controlsClearance: ControlsClearance {
        didSet { defaults.set(controlsClearance.rawValue, forKey: Keys.controlsClearance) }
    }
    /// Size of the translation line relative to the primary subtitles
    /// (1 = the same size).
    @Published public var translationScale: Double {
        didSet { defaults.set(translationScale, forKey: Keys.translationScale) }
    }

    public static let defaultTextColor = Color.white
    public static let defaultOutlineColor = Color.black
    public static let defaultOutlineWidth = 0.0
    public static let defaultBackgroundOpacity = 0.65
    public static let defaultEdgeInset = 0.08
    public static let edgeInsetRange = 0.03...0.4
    public static let defaultOriginalPosition = Position.bottom
    public static let defaultTranslationPosition = Position.bottom
    public static let defaultTranslationScale = 1.0
    public static let translationScaleRange = 0.5...1.5
    public static let defaultControlsClearance = ControlsClearance.always
    /// Space between the top of the controls bar and the subtitle box.
    public static let controlsClearanceGap: CGFloat = 12

    public enum Position: String, CaseIterable, Identifiable {
        case bottom, top
        public var id: String { rawValue }
    }

    public enum ControlsClearance: String, CaseIterable, Identifiable {
        /// The resting position never goes below the bar, so the text never
        /// moves when the bar appears; `edgeInset` acts as "at least".
        case always
        /// `edgeInset` is honoured exactly (even right at the edge) and the
        /// text is lifted above the bar only while the bar is on screen.
        case whileControlsVisible

        public var id: String { rawValue }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let fontFamily = "LerzoPlayer.subFontFamily"
        static let textColor = "LerzoPlayer.subTextColor"
        static let outlineWidth = "LerzoPlayer.subOutlineWidth"
        static let outlineColor = "LerzoPlayer.subOutlineColor"
        static let backgroundOpacity = "LerzoPlayer.subBackgroundOpacity"
        static let edgeInset = "LerzoPlayer.subBottomInset"   // historical name, same meaning
        static let originalPosition = "LerzoPlayer.subOriginalPosition"
        static let translationPosition = "LerzoPlayer.subTranslationPosition"
        static let translationScale = "LerzoPlayer.subTranslationScale"
        static let controlsClearance = "LerzoPlayer.subControlsClearance"
    }

    private init() {
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? ""
        textColor = Color(hexString: defaults.string(forKey: Keys.textColor)) ?? Self.defaultTextColor
        outlineWidth = defaults.object(forKey: Keys.outlineWidth) as? Double ?? Self.defaultOutlineWidth
        outlineColor = Color(hexString: defaults.string(forKey: Keys.outlineColor)) ?? Self.defaultOutlineColor
        backgroundOpacity = defaults.object(forKey: Keys.backgroundOpacity) as? Double ?? Self.defaultBackgroundOpacity
        edgeInset = defaults.object(forKey: Keys.edgeInset) as? Double ?? Self.defaultEdgeInset
        originalPosition = defaults.string(forKey: Keys.originalPosition)
            .flatMap(Position.init(rawValue:)) ?? Self.defaultOriginalPosition
        translationPosition = defaults.string(forKey: Keys.translationPosition)
            .flatMap(Position.init(rawValue:)) ?? Self.defaultTranslationPosition
        translationScale = defaults.object(forKey: Keys.translationScale) as? Double ?? Self.defaultTranslationScale
        controlsClearance = defaults.string(forKey: Keys.controlsClearance)
            .flatMap(ControlsClearance.init(rawValue:)) ?? Self.defaultControlsClearance
    }

    public func reset() {
        fontFamily = ""
        textColor = Self.defaultTextColor
        outlineWidth = Self.defaultOutlineWidth
        outlineColor = Self.defaultOutlineColor
        backgroundOpacity = Self.defaultBackgroundOpacity
        edgeInset = Self.defaultEdgeInset
        originalPosition = Self.defaultOriginalPosition
        translationPosition = Self.defaultTranslationPosition
        translationScale = Self.defaultTranslationScale
        controlsClearance = Self.defaultControlsClearance
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

    /// AppKit counterpart of `font(size:)`, for measuring text.
    public func nsFont(size: CGFloat) -> NSFont {
        if fontFamily.isEmpty {
            let base = NSFont.systemFont(ofSize: size, weight: .semibold)
            if let rounded = base.fontDescriptor.withDesign(.rounded),
               let font = NSFont(descriptor: rounded, size: size) {
                return font
            }
            return base
        }
        return NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 9, size: size)
            ?? NSFont(name: fontFamily, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    /// Width of a space in that font. The subtitle words are laid out as
    /// separate views, so this is the gap between them that makes the line
    /// read like ordinary text (a fixed gap looked cramped at large sizes).
    public func spaceWidth(size: CGFloat) -> CGFloat {
        (" " as NSString).size(withAttributes: [.font: nsFont(size: size)]).width
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

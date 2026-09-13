import Foundation

/// Which language the user is learning and which one they read translations
/// in. Everything else — audio track, primary subtitles, the TAB translation
/// track and the AI tutor's languages — is derived from these two.
public final class LanguagePreferences: ObservableObject {
    public static let shared = LanguagePreferences()

    /// Sentinel for "do not auto-select anything for this role".
    public static let none = "none"
    /// Sentinel for "follow the macOS UI language" (native language only).
    public static let system = "system"

    /// ISO 639-1 code, `none`, or (native only) `system`.
    @Published public var learningLanguage: String {
        didSet { defaults.set(learningLanguage, forKey: Keys.learning) }
    }
    @Published public var nativeLanguage: String {
        didSet { defaults.set(nativeLanguage, forKey: Keys.native) }
    }
    /// UI language: `system`, or one of `uiLanguages`. Applied through the
    /// per-app `AppleLanguages` override, so it takes effect on relaunch.
    @Published public var uiLanguage: String {
        didSet {
            defaults.set(uiLanguage, forKey: Keys.ui)
            if uiLanguage == Self.system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([uiLanguage], forKey: "AppleLanguages")
            }
        }
    }

    /// Languages the app itself is translated into (the `.lproj` folders).
    public static let uiLanguages = ["en", "ru"]

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let learning = "VPlayer.learningLanguage"
        static let native = "VPlayer.nativeLanguage"
        static let ui = "VPlayer.uiLanguage"
    }

    private init() {
        learningLanguage = defaults.string(forKey: Keys.learning) ?? "en"
        nativeLanguage = defaults.string(forKey: Keys.native) ?? Self.system
        uiLanguage = defaults.string(forKey: Keys.ui) ?? Self.system
    }

    // MARK: - UI language

    /// The language the UI is actually showing right now (fixed at launch).
    public static var activeUILanguage: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The language the UI would show after a relaunch with the current choice.
    public var pendingUILanguage: String {
        if uiLanguage != Self.system, Self.uiLanguages.contains(uiLanguage) { return uiLanguage }
        return Bundle.preferredLocalizations(from: Self.uiLanguages, forPreferences: Self.systemPreferredLanguages).first ?? "en"
    }

    public var uiLanguageNeedsRelaunch: Bool { pendingUILanguage != Self.activeUILanguage }

    /// Name of a UI language in that language itself ("English", "Русский").
    public static func nativeDisplayName(forUILanguage code: String) -> String {
        (Locale(identifier: code).localizedString(forLanguageCode: code) ?? code).capitalized(with: Locale(identifier: code))
    }

    /// The user's macOS language list, ignoring this app's own `AppleLanguages` override.
    private static var systemPreferredLanguages: [String] {
        (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String])
            ?? Locale.preferredLanguages
    }

    // MARK: - Resolved codes

    /// The learning language as an ISO 639-1 code, or nil when disabled.
    public var resolvedLearningCode: String? {
        learningLanguage == Self.none ? nil : learningLanguage
    }

    /// The native language as an ISO 639-1 code, or nil when disabled or
    /// when it would coincide with the learning language (an English speaker
    /// studying English has nothing to translate into).
    public var resolvedNativeCode: String? {
        let code: String?
        switch nativeLanguage {
        case Self.none: code = nil
        case Self.system: code = Self.systemLanguageCode
        default: code = nativeLanguage
        }
        guard let code, code != resolvedLearningCode else { return nil }
        return code
    }

    public static var systemLanguageCode: String? {
        systemPreferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
    }

    // MARK: - Language list for the pickers

    /// Common languages offered in Settings, sorted by their localized names.
    public static let pickerLanguages: [String] = {
        let codes = ["en", "es", "fr", "de", "it", "pt", "ru", "uk", "pl", "cs", "nl", "sv", "no", "da", "fi",
                     "tr", "el", "he", "ar", "hi", "zh", "ja", "ko", "vi", "th", "id", "ro", "hu", "bg", "sr", "hr", "ka", "kk"]
        return codes.sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }()

    /// Language name in the UI language, e.g. "English" or "Английский".
    public static func displayName(for code: String) -> String {
        (Locale.current.localizedString(forLanguageCode: code) ?? code).capitalized(with: Locale.current)
    }

    /// Language name in English, for the Gemini prompt.
    public static func englishName(for code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - Track matching

    /// Picks the track that is in `code`, or nil if none matches. Prefers
    /// regular tracks over forced ones, then the container's default track.
    public static func bestTrack(in tracks: [MediaTrack], matching code: String) -> MediaTrack? {
        let candidates = tracks.filter { matches(track: $0, code: code) }
        return candidates.first { !$0.isForced && $0.isDefault }
            ?? candidates.first { !$0.isForced }
            ?? candidates.first
    }

    /// ISO 639-2/B (bibliographic) codes, common in Matroska files, that
    /// Foundation does not recognise — mapped to their 639-2/T equivalents.
    private static let bibliographicCodes: [String: String] = [
        "ger": "deu", "fre": "fra", "chi": "zho", "dut": "nld", "gre": "ell", "cze": "ces",
        "rum": "ron", "per": "fas", "arm": "hye", "ice": "isl", "mac": "mkd", "may": "msa",
        "slo": "slk", "alb": "sqi", "baq": "eus", "bur": "mya", "geo": "kat", "tib": "bod",
        "wel": "cym", "mao": "mri"
    ]

    static func matches(track: MediaTrack, code: String) -> Bool {
        let wanted = Locale.Language(identifier: code)
        // Containers usually carry ISO 639-2 codes ("eng", "rus"), sometimes 639-1.
        if var trackLang = track.lang?.trimmingCharacters(in: .whitespaces).lowercased(), !trackLang.isEmpty, trackLang != "und" {
            trackLang = bibliographicCodes[trackLang] ?? trackLang
            let found = Locale.Language(identifier: trackLang)
            guard let a = found.languageCode, let b = wanted.languageCode else { return false }
            return a.identifier(.alpha3) == b.identifier(.alpha3)
        }
        // No code at all: look for the language's name in the title, as a
        // whole word, in English, in the language itself and in the UI language.
        guard !track.title.isEmpty else { return false }
        let names = Set([
            Locale(identifier: "en").localizedString(forLanguageCode: code),
            Locale(identifier: code).localizedString(forLanguageCode: code),
            Locale.current.localizedString(forLanguageCode: code)
        ].compactMap { $0?.lowercased() })
        let words = Set(track.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        return !names.isDisjoint(with: words)
    }
}

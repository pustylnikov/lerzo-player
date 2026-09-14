import SwiftUI
import Translation

/// One-line translation of the clicked word with Apple's on-device engine
/// (the Translate app's, macOS 15+): works offline once the language pack is
/// downloaded and needs no key, so beginners without a bilingual dictionary
/// still get an answer. Learning → native language from the preferences.
@available(macOS 15, *)
struct WordTranslationLine: View {
    let word: String
    /// Reports the text so the card can size and lay itself out.
    var onResult: (String?) -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var translation: String?

    /// The system's download sheet is offered once per session; until the
    /// packs are installed (it checks every time), later clicks stay quiet.
    private static var offeredDownload = false

    var body: some View {
        // A modifier on an empty view never runs its task; keep a zero-size
        // anchor in the tree while there is nothing to show yet.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            if let translation {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.yellow)
                    Text(translation)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                }
            }
        }
        .task(id: word) { await start() }
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(word)
                let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                // The engine echoes words it does not know.
                let result = text.lowercased() == word.lowercased() ? nil : text
                translation = result
                onResult(result)
            } catch {
                // The download sheet was dismissed, or the engine failed.
                translation = nil
                onResult(nil)
            }
        }
    }

    private func start() async {
        translation = nil
        let prefs = LanguagePreferences.shared
        guard let learning = prefs.resolvedLearningCode,
              let native = prefs.resolvedNativeCode else {
            configuration = nil
            onResult(nil)
            return
        }
        let source = Locale.Language(identifier: learning)
        let target = Locale.Language(identifier: native)
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported where !Self.offeredDownload:
            Self.offeredDownload = true   // translate() shows the download sheet
        default:
            configuration = nil
            onResult(nil)
            return
        }
        // The task runs again only for a changed configuration value, so the
        // same language pair is invalidated rather than recreated.
        if var current = configuration, current.source == source, current.target == target {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}

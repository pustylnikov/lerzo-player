import Foundation

public final class GeminiService: ObservableObject {
    public static let shared = GeminiService()
    
    @Published public var apiKey: String = "" {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "VPlayer.geminiApiKey")
        }
    }
    
    @Published public var selectedModel: String = "gemini-2.5-flash"
    @Published public var isLoading: Bool = false
    @Published public var lastExplanation: SubtitleExplanation? = nil
    @Published public var errorMessage: String? = nil
    
    public init() {
        if let key = UserDefaults.standard.string(forKey: "VPlayer.geminiApiKey"), !key.isEmpty {
            self.apiKey = key
        } else if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty {
            self.apiKey = envKey
        }
    }
    
    public var hasApiKey: Bool {
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// Explain the current movie subtitle in context using Gemini
    public func explain(subText: String,
                        contextHistory: [String] = [],
                        translationPeekText: String? = nil,
                        focusedWord: String? = nil) async throws -> SubtitleExplanation {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "GeminiService", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Gemini API ключ не задан. Пожалуйста, укажите его в настройках плеера (значок ⚙️)."
            ])
        }
        
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }
        
        defer {
            Task { @MainActor in
                self.isLoading = false
            }
        }
        
        let contextBlock = contextHistory.isEmpty ? "" : "Previous lines for dialogue context:\n" + contextHistory.joined(separator: "\n") + "\n\n"
        let translationHint = (translationPeekText != nil && !translationPeekText!.isEmpty) ? "Official movie subtitle translation for reference: \"\(translationPeekText!)\"\n\n" : ""
        let wordFocusHint = (focusedWord != nil && !focusedWord!.isEmpty) ? "User focused word: \"\(focusedWord!)\". In addition to analyzing the sentence, make sure to include this word in difficultWords or idioms with detailed contextual meaning.\n\n" : ""
        
        // The tutor speaks the learner's native language and explains the
        // language being studied; both come from the language preferences.
        let prefs = LanguagePreferences.shared
        let learning = LanguagePreferences.englishName(for: prefs.resolvedLearningCode ?? "en")
        let native = LanguagePreferences.englishName(for: prefs.resolvedNativeCode ?? LanguagePreferences.systemLanguageCode ?? "en")

        let prompt = """
        You are an expert \(learning) language tutor helping a native \(native) speaker learn \(learning) by watching a movie in \(learning).
        Write all translations and explanations in \(native).
        
        \(contextBlock)\(translationHint)\(wordFocusHint)Current \(learning) dialogue line to explain:
        "\(subText)"
        
        Please provide:
        1. Natural, conversational \(native) translation fitting the movie scene.
        2. Breakdown of all idioms, phrasal verbs, slang, or figurative expressions in this sentence.
        3. 1 to 4 useful vocabulary words or collocations with part of speech and clear translation into \(native) (including the focused word if applicable).
        4. A brief contextual note in \(native) explaining the tone, nuance, cultural reference, or sarcasm.
        
        Respond with ONLY a raw JSON object (no markdown, no quotes outside JSON) conforming to:
        {
          "sentence": "\(subText.replacingOccurrences(of: "\"", with: "\\\""))",
          "translation": "translation into \(native)",
          "idioms": [
            {
              "idiom": "idiom or phrasal verb",
              "literalMeaning": "literal meaning in \(native)",
              "actualMeaning": "what it means in this context, in \(native)"
            }
          ],
          "difficultWords": [
            {
              "word": "word",
              "translation": "translation into \(native)",
              "partOfSpeech": "verb/noun/adj"
            }
          ],
          "contextNote": "short note in \(native) about subtext, humour or the situation"
        }
        """
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(selectedModel):generateContent?key=\(cleanKey)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GeminiService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "responseMimeType": "application/json"
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "GeminiService", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Ошибка Gemini API (\(httpResponse.statusCode)): \(errorText)"
            ])
        }
        
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = jsonObject["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let textResponse = firstPart["text"] as? String else {
            throw NSError(domain: "GeminiService", code: 502, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать ответ Gemini"])
        }
        
        // Clean markdown backticks if any
        var cleanJson = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanJson.hasPrefix("```json") {
            cleanJson = String(cleanJson.dropFirst(7))
        } else if cleanJson.hasPrefix("```") {
            cleanJson = String(cleanJson.dropFirst(3))
        }
        if cleanJson.hasSuffix("```") {
            cleanJson = String(cleanJson.dropLast(3))
        }
        cleanJson = cleanJson.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let jsonData = cleanJson.data(using: .utf8) else {
            throw NSError(domain: "GeminiService", code: 502, userInfo: [NSLocalizedDescriptionKey: "Ошибка кодировки JSON"])
        }
        
        let explanation = try JSONDecoder().decode(SubtitleExplanation.self, from: jsonData)
        
        await MainActor.run {
            self.lastExplanation = explanation
        }
        
        return explanation
    }
}

import Foundation

public final class GeminiService: ObservableObject {
    public static let shared = GeminiService()
    
    /// The user's Gemini key. Persisted in the login keychain, never in
    /// UserDefaults (which is a plain plist anyone can read).
    @Published public var apiKey: String = "" {
        didSet {
            guard !isLoadingKey, apiKey != oldValue else { return }
            KeychainStore.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.keychainAccount)
        }
    }
    private static let keychainAccount = "gemini-api-key"
    private static let legacyDefaultsKey = "LerzoPlayer.geminiApiKey"
    private var isLoadingKey = false

    /// Google retires model names for new keys every few months, so the
    /// model is discovered from the API on a 404 and remembered.
    @Published public var selectedModel: String = UserDefaults.standard.string(forKey: "LerzoPlayer.geminiModel") ?? defaultModel {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "LerzoPlayer.geminiModel") }
    }
    public static let defaultModel = "gemini-3.6-flash"
    /// Let the model think hard before answering. Off by default: for one
    /// subtitle line it mostly adds seconds of waiting and paid tokens.
    @Published public var deepThinking: Bool = UserDefaults.standard.bool(forKey: "LerzoPlayer.geminiDeepThinking") {
        didSet { UserDefaults.standard.set(deepThinking, forKey: "LerzoPlayer.geminiDeepThinking") }
    }
    /// Text models the key can use. Cached for a day — new models do not
    /// appear every minute, and the list call counts against the quota too.
    @Published public var availableModels: [String] = UserDefaults.standard.stringArray(forKey: modelsCacheKey) ?? [] {
        didSet {
            UserDefaults.standard.set(availableModels, forKey: Self.modelsCacheKey)
            UserDefaults.standard.set(Date(), forKey: Self.modelsFetchedAtKey)
        }
    }
    private static let modelsCacheKey = "LerzoPlayer.geminiModels"
    private static let modelsFetchedAtKey = "LerzoPlayer.geminiModelsFetchedAt"
    private static let modelsCacheLifetime: TimeInterval = 24 * 60 * 60

    /// True when the cached list is missing or older than a day.
    public var modelListIsStale: Bool {
        guard !availableModels.isEmpty,
              let fetched = UserDefaults.standard.object(forKey: Self.modelsFetchedAtKey) as? Date else { return true }
        return Date().timeIntervalSince(fetched) > Self.modelsCacheLifetime
    }
    @Published public var isLoading: Bool = false
    @Published public var lastExplanation: SubtitleExplanation? = nil
    /// Token usage of the last request and the running total since launch.
    @Published public var lastUsage: TokenUsage? = nil
    @Published public var sessionUsage = TokenUsage()

    public struct TokenUsage: Equatable {
        public var prompt = 0
        public var output = 0
        public var thoughts = 0
        public var total: Int { prompt + output + thoughts }

        init() {}
        /// From `usageMetadata` of a generateContent response.
        init?(metadata: [String: Any]?) {
            guard let metadata else { return nil }
            prompt = metadata["promptTokenCount"] as? Int ?? 0
            output = metadata["candidatesTokenCount"] as? Int ?? 0
            thoughts = metadata["thoughtsTokenCount"] as? Int ?? 0
            guard total > 0 else { return nil }
        }
        static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
            var r = a; r.prompt += b.prompt; r.output += b.output; r.thoughts += b.thoughts; return r
        }
    }
    @Published public var errorMessage: String? = nil

    public init() {
        isLoadingKey = true
        defer { isLoadingKey = false }
        let defaults = UserDefaults.standard
        let legacy = defaults.string(forKey: Self.legacyDefaultsKey) ?? ""
        if let key = KeychainStore.read(Self.keychainAccount), !key.isEmpty {
            apiKey = key
        } else if !legacy.isEmpty {
            // Migrate from the old UserDefaults storage.
            apiKey = legacy
            // Keep the plist copy until the keychain actually has the key.
            guard KeychainStore.write(legacy, account: Self.keychainAccount) else { return }
        } else if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty {
            // Development convenience; not persisted.
            apiKey = envKey
        }
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    /// Where a user gets a key; shared by Settings and the first-run screen.
    public static let apiKeyPageURL = URL(string: "https://aistudio.google.com/app/apikey")!

    public var hasApiKey: Bool {
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// Explain the current movie subtitle in context using Gemini
    public func explain(subText: String,
                        contextHistory: [String] = [],
                        translationPeekText: String? = nil,
                        focusedWord: String? = nil) async throws -> SubtitleExplanation {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw GeminiError.missingKey }
        
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
        
        // Retries handle two ways the request can be stale: the remembered
        // model was retired (404 → discover a current one), or the model does
        // not accept a thinking config (400 → send the request without it).
        var model = selectedModel
        var withThinking = !Self.thinkingUnsupported.contains(model)
        var data: Data
        while true {
            let request = try Self.generateRequest(model: model, key: cleanKey, prompt: prompt,
                                                   thinking: withThinking ? Self.thinkingConfig(for: model, deep: deepThinking) : nil,
                                                   deep: deepThinking)
            do {
                data = try await Self.perform(request, model: model)
                break
            } catch GeminiError.modelNotFound where model == selectedModel {
                model = try await discoverModel(key: cleanKey)
                withThinking = !Self.thinkingUnsupported.contains(model)
            } catch GeminiError.badRequest where withThinking {
                // Whatever the wording, the only thing we send that varies by
                // model is the thinking config — drop it for this model from now on.
                withThinking = false
                Self.thinkingUnsupported.insert(model)
            }
        }
        
        let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // A refused prompt comes back as 200 with no candidates, or with a
        // candidate that has a finishReason but no content.
        if let feedback = jsonObject?["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw GeminiError.blocked
        }
        let firstCandidate = (jsonObject?["candidates"] as? [[String: Any]])?.first
        guard let content = firstCandidate?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let textResponse = parts.first?["text"] as? String else {
            if let reason = firstCandidate?["finishReason"] as? String, reason != "STOP", reason != "MAX_TOKENS" {
                throw GeminiError.blocked
            }
            throw GeminiError.unreadableResponse
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
        
        let explanation: SubtitleExplanation
        do {
            explanation = try JSONDecoder().decode(SubtitleExplanation.self, from: Data(cleanJson.utf8))
        } catch {
            throw GeminiError.unreadableResponse
        }
        
        let usage = TokenUsage(metadata: jsonObject?["usageMetadata"] as? [String: Any])
        await MainActor.run {
            self.lastExplanation = explanation
            self.lastUsage = usage
            if let usage { self.sessionUsage = self.sessionUsage + usage }
        }
        
        return explanation
    }

    // MARK: - Key validation

    /// Cheap round trip to find out whether a key works, for the Settings
    /// "Check key" button. Returns nil when the key is good.
    public func validateKey(_ key: String) async -> GeminiError? {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .missingKey }
        do {
            let request = try Self.makeRequest(path: "models/\(selectedModel)", key: clean)
            _ = try await Self.perform(request, model: selectedModel)
            return nil
        } catch GeminiError.modelNotFound {
            do { _ = try await discoverModel(key: clean); return nil } catch { return GeminiError.from(transport: error) }
        } catch {
            return GeminiError.from(transport: error)
        }
    }

    // MARK: - Model discovery

    /// Asks the API which models this key can use and picks the newest
    /// general-purpose Flash one (fast and free-tier friendly). The choice
    /// is stored in `selectedModel`.
    @discardableResult
    func discoverModel(key: String) async throws -> String {
        let usable = try await fetchModels(key: key)
        guard let best = Self.preferredModel(from: usable) else {
            throw GeminiError.modelNotFound(model: selectedModel,
                                            detail: String(localized: "this key has no text model that supports generateContent"))
        }
        await MainActor.run { self.selectedModel = best }
        return best
    }

    /// Refreshes `availableModels` for the Settings picker. Returns the error, if any.
    public func refreshModels() async -> GeminiError? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingKey }
        do { _ = try await fetchModels(key: key); return nil } catch { return GeminiError.from(transport: error) }
    }

    /// Text-capable models this key can use, newest first; also stored in `availableModels`.
    private func fetchModels(key: String) async throws -> [String] {
        let request = try Self.makeRequest(path: "models?pageSize=200", key: key)
        let data = try await Self.perform(request, model: selectedModel)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let models = (json?["models"] as? [[String: Any]]) ?? []
        let usable = models.compactMap { entry -> String? in
            guard let name = entry["name"] as? String,
                  let methods = entry["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }
        // Only plain text chat models make sense for explaining subtitles.
        let sorted = usable.filter(Self.isTextChatModel).sorted { Self.version($0) > Self.version($1) || (Self.version($0) == Self.version($1) && $0 < $1) }
        await MainActor.run { self.availableModels = sorted }
        return usable
    }

    /// Flash / Pro text models; no image, speech, live, embedding or agent variants.
    static func isTextChatModel(_ name: String) -> Bool {
        guard name.hasPrefix("gemini-"), name.contains("flash") || name.contains("pro") else { return false }
        let unrelated = ["image", "tts", "live", "audio", "embedding", "robotics", "computer", "research", "vision", "omni", "-exp", "thinking"]
        return !unrelated.contains { name.contains($0) }
    }

    /// "gemini-3.6-flash-lite" → 3.6
    static func version(_ name: String) -> Double {
        let parts = name.split(separator: "-")
        return parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
    }

    /// Newest plain "gemini-X.Y-flash"; then any flash variant; then anything.
    static func preferredModel(from names: [String]) -> String? {
        let special = ["lite", "preview", "exp", "image", "tts", "live", "audio", "thinking", "embedding", "8b"]
        let gemini = names.filter { $0.hasPrefix("gemini-") && !$0.contains("gemma") }
        let plainFlash = gemini.filter { name in
            name.hasSuffix("-flash") && !special.contains { name.contains($0) }
        }
        let anyFlash = gemini.filter { $0.contains("flash") && !$0.contains("image") && !$0.contains("tts") && !$0.contains("live") && !$0.contains("audio") && !$0.contains("embedding") }
        for pool in [plainFlash, anyFlash, gemini] {
            if let best = pool.max(by: { (version($0), $0) < (version($1), $1) }) { return best }
        }
        return names.first
    }

    // MARK: - Transport

    private static let apiBase = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    /// The key travels in a header rather than the query string, so it never
    /// ends up in URL logs.
    private static func makeRequest(path: String, key: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: apiBase) else {
            throw GeminiError.other("Invalid API URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private static func generateRequest(model: String, key: String, prompt: String, thinking: [String: Any]?, deep: Bool) throws -> URLRequest {
        var request = try makeRequest(path: "models/\(model):generateContent", key: key)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        var generationConfig: [String: Any] = [
            "temperature": 0.3,
            "responseMimeType": "application/json",
            // The answer is a short JSON object; this only guards against runaway
            // output. The limit includes thinking tokens, so deep mode gets more room.
            "maxOutputTokens": deep ? 16384 : 4096
        ]
        if let thinking { generationConfig["thinkingConfig"] = thinking }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Models that answered 400 to a thinking config; persisted so the extra
    /// round trip happens once per model, not once per line.
    private static var thinkingUnsupported: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "LerzoPlayer.geminiNoThinking") ?? []) {
        didSet { UserDefaults.standard.set(Array(thinkingUnsupported).sorted(), forKey: "LerzoPlayer.geminiNoThinking") }
    }

    /// Per the REST reference, `thinkingLevel` is for Gemini 3+ ("use with
    /// earlier models results in an error"), `thinkingBudget` for 2.5, and
    /// older models have no thinking at all. Of the levels, only LOW/HIGH are
    /// accepted by every 3.x model (MINIMAL is not on 3.7/3.8 Flash and Pro).
    /// Budgets: 2.5 Pro cannot go below 128, 2.5 Flash/Flash-Lite accept 0 = off,
    /// -1 = dynamic on all of them. Anything the model still rejects is caught
    /// by the 400 fallback in `explain`.
    static func thinkingConfig(for model: String, deep: Bool) -> [String: Any]? {
        let v = version(model)
        if v >= 3 {
            return ["thinkingLevel": deep ? "HIGH" : "LOW"]
        }
        if v >= 2.5 {
            let minimum = model.contains("pro") ? 128 : 0
            return ["thinkingBudget": deep ? -1 : minimum]
        }
        return nil
    }

    /// Runs the request and maps every failure — transport or HTTP — to `GeminiError`.
    private static func perform(_ request: URLRequest, model: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GeminiError.from(transport: error)
        }
        guard let http = response as? HTTPURLResponse else { throw GeminiError.unreadableResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiError.from(status: http.statusCode, body: data, model: model)
        }
        return data
    }
}

import Foundation

/// Everything that can go wrong talking to Gemini, reduced to the handful of
/// situations a user can actually do something about.
public enum GeminiError: LocalizedError, Equatable {
    /// No key entered yet — the first-run situation.
    case missingKey
    /// Google rejected the key (malformed, revoked, or restricted to other APIs).
    case invalidKey
    /// The key is fine but the account has no access (API not enabled, billing, region).
    case accessDenied(String)
    /// Free-tier quota or per-minute rate limit hit.
    case quotaExceeded
    /// The model name is unknown to the API.
    case modelNotFound(model: String, detail: String)
    /// Google's side is overloaded or down (5xx).
    case serviceUnavailable
    /// No network, DNS failure, timeout.
    case offline
    case timedOut
    /// Gemini refused to answer because of its safety filters.
    case blocked
    /// 200 OK but not the JSON we asked for.
    case unreadableResponse
    /// The API rejected the request itself (400) — usually a generation
    /// parameter this model does not support.
    case badRequest(String)
    /// Anything else, with Google's own message.
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return String(localized: "AI explanations need a Gemini API key.")
        case .invalidKey:
            return String(localized: "Google rejected the API key.")
        case .accessDenied(let detail):
            return String(localized: "This key is not allowed to use Gemini: \(detail)")
        case .quotaExceeded:
            return String(localized: "The free quota for this key is used up for now.")
        case .modelNotFound(let model, let detail):
            return String(localized: "The model “\(model)” is not available for this key: \(detail)")
        case .serviceUnavailable:
            return String(localized: "Gemini is overloaded or temporarily down.")
        case .offline:
            return String(localized: "No internet connection.")
        case .timedOut:
            return String(localized: "Gemini took too long to answer.")
        case .blocked:
            return String(localized: "Gemini declined to explain this line (safety filter).")
        case .unreadableResponse:
            return String(localized: "Gemini sent an answer VPlayer could not read.")
        case .badRequest(let message), .other(let message):
            return String(localized: "Gemini error: \(message)")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missingKey:
            return String(localized: "Get a free key in Google AI Studio (it takes a minute), then paste it in Settings.")
        case .invalidKey:
            return String(localized: "Check the key in Settings — it should start with “AIza”. If you regenerated it, paste the new one.")
        case .accessDenied:
            return String(localized: "Open Google AI Studio and make sure the key has access to the Gemini API.")
        case .quotaExceeded:
            return String(localized: "Wait a minute and try again, or create a new key in Google AI Studio.")
        case .modelNotFound:
            return String(localized: "Try again later; if it keeps failing, update VPlayer.")
        case .serviceUnavailable, .timedOut:
            return String(localized: "Try again in a moment.")
        case .offline:
            return String(localized: "Check the connection and try again.")
        case .blocked:
            return String(localized: "Try a different line.")
        case .unreadableResponse, .badRequest, .other:
            return String(localized: "Try again; if it keeps failing, report the line to the developer.")
        }
    }

    /// Whether the fix lives in Settings (key problems) rather than in retrying.
    public var pointsToSettings: Bool {
        switch self {
        case .missingKey, .invalidKey, .accessDenied: return true
        default: return false
        }
    }

    // MARK: - Mapping

    /// Turns an HTTP failure from the Gemini REST API into a `GeminiError`,
    /// using Google's `{ "error": { code, message, status, details } }` body.
    static func from(status: Int, body: Data, model: String) -> GeminiError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let message = (error?["message"] as? String) ?? String(localized: "HTTP \(status)")
        let reasons = ((error?["details"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }

        switch status {
        case 400 where reasons.contains("API_KEY_INVALID") || message.localizedCaseInsensitiveContains("API key"):
            return .invalidKey
        case 400:
            return .badRequest(message)
        case 401:
            return .invalidKey
        case 403:
            // Leaked/blocked keys and "API not enabled" both come back as 403.
            return reasons.contains("API_KEY_INVALID") ? .invalidKey : .accessDenied(message)
        case 404:
            return .modelNotFound(model: model, detail: message)
        case 429:
            return .quotaExceeded
        case 500...599:
            return .serviceUnavailable
        default:
            return .other(message)
        }
    }

    static func from(transport error: Error) -> GeminiError {
        if let gemini = error as? GeminiError { return gemini }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            default: return .other(url.localizedDescription)
            }
        }
        if error is DecodingError { return .unreadableResponse }
        return .other(error.localizedDescription)
    }
}

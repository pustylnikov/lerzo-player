import Foundation
import SQLite3
import CryptoKit

enum CardExportError: LocalizedError {
    case noCards
    case sqlite(String)
    case packageCreation(String)

    var errorDescription: String? {
        switch self {
        case .noCards: return String(localized: "No cards selected for export.")
        case .sqlite(let message): return String(localized: "Could not create the Anki collection: \(message)")
        case .packageCreation(let message):
            let prefix = String(localized: "Could not create the Anki package.")
            return message.isEmpty ? prefix : "\(prefix) \(message)"
        }
    }
}

enum CardExporter {
    /// Fixed across exports so Anki recognises the note type when a card with
    /// the same stable GUID is imported again.
    private static let modelID: Int64 = 1_789_387_200_001
    private static let fieldNames = [
        "Word", "Sentence", "Translation", "Definition", "Explanation",
        "Source", "Screenshot", "Audio",
    ]

    static func exportAPKG(cards: [Card],
                           to destination: URL,
                           deckName: String,
                           oneDeckPerVideo: Bool,
                           includeDefinitions: Bool,
                           includeImages: Bool) throws {
        guard !cards.isEmpty else { throw CardExportError.noCards }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lerzo-anki-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let collectionURL = temp.appendingPathComponent("collection.anki2")
        try createCollection(at: collectionURL,
                             cards: cards,
                             deckName: deckName.isEmpty ? "Lerzo Player" : deckName,
                             oneDeckPerVideo: oneDeckPerVideo,
                             includeDefinitions: includeDefinitions,
                             includeImages: includeImages)

        var mediaMap: [String: String] = [:]
        if includeImages {
            for (index, card) in cards.enumerated() {
                guard let name = card.screenshot else { continue }
                let source = CardStore.shared.mediaDirectoryURL.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let key = String(index)
                try FileManager.default.copyItem(at: source, to: temp.appendingPathComponent(key))
                mediaMap[key] = name
            }
        }
        let mediaData = try JSONSerialization.data(withJSONObject: mediaMap, options: [.sortedKeys])
        try mediaData.write(to: temp.appendingPathComponent("media"), options: .atomic)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", temp.path, destination.path]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CardExportError.packageCreation(message)
        }
    }

    static func exportTSV(cards: [Card], to destination: URL, includeDefinitions: Bool) throws {
        guard !cards.isEmpty else { throw CardExportError.noCards }
        let header = ["Word", "Sentence", "Translation", "Definition", "Explanation", "Source"]
        let rows = cards.map { card in
            return [plain(card.word ?? ""), plain(card.sentence), plain(card.translation ?? ""),
                    plain(wordDetailsText(for: card, includeDictionary: includeDefinitions)),
                    plain(explanationText(for: card)), plain(sourceText(for: card))]
                .map(tsvCell).joined(separator: "\t")
        }
        let text = ([header.joined(separator: "\t")] + rows).joined(separator: "\n") + "\n"
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    private static func createCollection(at url: URL,
                                         cards: [Card],
                                         deckName: String,
                                         oneDeckPerVideo: Bool,
                                         includeDefinitions: Bool,
                                         includeImages: Bool) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let db = database else {
            throw CardExportError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }

        try exec(db, """
        PRAGMA user_version=11;
        CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null, dconf text not null, tags text not null);
        CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null);
        CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null, factor integer not null, reps integer not null, lapses integer not null, left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null);
        CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
        CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
        CREATE INDEX ix_notes_usn on notes (usn);
        CREATE INDEX ix_cards_usn on cards (usn);
        CREATE INDEX ix_cards_nid on cards (nid);
        CREATE INDEX ix_cards_sched on cards (did, queue, due);
        CREATE INDEX ix_revlog_usn on revlog (usn);
        CREATE INDEX ix_revlog_cid on revlog (cid);
        """)

        let now = Int64(Date().timeIntervalSince1970)
        let nowMilliseconds = now * 1000
        var deckNamesByPath: [String: String] = [:]
        for card in cards {
            let title = card.videoTitle.isEmpty
                ? URL(fileURLWithPath: card.videoPath).deletingPathExtension().lastPathComponent
                : card.videoTitle
            deckNamesByPath[card.videoPath] = oneDeckPerVideo ? title : deckName
        }
        let deckNames = Array(Set(deckNamesByPath.values)).sorted()
        let deckIDs = Dictionary(uniqueKeysWithValues: deckNames.map { ($0, stableID("deck:\($0)")) })
        let defaultDeckID = deckIDs[deckNames.first ?? deckName] ?? stableID("deck:\(deckName)")
        let models = try jsonString(modelJSON(modified: now, deckID: defaultDeckID))
        var deckObjects: [String: Any] = [:]
        for name in deckNames {
            let id = deckIDs[name]!
            deckObjects[String(id)] = deckObject(name: name, modified: now, deckID: id)
        }
        let decks = try jsonString(deckObjects)
        let conf = try jsonString([
            "nextPos": cards.count + 1, "estTimes": true, "activeDecks": deckNames.compactMap { deckIDs[$0] },
            "sortType": "noteFld", "timeLim": 0, "sortBackwards": false,
            "addToCur": true, "curDeck": defaultDeckID, "newSpread": 0, "collapseTime": 1200,
        ])
        let dconf = try jsonString(defaultDeckConfig(modified: now))

        try insert(db,
                   "INSERT INTO col VALUES (1,?,?,?,?,0,-1,0,?,?,?,?,?)",
                   [.int(now), .int(now), .int(nowMilliseconds), .int(11),
                    .text(conf), .text(models), .text(decks), .text(dconf), .text("{}")])

        for (index, card) in cards.enumerated() {
            let noteID = stableID("note:\(card.id.uuidString)")
            let cardID = stableID("card:\(card.id.uuidString)")
            let cardDeckName = deckNamesByPath[card.videoPath] ?? deckName
            let cardDeckID = deckIDs[cardDeckName] ?? defaultDeckID
            let values = fields(for: card,
                                includeDefinitions: includeDefinitions,
                                includeImages: includeImages)
            let flds = values.joined(separator: "\u{1f}")
            let sortField = card.word?.isEmpty == false ? card.word! : card.sentence
            let previousExport = card.exportedAt.map { Int64($0.timeIntervalSince1970) + 1 } ?? 0
            let modified = max(now, Int64(card.lastUsedAt.timeIntervalSince1970), previousExport)
            try insert(db,
                       "INSERT INTO notes VALUES (?,?,?,?,?,'',?,?,?,0,'')",
                       [.int(noteID), .text(card.guid), .int(modelID), .int(modified), .int(-1),
                        .text(flds), .text(sortField), .int(Int64(checksum(sortField)))])
            try insert(db,
                       "INSERT INTO cards VALUES (?,?,?,?,?,-1,0,0,?,0,0,0,0,0,0,0,0,'')",
                       [.int(cardID), .int(noteID), .int(cardDeckID),
                        .int(card.kind == .word ? 0 : 1), .int(modified), .int(Int64(index + 1))])
        }
    }

    private enum SQLValue {
        case int(Int64)
        case text(String)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(message)
            throw CardExportError.sqlite(detail)
        }
    }

    private static func insert(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CardExportError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CardExportError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func fields(for card: Card,
                               includeDefinitions: Bool,
                               includeImages: Bool) -> [String] {
        let word = html(card.word ?? "")
        let sentence = boldWord(in: card.sentence, word: card.word)
        let translation = html(card.translation ?? "")
        let definition = wordDetailsHTML(for: card, includeDictionary: includeDefinitions)
        let explanation = html(explanationText(for: card)).replacingOccurrences(of: "\n", with: "<br>")
        let source = html(sourceText(for: card))
        let screenshot = includeImages
            ? card.screenshot.map { "<img src=\"\(htmlAttribute($0))\">" } ?? ""
            : ""
        return [word, sentence, translation, definition, explanation, source, screenshot, ""]
    }

    private static func wordDetailsText(for card: Card, includeDictionary: Bool) -> String {
        var sections: [String] = []
        if let info = card.contextualWordInfo { sections.append(info.plainText) }
        if includeDictionary, let definition = card.definition, !definition.isEmpty {
            sections.append(definition)
        }
        return sections.joined(separator: "\n\n")
    }

    private static func wordDetailsHTML(for card: Card, includeDictionary: Bool) -> String {
        var sections: [String] = []
        if let info = card.contextualWordInfo {
            var parts = ["<div class=context-meaning>\(html(info.meaningInContext))</div>"]
            let details = [info.lemma, info.partOfSpeech].filter { !$0.isEmpty }.joined(separator: " · ")
            if !details.isEmpty { parts.append("<div class=word-details>\(html(details))</div>") }
            if !info.definition.isEmpty { parts.append("<div>\(html(info.definition))</div>") }
            if !info.otherMeanings.isEmpty {
                parts.append("<div>\(html(String(localized: "Other meanings: \(info.otherMeanings.joined(separator: " · "))")))</div>")
            }
            if !info.synonyms.isEmpty {
                parts.append("<div>\(html(String(localized: "Synonyms: \(info.synonyms.joined(separator: " · "))")))</div>")
            }
            sections.append("<div class=contextual-word>\(parts.joined())</div>")
        }
        if includeDictionary, let definition = card.definition, !definition.isEmpty {
            sections.append("<div class=dictionary-definition>\(html(definition).replacingOccurrences(of: "\n", with: "<br>"))</div>")
        }
        return sections.joined()
    }

    private static func explanationText(for card: Card) -> String {
        var sections: [String] = []
        if let explanation = card.explanation {
            if !explanation.translation.isEmpty { sections.append(explanation.translation) }
            sections.append(contentsOf: explanation.idioms.map { "\($0.idiom): \($0.actualMeaning)" })
            sections.append(contentsOf: explanation.difficultWords.map {
                let part = $0.partOfSpeech.map { " (\($0))" } ?? ""
                return "\($0.word)\(part): \($0.translation)"
            })
            if let note = explanation.contextNote, !note.isEmpty { sections.append(note) }
        }
        if let notes = card.notes, !notes.isEmpty { sections.append(notes) }
        return sections.joined(separator: "\n")
    }

    private static func sourceText(for card: Card) -> String {
        "\(URL(fileURLWithPath: card.videoPath).lastPathComponent), \(OSDView.formatTime(card.time))"
    }

    private static func modelJSON(modified: Int64, deckID: Int64) -> [String: Any] {
        let fields: [[String: Any]] = fieldNames.enumerated().map { index, name in
            ["name": name, "ord": index, "sticky": false, "rtl": false, "font": "Arial", "size": 20,
             "media": [], "description": "", "plainText": false, "collapsed": false, "excludeFromSearch": false]
        }
        let wordFront = "{{#Word}}<div class=media>{{Screenshot}}</div><div class=word>{{Word}}</div><div class=sentence>{{Sentence}}</div>{{/Word}}"
        let phraseFront = "{{^Word}}<div class=media>{{Screenshot}}</div><div class=sentence>{{Sentence}}</div>{{/Word}}"
        let back = "{{FrontSide}}<hr id=answer><div class=translation>{{Translation}}</div><div class=definition>{{Definition}}</div><div class=explanation>{{Explanation}}</div><div class=source>{{Source}}</div>{{Audio}}"
        let templates: [[String: Any]] = [
            ["name": "Word → meaning", "ord": 0, "qfmt": wordFront, "afmt": back, "did": NSNull(), "bqfmt": "", "bafmt": ""],
            ["name": "Phrase → translation", "ord": 1, "qfmt": phraseFront, "afmt": back, "did": NSNull(), "bqfmt": "", "bafmt": ""],
        ]
        let css = ".card{font-family:-apple-system,Arial;font-size:20px;text-align:center;color:#111;background:#fff}.word{font-size:34px;font-weight:700;margin:12px}.sentence{font-size:21px;margin:12px}.translation{font-size:22px;margin:12px}.definition,.explanation{font-size:17px;margin:10px;line-height:1.4}.context-meaning{font-size:22px;font-weight:700}.word-details{font-size:13px;color:#777;margin:3px}.dictionary-definition{font-size:14px;color:#666;margin-top:12px}.source{font-size:12px;color:#777;margin-top:12px}.media img{max-width:100%;max-height:320px;border-radius:8px}.nightMode .card{color:#eee;background:#1c1c1e}"
        return [String(modelID): [
            "id": modelID, "name": "Lerzo Player", "type": 0, "mod": modified,
            "usn": -1, "sortf": 0, "did": deckID, "tmpls": templates,
            "flds": fields, "css": css, "latexPre": "", "latexPost": "",
            "latexsvg": false, "req": [[0, "all", [0]], [1, "none", [0]]],
        ]]
    }

    private static func deckObject(name: String, modified: Int64, deckID: Int64) -> [String: Any] {
        ["id": deckID, "name": name, "mod": modified, "usn": -1,
         "desc": "", "dyn": 0, "collapsed": false, "browserCollapsed": false,
         "extendNew": 10, "extendRev": 50, "conf": 1,
         "newToday": [0, 0], "revToday": [0, 0], "lrnToday": [0, 0], "timeToday": [0, 0]]
    }

    private static func defaultDeckConfig(modified: Int64) -> [String: Any] {
        ["1": ["id": 1, "name": "Default", "mod": modified, "usn": 0,
               "maxTaken": 60, "timer": 0, "autoplay": true, "replayq": true,
               "new": ["delays": [1, 10], "ints": [1, 4], "initialFactor": 2500,
                       "separate": true, "order": 1, "perDay": 20, "bury": true],
               "lapse": ["delays": [10], "mult": 0, "minInt": 1, "leechFails": 8,
                          "leechAction": 0],
               "rev": ["perDay": 200, "ease4": 1.3, "fuzz": 0.05, "ivlFct": 1,
                        "maxIvl": 36500, "hardFactor": 1.2, "bury": true]]]
    }

    private static func jsonString(_ object: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private static func stableID(_ value: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int64(hash & 0x3fff_ffff_ffff_ffff) + 1
    }

    private static func checksum(_ value: String) -> UInt32 {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func boldWord(in sentence: String, word: String?) -> String {
        guard let word, !word.isEmpty,
              let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: word), options: .caseInsensitive)
        else { return html(sentence) }
        let source = sentence as NSString
        let matches = regex.matches(in: sentence, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return html(sentence) }
        var result = "", location = 0
        for match in matches {
            result += html(source.substring(with: NSRange(location: location, length: match.range.location - location)))
            result += "<b>\(html(source.substring(with: match.range)))</b>"
            location = match.range.location + match.range.length
        }
        result += html(source.substring(from: location))
        return result
    }

    private static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func htmlAttribute(_ value: String) -> String { html(value) }
    private static func plain(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
    private static func tsvCell(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

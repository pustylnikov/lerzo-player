import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CardsWindow: View {
    static let windowID = "cards"

    @ObservedObject private var store = CardStore.shared
    @State private var selection = Set<UUID>()
    @State private var expandedExportedGroups = Set<String>()
    @State private var pendingUndo: [Card] = []
    @State private var undoWorkItem: DispatchWorkItem?
    @State private var showExport = false

    private struct VideoGroup: Identifiable {
        let path: String
        let title: String
        let cards: [Card]
        var id: String { path }
        var newCards: [Card] { cards.filter { $0.exportedAt == nil } }
        var exportedCards: [Card] { cards.filter { $0.exportedAt != nil } }
    }

    private var groups: [VideoGroup] {
        let grouped = Dictionary(grouping: store.cards, by: \.videoPath)
        return grouped.map { path, cards in
            VideoGroup(path: path,
                       title: cards.last?.videoTitle ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                       cards: cards.sorted { $0.createdAt > $1.createdAt })
        }
        .sorted { ($0.cards.map(\.lastUsedAt).max() ?? .distantPast) > ($1.cards.map(\.lastUsedAt).max() ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(groups) { group in
                            groupView(group)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 520, idealHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(CardWindowReader { KeyboardMonitor.shared.cardsWindow = $0 })
        .onAppear {
            selection.formUnion(store.cards.filter { $0.exportedAt == nil }.map(\.id))
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            removeWithUndo(selection)
        }
        .onDisappear { finishPendingUndo() }
        .sheet(isPresented: $showExport) {
            CardsExportView(selectedIDs: selection) { exportedIDs in
                selection.subtract(exportedIDs)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cards")
                    .font(.system(size: 18, weight: .bold))
                Text("\(store.cards.filter { $0.exportedAt == nil }.count) new · \(store.cards.filter { $0.exportedAt != nil }.count) exported")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Export…") { showExport = true }
                .buttonStyle(.borderedProminent)
                .disabled(store.cards.isEmpty)
            if !selection.isEmpty {
                Button("Delete Selected") { removeWithUndo(selection) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !pendingUndo.isEmpty { undoBanner.offset(y: 42) }
        }
        .zIndex(2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("No cards yet")
                .font(.system(size: 16, weight: .semibold))
            Text("Click a subtitle word, ask for an AI breakdown, or press S on a line.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupView(_ group: VideoGroup) -> some View {
        VStack(spacing: 0) {
            groupHeader(group)
            if group.newCards.isEmpty {
                Text("No new cards in this video")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ForEach(group.newCards) { card in
                    Divider().opacity(0.5)
                    cardRow(card)
                }
            }

            if !group.exportedCards.isEmpty {
                Divider().opacity(0.5)
                Button {
                    if expandedExportedGroups.contains(group.id) {
                        expandedExportedGroups.remove(group.id)
                    } else {
                        expandedExportedGroups.insert(group.id)
                    }
                } label: {
                    HStack {
                        Image(systemName: expandedExportedGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(group.exportedCards.count) exported")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if expandedExportedGroups.contains(group.id) {
                    ForEach(group.exportedCards) { card in
                        Divider().opacity(0.5)
                        cardRow(card)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private func groupHeader(_ group: VideoGroup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("\(group.newCards.count) new · \(group.exportedCards.count) exported")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Menu {
                Button("Delete Exported") {
                    removeImmediately(Set(group.exportedCards.map(\.id)))
                }
                .disabled(group.exportedCards.isEmpty)
                Divider()
                Button("Delete All Cards from This Video", role: .destructive) {
                    removeImmediately(Set(group.cards.map(\.id)))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.035))
    }

    private func cardRow(_ card: Card) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: selectionBinding(for: card.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 5)

            screenshot(for: card)

            VStack(alignment: .leading, spacing: 7) {
                if card.kind == .word {
                    TextField("Word", text: optionalTextBinding(for: card.id, keyPath: \.word))
                        .font(.system(size: 14, weight: .bold))
                        .textFieldStyle(.plain)
                }
                TextField("Sentence", text: textBinding(for: card.id, keyPath: \.sentence))
                    .font(.system(size: 13, weight: .medium))
                    .textFieldStyle(.plain)
                TextField("Translation", text: optionalTextBinding(for: card.id, keyPath: \.translation))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .textFieldStyle(.plain)
                TextField("Definition", text: optionalTextBinding(for: card.id, keyPath: \.definition), axis: .vertical)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                if let info = card.contextualWordInfo {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Gemini word meaning", systemImage: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.yellow)
                        Text(info.plainText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(5)
                    }
                }
                TextField("Note", text: optionalTextBinding(for: card.id, keyPath: \.notes), axis: .vertical)
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                if let explanation = card.explanation {
                    Text(explanationSummary(explanation))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                Text("\(OSDView.formatTime(card.time)) · \(card.kind == .word ? String(localized: "Word card") : String(localized: "Phrase card"))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Button {
                removeWithUndo([card.id])
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete Card")
        }
        .padding(14)
    }

    @ViewBuilder
    private func screenshot(for card: Card) -> some View {
        if let name = card.screenshot,
           let image = NSImage(contentsOf: store.mediaDirectoryURL.appendingPathComponent(name)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 112, height: 63)
                .overlay(Image(systemName: "photo").foregroundColor(.secondary))
        }
    }

    private var undoBanner: some View {
        HStack(spacing: 10) {
            Text(pendingUndo.count == 1 ? "Card deleted" : "\(pendingUndo.count) cards deleted")
            Button("Undo") { undoDeletion() }
                .buttonStyle(.plain)
                .foregroundColor(.yellow)
                .fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.black.opacity(0.86)))
        .foregroundColor(.white)
        .shadow(radius: 8)
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selection.contains(id) }, set: { selected in
            if selected { selection.insert(id) } else { selection.remove(id) }
        })
    }

    private func textBinding(for id: UUID, keyPath: WritableKeyPath<Card, String>) -> Binding<String> {
        Binding(get: { store.card(withID: id)?[keyPath: keyPath] ?? "" }, set: { value in
            guard var card = store.card(withID: id) else { return }
            card[keyPath: keyPath] = value
            store.update(card)
        })
    }

    private func optionalTextBinding(for id: UUID, keyPath: WritableKeyPath<Card, String?>) -> Binding<String> {
        Binding(get: { store.card(withID: id)?[keyPath: keyPath] ?? "" }, set: { value in
            guard var card = store.card(withID: id) else { return }
            card[keyPath: keyPath] = value.isEmpty ? nil : value
            store.update(card)
        })
    }

    private func explanationSummary(_ explanation: SubtitleExplanation) -> String {
        var parts = [explanation.translation]
        parts.append(contentsOf: explanation.idioms.map { "\($0.idiom): \($0.actualMeaning)" })
        parts.append(contentsOf: explanation.difficultWords.map { "\($0.word): \($0.translation)" })
        if let note = explanation.contextNote, !note.isEmpty { parts.append(note) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func removeWithUndo(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        finishPendingUndo()
        pendingUndo = store.remove(ids: ids)
        selection.subtract(ids)
        let work = DispatchWorkItem { finishPendingUndo() }
        undoWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func undoDeletion() {
        undoWorkItem?.cancel()
        undoWorkItem = nil
        store.restore(pendingUndo)
        selection.formUnion(pendingUndo.map(\.id))
        pendingUndo = []
    }

    private func finishPendingUndo() {
        undoWorkItem?.cancel()
        undoWorkItem = nil
        if !pendingUndo.isEmpty { store.discardMedia(for: pendingUndo) }
        pendingUndo = []
    }

    private func removeImmediately(_ ids: Set<UUID>) {
        finishPendingUndo()
        let removed = store.remove(ids: ids)
        selection.subtract(ids)
        store.discardMedia(for: removed)
    }
}

private struct CardsExportView: View {
    private enum ExportFormat: String, CaseIterable, Identifiable {
        case apkg, tsv
        var id: String { rawValue }
    }
    private enum Scope: String, CaseIterable, Identifiable {
        case selected, video, all
        var id: String { rawValue }
    }

    @ObservedObject private var store = CardStore.shared
    @Environment(\.dismiss) private var dismiss
    let selectedIDs: Set<UUID>
    let onExport: (Set<UUID>) -> Void

    @State private var format: ExportFormat = .apkg
    @State private var scope: Scope
    @State private var videoPath: String
    @State private var deckName: String
    @State private var oneDeckPerVideo = false
    @State private var includeDefinitions: Bool
    @State private var includeImages = true
    @State private var deleteAfterExport = false
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(selectedIDs: Set<UUID>, onExport: @escaping (Set<UUID>) -> Void) {
        self.selectedIDs = selectedIDs
        self.onExport = onExport
        let cards = CardStore.shared.cards
        let currentPath = MPVPlayer.shared.currentFileURL?.standardizedFileURL.path
        let initialPath = cards.first(where: { $0.videoPath == currentPath })?.videoPath ?? cards.first?.videoPath ?? ""
        let initialTitle = cards.first(where: { $0.videoPath == initialPath })?.videoTitle ?? "Lerzo Player"
        _scope = State(initialValue: selectedIDs.isEmpty ? .all : .selected)
        _videoPath = State(initialValue: initialPath)
        _deckName = State(initialValue: initialTitle.isEmpty ? "Lerzo Player" : initialTitle)
        let initialCards = selectedIDs.isEmpty ? cards : cards.filter { selectedIDs.contains($0.id) }
        _includeDefinitions = State(initialValue: !initialCards.contains { $0.contextualWordInfo != nil })
    }

    private var videoChoices: [(path: String, title: String)] {
        Dictionary(grouping: store.cards, by: \.videoPath).map { path, cards in
            (path, cards.first?.videoTitle ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var cardsToExport: [Card] {
        switch scope {
        case .selected: return store.cards.filter { selectedIDs.contains($0.id) }
        case .video: return store.cards.filter { $0.videoPath == videoPath }
        case .all: return store.cards
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(.yellow)
                Text("Export Cards")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
            }

            Picker("Format:", selection: $format) {
                Text("Anki package (.apkg)").tag(ExportFormat.apkg)
                Text("Tab-separated text (.tsv)").tag(ExportFormat.tsv)
            }

            Picker("Cards:", selection: $scope) {
                Text("Selected (\(selectedIDs.count))").tag(Scope.selected)
                    .disabled(selectedIDs.isEmpty)
                Text("One video").tag(Scope.video)
                Text("All cards (\(store.cards.count))").tag(Scope.all)
            }
            .pickerStyle(.segmented)

            if scope == .video {
                Picker("Video:", selection: $videoPath) {
                    ForEach(videoChoices, id: \.path) { choice in
                        Text(choice.title).tag(choice.path)
                    }
                }
            }

            if format == .apkg {
                TextField("Deck name", text: $deckName)
                    .textFieldStyle(.roundedBorder)
                Toggle("Create one deck per video", isOn: $oneDeckPerVideo)
                    .disabled(scope == .video)
                Toggle("Include images", isOn: $includeImages)
            }

            Toggle("Include macOS dictionary definitions", isOn: $includeDefinitions)
            Toggle("Delete exported cards after export", isOn: $deleteAfterExport)

            Text("Gemini word meanings are always exported. macOS dictionary text is optional and is kept separate to avoid noisy cards.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            HStack {
                Text("\(cardsToExport.count) cards")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") { export() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cardsToExport.isEmpty || isExporting)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func export() {
        let panel = NSSavePanel()
        let ext = format.rawValue
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = suggestedFilename(extension: ext)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let cards = cardsToExport
        let ids = Set(cards.map(\.id))
        let format = format
        let deckName = deckName
        let perVideo = oneDeckPerVideo
        let includeDefinitions = includeDefinitions
        let includeImages = includeImages
        isExporting = true
        errorMessage = nil
        Task.detached {
            do {
                switch format {
                case .apkg:
                    try CardExporter.exportAPKG(cards: cards, to: url, deckName: deckName,
                                                oneDeckPerVideo: perVideo,
                                                includeDefinitions: includeDefinitions,
                                                includeImages: includeImages)
                case .tsv:
                    try CardExporter.exportTSV(cards: cards, to: url, includeDefinitions: includeDefinitions)
                }
                await MainActor.run {
                    store.markExported(ids: ids)
                    if deleteAfterExport {
                        let removed = store.remove(ids: ids)
                        store.discardMedia(for: removed)
                    }
                    onExport(ids)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }

    private func suggestedFilename(extension ext: String) -> String {
        let base: String
        if scope == .video, let title = videoChoices.first(where: { $0.path == videoPath })?.title {
            base = title
        } else {
            base = deckName.isEmpty ? "Lerzo Player" : deckName
        }
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe).\(ext)"
    }
}

private struct CardWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onWindow(window) }
    }
}

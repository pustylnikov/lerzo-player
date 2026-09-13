import SwiftUI
import AppKit

/// Facts about this build shown in the About window. The license texts travel in
/// `Contents/Resources`: `LICENSE` in every build, `THIRD-PARTY-SOURCES.md` only in
/// bundles assembled by `scripts/release.sh`.
enum AboutInfo {
    static let websiteURL = URL(string: "https://lerzowords.com/player")!
    /// Public repository; nil hides the button until the repository exists.
    static let repositoryURL: URL? = nil

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    static var licenseText: String? {
        Bundle.main.url(forResource: "LICENSE", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    struct Library: Identifiable {
        let name: String
        let version: String
        let license: String
        let source: URL?
        let formula: URL?
        var id: String { name }
    }

    /// Rows of the table in THIRD-PARTY-SOURCES.md:
    /// `| [name](formula) | version | license | source | libraries |`
    static var libraries: [Library] {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-SOURCES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> Library? in
            guard line.hasPrefix("| [") else { return nil }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 6 else { return nil }
            let link = cells[1]
            guard let close = link.firstIndex(of: "]") else { return nil }
            let name = String(link[link.index(after: link.startIndex)..<close])
            let formula = link[link.index(close, offsetBy: 2)...].dropLast()
            return Library(name: name, version: cells[2], license: cells[3],
                           source: URL(string: cells[4]), formula: URL(string: String(formula)))
        }
    }
}

struct AboutView: View {
    static let windowID = "about"
    private enum Tab: Hashable { case about, license, libraries }
    @State private var tab: Tab = .about
    private let libraries = AboutInfo.libraries

    var body: some View {
        VStack(spacing: 16) {
            header
            Picker("", selection: $tab) {
                Text("About").tag(Tab.about)
                Text("License").tag(Tab.license)
                Text("Libraries").tag(Tab.libraries)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Group {
                switch tab {
                case .about: aboutTab
                case .license: licenseTab
                case .libraries: librariesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .background(WindowReader { KeyboardMonitor.shared.aboutWindow = $0 })
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lerzo Player")
                    .font(.system(size: 22, weight: .bold))
                Text("Version \(AboutInfo.version)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(AboutInfo.copyright)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A video player for learning languages: clickable subtitles, line-by-line seeking and AI explanations of dialogue.")
                .font(.system(size: 13))
            Text("Lerzo Player is free software under the GNU General Public License, version 3. The source code of this exact version ships in the download next to the app, in the “Source code” folder.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Playback is powered by mpv and FFmpeg. The Libraries tab lists every open-source library included in this build.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Link("Website ↗", destination: AboutInfo.websiteURL)
                if let repository = AboutInfo.repositoryURL {
                    Link("Source Code ↗", destination: repository)
                }
            }
            .font(.system(size: 12))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var licenseTab: some View {
        ScrollView {
            Text(AboutInfo.licenseText ?? String(localized: "The license text is missing from this build."))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.black.opacity(0.2))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var librariesTab: some View {
        if libraries.isEmpty {
            VStack(spacing: 8) {
                Text("This development build links the libraries installed by Homebrew.")
                Text("Release builds bundle them and list each one here with its version, license and source.")
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(libraries.count) libraries built by Homebrew are bundled with the app. Links lead to each library's source code and build recipe.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                List(libraries) { library in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(library.name) \(library.version)")
                                .font(.system(size: 12, weight: .medium))
                            Text(library.license)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let source = library.source {
                            Link("Source ↗", destination: source)
                        }
                        if let formula = library.formula {
                            Link("Recipe ↗", destination: formula)
                        }
                    }
                    .font(.system(size: 11))
                }
                .listStyle(.inset)
                .cornerRadius(6)
            }
        }
    }
}

/// Hands the hosting NSWindow to the caller once the view is in a window.
private struct WindowReader: NSViewRepresentable {
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

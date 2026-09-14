import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Load the API key (and migrate it out of UserDefaults) right away
        // rather than when Settings is first opened.
        _ = GeminiService.shared
        
        let args = CommandLine.arguments
        for arg in args.dropFirst() {
            if !arg.starts(with: "-") {
                let url = URL(fileURLWithPath: arg)
                if FileManager.default.fileExists(atPath: url.path) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MPVPlayer.shared.loadFile(url: url)
                    }
                    break
                }
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        MPVPlayer.shared.open(url: URL(fileURLWithPath: filename))
        return true
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        if let first = urls.first {
            MPVPlayer.shared.open(url: first)
        }
    }
}

@main
struct LerzoPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// Observed so the Video menu's Fit/Fill title follows the player.
    @ObservedObject private var player = MPVPlayer.shared
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updater = UpdaterController.shared
    
    var body: some Scene {
        Window("Lerzo Player", id: "main") {
            ContentView()
                .frame(minWidth: 800, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    MPVPlayer.shared.open(url: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lerzo Player") {
                    openWindow(id: AboutView.windowID)
                }
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandGroup(replacing: .newItem) {
                Button("Open Video File...") {
                    KeyboardMonitor.shared.onOpenFileRequested?()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Load Subtitle File...") {
                    KeyboardMonitor.shared.onOpenSubtitleRequested?()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(player.currentFileURL == nil)
            }
            
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    MPVPlayer.shared.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                
                Button("Replay Line") {
                    MPVPlayer.shared.seekSubtitle(direction: 0)
                    OSDController.shared.show(.replayLine)
                }
                .keyboardShortcut("r", modifiers: [])
                
                Button("Previous Line") {
                    MPVPlayer.shared.seekSubtitle(direction: -1)
                    OSDController.shared.show(.previousLine)
                }
                .keyboardShortcut("w", modifiers: [])

                Button("Next Line") {
                    MPVPlayer.shared.seekSubtitle(direction: 1)
                    OSDController.shared.show(.nextLine)
                }
                .keyboardShortcut("e", modifiers: [])
                
                Divider()

                Toggle("Pause After Each Line", isOn: Binding(
                    get: { player.autoPauseAfterLine },
                    set: { player.autoPauseAfterLine = $0; OSDController.shared.show(.autoPause) }
                ))
                .keyboardShortcut("p", modifiers: [])

                Menu("Auto-Pause Delay") {
                    Button("Later by 0.1 s") { adjustAutoPauseTail(by: MPVPlayer.autoPauseTailStep) }
                        .keyboardShortcut("p", modifiers: .shift)
                    Button("Earlier by 0.1 s") { adjustAutoPauseTail(by: -MPVPlayer.autoPauseTailStep) }
                        .keyboardShortcut("o", modifiers: .shift)
                    Button("Reset") { adjustAutoPauseTail(by: nil) }
                }

                Toggle("Repeat Current Line", isOn: Binding(
                    get: { player.isLoopingLine },
                    set: { _ in player.toggleLineLoop(); OSDController.shared.show(.loop) }
                ))
                .keyboardShortcut("l", modifiers: [])

                Button(abLoopTitle) {
                    player.cycleABLoop()
                    OSDController.shared.show(.loop)
                }
                .keyboardShortcut("l", modifiers: .shift)

                Divider()
                
                Button("Back 5 Seconds") {
                    MPVPlayer.shared.seekRelative(seconds: -5)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                
                Button("Forward 5 Seconds") {
                    MPVPlayer.shared.seekRelative(seconds: 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Mute / Unmute") {
                    MPVPlayer.shared.toggleMute()
                }
                .keyboardShortcut("m", modifiers: [])

                Toggle("Boost Dialogue", isOn: Binding(
                    get: { player.boostDialogue },
                    set: { player.boostDialogue = $0; OSDController.shared.show(.boostDialogue) }
                ))
                .keyboardShortcut("b", modifiers: [])

                Toggle("Always Show Translation", isOn: Binding(
                    get: { player.translationMode == .always },
                    set: { player.translationMode = $0 ? .always : .peek; OSDController.shared.show(.translationMode) }
                ))
                .keyboardShortcut(.tab, modifiers: .shift)

                Divider()

                Menu("Subtitle Delay") {
                    Button("Earlier by 0.1 s") { adjustDelay(.subtitle, by: -MPVPlayer.delayStep) }
                        .keyboardShortcut("z", modifiers: [])
                    Button("Later by 0.1 s") { adjustDelay(.subtitle, by: MPVPlayer.delayStep) }
                        .keyboardShortcut("x", modifiers: [])
                    Button("Reset") { adjustDelay(.subtitle, by: nil) }
                }
                Menu("Translation Delay") {
                    Button("Earlier by 0.1 s") { adjustDelay(.secondarySubtitle, by: -MPVPlayer.delayStep) }
                    Button("Later by 0.1 s") { adjustDelay(.secondarySubtitle, by: MPVPlayer.delayStep) }
                    Button("Reset") { adjustDelay(.secondarySubtitle, by: nil) }
                }
                Menu("Audio Delay") {
                    Button("Earlier by 0.1 s") { adjustDelay(.audio, by: -MPVPlayer.delayStep) }
                        .keyboardShortcut("z", modifiers: .shift)
                    Button("Later by 0.1 s") { adjustDelay(.audio, by: MPVPlayer.delayStep) }
                        .keyboardShortcut("x", modifiers: .shift)
                    Button("Reset") { adjustDelay(.audio, by: nil) }
                }
            }
            
            CommandMenu("Video") {
                Button(player.fillsWindow ? "Fit to Window" : "Fill Window") {
                    MPVPlayer.shared.setFillsWindow(!player.fillsWindow)
                    OSDController.shared.show(.fill)
                }
                Divider()
                Button("Zoom In") { MPVPlayer.shared.adjustZoom(by: MPVPlayer.zoomStep); OSDController.shared.show(.zoom) }
                    .keyboardShortcut("=", modifiers: [])
                Button("Zoom Out") { MPVPlayer.shared.adjustZoom(by: -MPVPlayer.zoomStep); OSDController.shared.show(.zoom) }
                    .keyboardShortcut("-", modifiers: [])
                Button("Reset Zoom and Position") { MPVPlayer.shared.resetZoomAndPan(); OSDController.shared.show(.zoom) }
                    .keyboardShortcut("0", modifiers: [])
                Menu("Move Picture") {
                    Button("Up") { MPVPlayer.shared.pan(dx: 0, dy: -MPVPlayer.panStep); OSDController.shared.show(.zoom) }
                        .keyboardShortcut(.upArrow, modifiers: .shift)
                    Button("Down") { MPVPlayer.shared.pan(dx: 0, dy: MPVPlayer.panStep); OSDController.shared.show(.zoom) }
                        .keyboardShortcut(.downArrow, modifiers: .shift)
                    Button("Left") { MPVPlayer.shared.pan(dx: -MPVPlayer.panStep, dy: 0); OSDController.shared.show(.zoom) }
                        .keyboardShortcut(.leftArrow, modifiers: .shift)
                    Button("Right") { MPVPlayer.shared.pan(dx: MPVPlayer.panStep, dy: 0); OSDController.shared.show(.zoom) }
                        .keyboardShortcut(.rightArrow, modifiers: .shift)
                }
                Divider()
                Button("Remove Black Bars") {
                    MPVPlayer.shared.removeBlackBars { OSDController.shared.show(.crop($0)) }
                }
                Button("Reset Crop") { MPVPlayer.shared.resetCrop() }
                    .disabled(player.videoCrop.isEmpty)
                Divider()
                Button("Brightness, Contrast, Gamma…") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
                }
            }

            CommandMenu("Language Learning (AI)") {
                Button("Explain Line with Gemini") {
                    KeyboardMonitor.shared.onExplainRequested?()
                }
                .keyboardShortcut("g", modifiers: .command)
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleShortcuts"), object: nil)
                }
                .keyboardShortcut("h", modifiers: [])
            }
        }

        aboutWindow
    }

    /// The About window; `KeyboardMonitor` leaves keys alone while it is in front.
    private var aboutWindow: some Scene {
        Window("About Lerzo Player", id: AboutView.windowID) {
            AboutView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }

    /// `nil` resets the delay. Shows the OSD so the menu gives the same feedback as the keys.
    private var abLoopTitle: LocalizedStringKey {
        switch player.loopMode {
        case .ab(_, nil): return "Mark Loop End"
        case .ab: return "Clear A–B Loop"
        default: return "Mark Loop Start"
        }
    }

    private func adjustAutoPauseTail(by delta: Double?) {
        if let delta {
            MPVPlayer.shared.adjustAutoPauseTail(by: delta)
        } else {
            MPVPlayer.shared.setAutoPauseTail(0)
        }
        OSDController.shared.show(.autoPauseTail)
    }

    private func adjustDelay(_ stream: MPVPlayer.DelayStream, by delta: Double?) {
        if let delta {
            MPVPlayer.shared.adjustDelay(of: stream, by: delta)
        } else {
            MPVPlayer.shared.resetDelay(of: stream)
        }
        OSDController.shared.show(.delay(stream))
    }
}

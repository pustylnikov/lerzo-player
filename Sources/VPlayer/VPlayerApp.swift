import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
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
        let url = URL(fileURLWithPath: filename)
        MPVPlayer.shared.loadFile(url: url)
        return true
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        if let first = urls.first {
            MPVPlayer.shared.loadFile(url: first)
        }
    }
}

@main
struct VPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Window("VPlayer", id: "main") {
            ContentView()
                .frame(minWidth: 800, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    MPVPlayer.shared.loadFile(url: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
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
            }
            
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    MPVPlayer.shared.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                
                Button("Replay Line") {
                    MPVPlayer.shared.seekSubtitle(direction: 0)
                }
                .keyboardShortcut("r", modifiers: [])
                
                Button("Next Line") {
                    MPVPlayer.shared.seekSubtitle(direction: 1)
                }
                .keyboardShortcut("e", modifiers: [])
                
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
            }
            
            CommandMenu("Language Learning (AI)") {
                Button("Explain Line with Gemini") {
                    KeyboardMonitor.shared.onExplainRequested?()
                }
                .keyboardShortcut("g", modifiers: .command)
            }
        }
    }
}

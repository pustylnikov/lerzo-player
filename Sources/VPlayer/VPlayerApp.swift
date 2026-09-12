import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        let args = CommandLine.arguments
        if args.count > 1 {
            let path = args[1]
            if !path.starts(with: "-") {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MPVPlayer.shared.loadFile(url: url)
                    }
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
                .frame(minWidth: 800, minHeight: 480)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    MPVPlayer.shared.loadFile(url: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandGroup(replacing: .newItem) {
                Button("Открыть видеофайл...") {
                    KeyboardMonitor.shared.onOpenFileRequested?()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            
            CommandMenu("Воспроизведение") {
                Button("Воспроизведение / Пауза") {
                    MPVPlayer.shared.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                
                Button("Повторить реплику сначала") {
                    MPVPlayer.shared.seekSubtitle(direction: 0)
                }
                .keyboardShortcut("r", modifiers: [])
                
                Button("Следующая реплика") {
                    MPVPlayer.shared.seekSubtitle(direction: 1)
                }
                .keyboardShortcut("e", modifiers: [])
                
                Divider()
                
                Button("Перемотка -5 сек") {
                    MPVPlayer.shared.seekRelative(seconds: -5)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                
                Button("Перемотка +5 сек") {
                    MPVPlayer.shared.seekRelative(seconds: 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            
            CommandMenu("Изучение языка (ИИ)") {
                Button("Разобрать реплику с Gemini") {
                    KeyboardMonitor.shared.onExplainRequested?()
                }
                .keyboardShortcut("g", modifiers: .command)
            }
        }
    }
}

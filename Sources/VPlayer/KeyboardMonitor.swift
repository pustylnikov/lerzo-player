import Cocoa
import SwiftUI

public final class KeyboardMonitor: ObservableObject {
    public static let shared = KeyboardMonitor()
    
    private var localMonitor: Any?
    public var onExplainRequested: (() -> Void)?
    public var onOpenFileRequested: (() -> Void)?
    public var onOpenSettingsRequested: (() -> Void)?
    public var onDismissExplanationRequested: (() -> Void)?
    public var onDismissSettingsRequested: (() -> Void)?
    public var onToggleShortcutsRequested: (() -> Void)?
    public var isExplanationOpen: Bool = false
    public var isShortcutsOpen: Bool = false
    /// While the settings sheet is up, player shortcuts must not fire from
    /// its sliders and pickers; only Escape (close) and Cmd+, are handled.
    public var isSettingsOpen: Bool = false
    
    public init() {
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    public func startMonitoring() {
        guard localMonitor == nil else { return }
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            return self.handleEvent(event)
        }
    }
    
    public func stopMonitoring() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
    
    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        // If a text field has focus (e.g. typing API key), do not intercept typing!
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return event
        }
        
        if isSettingsOpen {
            guard event.type == .keyDown else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 || (flags.contains(.command) && event.charactersIgnoringModifiers == ",") {
                onDismissSettingsRequested?()
                return nil
            }
            return event
        }

        let player = MPVPlayer.shared
        let osd = OSDController.shared
        // Arrow keys carry .numericPad/.function; those are not user-held modifiers.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        // Ctrl/Option chords (Ctrl+Space switches the input source, Option+arrows
        // are text navigation…) belong to the system, not to the player.
        // Only Cmd combinations and bare keys are player shortcuts.
        if flags.contains(.control) || flags.contains(.option) {
            return event
        }
        if flags.contains(.command) {
            let commandShortcuts: Set<String> = ["g", "o", ","]
            guard let ch = event.charactersIgnoringModifiers?.lowercased(), commandShortcuts.contains(ch) else {
                return event
            }
        }
        
        if event.type == .keyDown {
            // H (keyCode 4) -> toggle the shortcuts cheat sheet
            if event.keyCode == 4 && flags.isEmpty {
                onToggleShortcutsRequested?()
                return nil
            }

            // ESCAPE KEY (keyCode 53) -> Dismiss cheat sheet / popover or exit fullscreen
            if event.keyCode == 53 {
                if isShortcutsOpen {
                    onToggleShortcutsRequested?()
                    return nil
                } else if isExplanationOpen {
                    onDismissExplanationRequested?()
                    return nil
                } else if player.isFullscreen {
                    player.toggleFullscreen()
                    return nil
                }
            }
            
            // TAB KEY (keyCode 48) - Peek translation (secondary subtitle track)
            if event.keyCode == 48 {
                player.setPeekingTranslation(true)
                return nil
            }


            // Bare keys are matched by physical key code so they work in any
            // keyboard layout (on a Russian layout "[" types "х").
            if flags.isEmpty {
                switch event.keyCode {
                case 33: // [  -> slower (mpv/IINA convention)
                    player.adjustSpeed(by: -MPVPlayer.speedStep); osd.show(.speed); return nil
                case 30: // ]  -> faster
                    player.adjustSpeed(by: MPVPlayer.speedStep); osd.show(.speed); return nil
                case 51: // Backspace -> 1x
                    player.resetSpeed(); osd.show(.speed); return nil
                case 46: // M -> mute, the desktop video player convention
                    player.toggleMute(); osd.show(.volume); return nil
                case 6: // Z -> subtitles earlier (mpv convention)
                    player.adjustDelay(of: .subtitle, by: -MPVPlayer.delayStep); osd.show(.delay(.subtitle)); return nil
                case 7: // X -> subtitles later
                    player.adjustDelay(of: .subtitle, by: MPVPlayer.delayStep); osd.show(.delay(.subtitle)); return nil
                case 24: // = -> zoom in
                    player.adjustZoom(by: MPVPlayer.zoomStep); osd.show(.zoom); return nil
                case 27: // - -> zoom out
                    player.adjustZoom(by: -MPVPlayer.zoomStep); osd.show(.zoom); return nil
                case 29: // 0 -> 100 %, centred
                    player.resetZoomAndPan(); osd.show(.zoom); return nil
                default: break
                }
            }
            if flags == [.shift] {
                let step = MPVPlayer.panStep
                switch event.keyCode {
                case 6: // Shift+Z -> audio earlier
                    player.adjustDelay(of: .audio, by: -MPVPlayer.delayStep); osd.show(.delay(.audio)); return nil
                case 7: // Shift+X -> audio later
                    player.adjustDelay(of: .audio, by: MPVPlayer.delayStep); osd.show(.delay(.audio)); return nil
                case 123: player.pan(dx: -step, dy: 0); osd.show(.zoom); return nil   // Shift+← -> move picture left
                case 124: player.pan(dx: step, dy: 0); osd.show(.zoom); return nil    // Shift+→
                case 126: player.pan(dx: 0, dy: -step); osd.show(.zoom); return nil   // Shift+↑
                case 125: player.pan(dx: 0, dy: step); osd.show(.zoom); return nil    // Shift+↓
                default: break
                }
            }
            
            // CMD + G -> Trigger Gemini Explanation
            if flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "g" {
                player.pause()
                onExplainRequested?()
                return nil
            }
            
            // CMD + O -> Open File
            if flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "o" {
                onOpenFileRequested?()
                return nil
            }
            
            // CMD + , -> Open Settings
            if flags.contains(.command) && event.charactersIgnoringModifiers == "," {
                onOpenSettingsRequested?()
                return nil
            }
            
            // SPACE (keyCode 49) -> Dismiss popover and resume, OR Play/Pause
            if event.keyCode == 49 {
                if isExplanationOpen {
                    onDismissExplanationRequested?()
                    return nil
                }
                player.togglePlayPause()
                return nil
            }
            
            // R KEY (keyCode 15) -> Replay Subtitle Line (sub-seek 0)
            if event.keyCode == 15 {
                player.seekSubtitle(direction: 0)
                osd.show(.replayLine)
                return nil
            }
            
            // E KEY (keyCode 14) -> Jump to Next Subtitle Line (sub-seek 1)
            if event.keyCode == 14 {
                player.seekSubtitle(direction: 1)
                osd.show(.nextLine)
                return nil
            }
            
            // LEFT ARROW (keyCode 123) -> Seek -5s
            if event.keyCode == 123 {
                player.seekRelative(seconds: -5)
                osd.show(.seek(seconds: -5))
                return nil
            }
            
            // RIGHT ARROW (keyCode 124) -> Seek +5s
            if event.keyCode == 124 {
                player.seekRelative(seconds: 5)
                osd.show(.seek(seconds: 5))
                return nil
            }
            
            // UP ARROW (keyCode 126) -> Volume +5
            if event.keyCode == 126 {
                player.setVolume(player.volume + 5)
                osd.show(.volume)
                return nil
            }
            
            // DOWN ARROW (keyCode 125) -> Volume -5
            if event.keyCode == 125 {
                player.setVolume(player.volume - 5)
                osd.show(.volume)
                return nil
            }
            
            // F KEY (keyCode 3) -> Fullscreen
            if event.keyCode == 3 {
                player.toggleFullscreen()
                return nil
            }
            
        } else if event.type == .keyUp {
            // TAB KEY UP -> Hide translation peek
            if event.keyCode == 48 {
                player.setPeekingTranslation(false)
                return nil
            }
        }
        
        return event
    }
}

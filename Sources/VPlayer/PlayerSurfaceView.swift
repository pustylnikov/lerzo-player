import SwiftUI
import AppKit

public struct PlayerSurfaceView: NSViewRepresentable {
    public var onMouseMove: (() -> Void)? = nil
    
    public init(onMouseMove: (() -> Void)? = nil) {
        self.onMouseMove = onMouseMove
    }
    
    public func makeNSView(context: Context) -> DroppableNSView {
        let view = DroppableNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.onMouseMove = onMouseMove
        view.onFileDropped = { url in
            handleDroppedFile(url)
        }
        return view
    }
    
    public func updateNSView(_ nsView: DroppableNSView, context: Context) {
        nsView.onMouseMove = onMouseMove
    }
    
    private func handleDroppedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let subExtensions = ["srt", "ass", "ssa", "vtt", "sub"]
        if subExtensions.contains(ext) {
            MPVPlayer.shared.loadExternalSubtitle(fileURL: url)
        } else {
            MPVPlayer.shared.loadFile(url: url)
        }
    }
}

public class DroppableNSView: NSView {
    public var onFileDropped: ((URL) -> Void)?
    public var onMouseMove: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
    
    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMove?()
    }
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }
    
    public override func layout() {
        super.layout()
        MPVPlayer.shared.updateChildWindowFrame()
    }
    
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        MPVPlayer.shared.updateChildWindowFrame()
    }
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let win = self.window else { return }
        win.isOpaque = false
        win.backgroundColor = .clear
        win.styleMask.insert(.fullSizeContentView)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.collectionBehavior = [.fullScreenPrimary]
        // Layer-back the content view up front so the EDR flag that
        // MPVPlayer toggles for HDR playback has a layer to land on.
        win.contentView?.wantsLayer = true
        
        NotificationCenter.default.removeObserver(self)
        
        let notifs: [NSNotification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.willEnterFullScreenNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification
        ]
        
        for name in notifs {
            NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged), name: name, object: win)
        }
        // Fires when display settings change, e.g. HDR toggled in System Settings.
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        
        MPVPlayer.shared.attach(view: self)
    }
    
    @objc private func screenParametersChanged(_ notification: Notification) {
        MPVPlayer.shared.updateHDROutput()
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        if notification.name == NSWindow.didChangeScreenNotification {
            MPVPlayer.shared.updateHDROutput()
        }
        if notification.name == NSWindow.willExitFullScreenNotification {
            MPVPlayer.shared.prepareForFullscreenExit()
            return
        }

        if notification.name == NSWindow.didExitFullScreenNotification {
            MPVPlayer.shared.finishFullscreenTransition()
        }

        MPVPlayer.shared.updateChildWindowFrame()
        
        // AppKit and mpv can both change their window geometry during this animation.
        // Repeat the sync after the transition has settled so the video has no
        // title-bar-sized gap at the top of the fullscreen screen.
        if notification.name == NSWindow.didEnterFullScreenNotification || notification.name == NSWindow.didExitFullScreenNotification {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MPVPlayer.shared.updateChildWindowFrame()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MPVPlayer.shared.updateChildWindowFrame()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MPVPlayer.shared.updateChildWindowFrame()
            }
        }
    }
    
    public override func mouseUp(with event: NSEvent) {
        onMouseMove?()
        if event.clickCount == 2 {
            MPVPlayer.shared.toggleFullscreen()
        } else if event.clickCount == 1 {
            MPVPlayer.shared.togglePlayPause()
        }
    }
    
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }
    
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pasteboard = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let firstURL = pasteboard.first else {
            return false
        }
        onFileDropped?(firstURL)
        return true
    }
}

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
        win.collectionBehavior = [.fullScreenPrimary]
        
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
        
        MPVPlayer.shared.attach(view: self)
    }
    
    @objc private func windowGeometryChanged(_ notification: Notification) {
        MPVPlayer.shared.updateChildWindowFrame()
        
        // When entering or exiting fullscreen, macOS animates over 0.3s.
        // Schedule minor delayed frame syncs to guarantee lock at the end of the transition.
        if notification.name == NSWindow.didEnterFullScreenNotification || notification.name == NSWindow.didExitFullScreenNotification {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MPVPlayer.shared.updateChildWindowFrame()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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

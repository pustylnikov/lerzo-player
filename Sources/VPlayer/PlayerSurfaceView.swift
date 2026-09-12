import SwiftUI
import AppKit

public struct PlayerSurfaceView: NSViewRepresentable {
    public init() {}
    
    public func makeNSView(context: Context) -> DroppableNSView {
        let view = DroppableNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.onFileDropped = { url in
            handleDroppedFile(url)
        }
        return view
    }
    
    public func updateNSView(_ nsView: DroppableNSView, context: Context) {}
    
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
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let win = self.window else { return }
        win.isOpaque = false
        win.backgroundColor = .clear
        
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: win)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: win)
        
        MPVPlayer.shared.attach(view: self)
    }
    
    @objc private func windowDidResize() {
        MPVPlayer.shared.updateChildWindowFrame()
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

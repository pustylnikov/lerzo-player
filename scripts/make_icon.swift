// Builds Resources/AppIcon.icns from Resources/AppIcon.svg.
//
// The SVG is the brand master: a full-bleed 1024x1024 square. macOS icons live on
// Apple's grid instead — an 824 pt rounded square centred in a 1024 pt canvas with
// transparent margins for the system shadow — so the artwork is scaled into that
// rounded square here before rasterizing every size the iconset needs.
//
// Usage: swift scripts/make_icon.swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("Resources/AppIcon.svg")
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")

guard var source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
    fputs("cannot read \(sourceURL.path)\n", stderr)
    exit(1)
}
// Keep only the drawing: strip the XML prolog and the outer <svg> element.
source = source.replacingOccurrences(of: "<\\?xml[^>]*\\?>", with: "", options: .regularExpression)
source = source.replacingOccurrences(of: "<svg[^>]*>", with: "", options: .regularExpression)
source = source.replacingOccurrences(of: "</svg>", with: "")

let side = 824.0, inset = (1024.0 - side) / 2, radius = 185.4
let master = """
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
<defs><clipPath id="tile"><rect x="\(inset)" y="\(inset)" width="\(side)" height="\(side)" rx="\(radius)"/></clipPath></defs>
<g clip-path="url(#tile)"><g transform="translate(\(inset) \(inset)) scale(\(side / 1024))">\(source)</g></g>
</svg>
"""

guard let image = NSImage(data: master.data(using: .utf8)!) else {
    fputs("SVG could not be parsed\n", stderr)
    exit(1)
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(icnsURL.path)")

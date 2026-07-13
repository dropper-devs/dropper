// Generates Dropper.icns: the brand droplet (matching site/app/icon.svg) on a
// dark rounded square. Usage: swift tools/make_icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(outDir)/Dropper.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func drawIcon(size: Int, path: String) {
    let s = CGFloat(size)
    let u = s / 64  // the SVG's 64-box unit
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // Rounded-rect background with the macOS-style inset.
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.185, yRadius: s * 0.185)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.125, green: 0.132, blue: 0.168, alpha: 1),
        NSColor(calibratedRed: 0.070, green: 0.074, blue: 0.094, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    // The droplet — the same SF Symbol the menu bar item uses (drop.fill),
    // rendered as a mask and filled with the brand gradient.
    let symbol = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(
            pointSize: s * 0.5, weight: .regular))!
    var proposed = CGRect(origin: .zero, size: symbol.size)
    let mask = symbol.cgImage(forProposedRect: &proposed, context: nil, hints: nil)!

    // Aspect-fit the glyph into a centered box (~56% of the icon side).
    let boxHeight = s * 0.56
    let aspect = CGFloat(mask.width) / CGFloat(mask.height)
    let box = NSRect(x: (s - boxHeight * aspect) / 2,
                     y: (s - boxHeight) / 2,
                     width: boxHeight * aspect, height: boxHeight)

    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.clip(to: box, mask: mask)
    let colors = [
        NSColor(calibratedRed: 0.478, green: 0.408, blue: 0.905, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.545, green: 0.612, blue: 0.976, alpha: 1).cgColor, // #8b9cf9
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: s / 2, y: box.minY),
                           end: CGPoint(x: s / 2, y: box.maxY),
                           options: [])
    ctx.restoreGState()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(size)")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

for (size, name) in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
] {
    drawIcon(size: size, path: "\(iconset)/\(name).png")
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/Dropper.icns"]
task.launch()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print(task.terminationStatus == 0 ? "Wrote \(outDir)/Dropper.icns" : "iconutil failed")
exit(task.terminationStatus)

// Generates RE2Trainer.icns. Drawn in code so the repo carries no binary blob
// and the icon can be tweaked by editing values here.
import AppKit

func draw(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.06
    let body = NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset),
                            xRadius: size * 0.22, yRadius: size * 0.22)
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1),
               ending:   NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.03, alpha: 1))?
        .draw(in: body, angle: -90)

    // Red bar, echoing the game's title treatment.
    let bar = NSBezierPath(roundedRect: NSRect(x: size * 0.20, y: size * 0.30,
                                               width: size * 0.60, height: size * 0.055),
                           xRadius: size * 0.03, yRadius: size * 0.03)
    NSColor(calibratedRed: 0.78, green: 0.09, blue: 0.11, alpha: 1).setFill()
    bar.fill()

    let text = "RE2" as NSString
    let fs = size * 0.34
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fs, weight: .heavy),
        .foregroundColor: NSColor.white,
    ]
    let ts = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (size - ts.width) / 2, y: size * 0.40), withAttributes: attrs)
    img.unlockFocus()
    return img
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
                   (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),
                   (512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let img = draw(CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
print("wrote \(outDir)")

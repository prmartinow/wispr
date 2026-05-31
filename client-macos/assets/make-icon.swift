import AppKit

// Renders the Wispr app icon (1024×1024 master PNG): a violet-gradient squircle with a white
// soundwave glyph. Usage: swift make-icon.swift <out.png>
let S = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/wispr-icon-1024.png"

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let inset = 86.0
let rect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.34, blue: 0.95, alpha: 1),
    NSColor(srgbRed: 0.63, green: 0.29, blue: 0.92, alpha: 1),
])!
gradient.draw(in: squircle, angle: -60)

let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
if let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let glyph = NSImage(size: base.size)
    glyph.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: base.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    glyph.unlockFocus()
    glyph.draw(in: NSRect(x: (S - base.size.width) / 2, y: (S - base.size.height) / 2,
                          width: base.size.width, height: base.size.height))
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

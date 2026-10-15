// Immagine di anteprima per i social (1280×640), disegnata da codice come
// l'icona: si rigenera cambiando testo o colori, senza file grafici da
// mantenere. Uso: swift Tools/MakeSocialPreview.swift docs/images/social-preview.png
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "docs/images/social-preview.png"
let size = NSSize(width: 1280, height: 640)
let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Sfondo: grigio antracite con un leggero gradiente, come la finestra scura.
let colors = [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.23, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

// Icona a sinistra.
if let icon = NSImage(contentsOfFile: "Resources/icona-anteprima.png")
    ?? NSImage(contentsOfFile: "docs/images/icon.png") {
    icon.draw(in: NSRect(x: 90, y: 160, width: 320, height: 320))
}

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at point: NSPoint, width: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = 4
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
    string.draw(with: NSRect(x: point.x, y: point.y - bounds.height, width: width, height: bounds.height),
                options: [.usesLineFragmentOrigin])
}

let left: CGFloat = 470
let textWidth: CGFloat = 730
draw("Ammugghia", size: 84, weight: .bold, color: .white, at: NSPoint(x: left, y: 470), width: textWidth)
draw("Find the GBs hiding in “System Data”.", size: 38, weight: .semibold,
     color: NSColor(calibratedRed: 0.55, green: 0.80, blue: 1.0, alpha: 1),
     at: NSPoint(x: left, y: 355), width: textWidth)
draw("A native macOS disk cleaner for developers that refuses rather than guesses: Xcode, simulators, Android, package managers, AI models, app leftovers.",
     size: 24, weight: .regular, color: NSColor(white: 0.82, alpha: 1),
     at: NSPoint(x: left, y: 285), width: textWidth)
draw("Open source · MIT · signed & notarized · no network · macOS 14+",
     size: 19, weight: .medium, color: NSColor(white: 0.60, alpha: 1),
     at: NSPoint(x: left, y: 130), width: textWidth)

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { exit(1) }
// Dimensione esatta richiesta da GitHub, indipendente dalla risoluzione dello schermo.
rep.size = size
let exact = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: exact)
rep.draw(in: NSRect(x: 0, y: 0, width: 1280, height: 640))
NSGraphicsContext.restoreGraphicsState()
try! exact.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("✓ \(output)")

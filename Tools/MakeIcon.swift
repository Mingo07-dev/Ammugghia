// Genera l'icona dell'applicazione: un computer portatile con una scopa.
//
// Disegnata con CoreGraphics invece di importare un'immagine, così è
// riproducibile, resta nitida a ogni dimensione e non aggiunge file binari al
// repository. Uso:  swift Tools/MakeIcon.swift <cartella-iconset>
//
// Il disegno è definito in uno spazio 1024×1024 e riscalato per ogni misura
// richiesta dal formato .iconset.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Utilità di disegno

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, a])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: srgb,
               colors: stops.map(\.0) as CFArray,
               locations: stops.map(\.1))!
}

extension CGContext {
    func fillLinearGradient(path: CGPath, from: CGPoint, to: CGPoint, stops: [(CGColor, CGFloat)]) {
        saveGState()
        addPath(path)
        clip()
        drawLinearGradient(gradient(stops), start: from, end: to, options: [])
        restoreGState()
    }

    func fill(_ path: CGPath, _ c: CGColor) {
        saveGState()
        setFillColor(c)
        addPath(path)
        fillPath()
        restoreGState()
    }
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
}

/// Stella a quattro punte con i lati concavi: le scintille che suggeriscono
/// "pulito" senza aggiungere dettagli che sparirebbero a 16 pixel.
func sparkle(center: CGPoint, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let waist = r * 0.26
    p.move(to: CGPoint(x: center.x, y: center.y + r))
    p.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y),
                   control: CGPoint(x: center.x + waist, y: center.y + waist))
    p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r),
                   control: CGPoint(x: center.x + waist, y: center.y - waist))
    p.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y),
                   control: CGPoint(x: center.x - waist, y: center.y - waist))
    p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r),
                   control: CGPoint(x: center.x - waist, y: center.y + waist))
    p.closeSubpath()
    return p
}

// MARK: - Il disegno

func drawIcon(in ctx: CGContext) {

    // ── Sfondo: quadrato con angoli arrotondati in stile macOS.
    // Il contenuto occupa 824 punti su 1024, il resto è il margine che il
    // sistema si aspetta attorno all'icona.
    let plate = roundedRect(100, 90, 824, 824, 188)

    // Ombra molto contenuta e solo verso il basso: con valori più alti il
    // contorno sfumato diventa un anello scuro attorno all'icona.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10),
                  blur: 22, color: color(12, 28, 66, 0.20))
    ctx.fill(plate, color(40, 110, 235))
    ctx.restoreGState()

    ctx.fillLinearGradient(path: plate,
                           from: CGPoint(x: 0, y: 914), to: CGPoint(x: 0, y: 90),
                           stops: [(color(90, 168, 255), 0),
                                   (color(46, 116, 236), 0.55),
                                   (color(24, 74, 190), 1)])

    // Riflesso morbido in alto, per dare volume alla superficie.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawRadialGradient(gradient([(color(255, 255, 255, 0.30), 0),
                                     (color(255, 255, 255, 0), 1)]),
                           startCenter: CGPoint(x: 420, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 420, y: 900), endRadius: 560,
                           options: [])
    ctx.restoreGState()

    // ── Computer portatile.
    // Spostato a sinistra e in alto per lasciare spazio alla scopa.
    let screenOuter = roundedRect(206, 462, 430, 300, 26)
    let screenInner = roundedRect(230, 486, 382, 252, 14)
    let base = roundedRect(166, 404, 510, 48, 22)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10),
                  blur: 22, color: color(8, 20, 46, 0.42))

    // Scocca dello schermo.
    ctx.fillLinearGradient(path: screenOuter,
                           from: CGPoint(x: 0, y: 762), to: CGPoint(x: 0, y: 462),
                           stops: [(color(246, 248, 251), 0), (color(198, 206, 219), 1)])
    ctx.restoreGState()

    // Vetro dello schermo.
    ctx.fillLinearGradient(path: screenInner,
                           from: CGPoint(x: 230, y: 738), to: CGPoint(x: 612, y: 486),
                           stops: [(color(22, 40, 72), 0), (color(11, 22, 44), 1)])

    // Riflesso diagonale sul vetro.
    let glare = CGMutablePath()
    glare.move(to: CGPoint(x: 246, y: 738))
    glare.addLine(to: CGPoint(x: 400, y: 738))
    glare.addLine(to: CGPoint(x: 250, y: 486))
    glare.addLine(to: CGPoint(x: 230, y: 486))
    glare.closeSubpath()
    ctx.saveGState()
    ctx.addPath(screenInner)
    ctx.clip()
    ctx.fill(glare, color(255, 255, 255, 0.10))
    ctx.restoreGState()

    // Tre barre sullo schermo: alludono a una lista di elementi da pulire e
    // restano leggibili anche molto in piccolo.
    let barColors = [color(120, 210, 160), color(240, 190, 90), color(150, 170, 205, 0.75)]
    for (index, barColor) in barColors.enumerated() {
        let y = 646 - CGFloat(index) * 62
        let width: CGFloat = [250, 196, 148][index]
        ctx.fill(roundedRect(266, y, width, 30, 15), barColor)
    }

    // Base del portatile, con l'incavo per l'apertura.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8),
                  blur: 18, color: color(8, 20, 46, 0.38))
    ctx.fillLinearGradient(path: base,
                           from: CGPoint(x: 0, y: 452), to: CGPoint(x: 0, y: 404),
                           stops: [(color(232, 236, 243), 0), (color(176, 185, 201), 1)])
    ctx.restoreGState()
    ctx.fill(roundedRect(366, 436, 110, 10, 5), color(140, 150, 168, 0.85))

    // ── Scopa, inclinata e in primo piano sulla destra.
    ctx.saveGState()
    ctx.translateBy(x: 664, y: 286)
    ctx.rotate(by: -20 * .pi / 180)
    ctx.setShadow(offset: CGSize(width: -10, height: -12),
                  blur: 26, color: color(8, 20, 46, 0.45))

    // Manico.
    ctx.fillLinearGradient(path: roundedRect(-19, 150, 38, 372, 19),
                           from: CGPoint(x: -19, y: 0), to: CGPoint(x: 19, y: 0),
                           stops: [(color(214, 150, 86), 0),
                                   (color(178, 112, 56), 0.55),
                                   (color(140, 84, 40), 1)])

    // Setole: trapezio che si allarga verso il basso.
    let bristles = CGMutablePath()
    bristles.move(to: CGPoint(x: -74, y: 168))
    bristles.addLine(to: CGPoint(x: 74, y: 168))
    bristles.addLine(to: CGPoint(x: 112, y: 8))
    bristles.addQuadCurve(to: CGPoint(x: 96, y: -6), control: CGPoint(x: 108, y: -6))
    bristles.addLine(to: CGPoint(x: -96, y: -6))
    bristles.addQuadCurve(to: CGPoint(x: -112, y: 8), control: CGPoint(x: -108, y: -6))
    bristles.closeSubpath()
    ctx.fillLinearGradient(path: bristles,
                           from: CGPoint(x: 0, y: 168), to: CGPoint(x: 0, y: -6),
                           stops: [(color(240, 196, 108), 0), (color(206, 150, 66), 1)])

    // Solchi verticali fra le setole.
    ctx.saveGState()
    ctx.addPath(bristles)
    ctx.clip()
    for offset in stride(from: -80.0, through: 80.0, by: 32.0) {
        let groove = CGMutablePath()
        groove.move(to: CGPoint(x: CGFloat(offset), y: 160))
        groove.addLine(to: CGPoint(x: CGFloat(offset) * 1.42, y: -6))
        ctx.addPath(groove)
    }
    ctx.setStrokeColor(color(150, 100, 40, 0.42))
    ctx.setLineWidth(9)
    ctx.strokePath()
    ctx.restoreGState()

    // Fascetta metallica che unisce manico e setole.
    ctx.fillLinearGradient(path: roundedRect(-60, 150, 120, 56, 16),
                           from: CGPoint(x: 0, y: 206), to: CGPoint(x: 0, y: 150),
                           stops: [(color(238, 242, 248), 0), (color(168, 180, 198), 1)])
    ctx.restoreGState()

    // ── Scintille: l'effetto "pulito", accanto alle setole.
    ctx.fill(sparkle(center: CGPoint(x: 322, y: 296), radius: 46), color(255, 255, 255, 0.96))
    ctx.fill(sparkle(center: CGPoint(x: 414, y: 214), radius: 28), color(255, 255, 255, 0.82))
    ctx.fill(sparkle(center: CGPoint(x: 250, y: 208), radius: 20), color(255, 255, 255, 0.62))

    // Bordo interno chiaro: rifinitura tipica delle icone di sistema.
    ctx.saveGState()
    ctx.addPath(roundedRect(103, 93, 818, 818, 186))
    ctx.setStrokeColor(color(255, 255, 255, 0.24))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Scrittura dei file

func render(size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(in: ctx)
    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "MakeIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "impossibile creare \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "MakeIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "scrittura non riuscita: \(url.path)"])
    }
}

// Misure richieste dal formato .iconset di macOS.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("Uso: swift MakeIcon.swift <cartella-iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outputDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for variant in variants {
    guard let image = render(size: variant.size) else {
        FileHandle.standardError.write("render non riuscito a \(variant.size)px\n".data(using: .utf8)!)
        exit(1)
    }
    try write(image, to: outputDir.appendingPathComponent("\(variant.name).png"))
}

// Copia grande separata, comoda per l'anteprima e per il README.
if let preview = render(size: 1024) {
    try write(preview, to: outputDir.deletingLastPathComponent().appendingPathComponent("icona-anteprima.png"))
}

print("✓ \(variants.count) immagini generate in \(outputDir.path)")

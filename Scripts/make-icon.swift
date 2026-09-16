import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

let source = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/AppIcon.svg"
guard let image = NSImage(contentsOfFile: source) else {
    fputs("Could not load icon source: \(source)\n", stderr)
    exit(1)
}

let iconset = NSTemporaryDirectory() + UUID().uuidString + ".iconset"
defer { try? FileManager.default.removeItem(atPath: iconset) }
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func writePNG(_ size: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: iconset + "/" + name))
}

writePNG(16, "icon_16x16.png")
writePNG(32, "icon_16x16@2x.png")
writePNG(32, "icon_32x32.png")
writePNG(64, "icon_32x32@2x.png")
writePNG(128, "icon_128x128.png")
writePNG(256, "icon_128x128@2x.png")
writePNG(256, "icon_256x256.png")
writePNG(512, "icon_256x256@2x.png")
writePNG(512, "icon_512x512.png")
writePNG(1024, "icon_512x512@2x.png")
try? FileManager.default.removeItem(atPath: output + ".png")
try! FileManager.default.copyItem(atPath: iconset + "/icon_512x512@2x.png", toPath: output + ".png")
let preview = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png")
try! Data(contentsOf: URL(fileURLWithPath: iconset + "/icon_512x512@2x.png")).write(to: preview)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset, "-o", output]
try! process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("Wrote \(output)")

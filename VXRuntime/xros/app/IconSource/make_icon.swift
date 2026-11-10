// Makes the visionOS app icon (a solid image stack: Back, Middle, Front, 1024x1024 each) from a picture the user supplied, at build time.
// usage: swift make_icon.swift <input image> <output dir>   -> <output dir>/Assets.xcassets/AppIcon.solidimagestack/...
// The picture (skyrim-icon.jpeg, README.md) is user-supplied art, committed with the user's approval; the generated catalog (../Icon) is
// committed too, so the build does not run this. Front is the picture with its black background turned into transparency (alpha = brightest channel, colour
// divided by alpha), so Front over the plain black Back reproduces the picture exactly; Middle is empty. The system masks the stack to a circle.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { FileHandle.standardError.write(Data("make_icon: cannot read \(args.count > 1 ? args[1] : "?")\n".utf8)); exit(2) }

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func context() -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func write(_ ctx: CGContext, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let img = ctx.makeImage(), let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(3) }
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { exit(3) }
}

// Front: the picture scaled to 1024 (high-quality interpolation, centred square crop), then black keyed out.
let front = context()
front.interpolationQuality = .high
front.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
front.fill(CGRect(x: 0, y: 0, width: size, height: size))
let side = min(image.width, image.height)
let crop = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)) ?? image
front.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
let px = front.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
for i in 0..<(size * size) {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])   // opaque here, so not premultiplied yet
    let a = max(r, g, b)
    // premultiplied storage: colour stays as is, alpha = brightest channel (so colour/alpha is the unpremultiplied colour, at most 1)
    px[i * 4 + 3] = UInt8(a)
}

let back = context()
back.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
back.fill(CGRect(x: 0, y: 0, width: size, height: size))
let middle = context()

let stack = URL(fileURLWithPath: args[2]).appendingPathComponent("Assets.xcassets/AppIcon.solidimagestack")
let info = "\"info\" : { \"author\" : \"xcode\", \"version\" : 1 }"
func put(_ name: String, _ ctx: CGContext) {
    let layer = stack.appendingPathComponent("\(name).solidimagestacklayer")
    write(ctx, layer.appendingPathComponent("Content.imageset/\(name).png"))
    try? "{ \(info) }\n".write(to: layer.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    try? "{ \"images\" : [ { \"filename\" : \"\(name).png\", \"idiom\" : \"vision\", \"scale\" : \"2x\" } ], \(info) }\n"
        .write(to: layer.appendingPathComponent("Content.imageset/Contents.json"), atomically: true, encoding: .utf8)
}
put("Front", front); put("Middle", middle); put("Back", back)
try? "{ \"layers\" : [ { \"filename\" : \"Front.solidimagestacklayer\" }, { \"filename\" : \"Middle.solidimagestacklayer\" }, { \"filename\" : \"Back.solidimagestacklayer\" } ], \(info) }\n"
    .write(to: stack.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try? "{ \(info) }\n".write(to: stack.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("make_icon: \(args[2])/Assets.xcassets/AppIcon.solidimagestack from \(args[1])")

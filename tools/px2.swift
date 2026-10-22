import Foundation
import CoreGraphics
import ImageIO
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let src = CGImageSourceCreateWithURL(url, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("open FAIL"); exit(1) }
let w = img.width, h = img.height
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w*h*4)
func c(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i=(y*w+x)*4; return (Int(px[i]), Int(px[i+1]), Int(px[i+2])) }
print("size \(w)x\(h)")
for y in stride(from: 0, to: h, by: 128) {
    var s = ""
    for x in stride(from: 0, to: w, by: 92) { let p = c(x,y); s += "(\(p.0),\(p.1),\(p.2))" }
    print("y=\(y): \(s)")
}

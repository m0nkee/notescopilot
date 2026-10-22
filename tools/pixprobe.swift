import Foundation
import CoreGraphics
import ImageIO

let url = URL(fileURLWithPath: "preview-settings.png") as CFURL
guard let src = CGImageSourceCreateWithURL(url, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }
let w = img.width, h = img.height
let space = CGColorSpaceCreateDeviceRGB
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let data = ctx.data else { exit(1) }
let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
func colorAt(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let i = (y * w + x) * 4
    return (px[i], px[i+1], px[i+2])
}
// 区域平均色
func regionAvg(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> (Double, Double, Double) {
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for y in stride(from: y0, to: y1, by: 8) {
        for x in stride(from: x0, to: x1, by: 8) {
            let c = colorAt(x, y); r += Double(c.r); g += Double(c.g); b += Double(c.b); n += 1
        }
    }
    return (r/n, g/n, b/n)
}
let sAvg = regionAvg(10, 170, 100, h-100)
print("size \(w)x\(h)")
print(String(format: "sidebar avg  = %.0f %.0f %.0f", sAvg.0, sAvg.1, sAvg.2))
let cAvg = regionAvg(300, w-100, 200, h-200)
print(String(format: "content avg  = %.0f %.0f %.0f", cAvg.0, cAvg.1, cAvg.2))
// 找显著彩色像素（非灰阶）：accent 图标/绿色标记
var colored = 0
var greenish = 0
for y in stride(from: 0, to: h, by: 4) {
    for x in stride(from: 0, to: w, by: 4) {
        let c = colorAt(x, y)
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        if Int(mx) - Int(mn) > 60 { colored += 1 }
        if c.g > 120 && c.g > Int(c.r) + 40 && c.g > Int(c.b) + 40 { greenish += 1 }
    }
}
print("colored px (accent) = \(colored)")
print("green px (生效标记) = \(greenish)")
// 顶部标题区是否深色粗体文本（黑白对比行数）
var darkRows = 0
for y in stride(from: 40, to: 200, by: 4) {
    var dark = 0
    for x in stride(from: 360, to: w-40, by: 6) {
        let c = colorAt(x, y)
        if c.r < 100 && c.g < 100 && c.b < 100 { dark += 1 }
    }
    if dark > 3 { darkRows += 1 }
}
print("header dark-text rows = \(darkRows)")

import Foundation
import AppKit
let now = Date(timeIntervalSince1970: 1_750_000_000)
let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "zh_CN")
print("date:", df.string(from: now))
let tz = TimeZone.current
print("tz:", tz.identifier, "offset:", tz.secondsFromGMT(for: now))

let p = TemplateEngine.plan("A {{ask:问题一}} B {{ai:指令一}} C {{ask:问题二}} D {{date}}", selection: "", clipboard: "", now: now)
print("asks:", p.asks)
print("ais:", p.ais)
print("text:", p.text.replacingOccurrences(of: "\u{E000}", with: "[[").replacingOccurrences(of: "\u{E001}", with: "]]"))

let p2 = TemplateEngine.plan("引用：{{selection}} + {{clipboard}}", selection: "选A", clipboard: "剪B", now: now)
print("p2:", p2.text)

let full = TemplateEngine.render(p, answers: [0: "张三", 2: "李四"], ais: [1: "AI结果"])
print("full:", full)

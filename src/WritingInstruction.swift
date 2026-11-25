import Foundation
import NaturalLanguage

enum WritingInstruction: Equatable, ExpressibleByStringLiteral {
    case text(String)
    case translate

    static let translationHint = "中文译成英文，其他语言译成中文"

    init(stringLiteral value: String) { self = .text(value) }

    func prompt(for source: String) -> String {
        switch self {
        case .text(let text):
            return text
        case .translate:
            return Self.translationDirection(for: source) + "保留原意、语气和段落格式，只输出译文。"
        }
    }

    private static func translationDirection(for source: String) -> String {
        let automatic = "请根据整句话的语法判断原文的主要语言。以中文（含简体和繁体）为主时，将整段翻译成英文。以其他语言为主时，将整段翻译成简体中文。保留专有名词。"
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(source)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return automatic }
        let chinese = language == .simplifiedChinese || language == .traditionalChinese

        if source.unicodeScalars.contains(where: { $0.properties.isIdeographic }),
           source.range(of: #"\p{Latin}"#, options: .regularExpression) != nil {
            let probabilities = recognizer.languageHypotheses(withMaximum: 5)
            let confidence = chinese ? (probabilities[.simplifiedChinese] ?? 0) + (probabilities[.traditionalChinese] ?? 0)
                                     : (probabilities[language] ?? 0)
            if confidence < 0.75 { return automatic }
            // Capitalized product names alone can make a Chinese sentence look English.
            if language == .english && source.range(of: #"(?<!\p{Latin})[a-z]"#, options: .regularExpression) == nil {
                return automatic
            }
        }
        return chinese ? "请将原文翻译成英文。" : "请将原文翻译成简体中文。"
    }
}

import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L10n.text("Follow System")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "zh": return .simplifiedChinese
            case "en": return .english
            default: continue
            }
        }
        return .english
    }
}

final class L10n: ObservableObject, @unchecked Sendable {
    static let preferenceKey = "nc.interface.language"
    static let didChange = Notification.Name("nc.interface.languageDidChange")
    static let shared = L10n(defaults: .standard)
    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.compactMap { language in
            guard language != .system,
                  let url = Bundle.main.resourceURL?.appendingPathComponent("\(language.rawValue).lproj"),
                  let bundle = Bundle(url: url) else { return nil }
            return (language, bundle)
        }
    )

    private let defaults: UserDefaults
    @Published private(set) var language: AppLanguage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        language = Self.preference(in: defaults)
    }

    @MainActor
    func select(_ language: AppLanguage) {
        guard self.language != language else { return }
        defaults.set(language.rawValue, forKey: Self.preferenceKey)
        self.language = language
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    var locale: Locale { Locale(identifier: resolvedLanguage.rawValue) }

    // Background services can translate messages using the thread-safe defaults store.
    // SwiftUI observes the main-thread publisher to refresh existing views.
    private var resolvedLanguage: AppLanguage { Self.preference(in: defaults).resolved() }

    private static func preference(in defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func text(_ key: String) -> String {
        text(key, language: shared.resolvedLanguage)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let language = shared.resolvedLanguage
        return String(format: text(key, language: language),
                      locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    private static func text(_ key: String, language: AppLanguage) -> String {
        bundles[language]?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

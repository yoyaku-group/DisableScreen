import Foundation

/// Localization for the menu-bar UI.
///
/// English strings are the KEYS: a miss (no lproj, or a language we don't
/// ship) falls back to the English literal, which is exactly the product
/// default (CFBundleDevelopmentRegion = en). French ships as a translation
/// in `fr.lproj/Localizable.strings`, copied into the bundle by
/// `scripts/build-runclosed-app.sh`.
///
/// Why not SwiftPM resources: the app is assembled as a plain .app bundle by
/// the build script (SMAppService/signing requirements), so the lproj files
/// travel with the bundle like any native macOS app. A bare `swift test` run
/// simply resolves to the English keys.
enum L10n {
    /// Translate an English base string. `key` doubles as the fallback.
    static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// `Display %d` style: translate the pattern, then substitute N arguments.
    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}

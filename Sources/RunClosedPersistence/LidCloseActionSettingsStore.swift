import Foundation
import RunClosedCore

/// On-disk operator settings for the lid-close actions (ADR 026).
///
/// Lives in `UserDefaults`, under the same suite as the two kill switches
/// (`com.benjaminbelaga.RunClosed`), for the same reasons: the menu bar, the
/// CLI and the ADR 024 backstop all have to read the SAME answer, and an
/// operator must be able to change it without a rebuild.
///
/// `enabled` defaults to FALSE. There is no `defaults write` shortcut needed to
/// turn the feature off — it starts off.
public enum LidCloseActionSettingsStore {
    public static let suiteName = "com.benjaminbelaga.RunClosed"
    public static let key = "lidCloseActions"

    /// Resolve the defaults domain.
    ///
    /// Inside the bundle (app AND embedded `runclosed-cli`) the main bundle id
    /// IS the suite: `UserDefaults(suiteName: <own id>)` is rejected by
    /// Foundation ("does not make sense and will not work", measured on the
    /// built bundle), so the standard domain is the same plist. Same resolution
    /// as `LowBatteryGuardSettings` / `ThermalGuardSettings`.
    public static func domain() -> UserDefaults? {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName)
    }

    /// Read the settings. Absent / unreadable → the compiled-in defaults, which
    /// are "off".
    public static func load(from defaults: UserDefaults? = LidCloseActionSettingsStore.domain())
        -> LidCloseActionSettings {
        guard let data = defaults?.data(forKey: key),
              let settings = try? JSONDecoder().decode(LidCloseActionSettings.self, from: data)
        else { return LidCloseActionSettings() }
        return settings
    }

    /// Persist the settings. Returns whether the write landed, so the caller can
    /// tell the operator "it did not stick" instead of showing a switch that
    /// will read back the old value.
    @discardableResult
    public static func save(_ settings: LidCloseActionSettings,
                            to defaults: UserDefaults? = LidCloseActionSettingsStore.domain()) -> Bool {
        guard let defaults else { return false }
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}

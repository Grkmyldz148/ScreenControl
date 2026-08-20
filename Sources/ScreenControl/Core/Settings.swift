import Foundation
import ServiceManagement

/// UserDefaults üstünde tip güvenli ayar deposu.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let syncEnabled = "syncEnabled"
        static let interceptKeys = "interceptBrightnessKeys"
        static let showHUD = "showHUD"
        static let showPercentage = "showPercentageInMenuBar"
        static let fineStepModifier = "useFineStepWithShiftOption"
        static let curves = "brightnessCurves"
        static let restoreOnWake = "restoreBrightnessOnWake"
        static let softwareDimming = "softwareDimmingEnabled"
        static let backlightOffAtZero = "backlightOffAtZero"
        static let trace = "traceEnabled"
        static let lastBrightness = "lastBrightness"
    }

    private init() {
        defaults.register(defaults: [
            Key.syncEnabled: true,
            Key.interceptKeys: true,
            Key.showHUD: true,
            Key.showPercentage: false,
            Key.fineStepModifier: true,
            Key.restoreOnWake: true,
            Key.softwareDimming: true,
            Key.backlightOffAtZero: true,
        ])
    }

    var syncEnabled: Bool {
        get { defaults.bool(forKey: Key.syncEnabled) }
        set { defaults.set(newValue, forKey: Key.syncEnabled) }
    }

    var interceptBrightnessKeys: Bool {
        get { defaults.bool(forKey: Key.interceptKeys) }
        set { defaults.set(newValue, forKey: Key.interceptKeys) }
    }

    var showHUD: Bool {
        get { defaults.bool(forKey: Key.showHUD) }
        set { defaults.set(newValue, forKey: Key.showHUD) }
    }

    var showPercentageInMenuBar: Bool {
        get { defaults.bool(forKey: Key.showPercentage) }
        set { defaults.set(newValue, forKey: Key.showPercentage) }
    }

    /// Sürgünün alt ucunda DDC bitince gamma ile karartmaya devam et.
    var softwareDimmingEnabled: Bool {
        get { defaults.bool(forKey: Key.softwareDimming) }
        set { defaults.set(newValue, forKey: Key.softwareDimming) }
    }

    /// Sürgü tam sıfıra inince monitörün arka ışığını DDC ile söndür.
    /// Gamma karartması görüntüyü siyaha indirir ama panel yanmaya devam eder;
    /// gerçek siyah ancak arka ışık kapanınca olur.
    var backlightOffAtZero: Bool {
        get { defaults.bool(forKey: Key.backlightOffAtZero) }
        set { defaults.set(newValue, forKey: Key.backlightOffAtZero) }
    }

    /// `defaults write app.pushbrands.screencontrol traceEnabled -bool true`
    var traceEnabled: Bool { defaults.bool(forKey: Key.trace) }

    var restoreOnWake: Bool {
        get { defaults.bool(forKey: Key.restoreOnWake) }
        set { defaults.set(newValue, forKey: Key.restoreOnWake) }
    }

    // MARK: - Ekran başına kalibrasyon eğrisi

    func curve(for displayKey: String) -> BrightnessCurve {
        guard
            let blob = defaults.dictionary(forKey: Key.curves)?[displayKey],
            let data = blob as? Data,
            let curve = try? JSONDecoder().decode(BrightnessCurve.self, from: data)
        else { return .identity }
        return curve
    }

    func setCurve(_ curve: BrightnessCurve, for displayKey: String) {
        var all = defaults.dictionary(forKey: Key.curves) ?? [:]
        all[displayKey] = try? JSONEncoder().encode(curve)
        defaults.set(all, forKey: Key.curves)
    }

    // MARK: - Uyandıktan / yeniden bağlandıktan sonra geri yükleme

    func lastBrightness(for displayKey: String) -> Double? {
        (defaults.dictionary(forKey: Key.lastBrightness)?[displayKey] as? NSNumber)?.doubleValue
    }

    func setLastBrightness(_ value: Double, for displayKey: String) {
        var all = defaults.dictionary(forKey: Key.lastBrightness) ?? [:]
        all[displayKey] = NSNumber(value: value)
        defaults.set(all, forKey: Key.lastBrightness)
    }

    // MARK: - Girişte başlat

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("ScreenControl: could not change launch at login: \(error)")
            }
        }
    }
}

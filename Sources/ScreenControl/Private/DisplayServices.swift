import Foundation
import CoreGraphics

// MARK: - DisplayServices (private framework)
//
// Dahili (built-in) ekranın parlaklığını okuyup yazmak için.
// Public API (NSScreen) parlaklık yazmayı desteklemiyor; IOKit'in eski
// "brightness" property'si de Apple Silicon'da çalışmıyor.
// dlopen ile bağlanıyoruz ki framework bir gün kaybolursa app çökmesin.

enum DisplayServices {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let getFn: GetFn? = sym("DisplayServicesGetBrightness", GetFn.self)
    private static let setFn: SetFn? = sym("DisplayServicesSetBrightness", SetFn.self)
    private static let canFn: CanFn? = sym("DisplayServicesCanChangeBrightness", CanFn.self)
    private static let changedFn: ChangedFn? = sym("DisplayServicesBrightnessChanged", ChangedFn.self)

    static var isAvailable: Bool { getFn != nil && setFn != nil }

    /// 0.0 ... 1.0 aralığında parlaklık. Desteklenmiyorsa nil.
    static func brightness(of id: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(id, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    static func setBrightness(_ value: Float, of id: CGDirectDisplayID) -> Bool {
        guard let setFn else { return false }
        let clamped = min(max(value, 0), 1)
        guard setFn(id, clamped) == 0 else { return false }
        // Sistemin kendi state'ini (ve Ayarlar'daki slider'ı) senkron tutar.
        changedFn?(id, Double(clamped))
        return true
    }

    static func canChangeBrightness(of id: CGDirectDisplayID) -> Bool {
        canFn?(id) ?? (brightness(of: id) != nil)
    }
}

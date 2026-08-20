import Foundation
import AppKit
import CoreGraphics

/// `ScreenControl --diagnose` ile çalışır: ne bulundu, ne çalışıyor, ne eksik.
/// Bir monitör beklendiği gibi davranmadığında ilk bakılacak yer burası.
enum Diagnostics {

    @MainActor
    static func run() {
        print("ScreenControl diagnostics")
        print(String(repeating: "─", count: 52))

        print("\nSystem")
        print("  macOS          : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("  Architecture   : \(machineArchitecture())")
        print("  DisplayServices: \(DisplayServices.isAvailable ? "available" : "MISSING")")
        print("  Accessibility  : \(MediaKeyTap.hasAccessibilityPermission ? "granted" : "NOT GRANTED")")

        print("\nDisplays")
        let displays = DisplayRegistry.discover()
        if displays.isEmpty { print("  (no displays found)") }

        for display in displays {
            print("\n  ▸ \(display.name)")
            print("    type          : \(display.isBuiltin ? "built-in" : "external")")
            print("    CGDisplayID   : \(display.id)")
            print("    persistent key: \(display.persistentKey)")

            if display.isBuiltin {
                let value = DisplayServices.brightness(of: display.id)
                print("    brightness    : \(value.map { String(format: "%.0f%%", $0 * 100) } ?? "unreadable")")
                print("    writable      : \(DisplayServices.canChangeBrightness(of: display.id) ? "yes" : "no")")
            } else if let ddc = display.ddc {
                print("    DDC/CI        : working")
                for code in [VCPCode.brightness, .contrast, .volume, .powerMode] {
                    if let (current, maxValue) = ddc.read(code, retries: 2) {
                        let note = code == .powerMode
                            ? "  (1=on, 4=backlight off)"
                            : ""
                        print(String(format: "    VCP 0x%02X      : %d / %d%@", code.rawValue, current, maxValue, note))
                    } else {
                        print(String(format: "    VCP 0x%02X      : not supported", code.rawValue))
                    }
                }
                // Kendi işlem içi durumumuz değil, ekrana gerçekten uygulanmış
                // tabloyu okuyoruz — tanılama ayrı bir işlem olarak çalışıyor.
                let dim = appliedGammaPeak(display.id)
                print("    gamma dimming : \(dim < 0.999 ? String(format: "%.0f%% (active)", dim * 100) : "none")")
                let curve = Settings.shared.curve(for: display.persistentKey)
                print("    mapping       : \(curve.isIdentity ? "linear" : "\(curve.anchors.count)-point calibration")")
            } else {
                print("    DDC/CI        : NO RESPONSE")
                print("                    (virtual displays such as DisplayLink or Sidecar, and")
                print("                     some USB-C hubs, do not carry the I2C channel)")
            }
        }

        print("\nSettings")
        print("  link displays      : \(Settings.shared.syncEnabled)")
        print("  intercept keys     : \(Settings.shared.interceptBrightnessKeys)")
        print("  dim below zero     : \(Settings.shared.softwareDimmingEnabled)")
        print("  backlight at zero  : \(Settings.shared.backlightOffAtZero ? "off" : "stays on")")
        print("  on-screen HUD      : \(Settings.shared.showHUD)")
        print("  launch at login    : \(Settings.shared.launchAtLogin)")
        print("")
    }

    /// Ekrana o an uygulanmış gamma eğrisinin tepe değeri. 1.0 = karartma yok.
    private static func appliedGammaPeak(_ id: CGDirectDisplayID) -> Double {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return 1 }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &sampleCount) == .success,
              sampleCount > 0 else { return 1 }
        return Double(red[Int(sampleCount) - 1])
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}

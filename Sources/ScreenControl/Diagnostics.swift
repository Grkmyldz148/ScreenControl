import Foundation
import AppKit
import CoreGraphics

/// `ScreenControl --diagnose` ile çalışır: ne bulundu, ne çalışıyor, ne eksik.
/// Bir monitör beklendiği gibi davranmadığında ilk bakılacak yer burası.
enum Diagnostics {

    @MainActor
    static func run() {
        print("ScreenControl tanılama")
        print(String(repeating: "─", count: 52))

        print("\nSistem")
        print("  macOS       : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("  Mimari      : \(machineArchitecture())")
        print("  DisplayServices: \(DisplayServices.isAvailable ? "var" : "YOK")")
        print("  Erişilebilirlik izni: \(MediaKeyTap.hasAccessibilityPermission ? "verildi" : "VERİLMEDİ")")

        print("\nEkranlar")
        let displays = DisplayRegistry.discover()
        if displays.isEmpty { print("  (hiç ekran bulunamadı)") }

        for display in displays {
            print("\n  ▸ \(display.name)")
            print("    tip          : \(display.isBuiltin ? "dahili" : "harici")")
            print("    CGDisplayID  : \(display.id)")
            print("    kalıcı anahtar: \(display.persistentKey)")

            if display.isBuiltin {
                let value = DisplayServices.brightness(of: display.id)
                print("    parlaklık    : \(value.map { String(format: "%.0f%%", $0 * 100) } ?? "okunamadı")")
                print("    yazılabilir  : \(DisplayServices.canChangeBrightness(of: display.id) ? "evet" : "hayır")")
            } else if let ddc = display.ddc {
                print("    DDC/CI       : çalışıyor")
                for code in [VCPCode.brightness, .contrast, .volume, .powerMode] {
                    if let (current, maxValue) = ddc.read(code, retries: 2) {
                        let note = code == .powerMode
                            ? "  (1=açık, 4=arka ışık kapalı)"
                            : ""
                        print(String(format: "    VCP 0x%02X     : %d / %d%@", code.rawValue, current, maxValue, note))
                    } else {
                        print(String(format: "    VCP 0x%02X     : desteklenmiyor", code.rawValue))
                    }
                }
                // Kendi işlem içi durumumuz değil, ekrana gerçekten uygulanmış
                // tabloyu okuyoruz — tanılama ayrı bir işlem olarak çalışıyor.
                let dim = appliedGammaPeak(display.id)
                print("    gamma karartma: \(dim < 0.999 ? String(format: "%.0f%% (aktif)", dim * 100) : "yok")")
                let curve = Settings.shared.curve(for: display.persistentKey)
                print("    eşleme       : \(curve.isIdentity ? "doğrusal" : "\(curve.anchors.count) noktalı kalibrasyon")")
            } else {
                print("    DDC/CI       : CEVAP YOK")
                print("                   (DisplayLink/Sidecar gibi sanal ekranlar ve bazı")
                print("                    USB-C hub'lar I2C kanalını geçirmez)")
            }
        }

        print("\nAyarlar")
        print("  ekranları eşitle    : \(Settings.shared.syncEnabled)")
        print("  tuşları yakala      : \(Settings.shared.interceptBrightnessKeys)")
        print("  sıfır altı karartma : \(Settings.shared.softwareDimmingEnabled)")
        print("  sıfırda arka ışık   : \(Settings.shared.backlightOffAtZero ? "söndür" : "açık kalsın")")
        print("  ekran göstergesi    : \(Settings.shared.showHUD)")
        print("  girişte başlat      : \(Settings.shared.launchAtLogin)")
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

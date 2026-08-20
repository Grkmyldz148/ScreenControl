import Foundation
import IOKit
import CoreGraphics
import AppKit

/// Sistemdeki tek bir ekran.
final class ManagedDisplay {
    let id: CGDirectDisplayID
    /// Yeniden bağlanmalarda ayarları eşleştirmek için kalıcı kimlik.
    let persistentKey: String
    let name: String
    let isBuiltin: Bool

    /// Harici monitörse ve DDC'ye cevap veriyorsa dolu.
    let ddc: DDCLink?
    /// Monitörün bildirdiği maksimum parlaklık değeri (genelde 100).
    private(set) var ddcMaxBrightness: UInt16 = 100

    /// Son bilinen parlaklık, 0.0 ... 1.0 normalize.
    private(set) var brightness: Double = 0.5

    var supportsBrightness: Bool { isBuiltin ? DisplayServices.canChangeBrightness(of: id) : ddc != nil }

    /// Sürgünün en altındaki bu oran DDC'ye değil, gamma karartmasına ayrılır.
    /// DDC parlaklık 0 arka ışığı söndürmediği için tek siyaha inme yolu bu.
    static let softwareDimSpan = 0.25

    /// Dahili panelde gerek yok (0 = arka ışık kapalı), kapalıysa da 0.
    private var dimSpan: Double {
        guard !isBuiltin, ddc != nil, Settings.shared.softwareDimmingEnabled else { return 0 }
        return Self.softwareDimSpan
    }

    /// 1.0 = gamma karartması yok.
    var softwareDimFactor: Double {
        isBuiltin ? 1 : SoftwareDimmer.shared.factor(for: id)
    }

    private(set) var isBacklightOff = false

    private var canBlackout: Bool {
        !isBuiltin && ddc != nil && Settings.shared.backlightOffAtZero
    }

    /// VCP 0xD6 ile arka ışığı söndürür/yakar.
    ///
    /// Yalnızca değer **4** (DPMS Off) kullanılıyor: monitörün ana kartı açık
    /// kalır, bu yüzden DDC'ye cevap vermeye ve USB-C üzerinden Mac'i şarj
    /// etmeye devam eder — ölçtük, 20V/4.5A hiç düşmüyor. Değer **5** (hard off)
    /// güç hatlarını gerçekten keser ve geri açmak için fiziksel düğme
    /// gerektirebilir; asla kullanmıyoruz.
    func setBacklight(on: Bool) {
        guard let ddc else { return }
        let wantOff = !on
        guard wantOff != isBacklightOff else { return }
        isBacklightOff = wantOff
        DispatchQueue.global(qos: .userInitiated).async {
            ddc.write(.powerMode, value: on ? 1 : 4)
        }
    }

    /// Önceki oturum çökerek monitörü kapalı bırakmış olabilir; durum takibine
    /// bakmadan koşulsuz açar.
    func forceBacklightOn() {
        guard let ddc else { return }
        isBacklightOff = false
        DispatchQueue.global(qos: .userInitiated).async { ddc.write(.powerMode, value: 1) }
    }

    /// Uygulama kapanırken kullanılır: asenkron yazma süreç ölmeden önce
    /// hatta çıkmayabilir, o yüzden burada bekliyoruz.
    func forceBacklightOnBlocking() {
        guard let ddc else { return }
        isBacklightOff = false
        ddc.write(.powerMode, value: 1)
    }

    init(id: CGDirectDisplayID, name: String, isBuiltin: Bool, persistentKey: String, ddc: DDCLink?) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.persistentKey = persistentKey
        self.ddc = ddc
    }

    // MARK: - Parlaklık

    /// Donanımdan gerçek değeri okur ve cache'ler. Blocking.
    @discardableResult
    func refreshBrightness() -> Double? {
        if isBuiltin {
            guard let value = DisplayServices.brightness(of: id) else { return nil }
            brightness = Double(value)
            return brightness
        }
        guard let ddc, let (current, maxValue) = ddc.read(.brightness) else { return nil }
        ddcMaxBrightness = maxValue

        // Donanım değerini, o an uygulanan gamma karartmasıyla birleştirip
        // sürgünün gösterdiği tek sayıya geri çeviriyoruz.
        let hardware = Double(current) / Double(maxValue)
        let span = dimSpan
        let software = SoftwareDimmer.shared.factor(for: id)
        brightness = (span > 0 && software < 0.999)
            ? software * span
            : span + hardware * (1 - span)
        if Settings.shared.traceEnabled {
            NSLog("SC-TRACE refresh name=%@ ddc=%d/%d span=%.2f sw=%.4f -> combined=%.4f", name, Int(current), Int(maxValue), span, software, brightness)
        }
        return brightness
    }

    /// 0.0 ... 1.0. `smooth` true ise slider sürükleme için coalesce edilir.
    func setBrightness(_ value: Double, smooth: Bool = false) {
        let clamped = min(max(value, 0), 1)
        brightness = clamped

        if isBuiltin {
            DisplayServices.setBrightness(Float(clamped), of: id)
            return
        }
        guard let ddc else { return }

        // Sürgüyü iki bölgeye ayırıyoruz:
        //   üst bölge  -> DDC 0..100, gamma'ya dokunulmaz
        //   alt bölge  -> DDC dibinde sabit, karartmayı gamma devralır
        let span = dimSpan
        let hardware: Double
        let software: Double
        if span <= 0 {
            hardware = clamped
            software = 1
        } else if clamped >= span {
            hardware = (clamped - span) / (1 - span)
            software = 1
        } else {
            hardware = 0
            software = clamped / span
        }
        if Settings.shared.traceEnabled {
            NSLog("SC-TRACE set name=%@ combined=%.4f span=%.2f hw=%.4f sw=%.4f", name, clamped, span, hardware, software)
        }
        SoftwareDimmer.shared.setFactor(software, for: id)

        if canBlackout { setBacklight(on: clamped > 0.0001) }

        let raw = UInt16((hardware * Double(ddcMaxBrightness)).rounded())
        if smooth {
            ddc.writeCoalesced(.brightness, value: raw)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { ddc.write(.brightness, value: raw) }
        }
    }

    /// Kontrast — sadece DDC monitörlerde.
    func setContrast(_ value: Double) {
        guard let ddc else { return }
        let raw = UInt16((min(max(value, 0), 1) * 100).rounded())
        ddc.writeCoalesced(.contrast, value: raw)
    }
}

/// Bağlı ekranları keşfeder ve CGDirectDisplayID <-> IOAVService eşleştirmesini yapar.
enum DisplayRegistry {

    // MARK: - IORegistry yardımcıları

    private static func registryPath(_ entry: io_service_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    /// IORegistry path'inden framebuffer token'ını çeker: ".../dispext0@70000000/..." -> "dispext0"
    ///
    /// Apple Silicon'da bir ekranın AppleCLCD2 (EDID/ürün bilgisi taşır) ve
    /// DCPAVServiceProxy (I2C kanalı) node'ları farklı IORegistry dallarında durur;
    /// ikisini birbirine bağlayan tek ortak şey bu "dispN"/"dispextN" isim eki.
    private static func framebufferToken(from path: String) -> String? {
        for component in path.split(separator: "/") {
            let name = component.split(separator: "@").first.map(String.init) ?? String(component)
            let base = name.split(separator: ":").first.map(String.init) ?? name
            if base.hasPrefix("dispext") || base == "disp0" || (base.hasPrefix("disp") && base.dropFirst(4).allSatisfy(\.isNumber) && base.count > 4) {
                return base
            }
        }
        return nil
    }

    private static func matchingServices(_ className: String) -> [io_service_t] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        return services
    }

    private struct ProductIdentity: Hashable {
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
    }

    /// AppleCLCD2 node'larından "ürün kimliği -> framebuffer token" tablosu çıkarır.
    private static func frameBufferTokensByProduct() -> [ProductIdentity: String] {
        var table: [ProductIdentity: String] = [:]
        for service in matchingServices("AppleCLCD2") {
            defer { IOObjectRelease(service) }
            guard
                let attributes = IORegistryEntryCreateCFProperty(
                    service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any],
                let product = attributes["ProductAttributes"] as? [String: Any],
                let token = framebufferToken(from: registryPath(service))
            else { continue }

            let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0
            let model  = (product["ProductID"] as? NSNumber)?.uint32Value ?? 0
            let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
            table[ProductIdentity(vendor: vendor, model: model, serial: serial)] = token
        }
        return table
    }

    /// Harici DCPAVServiceProxy'lerden "framebuffer token -> IOAVService" tablosu çıkarır.
    private static func avServicesByToken() -> [String: IOAVServiceRef] {
        var table: [String: IOAVServiceRef] = [:]
        for service in matchingServices("DCPAVServiceProxy") {
            defer { IOObjectRelease(service) }
            let location = IORegistryEntryCreateCFProperty(
                service, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
            guard location == "External",
                  let token = framebufferToken(from: registryPath(service)),
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue()
            else { continue }
            table[token] = av
        }
        return table
    }

    // MARK: - Keşif

    /// Aynı model iki monitör takılıysa EDID seri numarası da aynı çıkabiliyor;
    /// o durumda ayarların karışmaması için sıra numarası ekliyoruz.
    private static func persistentKey(for id: CGDirectDisplayID, index: Int) -> String {
        if CGDisplayIsBuiltin(id) != 0 { return "builtin" }
        return String(
            format: "ext-%04X-%04X-%08X-%d",
            CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id), index
        )
    }

    private static func localizedName(for id: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) {
            return screen.localizedName
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Dahili Ekran" : "Harici Monitör"
    }

    /// Bağlı bütün ekranları bulur. DDC yoklaması yaptığı için blocking — arka planda çağır.
    static func discover() -> [ManagedDisplay] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        ids = Array(ids.prefix(Int(count)))

        let tokenTable = frameBufferTokensByProduct()
        let avTable = avServicesByToken()

        var displays: [ManagedDisplay] = []
        for (index, id) in ids.enumerated() {
            // Mirror set'te ikincil ekranlara ayrı satır açmıyoruz.
            if CGDisplayIsInMirrorSet(id) != 0, CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { continue }

            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            var link: DDCLink?

            if !isBuiltin {
                let identity = ProductIdentity(
                    vendor: CGDisplayVendorNumber(id),
                    model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id)
                )
                if let token = tokenTable[identity], let av = avTable[token] {
                    let candidate = DDCLink(avService: av, label: token)
                    // Sanal ekranlar (DisplayLink, Sidecar) DDC'ye cevap vermez;
                    // gerçekten konuşabildiğini doğrulamadan slider göstermiyoruz.
                    if candidate.supports(.brightness) { link = candidate }
                }
            }

            let display = ManagedDisplay(
                id: id,
                name: localizedName(for: id),
                isBuiltin: isBuiltin,
                persistentKey: persistentKey(for: id, index: index),
                ddc: link
            )
            display.refreshBrightness()
            displays.append(display)
        }

        // Dahili ekran her zaman en üstte.
        return displays.sorted { $0.isBuiltin && !$1.isBuiltin }
    }
}

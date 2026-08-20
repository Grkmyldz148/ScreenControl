import Foundation
import CoreGraphics

/// DDC parlaklık 0'ın *altına* inebilmek için ekranın gamma eğrisini ölçekler.
///
/// Neden gerekli: DDC'de parlaklık 0 arka ışığı söndürmez, sadece minimuma
/// çeker — panel hâlâ yanıyordur. Arka ışığı gerçekten kapatmanın tek DDC yolu
/// güç komutu (VCP 0xD6) ama monitör Mac'i USB-C ile şarj ediyorsa bu güç
/// dağıtımını da riske atar. Bunun yerine ekranın çıkış eğrisini ölçekleyip
/// görüntüyü siyaha indiriyoruz: monitör açık ve şarj eder halde kalıyor.
///
/// Güvenlik: CoreGraphics, gamma tablosunu ayarlayan işlem öldüğünde tabloyu
/// kendiliğinden geri alıyor. Yani uygulama çökse bile ekran karanlık kalmaz.
final class SoftwareDimmer {
    static let shared = SoftwareDimmer()

    private struct GammaTable {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    /// Karartmaya başlamadan önceki tablo — kullanıcının renk profili burada.
    private var baseTables: [CGDirectDisplayID: GammaTable] = [:]
    private var factors: [CGDirectDisplayID: Double] = [:]
    private let lock = NSLock()

    private init() {}

    /// 1.0 = karartma yok.
    func factor(for id: CGDirectDisplayID) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return factors[id] ?? 1
    }

    var isDimmingAnything: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !factors.isEmpty
    }

    /// 1.0 = dokunma, 0.0 = tam siyah.
    func setFactor(_ factor: Double, for id: CGDirectDisplayID) {
        let clamped = min(max(factor, 0), 1)
        lock.lock()
        defer { lock.unlock() }

        guard clamped < 0.999 else {
            guard factors[id] != nil else { return }
            // Karartma kalktı: tabloyu geri koy ve referansı bırak ki bir dahaki
            // sefere kullanıcının güncel renk profilini yeniden yakalayalım.
            if let base = baseTables[id] { write(base, to: id) }
            factors.removeValue(forKey: id)
            baseTables.removeValue(forKey: id)
            return
        }

        // Referans tabloyu yalnızca karartmadığımız anda yakalıyoruz; yoksa kendi
        // ölçeklediğimiz tabloyu referans alıp katlanarak karartırdık.
        if baseTables[id] == nil {
            guard let captured = capture(id) else { return }
            baseTables[id] = captured
        }
        guard let base = baseTables[id] else { return }

        factors[id] = clamped
        let scale = CGGammaValue(clamped)
        write(GammaTable(
            red: base.red.map { $0 * scale },
            green: base.green.map { $0 * scale },
            blue: base.blue.map { $0 * scale }
        ), to: id)
    }

    /// Uykudan çıkışta veya ekran yeniden yapılandırıldığında macOS gamma'yı
    /// sıfırlıyor. Karartmayı yeniden uygulamak, referans tabloyu da yeniden
    /// yakalamak gerekiyor.
    func reapplyAll() {
        lock.lock()
        let previous = factors
        baseTables.removeAll()
        factors.removeAll()
        lock.unlock()

        for (id, factor) in previous { setFactor(factor, for: id) }
    }

    func restoreAll() {
        lock.lock()
        let ids = Array(factors.keys)
        lock.unlock()
        for id in ids { setFactor(1, for: id) }
    }

    // MARK: - Ham tablo işlemleri

    private func capture(_ id: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }

        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &sampleCount) == .success,
              sampleCount > 0
        else { return nil }

        let n = Int(sampleCount)
        return GammaTable(red: Array(red[0..<n]), green: Array(green[0..<n]), blue: Array(blue[0..<n]))
    }

    @discardableResult
    private func write(_ table: GammaTable, to id: CGDirectDisplayID) -> Bool {
        var red = table.red, green = table.green, blue = table.blue
        return CGSetDisplayTransferByTable(id, UInt32(red.count), &red, &green, &blue) == .success
    }
}

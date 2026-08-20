import Foundation
import IOKit

/// DDC/CI VCP kontrol kodları (MCCS standardı).
enum VCPCode: UInt8 {
    case brightness = 0x10
    case contrast   = 0x12
    case redGain    = 0x16
    case greenGain  = 0x18
    case blueGain   = 0x1A
    case volume     = 0x62
    case inputSource = 0x60
    case powerMode  = 0xD6
}

/// Tek bir harici monitörle DDC/CI konuşan nesne.
///
/// I2C bus paylaşımlı ve thread-safe değil: bütün trafiği tek bir serial
/// queue üzerinden akıtıyoruz ve ardışık işlemler arasına zorunlu bekleme
/// koyuyoruz. Monitörler DDC isteklerine yavaş cevap verir; peş peşe hızlı
/// istek atılırsa cevaplar karışır veya bus kilitlenir.
final class DDCLink {
    /// DDC/CI slave adresi (7-bit 0x37, write için 8-bit 0x6E).
    private static let chipAddress: UInt32 = 0x37
    private static let sourceAddress: UInt32 = 0x51
    /// Checksum XOR tohumu: hedef adres (0x6E) ^ kaynak adres (0x51).
    private static let checksumSeed: UInt8 = 0x6E ^ 0x51

    /// MCCS spec'i iki istek arasında en az 40 ms ister; 50 ms güvenli taban.
    private static let interCommandDelay: useconds_t = 50_000
    /// Yazma sonrası monitörün değeri işlemesi için ek bekleme.
    private static let postWriteDelay: useconds_t = 20_000

    private let avService: IOAVServiceRef
    private let queue: DispatchQueue

    /// Slider sürüklerken oluşan yazma seli için son-değer-kazanır kuyruğu.
    private var pendingWrites: [VCPCode: UInt16] = [:]
    private var flushScheduled = false
    private let pendingLock = NSLock()

    init(avService: IOAVServiceRef, label: String) {
        self.avService = avService
        self.queue = DispatchQueue(label: "app.pushbrands.screencontrol.ddc.\(label)", qos: .userInitiated)
    }

    // MARK: - Ham I2C

    private func writePacket(_ payload: [UInt8]) -> Bool {
        // Paket: [uzunluk|0x80, komut, ...veri, checksum]
        var packet = [UInt8]([UInt8(0x80 | payload.count)] + payload + [0])
        var checksum = Self.checksumSeed
        for byte in packet.dropLast() { checksum ^= byte }
        packet[packet.count - 1] = checksum

        let size = UInt32(packet.count)
        let result = packet.withUnsafeMutableBytes {
            IOAVServiceWriteI2C(avService, Self.chipAddress, Self.sourceAddress, $0.baseAddress!, size)
        }
        return result == KERN_SUCCESS
    }

    // MARK: - Yüksek seviye

    /// VCP değerini okur. `(current, max)` döner. Blocking — arka planda çağır.
    func read(_ code: VCPCode, retries: Int = 4) -> (current: UInt16, max: UInt16)? {
        queue.sync {
            for attempt in 0..<retries {
                if attempt > 0 { usleep(Self.interCommandDelay) }

                // 0x01 = Get VCP Feature
                guard writePacket([0x01, code.rawValue]) else { continue }
                usleep(Self.interCommandDelay)

                var reply = [UInt8](repeating: 0, count: 12)
                let ok = reply.withUnsafeMutableBytes {
                    IOAVServiceReadI2C(avService, Self.chipAddress, 0, $0.baseAddress!, 12)
                } == KERN_SUCCESS
                guard ok else { continue }

                // Beklenen cevap: 6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <chk>
                // reply[2] == 0x02 -> "VCP Feature Reply", reply[3] == 0 -> hata yok
                guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue else { continue }

                let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
                let current  = UInt16(reply[8]) << 8 | UInt16(reply[9])
                guard maxValue > 0 else { continue }
                return (current, maxValue)
            }
            return nil
        }
    }

    /// VCP değerini yazar (blocking).
    @discardableResult
    func write(_ code: VCPCode, value: UInt16) -> Bool {
        queue.sync { writeNow(code, value) }
    }

    private func writeNow(_ code: VCPCode, _ value: UInt16) -> Bool {
        // 0x03 = Set VCP Feature
        let ok = writePacket([0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
        usleep(Self.postWriteDelay)
        return ok
    }

    /// Slider sürüklemesi için: hızlı çağrılara dayanıklı, sadece son değeri gönderir.
    func writeCoalesced(_ code: VCPCode, value: UInt16) {
        pendingLock.lock()
        pendingWrites[code] = value
        let needsSchedule = !flushScheduled
        if needsSchedule { flushScheduled = true }
        pendingLock.unlock()

        guard needsSchedule else { return }
        queue.async { [weak self] in
            guard let self else { return }
            while true {
                self.pendingLock.lock()
                guard let (code, value) = self.pendingWrites.popFirst() else {
                    self.flushScheduled = false
                    self.pendingLock.unlock()
                    return
                }
                self.pendingLock.unlock()
                _ = self.writeNow(code, value)
                usleep(Self.interCommandDelay)
            }
        }
    }

    /// Monitörün bu VCP kodunu gerçekten desteklediğini doğrular.
    func supports(_ code: VCPCode) -> Bool {
        read(code, retries: 3) != nil
    }
}

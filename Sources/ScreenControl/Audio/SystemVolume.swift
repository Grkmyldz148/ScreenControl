import AppKit
import AudioToolbox
import CoreAudio

/// Mac'in sistem sesi: o an seçili çıkış aygıtının ana ses seviyesi ve sessiz durumu.
///
/// Her aygıt ses seviyesini yazılımdan ayarlatmaz. HDMI/DisplayPort üzerinden monitöre
/// giden ses çoğunlukla sabittir; macOS'un kendi ses menüsü de orada sürgüyü kilitler.
/// Böyle bir aygıtta `controllable` false döner.
enum SystemVolume {

    struct State: Encodable {
        let device: String
        let controllable: Bool
        let canMute: Bool
        let percent: Double
        let muted: Bool
    }

    static func current() -> State? {
        guard let device = defaultOutputDevice() else { return nil }
        let volume: Float32? = read(volumeAddress, of: device)
        let muted: UInt32? = read(muteAddress, of: device)
        return State(
            device: name(of: device) ?? "Sound output",
            controllable: volume != nil && isSettable(volumeAddress, of: device),
            canMute: muted != nil && isSettable(muteAddress, of: device),
            percent: (Double(volume ?? 0) * 1000).rounded() / 10,
            muted: muted == 1
        )
    }

    /// 0...1
    @discardableResult
    static func setVolume(_ value: Double) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        return write(Float32(min(max(value, 0), 1)), to: volumeAddress, of: device)
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        return write(UInt32(muted ? 1 : 0), to: muteAddress, of: device)
    }

    // MARK: - Ses tuşları

    enum Key: String, Decodable {
        case up, down, mute
    }

    /// Klavyedeki ses tuşuna basılmış gibi yapar. Sesi yazılımdan ayarlanamayan
    /// aygıtlarda (düğmeli ses kartları) SoundSource gibi araçlar bu tuşları yakalayıp
    /// kendi ses seviyelerini değiştiriyor; telefon da aynı yoldan geçiyor.
    /// Sentetik olay göndermek Erişilebilirlik izni ister (F1/F2 için zaten isteniyor).
    @discardableResult
    static func press(_ key: Key) -> Bool {
        guard MediaKeyTap.hasAccessibilityPermission else { return false }
        // ev_keymap.h: NX_KEYTYPE_SOUND_UP = 0, NX_KEYTYPE_SOUND_DOWN = 1, NX_KEYTYPE_MUTE = 7
        let code: Int = switch key {
        case .up: 0
        case .down: 1
        case .mute: 7
        }
        for state in [0xA, 0xB] {  // 0xA: basıldı, 0xB: bırakıldı
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,  // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: code << 16 | state << 8,
                data2: -1
            ) else { return false }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: - CoreAudio

    /// Kanal başına değil, aygıtın tek "ana" ses seviyesi; macOS'un sürgüsü de bunu kullanır.
    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputDevice() -> AudioObjectID? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let device: AudioObjectID? = read(address, of: AudioObjectID(kAudioObjectSystemObject))
        return device.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func read<T>(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func write<T>(_ value: T, to address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        var address = address
        guard isSettable(address, of: object) else { return false }
        return withUnsafeBytes(of: value) { bytes in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
        } == noErr
    }

    private static func isSettable(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address) else { return false }
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }
}

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// F1/F2 (parlaklık) tuşlarını sistemden önce yakalar.
///
/// Bu tuşlar normal `keyDown` değil, `NSSystemDefined` (tip 14) alt tip 8
/// olarak gelir — donanım medya tuşları hep bu kanaldan akar. CGEventTap
/// olmadan yakalanamazlar, CGEventTap da Erişilebilirlik izni ister.
final class MediaKeyTap {

    enum Key {
        case brightnessUp
        case brightnessDown
    }

    struct Event {
        let key: Key
        let isRepeat: Bool
        /// ⇧⌥ basılı: macOS'un kendi davranışı gibi 1/4 adım.
        let isFineStep: Bool
        /// ⌃ basılı: sadece harici monitörü etkile.
        let externalOnly: Bool
    }

    /// IOKit hidsystem/ev_keymap.h sabitleri.
    private static let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
    private static let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3
    private static let NX_SUBTYPE_AUX_CONTROL_BUTTONS: Int16 = 8
    /// NSSystemDefined event tipi — CGEventType enum'unda karşılığı yok.
    private static let systemDefinedEventType: UInt32 = 14

    /// Handler true dönerse olay yutulur (sistem kendi parlaklığını değiştirmez).
    private let handler: (Event) -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isRunning = false

    init(handler: @escaping (Event) -> Bool) {
        self.handler = handler
    }

    deinit { stop() }

    // MARK: - İzin

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Sistem izin penceresini açar. Kullanıcı kabul edene kadar tap kurulamaz.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Yaşam döngüsü

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard Self.hasAccessibilityPermission else { return false }

        let mask = CGEventMask(1 << Self.systemDefinedEventType)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.process(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        return true
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - Olay işleme

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Sistem tap'i ağır iş yaparsak veya kullanıcı girdisiyle devre dışı bırakabilir;
        // sessizce ölmemesi için yeniden açıyoruz.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.NX_SUBTYPE_AUX_CONTROL_BUTTONS
        else { return Unmanaged.passUnretained(event) }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        let key: Key
        switch keyCode {
        case Self.NX_KEYTYPE_BRIGHTNESS_UP: key = .brightnessUp
        case Self.NX_KEYTYPE_BRIGHTNESS_DOWN: key = .brightnessDown
        default: return Unmanaged.passUnretained(event)
        }

        // Tuş bırakma olayını da yutmalıyız, yoksa sistem yarım olay görüp
        // kendi parlaklık HUD'ını gösterebiliyor.
        guard isKeyDown else { return nil }

        let modifiers = nsEvent.modifierFlags
        // ⌥ tek başına: macOS'ta "Ekranlar ayarlarını aç" kısayolu — ona dokunmuyoruz.
        if modifiers.contains(.option), !modifiers.contains(.shift) {
            return Unmanaged.passUnretained(event)
        }

        let payload = Event(
            key: key,
            isRepeat: isRepeat,
            isFineStep: modifiers.contains(.shift) && modifiers.contains(.option),
            externalOnly: modifiers.contains(.control)
        )
        return handler(payload) ? nil : Unmanaged.passUnretained(event)
    }
}

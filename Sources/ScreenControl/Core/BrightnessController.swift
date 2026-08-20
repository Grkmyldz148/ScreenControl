import Foundation
import AppKit
import CoreGraphics
import Combine

/// SwiftUI'nin bağlanacağı değer tipi görüntü.
struct DisplaySnapshot: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let isBuiltin: Bool
    let isControllable: Bool
    let hasDDC: Bool
    var brightness: Double
    /// 1.0 = gamma karartması yok, 0.0 = tam siyah.
    var softwareDim: Double
    var isBacklightOff: Bool
}

/// Uygulamanın beyni: ekranları yönetir, tuşları yorumlar, senkronu uygular.
@MainActor
final class BrightnessController: ObservableObject {

    @Published private(set) var snapshots: [DisplaySnapshot] = []
    @Published private(set) var isDiscovering = false
    @Published var syncEnabled: Bool = Settings.shared.syncEnabled {
        didSet {
            Settings.shared.syncEnabled = syncEnabled
            if syncEnabled { syncExternalsToInternal(animated: false) }
        }
    }

    /// macOS'un kendi parlaklık tuşu adımı 1/16.
    private static let coarseStep = 1.0 / 16.0
    private static let fineStep = 1.0 / 64.0

    private var displays: [ManagedDisplay] = []
    private var keyTap: MediaKeyTap?
    private var internalPollTimer: Timer?
    private var reconfigureWorkItem: DispatchWorkItem?

    /// Poll'un kendi yazdığımız değeri "kullanıcı değişikliği" sanmaması için.
    private var lastSeenInternalBrightness: Double = -1
    /// Aynı hedefe tekrar tekrar DDC yazmamak için ekran başına son uygulanan değer.
    private var lastAppliedExternal: [String: Double] = [:]

    var onBrightnessChanged: ((DisplaySnapshot) -> Void)?

    // MARK: - Yaşam döngüsü

    func start() {
        refreshDisplays()
        installKeyTapIfEnabled()
        startInternalPolling()
        observeSystemEvents()
    }

    func stop() {
        // Ekranı karartılmış ya da sönük halde bırakmayalım.
        SoftwareDimmer.shared.restoreAll()
        for display in externalDisplays where display.isBacklightOff {
            display.forceBacklightOnBlocking()
        }
        keyTap?.stop()
        internalPollTimer?.invalidate()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Ekran keşfi

    func refreshDisplays() {
        guard !isDiscovering else { return }
        isDiscovering = true

        // DDC yoklaması I2C üzerinden yüzlerce ms sürebiliyor, ana thread'i tıkamayalım.
        Task.detached(priority: .userInitiated) {
            let found = DisplayRegistry.discover()
            await MainActor.run {
                self.displays = found
                self.restoreSavedBrightness()
                self.publishSnapshots()
                self.lastSeenInternalBrightness = self.internalDisplay?.brightness ?? -1
                self.isDiscovering = false
                if self.syncEnabled { self.syncExternalsToInternal(animated: false) }
            }
        }
    }

    private var internalDisplay: ManagedDisplay? {
        displays.first { $0.isBuiltin }
    }

    private var externalDisplays: [ManagedDisplay] {
        displays.filter { !$0.isBuiltin && $0.ddc != nil }
    }

    private func publishSnapshots() {
        snapshots = displays.map {
            DisplaySnapshot(
                id: $0.id,
                key: $0.persistentKey,
                name: $0.name,
                isBuiltin: $0.isBuiltin,
                isControllable: $0.supportsBrightness,
                hasDDC: $0.ddc != nil,
                brightness: $0.brightness,
                softwareDim: $0.softwareDimFactor,
                isBacklightOff: $0.isBacklightOff
            )
        }
    }

    private func restoreSavedBrightness() {
        // Önceki oturum çökerek monitörü sönük bırakmış olabilir; durum takibine
        // güvenmeden koşulsuz açıyoruz.
        for display in externalDisplays { display.forceBacklightOn() }

        guard Settings.shared.restoreOnWake else { return }
        for display in externalDisplays {
            guard let saved = Settings.shared.lastBrightness(for: display.persistentKey) else { continue }
            // Tam siyahı kalıcı olarak geri yüklemiyoruz. Uygulama karartılmışken
            // çökerse veya girişte başlarsa kullanıcı sebebini göremeyeceği kapkara
            // bir monitörle kalırdı. En düşük görünür seviyeye açıyoruz —
            // yeniden karartmak tek tuş.
            let target = max(saved, ManagedDisplay.softwareDimSpan)
            if abs(target - display.brightness) > 0.02 {
                display.setBrightness(target)
            }
        }
    }

    // MARK: - Dışarıdan parlaklık ayarlama (sürgüler)

    func setBrightness(_ value: Double, forKey key: String, smooth: Bool) {
        guard let display = displays.first(where: { $0.persistentKey == key }) else { return }
        display.setBrightness(value, smooth: smooth)
        Settings.shared.setLastBrightness(display.brightness, for: key)

        if display.isBuiltin {
            lastSeenInternalBrightness = display.brightness
            if syncEnabled { applyMappedBrightnessToExternals(from: display.brightness, smooth: smooth) }
        } else {
            // Harici sürgüyü elle oynatmak senkronu bozmasın diye hedefi güncelliyoruz.
            lastAppliedExternal[key] = display.brightness
        }
        publishSnapshots()
    }

    func setContrast(_ value: Double, forKey key: String) {
        displays.first { $0.persistentKey == key }?.setContrast(value)
    }

    // MARK: - Senkron

    private func applyMappedBrightnessToExternals(from internalValue: Double, smooth: Bool) {
        for display in externalDisplays {
            let curve = Settings.shared.curve(for: display.persistentKey)
            let target = curve.map(internalValue)
            // DDC yavaş; görünmeyecek kadar küçük farklar için bus'ı meşgul etmiyoruz.
            if let last = lastAppliedExternal[display.persistentKey], abs(last - target) < 0.005 { continue }
            lastAppliedExternal[display.persistentKey] = target
            display.setBrightness(target, smooth: smooth)
            Settings.shared.setLastBrightness(target, for: display.persistentKey)
        }
    }

    func syncExternalsToInternal(animated: Bool) {
        guard let internalDisplay else { return }
        lastAppliedExternal.removeAll()
        applyMappedBrightnessToExternals(from: internalDisplay.brightness, smooth: animated)
        publishSnapshots()
    }

    // MARK: - Dahili parlaklığı izleme

    /// Otomatik parlaklık, Ayarlar penceresi veya Touch Bar da parlaklığı değiştirebilir.
    /// Bunları tuş yakalamayla göremediğimiz için dahili değeri periyodik yokluyoruz.
    /// (Bu okuma I2C değil, ucuz bir framework çağrısı.)
    private func startInternalPolling() {
        internalPollTimer?.invalidate()
        internalPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollInternalBrightness() }
        }
    }

    private func pollInternalBrightness() {
        guard syncEnabled, let internalDisplay else { return }
        guard let current = internalDisplay.refreshBrightness() else { return }
        guard abs(current - lastSeenInternalBrightness) > 0.004 else { return }

        lastSeenInternalBrightness = current
        applyMappedBrightnessToExternals(from: current, smooth: true)
        publishSnapshots()
    }

    // MARK: - Klavye

    func installKeyTapIfEnabled() {
        keyTap?.stop()
        keyTap = nil
        guard Settings.shared.interceptBrightnessKeys else { return }

        let tap = MediaKeyTap { [weak self] event in
            // Event tap kaynağı ana run loop'a bağlı, yani bu closure zaten ana
            // thread'de çalışıyor. Buradan DispatchQueue.main.sync çağırmak
            // kendi kendini beklemek olur ve libdispatch süreci öldürür.
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { self?.handleBrightnessKey(event) ?? false }
        }
        _ = tap.start()
        keyTap = tap
    }

    var keyTapActive: Bool { keyTap?.isRunning ?? false }

    private func handleBrightnessKey(_ event: MediaKeyTap.Event) -> Bool {
        let step = event.isFineStep ? Self.fineStep : Self.coarseStep
        let delta = event.key == .brightnessUp ? step : -step

        // ⌃ basılıysa dahili ekrana dokunma, sadece monitörü oynat.
        if event.externalOnly {
            guard !externalDisplays.isEmpty else { return false }
            if Settings.shared.traceEnabled {
                NSLog("SC-TRACE key externalOnly delta=%.4f from=%@", delta,
                      externalDisplays.map { String(format: "%.4f", $0.brightness) }.joined(separator: ","))
            }
            for display in externalDisplays {
                let target = min(max(display.brightness + delta, 0), 1)
                display.setBrightness(target, smooth: true)
                lastAppliedExternal[display.persistentKey] = target
                Settings.shared.setLastBrightness(target, for: display.persistentKey)
            }
            publishSnapshots()
            if let first = snapshots.first(where: { !$0.isBuiltin }) { onBrightnessChanged?(first) }
            return true
        }

        guard let internalDisplay, internalDisplay.supportsBrightness else { return false }

        let target = min(max(internalDisplay.brightness + delta, 0), 1)
        internalDisplay.setBrightness(target)
        lastSeenInternalBrightness = target
        Settings.shared.setLastBrightness(target, for: internalDisplay.persistentKey)

        if syncEnabled {
            applyMappedBrightnessToExternals(from: target, smooth: true)
        }

        publishSnapshots()
        if let snapshot = snapshots.first(where: { $0.isBuiltin }) { onBrightnessChanged?(snapshot) }
        return true
    }

    // MARK: - Kalibrasyon

    /// Şu anki dahili/harici parlaklık çiftini "bunlar gözle eşit" olarak kaydeder.
    func addCalibrationPoint(forKey key: String) {
        guard
            let internalDisplay,
            let external = displays.first(where: { $0.persistentKey == key })
        else { return }

        var curve = Settings.shared.curve(for: key)
        curve.addAnchor(input: internalDisplay.brightness, output: external.brightness)
        Settings.shared.setCurve(curve, for: key)
        lastAppliedExternal[key] = external.brightness
    }

    func resetCalibration(forKey key: String) {
        Settings.shared.setCurve(.identity, for: key)
        lastAppliedExternal.removeValue(forKey: key)
        if syncEnabled { syncExternalsToInternal(animated: false) }
    }

    func calibration(forKey key: String) -> BrightnessCurve {
        Settings.shared.curve(for: key)
    }

    // MARK: - Sistem olayları

    private func observeSystemEvents() {
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Uykudan çıkışta DCP hazır olmayabiliyor; kısa bir nefes veriyoruz.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    Task { @MainActor in
                        // macOS uyanışta gamma tablosunu sıfırlıyor.
                        SoftwareDimmer.shared.reapplyAll()
                        self?.refreshDisplays()
                    }
                }
            }
        }
    }

    fileprivate func scheduleReconfiguration() {
        reconfigureWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                SoftwareDimmer.shared.reapplyAll()
                self?.refreshDisplays()
            }
        }
        reconfigureWorkItem = item
        // Monitör takıp çıkarmada birden çok callback geliyor; son olaydan sonra tek sefer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
}

private func displayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .disabledFlag, .enabledFlag]
    guard !flags.intersection(relevant).isEmpty else { return }
    let controller = Unmanaged<BrightnessController>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { controller.scheduleReconfiguration() } }
}

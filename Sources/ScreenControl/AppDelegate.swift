import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = BrightnessController()
    private let hud = BrightnessHUD()
    private let updater = UpdateController()
    private lazy var remote = RemoteServer(controller: controller)
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock ikonu ve menü çubuğu menüsü olmayan, sadece status item'da yaşayan uygulama.
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        setUpPanel()
        wireCallbacks()

        if Settings.shared.interceptBrightnessKeys, !MediaKeyTap.hasAccessibilityPermission {
            MediaKeyTap.requestAccessibilityPermission()
        }
        controller.start()
        applyRemoteControlSetting()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.close()
        remote.stop()
        controller.stop()
        SoftwareDimmer.shared.restoreAll()
    }

    // MARK: - Kurulum

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.action = #selector(togglePanel)
        button.target = self
    }

    private func setUpPanel() {
        panel = StatusPanel(
            rootView: ControlPanelView(controller: controller, updater: updater, remote: remote) {
                NSApp.terminate(nil)
            }
        )
    }

    private func wireCallbacks() {
        let bridge = SettingsBridge.shared
        bridge.onInterceptKeysChanged = { [weak self] in
            self?.controller.installKeyTapIfEnabled()
        }
        bridge.onSoftwareDimmingChanged = { [weak self] in
            // Bölgelendirme değişti; sürgü değerlerini donanımdan yeniden türet.
            self?.controller.refreshDisplays()
        }
        bridge.onMenuBarAppearanceChanged = { [weak self] in
            self?.updateStatusItemTitle()
        }
        bridge.onRemoteControlChanged = { [weak self] in
            self?.applyRemoteControlSetting()
        }
        remote.onChange = { [weak self] in
            self?.updateStatusItemTitle()
        }

        controller.onBrightnessChanged = { [weak self] snapshot in
            guard let self else { return }
            if Settings.shared.showHUD {
                self.hud.show(value: snapshot.brightness, title: snapshot.name, on: snapshot.id)
            }
            self.updateStatusItemTitle()
        }
    }

    private func applyRemoteControlSetting() {
        if Settings.shared.remoteControlEnabled {
            remote.start()
        } else {
            remote.stop()
        }
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }
        guard Settings.shared.showPercentageInMenuBar,
              let reference = controller.snapshots.first(where: \.isBuiltin) ?? controller.snapshots.first
        else {
            button.title = ""
            return
        }
        button.title = " \(Int((reference.brightness * 100).rounded()))%"
    }

    // MARK: - Etkileşim

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if panel.isShown {
            panel.close()
        } else {
            controller.refreshDisplays()
            panel.show(below: button)
        }
    }
}

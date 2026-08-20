import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = BrightnessController()
    private let hud = BrightnessHUD()
    private let updater = UpdateController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock ikonu ve menü çubuğu menüsü olmayan, sadece status item'da yaşayan uygulama.
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        setUpPopover()
        wireCallbacks()

        if Settings.shared.interceptBrightnessKeys, !MediaKeyTap.hasAccessibilityPermission {
            MediaKeyTap.requestAccessibilityPermission()
        }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ControlPanelView(controller: controller, updater: updater) { NSApp.terminate(nil) }
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

        controller.onBrightnessChanged = { [weak self] snapshot in
            guard let self else { return }
            if Settings.shared.showHUD {
                self.hud.show(value: snapshot.brightness, title: snapshot.name, on: snapshot.id)
            }
            self.updateStatusItemTitle()
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

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            controller.refreshDisplays()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

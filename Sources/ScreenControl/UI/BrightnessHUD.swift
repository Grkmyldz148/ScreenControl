import AppKit
import SwiftUI

/// Parlaklık tuşlarını yuttuğumuz için macOS kendi göstergesini çizmiyor.
/// Yerine sistemdekine yakın, hangi ekranın değiştiğini de söyleyen bir HUD.
@MainActor
final class BrightnessHUD {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private let model = HUDModel()

    func show(value: Double, title: String, on displayID: CGDirectDisplayID) {
        model.value = min(max(value, 0), 1)
        model.title = title

        let panel = existingPanel()
        position(panel, on: displayID)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, on displayID: CGDirectDisplayID) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main

        guard let frame = screen?.frame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            // macOS kendi HUD'ını ekranın alt kısmına koyuyor; aynı yeri kullanıyoruz.
            y: frame.minY + frame.height * 0.12
        ))
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}

@MainActor
private final class HUDModel: ObservableObject {
    @Published var value: Double = 0.5
    @Published var title: String = ""
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    /// macOS parlaklık göstergesi 16 dilime bölünmüş; adım hissi aynı olsun diye eşliyoruz.
    private let segmentCount = 16

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 62, weight: .regular))
                .foregroundStyle(.primary)

            HStack(spacing: 2) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    let filled = Double(index) < (model.value * Double(segmentCount)).rounded()
                    RoundedRectangle(cornerRadius: 1)
                        .fill(filled ? Color.primary : Color.primary.opacity(0.22))
                        .frame(width: 7, height: 7)
                }
            }

            Text(model.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 200, height: 200)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

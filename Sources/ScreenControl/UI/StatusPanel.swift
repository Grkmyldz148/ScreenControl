import AppKit
import SwiftUI

/// Menü çubuğu simgesinin altında açılan panel. NSPopover'ın yerini alıyor, çünkü:
///
///  - NSPopover konumunu kendisi seçiyor ve ekranlar üst üste dizildiğinde (monitör
///    dizüstünün üstünde) paneli iki ekranın sınırına yerleştirip üst yarısını
///    öbür ekrana taşıyor.
///  - Simgeye bağlı olduğu için menü çubuğu otomatik gizlendiğinde onunla birlikte
///    yukarı kayıp ekrandan çıkıyor.
///
/// Burada konumu biz hesaplıyoruz: simgenin bulunduğu ekranın menü çubuğunun hemen
/// altı, o ekranın dışına asla taşmadan. İçerik boyu değişince üst kenar sabit kalır.
@MainActor
final class StatusPanel: NSObject {

    private static let gap: CGFloat = 5
    private static let cornerRadius: CGFloat = 12
    private static let screenMargin: CGFloat = 8

    private let panel: KeyablePanel
    private let hostingView: SizeReportingHostingView<AnyView>
    private weak var anchor: NSStatusBarButton?
    private var eventMonitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?

    var onWillShow: (() -> Void)?

    var isShown: Bool { panel.isVisible }

    init<Content: View>(rootView: Content) {
        hostingView = SizeReportingHostingView(rootView: AnyView(rootView))
        panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .popUpMenu
        // Tam ekran uygulamaların üstünde ve hangi masaüstündeysek orada açılsın.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.masksToBounds = true

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        // Bölümler açılıp kapanınca (QR, kalibrasyon) panel aşağı doğru uzasın/kısalsın.
        hostingView.onSizeChange = { [weak self] in
            guard let self, self.isShown else { return }
            self.reposition()
        }
    }

    // MARK: - Göster / kapat

    func show(below button: NSStatusBarButton) {
        anchor = button
        onWillShow?()
        holdMenuBar(true)

        reposition()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        // Tıklamanın mouseUp'ı vurguyu sıfırlıyor; bir tur sonra açıyoruz.
        DispatchQueue.main.async { button.highlight(true) }
        startMonitoring()
    }

    func close() {
        guard isShown else { return }
        stopMonitoring()
        holdMenuBar(false)
        anchor?.highlight(false)
        panel.orderOut(nil)
    }

    // MARK: - Konum

    private func reposition() {
        guard let button = anchor, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let center = NSPoint(x: buttonRect.midX, y: buttonRect.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) })
            ?? buttonWindow.screen ?? NSScreen.main
        else { return }

        let size = hostingView.fittingSize

        // Simgenin anlık konumuna değil menü çubuğunun altına göre: çubuk kayarken
        // (tam ekranda belirme animasyonu) açılsa bile panel aynı yere oturur.
        let visibleMenuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let menuBarHeight = max(visibleMenuBar, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let top = screen.frame.maxY - menuBarHeight - Self.gap

        let minX = screen.visibleFrame.minX + Self.screenMargin
        let maxX = screen.visibleFrame.maxX - Self.screenMargin - size.width
        let x = min(max(buttonRect.midX - size.width / 2, minX), maxX)
        let y = max(top - size.height, screen.frame.minY)

        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    // MARK: - Dışarı tıklayınca kapanma

    private func startMonitoring() {
        stopMonitoring()
        // Başka bir uygulamaya, masaüstüne ya da başka bir menü çubuğu öğesine tıklama.
        // (Kendi simgemize tıklama bizim uygulamaya gider; onu düğmenin eylemi kapatır.)
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        ) {
            eventMonitors.append(monitor)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopMonitoring() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }

    // MARK: - Menü çubuğunu açık tutma

    /// Menü çubuğu otomatik gizleniyorsa (tam ekranda varsayılan), imleç panele inince
    /// çubuk kalkar. Sistemin kendi menüleri açıkken çubuk yerinde kalır; aynı "menü
    /// izleniyor" bildirimini göndererek Denetim Merkezi'nin davranışını taklit ediyoruz.
    /// Belgelenmemiş bir bildirim: macOS yok sayarsa panel yine doğru yerde durur,
    /// sadece üstündeki çubuk gizlenir.
    private var isHoldingMenuBar = false

    private func holdMenuBar(_ hold: Bool) {
        guard hold != isHoldingMenuBar else { return }
        isHoldingMenuBar = hold
        let name = hold ? "com.apple.HIToolbox.beginMenuTrackingNotification" : "com.apple.HIToolbox.endMenuTrackingNotification"
        DistributedNotificationCenter.default().post(name: .init(name), object: nil)
    }
}

/// Kenarlıksız paneller varsayılan olarak klavye odağı alamıyor; sürgüler ve Esc için gerekli.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// SwiftUI içeriğinin boyu değişince haber verir.
private final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // Yerleşim turu bitmeden fittingSize eski değeri verebiliyor.
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}

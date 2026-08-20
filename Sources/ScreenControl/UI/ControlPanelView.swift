import SwiftUI
import AppKit

struct ControlPanelView: View {
    @ObservedObject var controller: BrightnessController
    @ObservedObject var settings = SettingsBridge.shared

    var onQuit: () -> Void

    private var externals: [DisplaySnapshot] { controller.snapshots.filter { !$0.isBuiltin } }
    private var hasSyncableSetup: Bool {
        controller.snapshots.contains(where: \.isBuiltin) && externals.contains(where: \.hasDDC)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if controller.snapshots.isEmpty {
                emptyState
            } else {
                VStack(spacing: 18) {
                    ForEach(controller.snapshots) { snapshot in
                        DisplayRow(snapshot: snapshot, controller: controller)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

            if hasSyncableSetup {
                Divider()
                syncSection
            }

            if settings.interceptKeys && !controller.keyTapActive {
                Divider()
                permissionWarning
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    // MARK: - Bölümler

    private var header: some View {
        HStack {
            Label("Parlaklık", systemImage: "sun.max.fill")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if controller.isDiscovering {
                ProgressView().controlSize(.small)
            }
            settingsMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Girişte başlat", isOn: $settings.launchAtLogin)
            Toggle("Parlaklık tuşlarını yakala", isOn: $settings.interceptKeys)
            Toggle("Sıfırın altında karart", isOn: $settings.softwareDimming)
            Toggle("Sıfırda arka ışığı söndür", isOn: $settings.backlightOffAtZero)
            Toggle("Ekran göstergesini çiz", isOn: $settings.showHUD)
            Toggle("Menü çubuğunda yüzde göster", isOn: $settings.showPercentage)
            Toggle("Bağlanınca parlaklığı geri yükle", isOn: $settings.restoreOnWake)
            Divider()
            Button("Ekranları yeniden tara") { controller.refreshDisplays() }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Kontrol edilebilir ekran bulunamadı")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $controller.syncEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ekranları eşitle").font(.system(size: 12, weight: .medium))
                    Text("F1/F2 ikisini birlikte değiştirir")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if controller.syncEnabled {
                ForEach(externals.filter(\.hasDDC)) { external in
                    CalibrationBlock(snapshot: external, controller: controller)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var permissionWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Erişilebilirlik izni gerekli")
                    .font(.system(size: 11, weight: .medium))
                Text("F1/F2 tuşlarını yakalayabilmek için izin ver.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("Sistem Ayarları'nı aç") {
                    MediaKeyTap.requestAccessibilityPermission()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("⌃F1/⌃F2 · sadece monitör")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Çık", action: onQuit)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Tek ekran satırı

private struct DisplayRow: View {
    let snapshot: DisplaySnapshot
    @ObservedObject var controller: BrightnessController

    /// Sadece sürükleme sürerken dolu. Böylece sürgü hem donanımdan gelen
    /// gecikmeli değerle geri zıplamaz, hem de "hiç sürüklenmedi" durumu
    /// yanlışlıkla 0 yazmaya dönüşmez.
    @State private var dragValue: Double?

    private var displayedValue: Double { dragValue ?? snapshot.brightness }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(snapshot.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if snapshot.hasDDC {
                    Text("DDC")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.isBacklightOff {
                    Text("arka ışık kapalı")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                } else if snapshot.softwareDim < 0.999 {
                    // Bu bölgede DDC dibinde; karartmayı gamma yapıyor.
                    Image(systemName: "moon.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("Monitör en kısık halde, karartmaya gamma ile devam ediliyor")
                }
                Text("\(Int((displayedValue * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if snapshot.isControllable {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Slider(
                        value: Binding(
                            get: { displayedValue },
                            set: { newValue in
                                dragValue = newValue
                                controller.setBrightness(newValue, forKey: snapshot.key, smooth: true)
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            guard !editing else { return }
                            // Sürükleme biterken coalesce edilmemiş son yazma: monitörün
                            // tam olarak bırakılan değerde kalmasını garantiler.
                            if let dragValue {
                                controller.setBrightness(dragValue, forKey: snapshot.key, smooth: false)
                            }
                            dragValue = nil
                        }
                    )
                    .controlSize(.small)
                    Image(systemName: "sun.max").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                Text(snapshot.isBuiltin ? "Parlaklık kontrolü yok" : "Bu monitör DDC/CI'ye cevap vermiyor")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Kalibrasyon

private struct CalibrationBlock: View {
    let snapshot: DisplaySnapshot
    @ObservedObject var controller: BrightnessController
    @State private var curve: BrightnessCurve = .identity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Eşleme · \(snapshot.name)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(curve.isIdentity ? "doğrusal" : "\(curve.anchors.count) nokta")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            CurveGraph(curve: curve)
                .frame(height: 54)

            HStack(spacing: 6) {
                Button {
                    controller.addCalibrationPoint(forKey: snapshot.key)
                    curve = controller.calibration(forKey: snapshot.key)
                } label: {
                    Label("Şu an eşit", systemImage: "plus.circle")
                }
                .controlSize(.small)
                .help("İki ekran şu an gözünüze eşit görünüyorsa bu noktayı kaydeder.")

                Button {
                    controller.resetCalibration(forKey: snapshot.key)
                    curve = controller.calibration(forKey: snapshot.key)
                } label: {
                    Label("Sıfırla", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(curve.isIdentity)
            }
        }
        .onAppear { curve = controller.calibration(forKey: snapshot.key) }
    }
}

/// Eşleme eğrisinin küçük görseli: yatay dahili, dikey harici parlaklık.
private struct CurveGraph: View {
    let curve: BrightnessCurve

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.08))

                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    path.addLine(to: CGPoint(x: width, y: 0))
                }
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { path in
                    let steps = 32
                    for step in 0...steps {
                        let x = Double(step) / Double(steps)
                        let point = CGPoint(x: x * width, y: (1 - curve.map(x)) * height)
                        step == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.8)

                ForEach(curve.anchors) { anchor in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(x: anchor.input * width, y: (1 - anchor.output) * height)
                }
            }
        }
    }
}

// MARK: - Ayarları SwiftUI'ye bağlayan köprü

@MainActor
final class SettingsBridge: ObservableObject {
    static let shared = SettingsBridge()

    var onInterceptKeysChanged: (() -> Void)?
    var onMenuBarAppearanceChanged: (() -> Void)?

    @Published var launchAtLogin: Bool = Settings.shared.launchAtLogin {
        didSet { Settings.shared.launchAtLogin = launchAtLogin }
    }
    @Published var interceptKeys: Bool = Settings.shared.interceptBrightnessKeys {
        didSet {
            Settings.shared.interceptBrightnessKeys = interceptKeys
            if interceptKeys && !MediaKeyTap.hasAccessibilityPermission {
                MediaKeyTap.requestAccessibilityPermission()
            }
            onInterceptKeysChanged?()
        }
    }
    @Published var showHUD: Bool = Settings.shared.showHUD {
        didSet { Settings.shared.showHUD = showHUD }
    }
    @Published var showPercentage: Bool = Settings.shared.showPercentageInMenuBar {
        didSet {
            Settings.shared.showPercentageInMenuBar = showPercentage
            onMenuBarAppearanceChanged?()
        }
    }
    @Published var restoreOnWake: Bool = Settings.shared.restoreOnWake {
        didSet { Settings.shared.restoreOnWake = restoreOnWake }
    }
    @Published var backlightOffAtZero: Bool = Settings.shared.backlightOffAtZero {
        didSet {
            Settings.shared.backlightOffAtZero = backlightOffAtZero
            onSoftwareDimmingChanged?()
        }
    }
    @Published var softwareDimming: Bool = Settings.shared.softwareDimmingEnabled {
        didSet {
            Settings.shared.softwareDimmingEnabled = softwareDimming
            if !softwareDimming { SoftwareDimmer.shared.restoreAll() }
            onSoftwareDimmingChanged?()
        }
    }

    var onSoftwareDimmingChanged: (() -> Void)?
}

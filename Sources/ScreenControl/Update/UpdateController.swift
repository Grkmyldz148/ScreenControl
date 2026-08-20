import AppKit
import Combine
import Sparkle

/// Sparkle'ı uygulamaya bağlayan ince katman.
///
/// Uygulama menü çubuğunda yaşıyor (`LSUIElement`), yani Sparkle bir pencere
/// açtığında öne gelecek bir Dock ikonu yok. Bu yüzden güncelleme arayüzü
/// görünmeden önce uygulamayı geçici olarak normal uygulamaya çeviriyoruz;
/// aksi halde onay penceresi arkada kalıp kullanıcıya hiç ulaşmıyor.
@MainActor
final class UpdateController: NSObject, ObservableObject {

    /// Sparkle bir kontrol yürütürken menü öğesini pasifleştirmek için.
    @Published private(set) var canCheckForUpdates = false

    /// Otomatik denetim tercihi; Sparkle bunu kendi ayarlarında saklıyor.
    @Published var automaticallyChecks = false {
        didSet {
            guard let updater = updaterController?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecks
            else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    /// Paketlenmemiş çalıştırmalarda (`swift run`, `--diagnose`) Sparkle başlatılmaz.
    let isAvailable: Bool

    private var updaterController: SPUStandardUpdaterController?
    private var cancellable: AnyCancellable?

    override init() {
        // Sparkle çalışmak için gerçek bir .app paketi ve Info.plist'te bir besleme
        // adresi istiyor. İkisi de yoksa sessizce devre dışı kal: geliştirme
        // sırasında açılışta hata penceresi görmek istemiyoruz.
        isAvailable = Bundle.main.bundleIdentifier != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        super.init()

        guard isAvailable else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        updaterController = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    /// Kullanıcının menüden tetiklediği kontrol: sonuç ne olursa olsun pencere gösterir.
    func checkForUpdates() {
        guard let updaterController else { return }
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    /// Son başarılı denetimin zamanı; menüde göstermek için.
    var lastCheckDate: Date? { updaterController?.updater.lastUpdateCheckDate }

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {

    /// Zamanlanmış kontrollerde Sparkle'ın pencereyi doğrudan yüzümüze atmasını
    /// değil, önce nazikçe haber vermesini istiyoruz.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            // Arka planda bulunmuş bir güncelleme için pencere açılacaksa, menü
            // çubuğu uygulamasını geçici olarak öne alınabilir hale getir.
            if !state.userInitiated {
                _ = NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            // İş bitti; Dock ikonunu tekrar gizle.
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}

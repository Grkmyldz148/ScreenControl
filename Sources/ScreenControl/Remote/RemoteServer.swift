import AppKit
import Foundation
import Network

/// Telefondan kontrol: yerel ağda küçük bir HTTP sunucusu.
///
/// Telefon tarayıcısı `GET /` ile sayfayı alır, sürgüler `/api/...` uçlarını çağırır.
/// Parlaklık mantığının tamamı BrightnessController'da; burası sadece çevirmen,
/// böylece gamma karartması, arka ışık ve bağlı mod telefondan da aynen çalışır.
///
/// Güvenlik iki katmanlı:
///   1. Sadece özel ağ adreslerinden (ev ağı, Tailscale) gelen bağlantılar kabul edilir.
///      Router'da port yönlendirme ya da global bir IPv6 adresi yüzünden internetten
///      ulaşan biri daha tek bayt okunmadan düşer.
///   2. Her API isteği QR koddaki rastgele anahtarı taşımak zorunda.
@MainActor
final class RemoteServer: ObservableObject {

    enum Status: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    static let port: UInt16 = 18765
    private static let maxRequestSize = 16 * 1024
    private static let maxConnections = 16
    private static let connectionTimeout: TimeInterval = 10

    @Published private(set) var status: Status = .off
    /// Telefonun ulaşacağı yerel IPv4 adresi; ağ yoksa nil.
    @Published private(set) var address: String?
    @Published private(set) var token = Settings.shared.remoteToken

    /// Telefondan bir değişiklik uygulandıktan sonra (menü çubuğu yüzdesi için).
    var onChange: (() -> Void)?

    private let controller: BrightnessController
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var retryWorkItem: DispatchWorkItem?
    private lazy var iconPNG = Self.renderIcon()

    init(controller: BrightnessController) {
        self.controller = controller
    }

    var link: URL? {
        guard let address else { return nil }
        return URL(string: "http://\(address):\(Self.port)/?t=\(token)")
    }

    func regenerateToken() {
        token = Settings.shared.regenerateRemoteToken()
    }

    func refreshAddress() {
        address = Self.lanAddress()
    }

    // MARK: - Yaşam döngüsü

    func start() {
        guard listener == nil else { return }
        retryWorkItem?.cancel()
        refreshAddress()
        if status == .off { status = .starting }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        } catch {
            fail(Self.describe(error))
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                // stop() sonrası gelen .cancelled eski dinleyiciye ait; yok sayıyoruz.
                guard let self, let listener, listener === self.listener else { return }
                self.listenerStateChanged(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        retryWorkItem?.cancel()
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        status = .off
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = .running
            refreshAddress()
        case .waiting(let error):
            status = .failed(Self.describe(error))
        case .failed(let error):
            fail(Self.describe(error))
        default:
            break
        }
    }

    /// Port meşgulse ya da ağ geçici olarak yoksa vazgeçmiyoruz; kısa aralıkla yeniden deniyoruz.
    private func fail(_ message: String) {
        listener?.cancel()
        listener = nil
        status = .failed(message)

        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard Settings.shared.remoteControlEnabled else { return }
                self?.start()
            }
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error {
            return "Port \(port) is already in use by another app"
        }
        return error.localizedDescription
    }

    private static func describe(_ error: Error) -> String {
        (error as? NWError).map(describe) ?? error.localizedDescription
    }

    // MARK: - Bağlantılar

    private func accept(_ connection: NWConnection) {
        guard Self.isLocalPeer(connection.endpoint), connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }

        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())

        // Yarım bırakılan ya da boşta bekleyen bağlantılar yer tutmasın.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak connection] in
            connection?.cancel()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestSize) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }

                switch HTTPRequest.parse(buffer) {
                case .complete(let request):
                    self.send(self.route(request), on: connection)
                case .incomplete where buffer.count >= Self.maxRequestSize:
                    self.send(.error("request too large", status: 413), on: connection)
                case .incomplete where isComplete || error != nil:
                    connection.cancel()
                case .incomplete:
                    self.receive(on: connection, buffer: buffer)
                case .invalid:
                    self.send(.error("malformed request", status: 400), on: connection)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(
            content: response.serialized(),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Yönlendirme

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        if Settings.shared.traceEnabled {
            // Sorgu dizesini bilerek yazmıyoruz: anahtar orada.
            NSLog("SC-TRACE remote %@ %@", request.method, request.path)
        }

        // Sayfa ve ikon anahtarsız: içlerinde gizli bir şey yok, ve anahtar yanlışsa
        // sayfanın "QR'ı yeniden okut" diyebilmesi için yüklenebilmesi gerekiyor.
        switch (request.method, request.path) {
        case ("GET", "/"):
            var page = HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(RemotePage.html.utf8))
            page.extraHeaders = [(
                "Content-Security-Policy",
                "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self'; connect-src 'self'"
            )]
            return page
        case ("GET", "/icon.png"), ("GET", "/favicon.ico"), ("GET", "/apple-touch-icon.png"):
            guard let iconPNG else { return .error("not found", status: 404) }
            return HTTPResponse(status: 200, contentType: "image/png", body: iconPNG, cacheControl: "max-age=86400")
        default:
            break
        }

        guard request.path.hasPrefix("/api/") else { return .error("not found", status: 404) }
        guard isAuthorized(request) else { return .error("unauthorized", status: 401) }

        switch (request.method, request.path) {
        case ("GET", "/api/state"):
            return stateResponse()
        case ("POST", "/api/brightness"):
            guard let command = try? JSONDecoder().decode(BrightnessCommand.self, from: request.body) else {
                return .error("expected JSON like {\"percent\": 50}", status: 400)
            }
            return apply(command)
        case ("POST", "/api/link"):
            guard let command = try? JSONDecoder().decode(LinkCommand.self, from: request.body) else {
                return .error("expected JSON like {\"enabled\": true}", status: 400)
            }
            controller.syncEnabled = command.enabled
            onChange?()
            return stateResponse()
        case ("POST", "/api/volume"):
            guard let command = try? JSONDecoder().decode(VolumeCommand.self, from: request.body) else {
                return .error("expected JSON like {\"percent\": 30}, {\"muted\": true} or {\"key\": \"up\"}", status: 400)
            }
            return apply(command)
        case (_, "/api/state"), (_, "/api/brightness"), (_, "/api/link"), (_, "/api/volume"):
            return .error("method not allowed", status: 405)
        default:
            return .error("not found", status: 404)
        }
    }

    /// Anahtar ya `Authorization: Bearer …` başlığında (HTTP Shortcuts) ya da `?t=`
    /// sorgusunda (tarayıcı sayfası) gelir.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        var presented = request.query["t"]
        if let header = request.headers["authorization"], header.lowercased().hasPrefix("bearer ") {
            presented = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        }
        guard let presented else { return false }
        return Self.constantTimeEquals(Array(presented.utf8), Array(token.utf8))
    }

    /// Karşılaştırma süresi ilk farklı bayta göre değişmesin.
    private static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    // MARK: - API

    private struct BrightnessCommand: Decodable {
        /// "all" (varsayılan), "external", ya da bir ekranın anahtarı ("builtin", "ext-…").
        var display: String?
        /// 0...100, mutlak değer.
        var percent: Double?
        /// Mevcut değere eklenir; -100...100.
        var delta: Double?
        /// Sürükleme sürerken false. Bırakıldığında (ya da tek seferlik komutta) true:
        /// coalesce edilmeyen son yazma, monitörün tam o değerde kalmasını garantiler.
        var final: Bool?
    }

    private struct LinkCommand: Decodable {
        var enabled: Bool
    }

    private struct VolumeCommand: Decodable {
        /// 0...100, mutlak değer.
        var percent: Double?
        /// Mevcut değere eklenir; -100...100.
        var delta: Double?
        var muted: Bool?
        /// Klavyedeki ses tuşuna bas: sabit sesli aygıtlarda SoundSource gibi araçlar için.
        var key: SystemVolume.Key?
    }

    private struct StatePayload: Encodable {
        struct Display: Encodable {
            let key: String
            let name: String
            let builtin: Bool
            let controllable: Bool
            let percent: Double
            let backlightOff: Bool
        }
        let linked: Bool
        let canLink: Bool
        let displays: [Display]
        /// Çıkış aygıtı yoksa (ör. hepsi çıkarılmışsa) alan hiç yazılmaz.
        let volume: SystemVolume.State?
    }

    private func apply(_ command: BrightnessCommand) -> HTTPResponse {
        let inputs = [command.percent, command.delta].compactMap { $0 }
        guard !inputs.isEmpty, inputs.allSatisfy(\.isFinite) else {
            return .error("percent or delta is required", status: 400)
        }

        let controllable = controller.snapshots.filter(\.isControllable)
        let targets: [DisplaySnapshot]
        switch command.display ?? "all" {
        case "all":
            // Bağlı modda F1/F2 gibi: dahili ekranı ayarla, monitörler kalibrasyon
            // eğrisiyle takip etsin. Her birini aynı yüzdeye çekmek eğriyi bozardı.
            if controller.syncEnabled, let builtin = controllable.first(where: \.isBuiltin) {
                targets = [builtin]
            } else {
                targets = controllable
            }
        case "external":
            targets = controllable.filter { !$0.isBuiltin }
        case let key:
            targets = controllable.filter { $0.key == key }
        }
        guard !targets.isEmpty else { return .error("no controllable display matches", status: 404) }

        let smooth = !(command.final ?? true)
        for target in targets {
            let base = command.percent.map { $0 / 100 } ?? target.brightness
            let value = min(max(base + (command.delta ?? 0) / 100, 0), 1)
            controller.setBrightness(value, forKey: target.key, smooth: smooth)
        }
        onChange?()
        return stateResponse()
    }

    private func apply(_ command: VolumeCommand) -> HTTPResponse {
        if let key = command.key {
            guard SystemVolume.press(key) else {
                return .error("ScreenControl needs Accessibility permission to press the volume keys", status: 400)
            }
            return stateResponse()
        }

        let inputs = [command.percent, command.delta].compactMap { $0 }
        guard inputs.allSatisfy(\.isFinite), !inputs.isEmpty || command.muted != nil else {
            return .error("percent, delta, muted or key is required", status: 400)
        }
        guard let volume = SystemVolume.current() else {
            return .error("this Mac has no sound output right now", status: 404)
        }

        if !inputs.isEmpty {
            guard volume.controllable else {
                return .error("\(volume.device) has a fixed volume", status: 400)
            }
            let base = command.percent ?? volume.percent
            let value = min(max(base + (command.delta ?? 0), 0), 100) / 100
            SystemVolume.setVolume(value)
            // Klavyedeki ses tuşları gibi: sessizken sesi açmak sessizliği de kaldırır.
            if command.muted == nil, volume.muted, value > 0 { SystemVolume.setMuted(false) }
        }
        if let muted = command.muted {
            guard volume.canMute else { return .error("\(volume.device) cannot be muted", status: 400) }
            SystemVolume.setMuted(muted)
        }
        return stateResponse()
    }

    private func stateResponse() -> HTTPResponse {
        let snapshots = controller.snapshots
        let canLink = snapshots.contains(where: \.isBuiltin)
            && snapshots.contains { !$0.isBuiltin && $0.hasDDC }
        return .json(StatePayload(
            linked: controller.syncEnabled,
            canLink: canLink,
            displays: snapshots.map {
                StatePayload.Display(
                    key: $0.key,
                    name: $0.name,
                    builtin: $0.isBuiltin,
                    controllable: $0.isControllable,
                    percent: ($0.brightness * 1000).rounded() / 10,
                    backlightOff: $0.isBacklightOff
                )
            },
            volume: SystemVolume.current()
        ))
    }

    // MARK: - Ağ yardımcıları

    /// Ev ağı, Tailscale ya da bu Mac'in kendisi. Geri kalan her şey reddedilir.
    nonisolated static func isLocalPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isPrivate(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            // ::ffff:a.b.c.d — çift yığınlı soket IPv4 istemciyi böyle gösterir.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isPrivate(ipv4: Array(bytes[12...]))
            }
            if address.isLoopback || address.isLinkLocal { return true }
            return bytes[0] & 0xFE == 0xFC  // fc00::/7, ULA (Tailscale da burada)
        default:
            return false
        }
    }

    nonisolated static func isPrivate(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31):
            return true
        case (100, 64...127):
            return true  // 100.64.0.0/10: Tailscale
        default:
            return false
        }
    }

    /// QR koda yazılacak adres. Wi-Fi/Ethernet'teki özel adres önce, Tailscale sonra.
    nonisolated static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var best: (rank: Int, address: String)?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard
                flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                let socketAddress = entry.pointee.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let bytes = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { [UInt8]($0) }
            }
            // 169.254 kendi kendine atanmış adres: DHCP yok demek, telefon oraya ulaşamaz.
            guard isPrivate(ipv4: bytes), bytes[0] != 127, !(bytes[0] == 169 && bytes[1] == 254) else { continue }

            let isTailscale = bytes[0] == 100
            let isPhysical = String(cString: entry.pointee.ifa_name).hasPrefix("en")
            let rank = isTailscale ? 2 : (isPhysical ? 0 : 1)
            if best == nil || rank < best!.rank {
                best = (rank, bytes.map(String.init).joined(separator: "."))
            }
        }
        return best?.address
    }

    /// Android ana ekran kısayolu için uygulama ikonu.
    private static func renderIcon() -> Data? {
        let size = 192
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSApp.applicationIconImage.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

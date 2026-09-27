import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Panelin telefon bölümü: sunucu durumu, telefonun okutacağı QR kod ve bağlantı.
struct RemoteSection: View {
    @ObservedObject var remote: RemoteServer
    @State private var showCode = false

    private var statusText: String {
        switch remote.status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .failed(let message): return message
        case .running:
            guard let address = remote.address else { return "Not connected to a network" }
            return "On · \(address)"
        }
    }

    private var isHealthy: Bool { remote.status == .running && remote.address != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Phone remote").font(.system(size: 12, weight: .medium))
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(isHealthy ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(2)
                }
                Spacer()
                if remote.link != nil {
                    Button(showCode ? "Hide" : "Show QR") { showCode.toggle() }
                        .controlSize(.small)
                }
            }

            if showCode, let link = remote.link {
                HStack(alignment: .top, spacing: 12) {
                    QRCodeView(text: link.absoluteString)
                        .frame(width: 128, height: 128)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with your phone’s camera, then add the page to your home screen.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }
                        .controlSize(.small)
                        Button("New link") { remote.regenerateToken() }
                            .controlSize(.small)
                            .help("Creates a new secret. Pages already saved on phones stop working.")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Wi-Fi değişmiş olabilir; QR'daki adres panel her açıldığında tazelenir.
        .onAppear { remote.refreshAddress() }
    }
}

private struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                // Koyu temada da kameranın okuyabilmesi için beyaz sessiz bölge.
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

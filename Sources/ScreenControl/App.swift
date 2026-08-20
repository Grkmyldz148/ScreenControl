import AppKit

@main
enum ScreenControlApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
            return
        }

        let application = NSApplication.shared
        // NSApplication.delegate zayıf referans tutuyor; run() boyunca yaşasın diye
        // güçlü referansı burada tutuyoruz.
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

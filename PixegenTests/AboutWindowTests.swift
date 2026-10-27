import AppKit
import Testing
@testable import Pixegen

/// Pixegen ▸ About Pixegen: its credits, version and window.
@MainActor struct AboutWindowTests {
    @Test func creditsListPixegenAndEveryoneBehindCompositor() {
        let credits = AboutWindowController.credits()
        // Names keep to one line with no-break spaces and hyphens.
        let text = credits.string.replacingOccurrences(of: "\u{a0}", with: " ").replacingOccurrences(of: "\u{2011}", with: "-")
        for name in ["Ted Lee", "Robbie Tilton", "Cengokill", "Myron Koch", "Tao Xin", "xocialize", "Sparkle", "libwebp"] {
            #expect(text.contains(name), "\(name) is missing")
        }
        // Pixegen first, then Compositor's author, then its contributors.
        let order = ["Ted Lee", "Robbie Tilton", "Cengokill"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(order == order.sorted() && order.count == 3)

        var profiles: Set<URL> = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { link, _, _ in
            if let url = link as? URL, url.host == "github.com", url.pathComponents.count == 2 { profiles.insert(url) }
        }
        #expect(profiles.count == 25)
    }

    @Test func showsTheBundleVersion() {
        #expect(AboutWindowController.versionString() == "Version 1.0")
    }

    @Test func opensOneFixedSizeWindowAndReusesIt() throws {
        let about = AboutWindowController.shared
        about.show()
        let window = try #require(about.window)
        defer { window.close() }
        #expect(window.isVisible)
        #expect(window.contentView?.frame.size == AboutWindowController.size)
        #expect(!window.styleMask.contains(.resizable))

        about.show()
        #expect(about.window === window)
        #expect(NSApp.windows.filter { $0.identifier?.rawValue == "aboutWindow" }.count == 1)
        #expect(NSImage(named: "AboutArt")?.size.width ?? 0 > 0)
    }
}


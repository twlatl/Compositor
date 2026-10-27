import AppKit
import SwiftUI

/// Pixegen ▸ About Pixegen: the app icon, version and credits (`Credits.html`) on the left, and the
/// About art on the right. One window, brought forward again if it's already open.
@MainActor
final class AboutWindowController: NSObject {
    static let shared = AboutWindowController()
    /// The art is square, so the window is the sidebar beside it at its full height.
    static let sidebarWidth: CGFloat = 400
    static let size = NSSize(width: sidebarWidth + 640, height: 640)

    private(set) var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        let isOpening = !window.isVisible
        window.makeKeyAndOrderFront(nil)
        if isOpening { window.center() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "About Pixegen"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("aboutWindow")
        // Open over a full-screen project window, rather than in a separate space.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // In a plain container: as the content view itself, the hosting view sizes the window to fit,
        // adding the title bar's height on top of the art's although the content runs under the bar.
        let host = NSHostingView(rootView: AboutView())
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        window.contentView = container
        window.setFrame(NSRect(origin: .zero, size: Self.size), display: false)
        self.window = window
        return window
    }

    /// The bundle's version, "Version 1.0".
    static func versionString(bundle: Bundle = .main) -> String {
        "Version " + (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }

    /// The app icon, from the asset catalog rather than the Dock's copy, which macOS caches and can
    /// keep showing an older icon.
    static var appIcon: NSImage { NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }

    /// `Credits.html` in the sidebar's type: the system font, semibold where the HTML is bold, in a
    /// secondary color, keeping its links and paragraphs.
    static func credits(bundle: Bundle = .main) -> NSAttributedString {
        guard let url = bundle.url(forResource: "Credits", withExtension: "html"),
              let data = try? Data(contentsOf: url),
              let credits = NSMutableAttributedString(html: data, documentAttributes: nil)
        else { return NSAttributedString() }
        let all = NSRange(location: 0, length: credits.length)
        credits.enumerateAttribute(.font, in: all) { font, range, _ in
            let bold = (font as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
            credits.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular), range: range)
        }
        credits.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: all)
        // Names without underlines, which would make the list busy; they still show a pointing hand.
        credits.removeAttribute(.underlineStyle, range: all)
        return credits
    }
}

/// The credits in a selectable text view that scrolls: SwiftUI's `Text` would drop the HTML's
/// paragraph spacing.
private struct CreditsView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.linkTextAttributes = [.foregroundColor: NSColor.secondaryLabelColor, .cursor: NSCursor.pointingHand]
        text.textStorage?.setAttributedString(AboutWindowController.credits())
        text.setAccessibilityLabel("Credits")
        text.setAccessibilityIdentifier("aboutCredits")
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

private struct AboutView: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Image(nsImage: AboutWindowController.appIcon)
                    .resizable().frame(width: 128, height: 128)
                    .padding(.bottom, 12)
                Text(AboutWindowController.versionString())
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("aboutVersion")
                    .padding(.bottom, 6)
                Text("Pixegen").font(.system(size: 26, weight: .bold))
                CreditsView()
                    .padding(.top, 22)
                .padding(.horizontal, 44)
                .padding(.bottom, 32)
            }
            .padding(.top, 44)
            .frame(width: AboutWindowController.sidebarWidth)
            Image("AboutArt")
                .resizable().interpolation(.high)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: AboutWindowController.size.height, height: AboutWindowController.size.height)
                .clipped()
                .accessibilityLabel("A parrot on a branch, painted in Pixegen")
                .accessibilityIdentifier("aboutArt")
        }
        .frame(width: AboutWindowController.size.width, height: AboutWindowController.size.height)
        // Under the title bar too, so the window is the art's height rather than that plus the bar's.
        .ignoresSafeArea()
    }
}

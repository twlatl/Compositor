import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Each project in a window of its own, grouped as native macOS tabs: AppKit draws the tab bar (with its + button),
/// lets a tab be dragged out into a window or windows merged, and gives the Window menu its tab commands.
@MainActor
final class ProjectWindows: ProjectWindowPresenting {
    /// Windows remember their size under this name; with tabs grouped they share one frame anyway.
    static let frameName = "PixelBoxEditor"
    private unowned let applicationDelegate: PixelBoxApplicationDelegate
    private var windows: [UUID: ProjectWindow] = [:]
    private var observer: NSObjectProtocol?
    private var workspace: ProjectWorkspace { applicationDelegate.workspace }

    init(applicationDelegate: PixelBoxApplicationDelegate) {
        self.applicationDelegate = applicationDelegate
        // Whatever made a project's window main (its tab clicked, ⌃Tab, the Window menu), the menus follow it.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? ProjectWindow,
                      let tab = self.workspace.tabs.first(where: { self.windows[$0.id] === window }) else { return }
                self.workspace.activate(tab.controller)
            }
        }
    }

    func window(for tab: ProjectTab) -> NSWindow? { windows[tab.id] }
    func hasWindow(_ tab: ProjectTab) -> Bool { windows[tab.id] != nil }

    func show(_ tab: ProjectTab, beside neighbor: ProjectTab?) {
        if let window = windows[tab.id] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(for: tab)
        windows[tab.id] = window
        if let neighbor, let host = windows[neighbor.id] {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            place(window)
            // A window of its own, not a tab of the main window that `.preferred` would put it in.
            window.tabbingMode = .disallowed
        }
        window.makeKeyAndOrderFront(nil)
        window.tabbingMode = .preferred
    }

    func close(_ tab: ProjectTab) {
        windows.removeValue(forKey: tab.id)?.close()
    }

    private func makeWindow(for tab: ProjectTab) -> ProjectWindow {
        let host = NSHostingController(rootView: ProjectWindowContent(tab: tab, applicationDelegate: applicationDelegate))
        // The editor's toolbar and title come from SwiftUI; its minimum size too, but never a size of its own, which
        // would shrink the window to fit.
        host.sceneBridgingOptions = [.toolbars, .title]
        host.sizingOptions = [.minSize]
        let window = ProjectWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.contentViewController = host
        window.identifier = NSUserInterfaceItemIdentifier("editor-\(tab.id.uuidString)")
        window.isReleasedWhenClosed = false
        // Projects aren't reopened at launch, so neither are their windows.
        window.isRestorable = false
        window.toolbarStyle = .unifiedCompact
        window.tabbingIdentifier = "editor"
        window.tabbingMode = .preferred
        window.title = tab.title
        window.onNewTab = { [weak self] in self?.workspace.newCanvas() }
        return window
    }

    /// A window of its own: stepped down from the one in front, or, for the first, where the last was left. A first
    /// launch fills the screen (without going full screen).
    private func place(_ window: NSWindow) {
        if let front = NSApp.mainWindow as? ProjectWindow ?? windows.values.first(where: { $0 !== window && $0.isVisible }) {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
            return
        }
        if !window.setFrameUsingName(Self.frameName), let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        }
        window.setFrameAutosaveName(Self.frameName)
    }
}

/// A project's window. The + in its tab bar opens a new canvas in a tab beside it.
final class ProjectWindow: NSWindow {
    var onNewTab: (() -> Void)?
    override func newWindowForTab(_ sender: Any?) { onNewTab?() }
}

private struct ProjectWindowContent: View {
    let tab: ProjectTab
    let applicationDelegate: PixelBoxApplicationDelegate
    var body: some View {
        ContentView(session: tab.session, applicationDelegate: applicationDelegate)
            .disabled(applicationDelegate.workspace.isManaging)
            .psdConversionSheet(tab.session)
            .rawDevelopSheet(tab.session)
            .background {
                ProjectWindowBridge(controller: tab.controller).frame(width: 0, height: 0)
            }
            .roundedControls()
    }
}

struct NewProjectDropTarget: ViewModifier {
    let workspace: ProjectWorkspace?
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
            .help(targeted ? "Open in a new tab" : "New canvas (⌘N) · Drop images here for new tabs")
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], delegate:
                NewProjectDropDelegate(workspace: workspace, targeted: $targeted))
    }
}

extension ProjectWorkspace {
    /// The layer being dragged, if a layer is: drops carry only the layer's id, and the drag pasteboard can be read
    /// while the drag is still in the air, before any drop.
    var draggedLayer: UUID? {
        guard let value = NSPasteboard(name: .drag).string(forType: NSPasteboard.PasteboardType(Self.layerType)) else { return nil }
        return UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// The project a layer lives in.
    func tab(holdingLayer id: UUID) -> ProjectTab? {
        tabs.first { $0.session.document?.layers.contains { $0.id == id } == true }
    }
    /// Dragging a layer onto the canvas it already lives in would do nothing, so that isn't a drop target. Another
    /// project's window or tab, a new tab, and every file drag still are.
    func canReceiveDrag(into destination: UUID?, layer: UUID? = nil) -> Bool {
        guard let destination, let layer = layer ?? draggedLayer, let source = tab(holdingLayer: layer) else { return true }
        return source.id != destination
    }
}

/// A drop that opens in a new project: files, images, or a layer dragged from another project.
private struct NewProjectDropDelegate: DropDelegate {
    let workspace: ProjectWorkspace?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool {
        // Option-dragging a layer duplicates it within the Layers panel, so it is not a drag to another project.
        if NSEvent.modifierFlags.contains(.option), info.hasItemsConforming(to: [ProjectWorkspace.layerType]) { return false }
        return workspace?.isManaging == false
            && info.hasItemsConforming(to: [ProjectWorkspace.layerType, UTType.fileURL.identifier, UTType.image.identifier])
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard let workspace, validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [ProjectWorkspace.layerType, UTType.fileURL.identifier, UTType.image.identifier])
        Task { await workspace.receiveProviders(providers, into: nil) }
        return true
    }
}

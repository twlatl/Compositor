import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Projects in windows, as many to a window as are tabbed together. A window keeps its projects' views in a tabless
/// tab view, one shown at a time: the others live on out of the window, so a canvas that isn't shown takes no events.
/// Each project's view has the window's tabs in a `DocumentTabBar` under the tool's bar. AppKit's own window tabs
/// aren't used: macOS won't hide their bar while there are two or more.
@MainActor
final class ProjectWindows: ProjectWindowPresenting {
    /// Windows remember their size under this name.
    static let frameName = "PixegenEditor"
    private unowned let applicationDelegate: PixegenApplicationDelegate
    private var windows: [ProjectWindow] = []
    /// Each project's view, kept as it moves from window to window.
    private var views: [UUID: NSViewController] = [:]
    private var observer: NSObjectProtocol?
    private var workspace: ProjectWorkspace { applicationDelegate.workspace }

    init(applicationDelegate: PixegenApplicationDelegate) {
        self.applicationDelegate = applicationDelegate
        // Whatever made a window main (a click, the Window menu), the menus follow the project it shows.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? ProjectWindow, self.windows.contains(window),
                      let tab = window.tabs.selected else { return }
                self.workspace.activate(tab.controller)
            }
        }
    }

    func window(for tab: ProjectTab) -> NSWindow? { container(of: tab) }
    func hasWindow(_ tab: ProjectTab) -> Bool { container(of: tab) != nil }
    func group(of tab: ProjectTab) -> [ProjectTab] { container(of: tab)?.tabs.list ?? [tab] }
    private func container(of tab: ProjectTab) -> ProjectWindow? { windows.first { $0.tabs.contains(tab) } }

    func show(_ tab: ProjectTab, beside neighbor: ProjectTab?) {
        defer { workspace.noteWindowLayoutChanged() }
        let window: ProjectWindow
        if let existing = container(of: tab) {
            window = existing
        } else if let neighbor, let host = container(of: neighbor) {
            window = host
            host.insert(tab, view: view(for: tab), at: host.tabs.list.count)
        } else {
            window = makeWindow()
            place(window)
            windows.append(window)
            window.insert(tab, view: view(for: tab), at: 0)
        }
        window.select(tab)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: ProjectTab) {
        defer { workspace.noteWindowLayoutChanged() }
        views.removeValue(forKey: tab.id)
        guard let window = container(of: tab) else { return }
        window.remove(tab)
        if let next = window.tabs.selected {
            // The tab beside it comes forward, and the menus act on it if this is the window in front.
            if NSApp.mainWindow === window || NSApp.mainWindow == nil { workspace.activate(next.controller) }
        } else {
            windows.removeAll { $0 === window }
            window.close()
        }
    }

    func move(_ tab: ProjectTab, to index: Int) {
        container(of: tab)?.move(tab, to: index)
        workspace.noteWindowLayoutChanged()
    }

    func moveToNewWindow(_ tab: ProjectTab) {
        guard let from = container(of: tab), from.tabs.list.count > 1 else { return }
        from.remove(tab)
        let window = makeWindow()
        windows.append(window)
        place(window)
        window.insert(tab, view: view(for: tab), at: 0)
        window.select(tab)
        window.makeKeyAndOrderFront(nil)
        workspace.activate(tab.controller)
        workspace.noteWindowLayoutChanged()
    }

    /// Window › Merge All Windows: every project's tab into `window`, in the order of the windows' tabs.
    func mergeAll(into window: ProjectWindow) {
        for other in windows where other !== window {
            for tab in other.tabs.list {
                other.remove(tab)
                window.insert(tab, view: view(for: tab), at: window.tabs.list.count)
            }
            other.close()
        }
        windows = [window]
        workspace.noteWindowLayoutChanged()
    }

    /// Window › Show Next Tab (⌃Tab) and Show Previous Tab (⌃⇧Tab), round the window's tabs.
    func showTab(after offset: Int, in window: ProjectWindow) {
        let list = window.tabs.list
        guard list.count > 1, let selected = window.tabs.selected, let index = list.firstIndex(where: { $0 === selected }) else { return }
        workspace.select(list[(index + offset + list.count) % list.count].id)
    }

    private func view(for tab: ProjectTab) -> NSViewController {
        if let view = views[tab.id] { return view }
        let host = NSHostingController(rootView: ProjectWindowContent(tab: tab, applicationDelegate: applicationDelegate))
        // The window's size is the window's own: a project shown doesn't resize it.
        host.sizingOptions = []
        views[tab.id] = host
        return host
    }

    private func makeWindow() -> ProjectWindow {
        let window = ProjectWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ProjectWindowRoot(window: window, applicationDelegate: applicationDelegate))
        // The editor's toolbar and title come from SwiftUI; its minimum size too, but never a size of its own, which
        // would shrink the window to fit.
        host.sceneBridgingOptions = [.toolbars, .title]
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.identifier = NSUserInterfaceItemIdentifier("editor-\(UUID().uuidString)")
        window.isReleasedWhenClosed = false
        // Projects aren't reopened at launch, so neither are their windows.
        window.isRestorable = false
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed
        // The toolbar shows the app's name instead; the title is still what the Window menu and Mission Control show.
        window.titleVisibility = .hidden
        window.onNewTab = { [weak self] in self?.workspace.newCanvas() }
        window.onMergeAll = { [weak self, weak window] in if let window { self?.mergeAll(into: window) } }
        window.onShowTab = { [weak self, weak window] offset in if let window { self?.showTab(after: offset, in: window) } }
        return window
    }

    /// A window of its own: stepped down from the one in front, or, for the first, where the last was left. A first
    /// launch fills the screen (without going full screen).
    private func place(_ window: NSWindow) {
        if let front = NSApp.mainWindow as? ProjectWindow ?? windows.first(where: { $0 !== window && $0.isVisible }) {
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

/// The tabs in one window, in order, and the one shown.
@MainActor @Observable
final class WindowTabs {
    private(set) var list: [ProjectTab] = []
    var selectedID: UUID?
    var selected: ProjectTab? { list.first { $0.id == selectedID } ?? list.first }
    func contains(_ tab: ProjectTab) -> Bool { list.contains { $0 === tab } }
    func insert(_ tab: ProjectTab, at index: Int) { list.insert(tab, at: min(max(0, index), list.count)) }
    func remove(_ tab: ProjectTab) { list.removeAll { $0 === tab } }
}

/// A window of projects. Its tab view has no tabs of its own to show: the projects' `DocumentTabBar`s switch it.
final class ProjectWindow: NSWindow {
    let tabs = WindowTabs()
    let tabView: NSTabViewController = {
        let controller = NSTabViewController()
        controller.tabStyle = .unspecified
        controller.tabView.tabViewType = .noTabsNoBorder
        controller.transitionOptions = []
        // The window's title is the project's, set from SwiftUI.
        controller.canPropagateSelectedChildViewControllerTitle = false
        return controller
    }()
    var onNewTab: (() -> Void)?
    var onMergeAll: (() -> Void)?
    var onShowTab: ((Int) -> Void)?

    func insert(_ tab: ProjectTab, view: NSViewController, at index: Int) {
        tabs.insert(tab, at: index)
        let item = NSTabViewItem(viewController: view)
        item.identifier = tab.id
        tabView.insertTabViewItem(item, at: min(index, tabView.tabViewItems.count))
        tab.controller.window = self
    }
    func remove(_ tab: ProjectTab) {
        let index = tabs.list.firstIndex { $0 === tab }
        let selected = tabs.selected
        tabs.remove(tab)
        if let item = tabView.tabViewItems.first(where: { $0.identifier as? UUID == tab.id }) { tabView.removeTabViewItem(item) }
        // The tab shown goes: the one that took its place comes forward, or the last.
        if selected === tab, let index, !tabs.list.isEmpty { select(tabs.list[min(index, tabs.list.count - 1)]) }
        else if let selected, selected !== tab { select(selected) }
    }
    func select(_ tab: ProjectTab) {
        tabs.selectedID = tab.id
        if let index = tabView.tabViewItems.firstIndex(where: { $0.identifier as? UUID == tab.id }) {
            tabView.selectedTabViewItemIndex = index
        }
    }
    func move(_ tab: ProjectTab, to index: Int) {
        guard let item = tabView.tabViewItems.first(where: { $0.identifier as? UUID == tab.id }) else { return }
        let selected = tabs.selected
        tabs.remove(tab)
        tabs.insert(tab, at: index)
        tabView.removeTabViewItem(item)
        tabView.insertTabViewItem(item, at: min(max(0, index), tabView.tabViewItems.count))
        if let selected { select(selected) }
    }

    override func newWindowForTab(_ sender: Any?) { onNewTab?() }
    override func mergeAllWindows(_ sender: Any?) { onMergeAll?() }
    override func selectNextTab(_ sender: Any?) { onShowTab?(1) }
    override func selectPreviousTab(_ sender: Any?) { onShowTab?(-1) }
}

/// The window's toolbar, title and close button follow the project it shows; the projects' views fill the rest.
private struct ProjectWindowRoot: View {
    let window: ProjectWindow
    let applicationDelegate: PixegenApplicationDelegate
    var body: some View {
        let workspace = applicationDelegate.workspace
        TabViewHost(controller: window.tabView)
            .frame(minWidth: 800, minHeight: 520)
            .ignoresSafeArea(.container, edges: window.tabs.selected?.session.canvasOnly == true ? .top : [])
            .navigationTitle(window.tabs.selected?.title ?? "Untitled")
            .toolbar(removing: .title)
            .toolbar {
                if let tab = window.tabs.selected { EditorToolbar(tab: tab, workspace: workspace) }
            }
            .background {
                if let tab = window.tabs.selected {
                    ProjectWindowBridge(controller: tab.controller) { _ in await workspace.closeWindow(of: tab.id) }
                        .frame(width: 0, height: 0)
                }
            }
            .disabled(workspace.isManaging)
            .preferredColorScheme(.dark)
            .roundedControls()
    }
}

private struct TabViewHost: NSViewControllerRepresentable {
    let controller: NSTabViewController
    func makeNSViewController(context: Context) -> NSTabViewController { controller }
    func updateNSViewController(_ controller: NSTabViewController, context: Context) {}
}

/// New canvas, the app's name, and the zoom buttons, for the project shown.
private struct EditorToolbar: ToolbarContent {
    let tab: ProjectTab
    let workspace: ProjectWorkspace
    var body: some ToolbarContent {
        let session = tab.session
        ToolbarItem(placement: .navigation) {
            Button { Task { await tab.controller.newCanvas() } } label: { Label("New canvas", systemImage: "plus") }
                .help("New canvas (⌘N)").accessibilityIdentifier("newCanvasToolbar")
                .disabled(session.isImporting || session.showsBusy || session.levels != nil)
                .modifier(NewProjectDropTarget(workspace: workspace))
        }
        // Plain text, without the glass macOS puts behind toolbar items.
        ToolbarItem(placement: .principal) {
            Text("Pixegen").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityIdentifier("appTitle")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Button("Fit") { session.fit() }.help("Fit canvas in window (⌘0)")
                .accessibilityIdentifier("fitCanvas").disabled(session.document == nil)
                .padding(.horizontal, 4)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("100%") { session.zoom(to: 1) }.help("Actual pixels (⌘1)")
                .accessibilityIdentifier("actualPixels").disabled(session.document == nil)
                .padding(.horizontal, 4)
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 0) {
                Button { session.zoomKeyboard(by: 1) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }.help("Zoom in (⌘+)").disabled(session.document == nil)
                Button { session.zoomKeyboard(by: -1) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }.help("Zoom out (⌘−)").disabled(session.document == nil)
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct ProjectWindowContent: View {
    let tab: ProjectTab
    let applicationDelegate: PixegenApplicationDelegate
    var body: some View {
        ContentView(session: tab.session, applicationDelegate: applicationDelegate)
            .disabled(applicationDelegate.workspace.isManaging)
            .psdConversionSheet(tab.session)
            .rawDevelopSheet(tab.session)
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

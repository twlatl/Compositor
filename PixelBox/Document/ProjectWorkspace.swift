import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
final class ProjectTab: Identifiable {
    let id = UUID()
    let session: EditorSession
    let controller: ProjectController
    let defaultName: String
    var title: String {
        (session.projectURL ?? session.photoshopSource)?.deletingPathExtension().lastPathComponent ?? defaultName
    }
    init(name: String) {
        defaultName = name
        session = EditorSession()
        controller = ProjectController(session: session)
    }
}

/// Puts projects on screen: each in a window of its own, grouped as native macOS tabs. The workspace decides which
/// project goes where; this makes and closes the windows. Absent in tests, where projects never reach the screen.
@MainActor
protocol ProjectWindowPresenting: AnyObject {
    /// Brings the tab's window to the front, first making it: as a tab beside `neighbor`'s window, or a window of its
    /// own when `neighbor` is nil.
    func show(_ tab: ProjectTab, beside neighbor: ProjectTab?)
    /// Closes the tab's window, without asking anything: the workspace has already asked.
    func close(_ tab: ProjectTab)
    /// Whether the tab has a window yet (or still): a tab in a group counts, shown or not.
    func hasWindow(_ tab: ProjectTab) -> Bool
}

/// Every open project, in whichever window or tab it's shown. Copying layers between projects, Paste of a copied
/// layer and the menus (which act on `current`) work across all of them.
@MainActor @Observable
final class ProjectWorkspace {
    private(set) var tabs: [ProjectTab] = []
    /// The project in the main window: the one the menus act on.
    private(set) var selectedID: UUID
    var isManaging = false
    @ObservationIgnored weak var presenter: ProjectWindowPresenting?
    var current: ProjectTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    /// Whether a project is free for the workspace to work on: nothing of the workspace's own running (an Open panel,
    /// Quit's questions), and nothing in progress in it that a close or a drop would cut across.
    func isIdle(_ tab: ProjectTab) -> Bool {
        let s = tab.session
        return !isManaging && s.canStartProjectOperation && s.hueSaturation == nil && s.filterEdit == nil
            && s.gradientEdit == nil && s.pixelMove == nil && s.colorPicker == nil
    }
    init() {
        let first = ProjectTab(name: "Untitled")
        first.session.skipsInitialClipboardCanvasSize = true
        tabs = [first]; selectedID = first.id
        first.controller.workspace = self
    }
    /// A new tab's name: "Untitled" if no tab shows it, otherwise the lowest "Untitled N" free, as Finder and Safari
    /// number them. Counting up for ever, closing the last tab made Untitled 2, then 3, and on.
    private var freeUntitledName: String {
        let taken = Set(tabs.map(\.title))
        guard taken.contains("Untitled") else { return "Untitled" }
        return (2...).lazy.map { "Untitled \($0)" }.first { !taken.contains($0) }!
    }
    /// The only project, still blank: what a file opened or dropped goes into rather than a tab of its own.
    private var blankStart: ProjectTab? {
        tabs.count == 1 && current.session.document == nil && current.session.projectURL == nil ? current : nil
    }
    private func append(_ tab: ProjectTab, beside neighbor: ProjectTab?) {
        tab.controller.workspace = self
        tabs.append(tab); selectedID = tab.id
        presenter?.show(tab, beside: neighbor)
    }
    /// The blank project left when the last window closed, waiting for one: what File › New puts up again.
    private var windowlessBlank: ProjectTab? {
        blankStart.flatMap { presenter?.hasWindow($0) == false ? $0 : nil }
    }
    /// A blank project in a new tab of the front window, or the blank start itself when that's all there is.
    @discardableResult
    func addTab(reuseEmpty: Bool = true) -> ProjectTab {
        if reuseEmpty, let blank = blankStart { presenter?.show(blank, beside: nil); return blank }
        let tab = ProjectTab(name: freeUntitledName)
        append(tab, beside: current)
        return tab
    }
    /// File › New Window: a blank project in a window of its own rather than a tab.
    func newWindow() {
        guard !isManaging else { return }
        if let blank = windowlessBlank { presenter?.show(blank, beside: nil); return }
        append(ProjectTab(name: freeUntitledName), beside: nil)
    }
    /// Brings a project's window to the front, which also makes it the one the menus act on.
    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedID = id
        presenter?.show(tab, beside: nil)
    }
    /// A project's window became the main window: by a click on its tab, ⌃Tab, the Window menu or anything else.
    func activate(_ controller: ProjectController) {
        guard let tab = tabs.first(where: { $0.controller === controller }) else { return }
        if selectedID != tab.id { selectedID = tab.id }
        tab.controller.resumeExternalChangeCheck()
    }
    func newCanvas() {
        guard !isManaging else { return }
        _ = addTab(reuseEmpty: windowlessBlank != nil)
    }
    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        guard !isManaging else { return false }
        isManaging = true
        defer { isManaging = false }
        var urls = suppliedURL.map { [$0] } ?? []
        if urls.isEmpty {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = UTType.openableDocuments
            panel.allowsMultipleSelection = true
            panel.treatsFilePackagesAsDirectories = false
            let window = current.controller.window
            let response = if let window, window.isVisible { await panel.beginSheetModal(for: window) } else { await panel.begin() }
            guard response == .OK else { return false }
            urls = panel.urls
        }
        var opened = false
        for url in urls { opened = await loadProject(url) || opened }
        return opened
    }
    private func loadProject(_ url: URL) async -> Bool {
        if let existing = tabs.first(where: { tab in
            [tab.session.projectURL, tab.session.photoshopSource].contains { $0?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }
        }) {
            select(existing.id); return true
        }
        // A Photoshop file is imported into a tab of its own, through the conversion sheet; it is never a package.
        if PSDReader.matches(url) {
            let tab = addTab()
            selectedID = tab.id
            await tab.session.importImages([url])
            if tab.session.document != nil { RecentProjects.shared.note(url); return true }
            if tabs.count > 1 { removeTab(tab.id) }
            return false
        }
        // Load into an unattached session, so a failed open never leaves a broken tab.
        let tab = ProjectTab(name: url.deletingPathExtension().lastPathComponent)
        tab.controller.window = current.controller.window
        guard await tab.controller.open(url) else { return false }
        // Into the blank start's place: a tab beside it, then the blank one closed, so it's as if it had been replaced.
        let blank = blankStart
        append(tab, beside: blank ?? current)
        if let blank { removeTab(blank.id) }
        return true
    }
    /// Closes a project's tab (or window), first settling what's in progress in it as Quit does, then asking about
    /// unsaved changes.
    func close(_ id: UUID) async {
        guard !isManaging, let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.session.textDraft != nil { guard tab.session.finishText() else { return } }
        await settlePendingEdits(in: tab)
        guard isIdle(tab) else { NSSound.beep(); return }
        isManaging = true
        defer { isManaging = false }
        guard await tab.controller.confirmQuit() else { return }
        removeTab(id)
    }
    /// Takes a project out and closes its window. With the last one gone a blank project waits, windowless, for the
    /// window the Dock or File › New brings back.
    func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        presenter?.close(tab)
        if tabs.isEmpty {
            let blank = ProjectTab(name: "Untitled")
            blank.controller.workspace = self
            tabs = [blank]; selectedID = blank.id
        } else if selectedID == id { selectedID = tabs[min(index, tabs.count-1)].id }
    }
    /// The order Quit asks about unsaved projects: the one on screen first, then the rest in the order they were
    /// opened, so it never jumps to another project before the one you're viewing.
    var quitOrder: [ProjectTab] { [current] + tabs.filter { $0.id != current.id } }
    private func finishTextEditing() -> Bool {
        for tab in quitOrder where tab.session.textDraft != nil {
            guard tab.session.finishText() else { return false }
        }
        return true
    }
    /// Readies a project for quitting or closing, rather than refusing over what's in progress. Edits on the canvas
    /// (a gradient waiting for Apply, pixels being moved) are applied, as switching tools does; an open dialog (a
    /// filter, Levels, Hue/Saturation, the color picker…) is cancelled, as its Cancel button would, so nothing is
    /// applied that wasn't OK'd.
    func settlePendingEdits(in tab: ProjectTab) async {
        let session = tab.session
        if session.gradientEdit != nil { await session.commitGradient() }
        if session.pixelMove != nil { await session.finishPixelMove() }
        session.cancelFilter()
        session.cancelHueSaturation()
        session.cancelLevels()
        session.finishAdjustmentEditing(commit: false)
        session.cancelColorRange()
        session.selectionAmountOperation = nil
        if session.colorPicker != nil { session.closeColorPicker(commit: false) }
    }
    func confirmQuit() async -> Bool {
        guard !isManaging, finishTextEditing() else { return false }
        for tab in quitOrder {
            await settlePendingEdits(in: tab)
            guard isIdle(tab) else { NSSound.beep(); return false }
        }
        isManaging = true; defer { isManaging = false }
        for tab in quitOrder {
            // Its window to the front, so the question about it is asked where it can be seen.
            select(tab.id)
            guard await tab.controller.confirmQuit() else { return false }
        }
        return true
    }

    /// Capture the destination before asynchronous provider loading. Dock/new-tab
    /// drops create one project per image; existing-tab drops add image layers.
    func receive(_ urls: [URL], into destination: UUID? = nil, at point: CGPoint? = nil) async {
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { for (url, scoped) in files where scoped { url.stopAccessingSecurityScopedResource() } }
        while isManaging || destination.flatMap({ id in tabs.first { $0.id == id } }).map({ !isIdle($0) }) == true {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        isManaging = true; defer { isManaging = false }
        for url in urls {
            if ProjectManifest.extensions.contains(url.pathExtension.lowercased()) { _ = await loadProject(url); continue }
            let tab: ProjectTab
            if let destination {
                guard let existing = tabs.first(where: { $0.id == destination }) else { continue }
                tab = existing
            } else { tab = addTab() }
            select(tab.id)
            await tab.session.importImages([url], at: point)
        }
    }
    func receiveProviders(_ providers: [NSItemProvider], into destination: UUID? = nil, at point: CGPoint? = nil) async {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(Self.layerType) {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: Self.layerType) { data, _ in continuation.resume(returning: data) }
                }
                if let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    await copyLayer(id, into: destination, at: point)
                }
            } else {
                await ImageFileDrop.importProviders([provider], into: current.session, at: point, workspace: self, destination: destination)
            }
        }
    }
    static let layerType = "net.pixegen.pixelbox.layer-row"
    /// Cmd-V with a whole layer copied: pastes it complete — a copy above it in its own project, or brought over as
    /// dragging it onto this tab does. False when there is none, and Paste goes on with pixels.
    func pasteCopiedLayer() -> Bool {
        let count = EditorSession.pasteboard.changeCount
        guard let source = tabs.first(where: { $0.session.copiedLayer?.changeCount == count }),
              let copied = source.session.copiedLayer?.ids, let layers = source.session.document?.layers else { return false }
        let ids = copied.filter { id in layers.contains { $0.id == id } }
        guard !ids.isEmpty else { return false }
        if source.id == selectedID {
            guard source.session.canEditLayers else { return false }
            source.session.duplicateLayers(ids, editName: "Paste")
            return true
        }
        let destination = selectedID
        Task { await copyLayers(ids, into: destination) }
        return true
    }
    func copyLayer(_ id: UUID, into destination: UUID?, at point: CGPoint? = nil) async {
        await copyLayers([id], into: destination, at: point)
    }
    /// Copies layers (folders with all they hold) into another project, or a new one, as one undo step there. Several
    /// keep where they sit relative to each other, centered on `point` or the canvas as a whole.
    func copyLayers(_ ids: [UUID], into destination: UUID?, at point: CGPoint? = nil) async {
        guard let id = ids.first, !isManaging, let sourceTab = tabs.first(where: { $0.session.document?.layers.contains(where: { $0.id == id }) == true }),
              sourceTab.session.canEditLayers, let snapshot = sourceTab.session.projectSnapshot(),
              let sourceDocument = sourceTab.session.document else { return }
        if let destination, destination == sourceTab.id { return }
        let target: ProjectTab
        if let destination {
            guard let existing = tabs.first(where: { $0.id == destination }), existing.session.canStartProjectOperation else { return }
            target = existing
        } else { target = addTab(reuseEmpty: false) }
        guard target.session.document == nil || target.session.canEditLayers else { return }
        let included = ids.reduce(into: Set(ids)) { $0.formUnion(sourceTab.session.descendantIDs(of: $1)) }
        var copied = sourceDocument.layers.filter { included.contains($0.id) }
        let used = target.session.document?.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0
        let added = copied.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) }
        guard used + added <= DocumentLimits.documentPixelBudget else { target.session.importError = "The copied layers exceed this project’s \(DocumentLimits.documentBudgetMegapixels)-megapixel limit."; return }
        isManaging = true
        sourceTab.session.isProjectBusy = true
        target.session.isProjectBusy = true
        defer {
            isManaging = false
            sourceTab.session.isProjectBusy = false
            target.session.isProjectBusy = false
        }
        do {
            for i in copied.indices where copied[i].maskSourceID.map({ !included.contains($0) }) == true {
                if copied[i].adjustment != nil { copied[i].maskSourceID = nil; continue }
                let layerID = copied[i].id
                copied[i].asset = try await Task.detached(priority: .userInitiated) { try LiveMaskBaker.bake(snapshot, target: layerID) }.value
                copied[i].maskSourceID = nil
            }
            let mapping = Dictionary(uniqueKeysWithValues: copied.map { ($0.id, UUID()) })
            let pictured = copied.filter { !$0.isGroup }.map { CGRect(origin: $0.transform.origin, size: $0.transform.size) }
            // A new project is the size of the pixels dragged in (turned as they're shown), not of the canvas they
            // came from; layers with none of their own (adjustments, blank layers) don't count.
            let drawn = copied.filter { !$0.isGroup && $0.adjustment == nil && ($0.asset != nil || $0.text != nil) }.map { layer in
                let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(layer.transform.point)
                let xs = corners.map(\.x), ys = corners.map(\.y)
                return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            let fitted = target.session.document == nil && !drawn.isEmpty
                ? drawn.dropFirst().reduce(drawn[0]) { $0.union($1) }.integral : nil
            let size = target.session.document?.size ?? fitted.map {
                CGSize(width: min(CGFloat(DocumentLimits.maxSide), $0.width), height: min(CGFloat(DocumentLimits.maxSide), $0.height))
            } ?? sourceDocument.size
            let anchor = fitted.map { CGPoint(x: $0.midX, y: $0.midY) } ?? (ids.count == 1 || pictured.isEmpty
                ? copied.first(where: { $0.id == id })?.transform.center ?? CGPoint(x: sourceDocument.size.width/2, y: sourceDocument.size.height/2)
                : { let r = pictured.dropFirst().reduce(pictured[0]) { $0.union($1) }; return CGPoint(x: r.midX, y: r.midY) }())
            let center = fitted == nil ? point ?? CGPoint(x: size.width/2, y: size.height/2) : CGPoint(x: size.width/2, y: size.height/2)
            let layers = copied.map { layer -> ImageLayer in
                var transform = layer.transform
                transform.origin.x += center.x-anchor.x; transform.origin.y += center.y-anchor.y
                var mask = layer.mask
                mask?.placement?.origin.x += center.x-anchor.x; mask?.placement?.origin.y += center.y-anchor.y
                return ImageLayer(id: mapping[layer.id]!, asset: layer.asset, name: layer.name, isVisible: layer.isVisible,
                    transform: transform, parentID: layer.parentID.flatMap { mapping[$0] }, isGroup: layer.isGroup,
                    opacity: layer.opacity, blendMode: layer.blendMode, mask: mask, maskSourceID: layer.maskSourceID.flatMap { mapping[$0] }, adjustment: layer.adjustment, shape: layer.shape, effects: layer.effects, text: layer.text)
            }
            target.session.isProjectBusy = false
            target.session.beginEdit("Copy Layers from Project")
            if target.session.document == nil { target.session.createDocument(width: Int(size.width), height: Int(size.height)) }
            target.session.document?.layers.append(contentsOf: layers)
            target.session.activeLayerID = mapping[id]
            target.session.selectedLayerIDs = Set(ids.compactMap { mapping[$0] })
            target.session.endEdit()
            select(target.id)
        } catch { target.session.importError = error.localizedDescription }
    }
}

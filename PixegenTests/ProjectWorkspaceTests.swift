import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Pixegen

@MainActor struct ProjectWorkspaceTests {
    @Test func newCanvasOpensAnEmptyTabWithoutAModal() {
        let workspace = ProjectWorkspace()
        let original = workspace.current
        original.session.createDocument(width: 4000, height: 3000)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current !== original)
        #expect(workspace.current.session.document == nil)
        #expect(!workspace.current.session.showsNewDocument)
        #expect(workspace.isIdle(workspace.current))
        #expect(original.session.document?.size.width == 4000)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 3)
        #expect(!workspace.current.session.showsNewDocument)
    }

    /// A gradient waiting for Apply used to leave Quit and the close button doing nothing at all; quitting applies it.
    @Test func quittingAppliesAPendingGradient() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 100, height: 20)
        session.addBlankLayer()
        session.selectTool(.gradient)
        session.beginGradient(at: CGPoint(x: 0, y: 10))
        session.moveGradient(end: CGPoint(x: 100, y: 10))
        session.endGradientDrag()
        #expect(!workspace.isIdle(workspace.current))
        let count = session.history.undoCount
        await workspace.settlePendingEdits(in: workspace.current)
        #expect(session.gradientEdit == nil)
        #expect(session.history.undoCount == count + 1)
        #expect(workspace.isIdle(workspace.current))
    }

    /// An open dialog used to block Quit too; quitting cancels it, leaving the layer as it was.
    @Test func quittingCancelsAnOpenDialog() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 100, height: 20)
        session.insert(try LiveMaskTests().asset([200, 100, 50, 255]))
        let original = session.activeLayer?.asset?.image
        for open in [{ session.beginFilter(.gaussianBlur) }, { session.beginHueSaturation() }, { session.beginLevels() }] {
            open()
            #expect(!workspace.isIdle(workspace.current))
            await workspace.settlePendingEdits(in: workspace.current)
            #expect(workspace.isIdle(workspace.current))
            #expect(session.activeLayer?.asset?.image === original)
        }
    }

    @Test func layerDropProviderCopiesIntoANewProject() async throws {
        let workspace = ProjectWorkspace()
        let source = workspace.current
        source.session.createDocument(width: 100, height: 100)
        source.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        let id = try #require(source.session.activeLayerID)
        let provider = NSItemProvider(item: Data(id.uuidString.utf8) as NSData, typeIdentifier: ProjectWorkspace.layerType)
        await workspace.receiveProviders([provider])
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current.id != source.id)
        #expect(workspace.current.session.document?.layers.count == 1)
        #expect(workspace.current.session.activeLayerID != id)
        #expect(source.session.document?.layers.first?.id == id)
    }

    /// New tabs take the lowest free Untitled number, so closing the last project gives "Untitled" again rather than
    /// counting up (issue #231).
    @Test func untitledNumbersStayLow() {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        #expect(first.title == "Untitled")
        first.session.createDocument(width: 10, height: 10)
        let second = workspace.addTab(), third = workspace.addTab()
        #expect(second.title == "Untitled 2" && third.title == "Untitled 3")
        workspace.removeTab(second.id)
        #expect(workspace.addTab().title == "Untitled 2", "the lowest free number")
        for tab in workspace.tabs { workspace.removeTab(tab.id) }
        #expect(workspace.tabs.count == 1 && workspace.current.title == "Untitled", "the last tab closed leaves Untitled")
    }

    @Test func tabsKeepIndependentDocumentsAndUndo() throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 4000, height: 4000)
        first.session.addBlankLayer()
        let second = workspace.addTab()
        second.session.createDocument(width: 640, height: 480)
        second.session.addBlankLayer()
        second.session.undo()
        #expect(first.session.document?.layers.count == 1)
        #expect(second.session.document?.layers.isEmpty == true)
        workspace.select(first.id)
        #expect(workspace.current === first)
        #expect(first.session.document?.size.width == 4000)
        workspace.removeTab(second.id)
        #expect(workspace.current === first)
        workspace.removeTab(first.id)
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil)
    }

    @Test func crossProjectCopyRemapsIdentityAndHasIndependentUndo() async throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 100, height: 100)
        first.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        let original = try #require(first.session.activeLayerID)
        let second = workspace.addTab()
        second.session.createDocument(width: 200, height: 200)
        await workspace.copyLayer(original, into: second.id)
        let copied = try #require(second.session.document?.layers.first)
        #expect(copied.id != original)
        #expect(copied.transform.center == CGPoint(x: 100, y: 100))
        #expect(first.session.document?.layers.count == 1)
        second.session.undo()
        #expect(second.session.document?.layers.isEmpty == true)
        #expect(first.session.document?.layers.count == 1)
        second.session.redo()
        #expect(second.session.document?.layers.first?.id == copied.id)
    }

    /// A layer dragged into a new project tab makes a canvas its own size, with it filling it, not the size of the
    /// canvas it came from.
    @Test func aLayerDraggedIntoANewTabSizesTheCanvasToIt() async throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 400, height: 300)
        let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let image = try #require(context.makeImage())
        first.session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"), centeredAt: CGPoint(x: 300, y: 100))
        let original = try #require(first.session.activeLayerID)
        await workspace.copyLayer(original, into: nil)
        let created = workspace.current
        #expect(created !== first)
        #expect(created.session.document?.size == CGSize(width: 120, height: 80))
        #expect(created.session.document?.layers.first?.transform.origin == .zero)
    }

    @Test func dockCreatesTabsAndTargetedImportUsesExistingTab() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        await workspace.receive([url, url])
        #expect(workspace.tabs.count == 2)
        let first = workspace.tabs[0]
        await workspace.receive([url], into: first.id)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current === first)
        #expect(first.session.document?.layers.count == 2)
        #expect(workspace.tabs[1].session.document?.layers.count == 1)
    }

    /// Quit asks about the project on screen first, then the others in the order they were opened.
    @Test @MainActor func quitAsksAboutTheActiveTabFirst() {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        let second = workspace.addTab(reuseEmpty: false)
        let third = workspace.addTab(reuseEmpty: false)
        workspace.select(second.id)
        #expect(workspace.quitOrder.map(\.id) == [second.id, first.id, third.id])
        workspace.select(third.id)
        #expect(workspace.quitOrder.map(\.id) == [third.id, first.id, second.id])
        workspace.select(first.id)
        #expect(workspace.quitOrder.map(\.id) == [first.id, second.id, third.id])
    }

    /// A new canvas goes in a tab beside the front project's window; New Window gives it a window of its own.
    @Test func newCanvasOpensBesideTheFrontWindowAndNewWindowStandsAlone() {
        let workspace = ProjectWorkspace()
        let windows = RecordingPresenter()
        workspace.presenter = windows
        let first = workspace.current
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let second = workspace.current
        #expect(windows.shown.last?.tab === second && windows.shown.last?.neighbor === first)
        workspace.newWindow()
        let third = workspace.current
        #expect(third !== second && windows.shown.last?.tab === third && windows.shown.last?.neighbor == nil)
    }

    /// Whichever window becomes main, by a click on its tab or otherwise, is the project the menus act on.
    @Test func theMainWindowsProjectIsCurrent() {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        let second = workspace.addTab(reuseEmpty: false)
        #expect(workspace.current === second)
        workspace.activate(first.controller)
        #expect(workspace.current === first)
        workspace.activate(ProjectController(session: EditorSession()))
        #expect(workspace.current === first, "a controller that isn't the workspace's changes nothing")
    }

    /// Images dropped on the Dock go into the blank start rather than leaving it behind as an empty tab.
    @Test func dropsFillTheBlankStartBeforeOpeningTabs() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        let windows = RecordingPresenter()
        workspace.presenter = windows
        let blank = workspace.current
        await workspace.receive([url, url])
        #expect(workspace.tabs.count == 2 && workspace.tabs[0] === blank)
        #expect(windows.shown.contains { $0.tab === workspace.tabs[1] && $0.neighbor === blank })
        #expect(windows.closed.isEmpty)
    }

    /// Closing a project closes its window; closing the last leaves a blank project with no window, which is the one
    /// put up again when the app is brought back.
    @Test func closingTheLastProjectLeavesABlankOneWithoutAWindow() {
        let workspace = ProjectWorkspace()
        let windows = RecordingPresenter()
        workspace.presenter = windows
        let first = workspace.current
        let second = workspace.addTab(reuseEmpty: false)
        workspace.removeTab(second.id)
        #expect(windows.closed.map(\.id) == [second.id] && workspace.current === first)
        workspace.removeTab(first.id)
        #expect(windows.closed.map(\.id) == [second.id, first.id])
        let blank = workspace.current
        #expect(blank !== first && blank.session.document == nil && !windows.shown.contains { $0.tab === blank })
        workspace.newCanvas()
        #expect(workspace.tabs.count == 1 && workspace.current === blank, "File › New puts it up rather than adding another")
        #expect(windows.shown.last?.tab === blank)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 2 && windows.shown.last?.neighbor === blank, "once it's up, a new tab beside it")
    }

    /// A layer dragged over the project it lives in has nowhere to go; any other project, or a new one, takes it.
    @Test func aLayerCanBeDroppedOnlyOnAnotherProject() throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 10, height: 10)
        first.session.addBlankLayer()
        let layer = try #require(first.session.activeLayerID)
        let second = workspace.addTab(reuseEmpty: false)
        #expect(!workspace.canReceiveDrag(into: first.id, layer: layer))
        #expect(workspace.canReceiveDrag(into: second.id, layer: layer))
        #expect(workspace.canReceiveDrag(into: nil, layer: layer))
    }

    /// Paste of a layer copied in another project brings it over, as dragging it there does.
    @Test func pastingALayerCopiedInAnotherProjectCopiesItThere() async throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 100, height: 100)
        first.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        first.session.copySelection()
        let second = workspace.addTab(reuseEmpty: false)
        second.session.createDocument(width: 100, height: 100)
        #expect(workspace.pasteCopiedLayer())
        for _ in 0..<100 where second.session.document?.layers.isEmpty != false { try await Task.sleep(for: .milliseconds(10)) }
        #expect(second.session.document?.layers.count == 1)
        #expect(second.session.document?.layers.first?.id != first.session.activeLayerID)
    }
}

/// Stands in for the windows: what was put on screen, and beside what, and what was closed; and the windows' tab groups.
@MainActor
final class RecordingPresenter: ProjectWindowPresenting {
    var shown: [(tab: ProjectTab, neighbor: ProjectTab?)] = []
    var closed: [ProjectTab] = []
    var groups: [[ProjectTab]] = []
    func show(_ tab: ProjectTab, beside neighbor: ProjectTab?) {
        shown.append((tab, neighbor))
        guard !groups.contains(where: { $0.contains { $0 === tab } }) else { return }
        if let neighbor, let index = groups.firstIndex(where: { $0.contains { $0 === neighbor } }) {
            groups[index].append(tab)
        } else { groups.append([tab]) }
    }
    func close(_ tab: ProjectTab) {
        closed.append(tab)
        groups = groups.map { $0.filter { $0 !== tab } }.filter { !$0.isEmpty }
    }
    func group(of tab: ProjectTab) -> [ProjectTab] { groups.first { $0.contains { $0 === tab } } ?? [tab] }
    func move(_ tab: ProjectTab, to index: Int) {
        guard let g = groups.firstIndex(where: { $0.contains { $0 === tab } }) else { return }
        groups[g].removeAll { $0 === tab }
        groups[g].insert(tab, at: min(index, groups[g].count))
    }
    func moveToNewWindow(_ tab: ProjectTab) {
        groups = groups.map { $0.filter { $0 !== tab } }.filter { !$0.isEmpty } + [[tab]]
    }
    func hasWindow(_ tab: ProjectTab) -> Bool {
        shown.contains { $0.tab === tab } && !closed.contains { $0 === tab }
    }
}

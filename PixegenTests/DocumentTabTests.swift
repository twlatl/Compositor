import AppKit
import Testing
@testable import Pixegen

/// What the document tabs show, and closing several at once.
@MainActor struct DocumentTabTests {
    private func make() -> (ProjectWorkspace, RecordingPresenter) {
        let workspace = ProjectWorkspace()
        let presenter = RecordingPresenter()
        workspace.presenter = presenter
        presenter.show(workspace.current, beside: nil)
        return (workspace, presenter)
    }

    @Test func aTabShowsItsZoomOnceThereIsACanvas() {
        let workspace = ProjectWorkspace()
        let tab = workspace.current
        #expect(tab.zoomLabel == nil)
        tab.session.createDocument(width: 100, height: 100)
        tab.session.zoom(to: 0.5)
        #expect(tab.zoomLabel == "@ 50%")
        tab.session.zoom(to: 2.738)
        #expect(tab.zoomLabel == "@ 273.8%")
    }

    @Test func closeOtherTabsLeavesOtherWindowsAlone() async {
        let (workspace, presenter) = make()
        let first = workspace.current
        let second = workspace.addTab(reuseEmpty: false)
        let third = workspace.addTab(reuseEmpty: false)
        workspace.newWindow()
        let elsewhere = workspace.current
        #expect(presenter.group(of: first).count == 3)

        await workspace.closeOthers(second.id)
        #expect(workspace.tabs.map(\.id) == [second.id, elsewhere.id])
        #expect(presenter.closed.contains { $0 === first } && presenter.closed.contains { $0 === third })
    }

    @Test func theCloseButtonClosesEveryTabInTheWindow() async {
        let (workspace, presenter) = make()
        let first = workspace.current
        _ = workspace.addTab(reuseEmpty: false)
        workspace.newWindow()
        let elsewhere = workspace.current

        let second = presenter.groups[0][1]
        #expect(presenter.groups.map { $0.map(\.id) } == [[first.id, second.id], [elsewhere.id]])
        await workspace.closeWindow(of: first.id)
        #expect(presenter.closed.map(\.id) == [first.id, second.id])
        #expect(workspace.tabs.map(\.id) == [elsewhere.id])
    }
}

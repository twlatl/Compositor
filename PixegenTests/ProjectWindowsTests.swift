import AppKit
import Testing
@testable import Pixegen

/// Projects in real windows, as tabs of Pixegen's own: several to a window, one shown at a time.
@MainActor
@Suite(.serialized)
struct ProjectWindowsTests {
    @Test func newCanvasOpensATabAndNewWindowAWindowOfItsOwn() async throws {
        let (workspace, windows) = make()
        defer { for tab in workspace.tabs { windows.close(tab) } }
        let first = workspace.current
        windows.show(first, beside: nil)
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let second = workspace.current
        let window = try #require(windows.window(for: first) as? ProjectWindow)
        #expect(windows.window(for: second) === window)
        #expect(window.tabs.list.map(\.id) == [first.id, second.id])
        #expect(window.tabs.selected === second && window.tabView.selectedTabViewItemIndex == 1)
        // AppKit's own tabs, whose bar can't be hidden, are off.
        #expect(window.tabbingMode == .disallowed && window.tabbedWindows == nil)

        workspace.newWindow()
        let third = try #require(windows.window(for: workspace.current))
        #expect(third !== window)
        #expect(workspace.tabsGrouped(with: first).map(\.id) == [first.id, second.id])
        #expect(workspace.tabsGrouped(with: workspace.current).count == 1)
    }

    /// The window's title is the shown project's name, for the Window menu; the toolbar shows the app's.
    @Test func theWindowIsTitledByTheTabShown() async throws {
        let (workspace, windows) = make()
        defer { for tab in workspace.tabs { windows.close(tab) } }
        let first = workspace.current
        windows.show(first, beside: nil)
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let window = try #require(windows.window(for: first))
        for _ in 0..<50 where window.title != "Untitled 2" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(window.title == "Untitled 2")
        workspace.select(first.id)
        for _ in 0..<50 where window.title != "Untitled" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(window.title == "Untitled")
        #expect(window.toolbar != nil && window.titleVisibility == .hidden)
    }

    /// A tab that isn't shown keeps its view, out of the window, so its canvas takes no keys or clicks meant for
    /// the one shown.
    @Test func onlyTheShownTabsViewIsInTheWindow() throws {
        let (workspace, windows) = make()
        defer { for tab in workspace.tabs { windows.close(tab) } }
        let first = workspace.current
        windows.show(first, beside: nil)
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let window = try #require(windows.window(for: first) as? ProjectWindow)
        let views = window.tabView.tabViewItems.compactMap(\.viewController)
        #expect(views.count == 2)
        #expect(views[0].view.window == nil && views[1].view.window === window)
        workspace.select(first.id)
        #expect(views[0].view.window === window && views[1].view.window == nil)
        #expect(window.tabView.tabViewItems.compactMap(\.viewController) == views, "switching keeps each tab's view")
    }

    /// Choosing a tab, or a window becoming main, makes its project the one the menus act on; closing the tab shown
    /// brings the next forward, and closing the last closes the window.
    @Test func theMenusFollowTheShownTabAndClosingOneShowsTheNext() throws {
        let (workspace, windows) = make()
        defer { for tab in workspace.tabs { windows.close(tab) } }
        let first = workspace.current
        windows.show(first, beside: nil)
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let second = workspace.current
        let window = try #require(windows.window(for: first) as? ProjectWindow)
        workspace.select(first.id)
        #expect(workspace.current === first && window.tabs.selected === first)
        workspace.select(second.id)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(workspace.current === second)
        workspace.removeTab(second.id)
        #expect(windows.window(for: second) == nil)
        #expect(window.tabs.selected === first && window.tabView.tabViewItems.count == 1)
        #expect(workspace.current === first)
    }

    @Test func tabsReorderMoveOutAndMergeBack() throws {
        let (workspace, windows) = make()
        defer { for tab in workspace.tabs { windows.close(tab) } }
        let first = workspace.current
        windows.show(first, beside: nil)
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let second = workspace.current
        workspace.newCanvas()
        let third = workspace.current
        let window = try #require(windows.window(for: first) as? ProjectWindow)

        windows.move(third, to: 0)
        #expect(window.tabs.list.map(\.id) == [third.id, first.id, second.id])
        #expect(window.tabView.tabViewItems.map { $0.identifier as? UUID } == [third.id, first.id, second.id])
        #expect(window.tabs.selected === third, "moving a tab doesn't change the one shown")

        // ⌃Tab and ⌃⇧Tab go round the window's tabs.
        window.selectNextTab(nil)
        #expect(window.tabs.selected === first && workspace.current === first)
        window.selectPreviousTab(nil)
        window.selectPreviousTab(nil)
        #expect(window.tabs.selected === second)

        windows.moveToNewWindow(second)
        let other = try #require(windows.window(for: second) as? ProjectWindow)
        #expect(other !== window && other.tabs.list.count == 1)
        #expect(window.tabs.list.map(\.id) == [third.id, first.id])
        #expect(workspace.current === second)

        window.mergeAllWindows(nil)
        #expect(window.tabs.list.map(\.id) == [third.id, first.id, second.id])
        #expect(windows.window(for: second) === window && !other.isVisible)
    }

    private func make() -> (ProjectWorkspace, ProjectWindows) {
        let delegate = PixegenApplicationDelegate()
        delegate.workspace.presenter = delegate.windows
        // Its windows only know it `unowned`, and the workspace its windows only weakly: kept for the whole run.
        Self.delegates.append(delegate)
        return (delegate.workspace, delegate.windows)
    }
    private static var delegates: [PixegenApplicationDelegate] = []
}

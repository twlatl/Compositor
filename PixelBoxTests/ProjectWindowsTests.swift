import AppKit
import Testing
@testable import PixelBox

/// Projects in real windows, grouped as native macOS tabs.
@MainActor
@Suite(.serialized)
struct ProjectWindowsTests {
    @Test func newCanvasOpensANativeTabAndNewWindowAWindowOfItsOwn() async throws {
        let (workspace, windows) = make()
        defer { for tab in workspace.tabs { windows.close(tab) } }
        let first = workspace.current
        windows.show(first, beside: nil)
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let second = workspace.current
        let firstWindow = try #require(windows.window(for: first)), secondWindow = try #require(windows.window(for: second))
        #expect(firstWindow.tabbedWindows?.count == 2)
        #expect(firstWindow.tabGroup === secondWindow.tabGroup && firstWindow.tabGroup?.selectedWindow === secondWindow)
        // The tab bar's + is AppKit's, offered because the window answers it.
        #expect(secondWindow.responds(to: #selector(NSResponder.newWindowForTab(_:))))

        workspace.newWindow()
        let thirdWindow = try #require(windows.window(for: workspace.current))
        #expect(thirdWindow.tabGroup !== firstWindow.tabGroup && thirdWindow.tabbedWindows == nil)
        #expect(firstWindow.tabbedWindows?.count == 2)
    }

    /// The window's title, and so its tab's, is the project's name; the editor's toolbar comes over from SwiftUI.
    @Test func tabsAreTitledByTheirProjects() async throws {
        let (workspace, windows) = make()
        defer { for tab in workspace.tabs { windows.close(tab) } }
        let first = workspace.current
        windows.show(first, beside: nil)
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let firstWindow = try #require(windows.window(for: first)), secondWindow = try #require(windows.window(for: workspace.current))
        for _ in 0..<50 where secondWindow.title != "Untitled 2" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(firstWindow.title == "Untitled" && secondWindow.title == "Untitled 2")
        #expect(firstWindow.toolbar != nil)
    }

    /// Choosing a tab (or any project's window becoming main) makes it the project the menus act on; closing a tab
    /// takes it out of the group.
    @Test func theMenusFollowTheMainWindowAndClosingATabUngroupsIt() throws {
        let (workspace, windows) = make()
        defer { for tab in workspace.tabs { windows.close(tab) } }
        let first = workspace.current
        windows.show(first, beside: nil)
        first.session.createDocument(width: 10, height: 10)
        workspace.newCanvas()
        let second = workspace.current
        let firstWindow = try #require(windows.window(for: first))
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: firstWindow)
        #expect(workspace.current === first)
        workspace.removeTab(second.id)
        #expect(windows.window(for: second) == nil)
        #expect(firstWindow.tabbedWindows == nil || firstWindow.tabbedWindows?.count == 1)
    }

    private func make() -> (ProjectWorkspace, ProjectWindows) {
        let delegate = PixelBoxApplicationDelegate()
        delegate.workspace.presenter = delegate.windows
        // Its windows only know it `unowned`, and the workspace its windows only weakly: kept for the whole run.
        Self.delegates.append(delegate)
        return (delegate.workspace, delegate.windows)
    }
    private static var delegates: [PixelBoxApplicationDelegate] = []
}

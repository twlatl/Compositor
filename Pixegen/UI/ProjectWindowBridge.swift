import AppKit
import SwiftUI

/// Intercepts only close approval and forwards SwiftUI's other window callbacks.
struct ProjectWindowBridge: NSViewRepresentable {
    let controller: ProjectController
    /// What the close button does; closing the controller's project when not given.
    var onClose: ((NSWindow) async -> Void)? = nil
    func makeNSView(context: Context) -> ProjectWindowView { ProjectWindowView(controller: controller) }
    func updateNSView(_ view: ProjectWindowView, context: Context) {
        view.update(controller, onClose: onClose)
        view.window?.representedURL = controller.session.projectURL
        view.window?.isDocumentEdited = controller.session.isModified
    }
}

final class ProjectWindowView: NSView {
    var controller: ProjectController
    private let proxy = ProjectWindowDelegate()
    init(controller: ProjectController) {
        self.controller = controller
        super.init(frame: .zero)
        proxy.controller = controller
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ controller: ProjectController, onClose: ((NSWindow) async -> Void)?) {
        self.controller = controller
        proxy.controller = controller
        proxy.onClose = onClose
        controller.window = window
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.controller.window = window
            if window.delegate !== self.proxy {
                self.proxy.previous = window.delegate
                window.delegate = self.proxy
            }
        }
    }
}

private final class ProjectWindowDelegate: NSObject, NSWindowDelegate {
    weak var previous: NSWindowDelegate?
    weak var controller: ProjectController?
    var onClose: ((NSWindow) async -> Void)?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let onClose { Task { await onClose(sender) }; return false }
        guard let controller else { return true }
        Task { await controller.close(sender) }
        return false
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
    }
}

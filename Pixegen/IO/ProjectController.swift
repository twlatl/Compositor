import AppKit
import UniformTypeIdentifiers
import SwiftUI

@MainActor
final class ProjectController {
    let session: EditorSession
    weak var window: NSWindow?
    weak var workspace: ProjectWorkspace?
    private var saveGeneration = 0
    /// Keeps the document in step with its package when something else writes it. See ProjectController+ExternalChanges.
    let externalChanges = ExternalChangeState()
    var canStart: Bool {
        session.canStartProjectOperation && workspace?.isManaging != true
    }
    init(session: EditorSession) { self.session = session }

    private func begin() -> Bool {
        guard session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        return true
    }

    @discardableResult
    func save(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return false }
        // Another save still writing finishes first; then this one saves whatever has changed since.
        await finishWriting()
        guard begin() else { return false }
        let prepared = await prepareSave(asNew: asNew)
        // Only the snapshot (and the Save panel) holds the tools. The document is captured, so editing can go on
        // while the package is written in the background, as in Photoshop.
        session.isProjectBusy = false
        guard let prepared else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision)
    }

    /// The save still writing, if any. Close, quit and replacing the document wait for it.
    private var writing: Task<Bool, Never>?
    func finishWriting() async { if let writing { _ = await writing.value } }

    /// File › Export PNG…: the flattened canvas, lossless, straight to a save panel.
    func exportPNG() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        guard let url = await savePanel(for: .png) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await ImageExporter.shared.exportPNG(snapshot, to: url) }
        catch { await showError("Couldn’t export PNG", error: error) }
    }

    /// File › Export As…: PNG, JPEG or a one-page PDF, at the canvas's size or scaled, previewed first. Export JPEG…
    /// opens it on JPEG.
    func exportAs(start: ExportFormat? = nil) async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            // With a 16-bit layer in it, a PNG can be written at 16 bits a channel too.
            let deepRaster = snapshot.images.values.contains { $0.deep != nil }
                ? try await ImageExporter.shared.render(snapshot, sixteenBit: true) : nil
            // With an HDR layer in it, it can go out as an EXR, light brighter than white kept.
            let hdrRaster = snapshot.images.values.contains { $0.isHDR }
                ? try await ImageExporter.shared.render(snapshot, sixteenBit: true, hdr: true) : nil
            let chosen: (data: Data, format: ExportFormat)? = await withCheckedContinuation { continuation in
                let sheet = NSWindow()
                sheet.styleMask = [.titled, .fullSizeContentView]
                sheet.title = "Export As"
                sheet.contentViewController = NSHostingController(rootView: ExportAsSheet(
                    raster: raster, deepRaster: deepRaster, hdrRaster: hdrRaster, session: session,
                    format: start ?? lastExportFormat) { chosen in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    // Release the hosted view and its closure after dismissal.
                    sheet.contentViewController = nil
                    continuation.resume(returning: chosen)
                })
                window.beginSheet(sheet)
            }
            guard let chosen else { return }
            lastExportFormat = chosen.format
            guard let url = await savePanel(for: chosen.format) else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await ImageExporter.shared.write(chosen.data, to: url)
        } catch { await showError("Couldn’t export", error: error) }
    }

    /// The Export panel's Export…: every slice in each of its formats, into a folder chosen here.
    func exportSlices() async {
        guard let slices = session.document?.slices, !slices.isEmpty, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Export Slices"
        panel.prompt = "Export"
        panel.message = "Choose a folder for the slices."
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let folder = panel.url else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let existing = SliceExporter.destinations(for: slices, in: folder).map(\.0)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = existing.count == 1 ? "Replace “\(existing[0].lastPathComponent)”?"
                : "Replace \(existing.count) files in “\(folder.lastPathComponent)”?"
            alert.informativeText = existing.count == 1 ? "A file with that name is already in the folder."
                : existing.prefix(5).map(\.lastPathComponent).joined(separator: ", ") + (existing.count > 5 ? ", …" : "")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            let answer: NSApplication.ModalResponse
            if let window { answer = await alert.beginSheetModal(for: window) } else { answer = alert.runModal() }
            guard answer == .alertFirstButtonReturn else { return }
        }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            _ = try await SliceExporter.shared.export(slices, composite: raster.image, to: folder)
            session.isProjectBusy = false
            session.closeExportPanel()
        } catch { await showError("Couldn’t export slices", error: error) }
    }

    /// The format Export As last used, offered first next time.
    private var lastExportFormat = ExportFormat.png

    /// Where an export goes: the project's name, with the format's extension.
    private func savePanel(for format: ExportFormat) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export " + format.rawValue
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            + "." + (format.type.preferredFilenameExtension ?? format.rawValue.lowercased())
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        return response == .OK ? panel.url : nil
    }
    func canvasSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: CanvasSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Canvas Size"
            sheet.contentViewController = NSHostingController(rootView: CanvasSizeSheet(document: document, session: session) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
            session.applyDocumentSize(resized, actionName: "Canvas Size")
        } catch { await showError("Couldn’t change canvas size", error: error) }
    }

    func imageSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: ImageSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Image Size"
            sheet.contentViewController = NSHostingController(rootView: ImageSizeSheet(document: document) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await ImageResizer.shared.resize(snapshot, to: options)
            session.applyImageSize(resized)
        } catch { await showError("Couldn’t resize the image", error: error) }
    }

    func trim() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: TrimOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Trim"
            sheet.contentViewController = NSHostingController(rootView: TrimSheet { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            guard let resized = try await ImageTrim.trim(snapshot, options: options) else {
                return
            }
            session.applyDocumentSize(resized, actionName: "Trim")
        } catch { await showError("Couldn’t trim image", error: error) }
    }

    /// View > Grid Settings…: changes only how the grid is drawn and snapped to, so nothing is saved or undone. The
    /// grid shows while the sheet is open, changing as it's edited, and goes back to how it was on Cancel.
    func gridSettings() async {
        guard let window, window.attachedSheet == nil else { return }
        let original = (grid: session.layoutGrid, appearance: session.gridAppearance, shown: session.showsGrid)
        session.showsGrid = true
        let settings: (LayoutGrid, GridAppearance)? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Grid"
            sheet.contentViewController = NSHostingController(rootView: GridSettingsSheet(
                session: session, grid: original.grid, appearance: original.appearance,
                preview: { [session] grid, appearance in
                    session.layoutGrid = grid
                    session.gridAppearance = appearance
                }) { settings in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    sheet.contentViewController = nil
                    continuation.resume(returning: settings)
                })
            window.beginSheet(sheet)
        }
        session.showsGrid = original.shown
        session.layoutGrid = settings?.0 ?? original.grid
        session.gridAppearance = settings?.1 ?? original.appearance
    }

    private func saveCurrent(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return true }
        guard let prepared = await prepareSave(asNew: asNew) else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision)
    }

    /// The document as it is now, and where it goes: asks with the Save panel when it has no file yet (or Save As).
    private func prepareSave(asNew: Bool) async -> (snapshot: ProjectSnapshot, destination: URL, revision: UUID)? {
        let revision = session.history.currentRevision
        guard let snapshot = session.projectSnapshot() else { return nil }
        var destination = asNew ? nil : session.projectURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = asNew ? "Save As" : "Save"
            // A document opened from a Photoshop file is offered back as one, beside it; replacing it still asks.
            let current = session.projectURL ?? session.photoshopSource
            if let folder = session.photoshopSource?.deletingLastPathComponent(), session.projectURL == nil {
                panel.directoryURL = folder
            }
            let picker = SaveFormatPicker(panel: panel, format: current.map(SaveFormat.init(for:)) ?? .pixegen,
                                          name: current?.deletingPathExtension().lastPathComponent ?? "Untitled")
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            withExtendedLifetime(picker) {}
            guard response == .OK, let url = panel.url else { return nil }
            destination = url
        }
        guard let destination else { return nil }
        return (snapshot, destination, revision)
    }

    /// Writes a captured document in the background. Only that captured version counts as saved.
    private func write(_ snapshot: ProjectSnapshot, to destination: URL, revision: UUID) async -> Bool {
        let task = Task { @MainActor [self] () -> Bool in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            // Our own save changes the package too; the watch ignores events until the saved bytes are remembered.
            externalChanges.saving = true
            defer { externalChanges.saving = false }
            do {
                if SaveFormat(for: destination) == .photoshop {
                    return try await writePhotoshop(snapshot, to: destination, revision: revision)
                }
                let quickLook = await ImageExporter.shared.quickLookImages(snapshot)
                try await ProjectStore.shared.save(snapshot, to: destination, quickLook: quickLook)
                session.projectURL = destination
                session.history.markSaved(revision)
                saveGeneration += 1
                RecentProjects.shared.note(destination)
                await rememberProjectDigest(for: destination)
                watchProject(at: destination)
                return true
            } catch {
                await showError("Couldn’t save the project", error: error)
                return false
            }
        }
        writing = task
        let saved = await task.value
        if writing == task { writing = nil }
        return saved
    }

    /// Saves as a Photoshop file. It isn't a package, so it isn't watched for changes, and a later Save writes it
    /// again. What changed on the way (text and effects as pixels, adjustments Photoshop lacks) is listed the first
    /// time the document goes to that file.
    private func writePhotoshop(_ snapshot: ProjectSnapshot, to destination: URL, revision: UUID) async throws -> Bool {
        let output = try await ImageExporter.shared.photoshopData(snapshot)
        try await ImageExporter.shared.write(output.data, to: destination)
        let isNewFile = session.projectURL?.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath()
        stopWatchingProject()
        session.projectURL = destination
        session.photoshopSource = nil
        session.history.markSaved(revision)
        saveGeneration += 1
        RecentProjects.shared.note(destination)
        if isNewFile, !output.conversions.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Saved “\(destination.lastPathComponent)” for Photoshop"
            alert.informativeText = "Some layers were changed to fit the Photoshop format:\n\n"
                + output.conversions.map { "\($0.layerName): \($0.message)" }.joined(separator: "\n")
                + "\n\nSave as a Pixegen project to keep everything editable."
            alert.addButton(withTitle: "OK")
            _ = await show(alert)
        }
        return true
    }

    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        if let workspace { return await workspace.open(suppliedURL) }
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        var source = suppliedURL
        if source == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = UTType.openableDocuments
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.title = "Open Project"
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return false }
            source = url
        }
        guard let source else { return false }
        // A recent project deleted in Finder: name the project, not the manifest inside it the load would miss.
        guard FileManager.default.fileExists(atPath: source.path) else {
            RecentProjects.shared.refresh()
            await showError("Couldn’t open the project", error: CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]))
            return false
        }
        if PSDReader.matches(source) {
            guard await confirmReplacement() else { return false }
            session.clearProject()
            stopWatchingProject()
            session.isProjectBusy = false
            await session.importImages([source])
            return session.document != nil
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Validate first. A corrupt project never discards the live document.
            var snapshot = try await ProjectStore.shared.load(from: source)
            let previousSave = saveGeneration
            guard await confirmReplacement() else { return false }
            // Saving in the confirmation can replace the very file being opened.
            if saveGeneration != previousSave,
               session.projectURL?.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() {
                snapshot = try await ProjectStore.shared.load(from: source)
            }
            session.installProject(snapshot, from: source)
            RecentProjects.shared.note(source)
            await rememberProjectDigest(for: source)
            watchProject(at: source)
            return true
        } catch {
            await showError("Couldn’t open the project", error: error)
            return false
        }
    }

    func newCanvas() async {
        if let workspace { workspace.newCanvas(); return }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed { session.clearProject(); stopWatchingProject() }
    }

    func close(_ window: NSWindow) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.close(tab.id)
            // Closed: its window too, should nothing on screen have closed it already.
            if !workspace.tabs.contains(where: { $0 === tab }) { window.close() }
            return
        }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed {
            session.clearProject()
            stopWatchingProject()
            window.close()
        }
    }

    func confirmQuit() async -> Bool {
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        return await confirmReplacement()
    }

    private func confirmReplacement() async -> Bool {
        // A save still writing finishes before the project can be closed or replaced, so its file is never cut short.
        await finishWriting()
        guard session.isModified, session.document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.projectURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        let response = await show(alert)
        if response == .alertFirstButtonReturn { return await saveCurrent() }
        return response == .alertThirdButtonReturn
    }

    private func showError(_ title: String, error: Error) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await show(alert)
    }

    private func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    private struct Incoming {
        let files: [(URL, Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var incoming: [Incoming] = []
    private var processing = false

    func receive(_ urls: [URL], at point: CGPoint? = nil) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.receive(urls, into: tab.id, at: point); return
        }
        guard !urls.isEmpty else { return }
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        await withCheckedContinuation { completion in
            incoming.append(Incoming(files: files, point: point, completion: completion))
            if !processing {
                processing = true
                Task { await drainIncoming() }
            }
        }
    }

    private func drainIncoming() async {
        while !incoming.isEmpty {
            let request = incoming.removeFirst()
            await session.waitForFileRequest()
            let urls = request.files.map(\.0)
            let projects = urls.filter { ProjectManifest.extensions.contains($0.pathExtension.lowercased()) }
            if projects.count > 1 {
                await showError("Open one project at a time", error: ProjectError.invalid)
            } else {
                var proceed = true
                if let project = projects.first { proceed = await open(project) }
                if proceed {
                    await session.importImages(urls.filter { !ProjectManifest.extensions.contains($0.pathExtension.lowercased()) },
                                               at: projects.isEmpty ? request.point : nil)
                }
            }
            for (url, scoped) in request.files where scoped { url.stopAccessingSecurityScopedResource() }
            request.completion.resume()
        }
        processing = false
    }
}

/// What Save writes: a Pixegen project, or a Photoshop file.
enum SaveFormat: Int {
    case pixegen, photoshop
    init(for url: URL) {
        self = ["psd", "psb"].contains(url.pathExtension.lowercased()) ? .photoshop : .pixegen
    }
    var type: UTType { self == .photoshop ? .photoshopImage : .pixegenProject }
    var pathExtension: String { self == .photoshop ? "psd" : "pbox" }
}

/// The Save panel's Format menu. Choosing one changes the extension on the name, as TextEdit's does.
@MainActor
final class SaveFormatPicker: NSObject {
    private weak var panel: NSSavePanel?
    private let menu = NSPopUpButton()

    init(panel: NSSavePanel, format: SaveFormat, name: String) {
        self.panel = panel
        super.init()
        menu.addItems(withTitles: ["Pixegen Project", "Photoshop (PSD)"])
        menu.selectItem(at: format.rawValue)
        menu.target = self
        menu.action = #selector(changed)
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, menu])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = row
        panel.nameFieldStringValue = name + "." + format.pathExtension
        apply(format)
    }

    @objc private func changed() { apply(SaveFormat(rawValue: menu.indexOfSelectedItem) ?? .pixegen) }

    private func apply(_ format: SaveFormat) {
        guard let panel else { return }
        panel.allowedContentTypes = [format.type]
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = (name.isEmpty ? "Untitled" : name) + "." + format.pathExtension
    }
}

/// What File › Export As… writes.
enum ExportFormat: String, CaseIterable {
    case png = "PNG", jpeg = "JPEG", tiff = "TIFF", pdf = "PDF", exr = "EXR"
    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .pdf: .pdf
        case .exr: .openEXR
        }
    }
}

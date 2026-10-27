import AppKit

/// The canvas's right-click menu, for the layer under the pointer: Convert to Outline for text, the stacking order,
/// and Duplicate and Delete. A layer that isn't selected is selected first, as a Finder item is.
@MainActor
enum CanvasContextMenu {
    static func menu(for session: EditorSession, at pixel: CGPoint) -> NSMenu? {
        guard session.canEditLayers, let document = session.document else { return nil }
        let drawn = document.renderLayers.filter { $0.asset != nil && $0.transform.contains(pixel) }
        let selectedHit = drawn.contains { session.selectedLayerIDs.contains($0.id) || $0.id == session.activeLayerID }
        if !selectedHit {
            guard let top = drawn.last else { return nil }
            session.selectLayers([top.id], primary: top.id)
            guard session.activeLayerID == top.id else { return nil }
        }
        let menu = NSMenu()
        if session.activeLayer?.liveText != nil {
            menu.addItem(ActionMenuItem(title: "Convert to Outline", enabled: session.canConvertTextToOutline) {
                session.convertTextToOutline()
            })
            menu.addItem(.separator())
        }
        for arrangement in [LayerArrangement.front, .forward, .backward, .back] {
            menu.addItem(ActionMenuItem(title: arrangement.rawValue, enabled: session.canArrange(arrangement)) {
                session.arrange(arrangement)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Duplicate Layer") { session.duplicateActiveLayer() })
        let deleteTitle = session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Mask"
            : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer"
        menu.addItem(ActionMenuItem(title: deleteTitle) {
            session.deleteLayerOrMask()
        })
        return menu
    }
}

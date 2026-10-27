import AppKit

/// Bring to Front, Bring Forward, Send Backward and Send to Back: the selected layers restacked among the others in
/// their own folder, as in Photoshop. Layers clipped to one that moves go with it.
nonisolated enum LayerArrangement: String, CaseIterable, Sendable {
    case back = "Send to Back"
    case front = "Bring to Front"
    case backward = "Send Backward"
    case forward = "Bring Forward"

    /// The Arrange panel's label.
    var shortName: String {
        switch self {
        case .back: "Back"
        case .front: "Front"
        case .backward: "Backward"
        case .forward: "Forward"
        }
    }

    var systemImage: String {
        switch self {
        case .back: "square.3.layers.3d.bottom.filled"
        case .front: "square.3.layers.3d.top.filled"
        case .backward: "square.2.layers.3d.bottom.filled"
        case .forward: "square.2.layers.3d.top.filled"
        }
    }

    /// `selected` (bottom to top, one flag per piece) rearranged: the order the pieces end up in, as their old
    /// positions. Selected pieces keep their order among themselves.
    func order(_ selected: [Bool]) -> [Int] {
        var order = Array(selected.indices)
        switch self {
        case .front:
            order = order.filter { !selected[$0] } + order.filter { selected[$0] }
        case .back:
            order = order.filter { selected[$0] } + order.filter { !selected[$0] }
        case .forward:
            // From the top down, so a run of selected pieces moves up together past the one above it.
            for i in stride(from: order.count - 2, through: 0, by: -1) where selected[order[i]] && !selected[order[i + 1]] {
                order.swapAt(i, i + 1)
            }
        case .backward:
            for i in stride(from: 1, to: order.count, by: 1) where selected[order[i]] && !selected[order[i - 1]] {
                order.swapAt(i, i - 1)
            }
        }
        return order
    }
}

extension EditorSession {
    /// The layers stacked as `arrangement` would leave them, or nil when nothing would move.
    func arranged(_ arrangement: LayerArrangement) -> [ImageLayer]? {
        guard canEditLayers, let layers = document?.layers else { return nil }
        let chosen = selectedLayerIDs.isEmpty ? Set(activeLayerID.map { [$0] } ?? []) : selectedLayerIDs
        guard !chosen.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        /// Inside a selected folder, a layer goes where its folder goes.
        func insideChosenFolder(_ layer: ImageLayer) -> Bool {
            var parent = layer.parentID
            for _ in 0..<64 {
                guard let id = parent else { return false }
                if chosen.contains(id) { return true }
                parent = byID[id]?.parentID
            }
            return false
        }
        let moving = chosen.filter { byID[$0].map { !insideChosenFolder($0) } == true }
        var result = layers
        var changed = false
        for (_, siblings) in Dictionary(grouping: layers.indices, by: { layers[$0].parentID }) {
            guard siblings.contains(where: { moving.contains(layers[$0].id) }) else { continue }
            // Pieces, bottom to top: a layer and those clipped to it above, unless a clipped one is moving without it.
            var pieces: [[Int]] = []
            for index in siblings {
                let layer = layers[index]
                if let base = layer.maskSourceID, let last = pieces.last, layers[last[0]].id == base,
                   !moving.contains(layer.id) || moving.contains(base) {
                    pieces[pieces.count - 1].append(index)
                } else {
                    pieces.append([index])
                }
            }
            let order = arrangement.order(pieces.map { moving.contains(layers[$0[0]].id) })
            guard order != Array(pieces.indices) else { continue }
            changed = true
            // The folder's slots in the list stay the same; who fills them changes.
            for (slot, index) in zip(siblings, order.flatMap { pieces[$0] }) {
                result[slot] = layers[index]
            }
        }
        guard changed else { return nil }
        Self.releaseDetachedClipping(in: &result)
        return result
    }

    func canArrange(_ arrangement: LayerArrangement) -> Bool { arranged(arrangement) != nil }

    /// Restacks the selected layers, one undo step.
    func arrange(_ arrangement: LayerArrangement) {
        guard let next = arranged(arrangement) else { return }
        finishOpacityEdit()
        beginEdit(arrangement.rawValue)
        document?.layers = next
        endEdit()
    }
}

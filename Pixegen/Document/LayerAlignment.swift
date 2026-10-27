import AppKit

/// What Align lines the selected layers up against: the box around all of them, or the canvas. With only one
/// layer to move, it's always the canvas.
nonisolated enum AlignmentTarget: String, CaseIterable, Sendable {
    case selection = "Selection"
    case canvas = "Canvas"
}

/// Photoshop's Align and Distribute commands, for the selected layers.
nonisolated enum LayerAlignment: String, CaseIterable, Sendable {
    case left = "Align Left Edges"
    case horizontalCenter = "Align Horizontal Centers"
    case right = "Align Right Edges"
    case top = "Align Top Edges"
    case verticalCenter = "Align Vertical Centers"
    case bottom = "Align Bottom Edges"
    case distributeTop = "Distribute Top Edges"
    case distributeVerticalCenter = "Distribute Vertical Centers"
    case distributeBottom = "Distribute Bottom Edges"
    case distributeLeft = "Distribute Left Edges"
    case distributeHorizontalCenter = "Distribute Horizontal Centers"
    case distributeRight = "Distribute Right Edges"
    case spaceVertically = "Distribute Vertical Spacing"
    case spaceHorizontally = "Distribute Horizontal Spacing"

    static let aligns: [LayerAlignment] = [.left, .horizontalCenter, .right, .top, .verticalCenter, .bottom]
    static let distributes: [LayerAlignment] = [.distributeTop, .distributeVerticalCenter, .distributeBottom,
                                                .distributeLeft, .distributeHorizontalCenter, .distributeRight]
    static let spacings: [LayerAlignment] = [.spaceVertically, .spaceHorizontally]

    /// Distributing spreads what's between the outermost two, so it takes three.
    var isDistribution: Bool { !Self.aligns.contains(self) }
    var minimumCount: Int { isDistribution ? 3 : 1 }

    var systemImage: String {
        switch self {
        case .left: "align.horizontal.left"
        case .horizontalCenter: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .verticalCenter: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        case .distributeTop: "distribute.vertical.top"
        case .distributeVerticalCenter: "distribute.vertical.center"
        case .distributeBottom: "distribute.vertical.bottom"
        case .distributeLeft: "distribute.horizontal.left"
        case .distributeHorizontalCenter: "distribute.horizontal.center"
        case .distributeRight: "distribute.horizontal.right"
        case .spaceVertically: "distribute.vertical.fill"
        case .spaceHorizontally: "distribute.horizontal.fill"
        }
    }

    /// Whether it moves things across (x) rather than up and down (y).
    private var horizontal: Bool {
        switch self {
        case .left, .horizontalCenter, .right, .distributeLeft, .distributeHorizontalCenter, .distributeRight,
             .spaceHorizontally: true
        default: false
        }
    }

    /// The part of a box this lines up: 0 its near edge, 0.5 its middle, 1 its far edge.
    private var fraction: CGFloat {
        switch self {
        case .left, .top, .distributeLeft, .distributeTop: 0
        case .horizontalCenter, .verticalCenter, .distributeHorizontalCenter, .distributeVerticalCenter,
             .spaceHorizontally, .spaceVertically: 0.5
        case .right, .bottom, .distributeRight, .distributeBottom: 1
        }
    }

    /// How far each of `boxes` moves, in the same order: aligned against `reference`, or, distributing, spread
    /// evenly between the two outermost, which stay where they are. Fewer boxes than it takes move nowhere.
    func offsets(for boxes: [CGRect], reference: CGRect) -> [CGSize] {
        let still = Array(repeating: CGSize.zero, count: boxes.count)
        guard boxes.count >= minimumCount else { return still }
        let start = { (box: CGRect) in self.horizontal ? box.minX : box.minY }
        let length = { (box: CGRect) in self.horizontal ? box.width : box.height }
        let moves: [CGFloat]
        switch self {
        case _ where !isDistribution:
            let target = start(reference) + length(reference) * fraction
            moves = boxes.map { target - (start($0) + length($0) * fraction) }
        case .spaceHorizontally, .spaceVertically:
            // Equal gaps, the boxes in the order their middles come; the first and last stay put.
            let order = boxes.indices.sorted { start(boxes[$0]) + length(boxes[$0]) / 2 < start(boxes[$1]) + length(boxes[$1]) / 2 }
            let first = boxes[order[0]], last = boxes[order[order.count - 1]]
            let filled = order.dropFirst().dropLast().reduce(CGFloat(0)) { $0 + length(boxes[$1]) }
            let gap = (start(last) - (start(first) + length(first)) - filled) / CGFloat(order.count - 1)
            var result = Array(repeating: CGFloat(0), count: boxes.count)
            var next = start(first) + length(first) + gap
            for index in order.dropFirst().dropLast() {
                result[index] = next - start(boxes[index])
                next += length(boxes[index]) + gap
            }
            moves = result
        default:
            let edge = { (box: CGRect) in start(box) + length(box) * self.fraction }
            let order = boxes.indices.sorted { edge(boxes[$0]) < edge(boxes[$1]) }
            let low = edge(boxes[order[0]]), high = edge(boxes[order[order.count - 1]])
            let step = (high - low) / CGFloat(order.count - 1)
            var result = Array(repeating: CGFloat(0), count: boxes.count)
            for (rank, index) in order.enumerated() {
                result[index] = low + step * CGFloat(rank) - edge(boxes[index])
            }
            moves = result
        }
        // Whole pixels, as a drag leaves them.
        return moves.map { horizontal ? CGSize(width: $0.rounded(), height: 0) : CGSize(width: 0, height: $0.rounded()) }
    }
}

extension EditorSession {
    /// What Align moves, each as one piece: a selected layer, or a selected folder with everything visible in it.
    /// A layer inside a selected folder goes with its folder. Bottom to top, empty folders and hidden layers left out.
    var alignmentItems: [[ImageLayer]] {
        guard canEditLayers, let document, !selectedLayerIDs.isEmpty else { return [] }
        let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
        let visible = document.effectiveVisibleIDs
        /// The outermost selected layer or folder holding `id`, itself included.
        func root(_ id: UUID) -> UUID? {
            var found: UUID?
            var current: UUID? = id
            for _ in 0..<64 {
                guard let next = current else { break }
                if selectedLayerIDs.contains(next) { found = next }
                current = parents[next] ?? nil
            }
            return found
        }
        var items: [UUID: [ImageLayer]] = [:]
        var order: [UUID] = []
        for layer in document.layers where layer.asset != nil && !layer.isGroup && visible.contains(layer.id) {
            guard let key = root(layer.id) else { continue }
            if items[key] == nil { order.append(key) }
            items[key, default: []].append(layer)
        }
        return order.compactMap { items[$0] }
    }

    /// The upright box around `layers` on the document, each turned as it's placed. A shape's stroke is inside its
    /// layer's box, so it counts.
    nonisolated static func alignmentBox(of layers: [ImageLayer]) -> CGRect? {
        let points = layers.flatMap { DistortWarp.corners(of: $0.transform) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func canAlign(_ alignment: LayerAlignment) -> Bool {
        alignmentItems.count >= alignment.minimumCount
    }

    /// Lines up, or spreads out, the selected layers as one undo step. Masks follow their layers as a move would.
    func align(_ alignment: LayerAlignment) {
        commitTransform()
        let items = alignmentItems
        guard canAlign(alignment), let document else { return }
        let boxes = items.compactMap(Self.alignmentBox)
        guard boxes.count == items.count else { return }
        let canvas = CGRect(origin: .zero, size: document.size)
        let reference = alignmentTarget == .canvas || items.count == 1
            ? canvas : boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        let offsets = alignment.offsets(for: boxes, reference: reference)
        var moves: [UUID: CGSize] = [:]
        for (item, offset) in zip(items, offsets) where offset != .zero {
            for layer in item { moves[layer.id] = offset }
        }
        guard !moves.isEmpty else { return }
        finishOpacityEdit()
        beginEdit(alignment.rawValue)
        for index in document.layers.indices {
            let layer = document.layers[index]
            guard let offset = moves[layer.id] else { continue }
            var moved = layer.transform
            moved.origin.x += offset.width
            moved.origin.y += offset.height
            if let mask = layer.mask {
                self.document?.layers[index].mask?.placement = mask.placement(movingLayer: layer.transform, to: moved)
            }
            self.document?.layers[index].transform = moved
        }
        endEdit()
    }
}

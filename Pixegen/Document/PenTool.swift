import AppKit

/// The Pen tool's modes, as Photoshop's Pen tools: three that draw a new path and two that add and remove points on a
/// shape's path.
nonisolated enum PenMode: String, CaseIterable, Sendable {
    case pen = "Pen"
    case freeform = "Freeform Pen"
    case curvature = "Curvature Pen"
    case addAnchor = "Add Anchor Point"
    case deleteAnchor = "Delete Anchor Point"
    var toolName: String { "\(rawValue) Tool" }
    /// The tool bar's picker, which has less room.
    var shortName: String {
        switch self {
        case .pen: "Pen"
        case .freeform: "Freeform"
        case .curvature: "Curvature"
        case .addAnchor: "Add"
        case .deleteAnchor: "Delete"
        }
    }
    /// Whether the mode draws a new path, rather than editing one already drawn.
    var draws: Bool { self == .pen || self == .freeform || self == .curvature }
}

/// What the pointer is over with the Pen tool, which its cursor shows.
nonisolated enum PenHover: Equatable, Sendable {
    case none
    /// The path's first point: clicking it closes the path.
    case close
    /// A shape's path, where Add Anchor Point would add one.
    case add
    /// A shape's anchor point, which Delete Anchor Point would remove.
    case delete
}

/// A path being drawn with the Pen tool, in document pixels. Nothing is made until it is finished.
struct PenDraft {
    let mode: PenMode
    /// Shape or Path, fixed when the path starts.
    let output: ShapeMode
    /// The points placed so far. The Curvature Pen keeps only the anchors clicked, and works out their handles from
    /// them each time (see `PenGeometry.curvatureKnots`).
    var knots: [ShapeOutline.Knot] = []
    /// Curvature Pen points made corners by double-clicking them.
    var corners: Set<Int> = []
    /// Where the pointer has been, while the Freeform Pen is dragged.
    var samples: [CGPoint] = []
    /// The pointer, for the segment to it that shows where the next click goes.
    var cursor: CGPoint?
    /// Where the press began, while the mouse is down; nil between clicks.
    var press: CGPoint?
    /// The press was on the first point, so letting go closes the path.
    var closing = false
    /// The press has moved further than a click's wobble.
    var dragged = false
    /// Option broke the new point's handles during this press: the incoming one stays where it was.
    var brokenIncoming: CGPoint?

    /// The path as it would be finished now, without the pointer.
    var subpath: ShapeOutline.Subpath {
        if mode == .curvature {
            return ShapeOutline.Subpath(closed: false, knots: PenGeometry.curvatureKnots(knots.map(\.anchor), corners: corners, closed: false))
        }
        if mode == .freeform { return ShapeOutline.Subpath(closed: false, knots: samples.map { ShapeOutline.Knot(anchor: $0) }) }
        return ShapeOutline.Subpath(closed: false, knots: knots)
    }

    /// The part of the path that would change with another click at the pointer: one segment from the last point
    /// for the Pen; the last two segments, which the new point bends, for the Curvature Pen.
    var rubberBand: ShapeOutline.Subpath? {
        guard press == nil, let cursor, let last = knots.last else { return nil }
        if mode == .curvature {
            let anchors = knots.map(\.anchor) + [cursor]
            let all = PenGeometry.curvatureKnots(anchors, corners: corners, closed: false)
            return ShapeOutline.Subpath(closed: false, knots: Array(all.suffix(3)))
        }
        guard mode == .pen else { return nil }
        return ShapeOutline.Subpath(closed: false, knots: [last, ShapeOutline.Knot(anchor: cursor)])
    }
}

/// The curves the Pen tool draws, and the cuts and joins Add and Delete Anchor Point make in a path.
nonisolated enum PenGeometry {
    /// Smooth knots through `points`, as the Curvature Pen draws them: each point's handles run parallel to the line
    /// between its neighbors, a third of the way to each. Corners, and the ends of an open path, have no handles.
    static func curvatureKnots(_ points: [CGPoint], corners: Set<Int>, closed: Bool) -> [ShapeOutline.Knot] {
        let count = points.count
        return points.indices.map { index in
            let point = points[index]
            guard !corners.contains(index) else { return ShapeOutline.Knot(anchor: point) }
            let wraps = closed && count > 2
            let previous = index > 0 ? points[index - 1] : wraps ? points[count - 1] : nil
            let next = index < count - 1 ? points[index + 1] : wraps ? points[0] : nil
            guard let previous, let next else { return ShapeOutline.Knot(anchor: point) }
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = hypot(dx, dy)
            guard length > 0 else { return ShapeOutline.Knot(anchor: point) }
            let ux = dx / length, uy = dy / length
            let back = hypot(point.x - previous.x, point.y - previous.y) / 3
            let ahead = hypot(next.x - point.x, next.y - point.y) / 3
            return ShapeOutline.Knot(anchor: point, incoming: CGPoint(x: point.x - ux * back, y: point.y - uy * back),
                                     outgoing: CGPoint(x: point.x + ux * ahead, y: point.y + uy * ahead))
        }
    }

    /// `point` turned about `origin` to the nearest eighth of a turn, keeping its distance: Shift's 45° steps.
    static func constrained(_ point: CGPoint, around origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x, dy = point.y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    // MARK: Freeform

    /// Bezier knots that follow `samples` to within `tolerance` (document pixels), by Philip Schneider's curve fitting
    /// ("An Algorithm for Automatically Fitting Digitized Curves", Graphics Gems, 1990). A closed path joins its end
    /// to its start smoothly.
    static func fitted(_ samples: [CGPoint], tolerance: CGFloat, closed: Bool) -> [ShapeOutline.Knot] {
        var points: [CGPoint] = []
        for sample in samples where sample.x.isFinite && sample.y.isFinite && points.last != sample { points.append(sample) }
        if closed, points.count > 2, points.last != points.first { points.append(points[0]) }
        guard points.count > 1 else { return points.map { ShapeOutline.Knot(anchor: $0) } }
        var start = unit(points[1] - points[0]), end = unit(points[points.count - 2] - points[points.count - 1])
        if closed, points.count > 3 {
            // One direction through the join, so the start and the end meet without a corner.
            let through = unit(points[1] - points[points.count - 2])
            start = through
            end = CGPoint(x: -through.x, y: -through.y)
        }
        var curves: [[CGPoint]] = []
        fit(points, first: 0, last: points.count - 1, start: start, end: end, error: tolerance * tolerance, into: &curves)
        var knots = [ShapeOutline.Knot(anchor: points[0])]
        for curve in curves {
            knots[knots.count - 1].outgoing = curve[1]
            knots.append(ShapeOutline.Knot(anchor: curve[3], incoming: curve[2]))
        }
        if closed, knots.count > 2, let last = knots.last {
            // The last knot is back on the first: its incoming handle is the first's.
            knots[0].incoming = last.incoming
            knots.removeLast()
        }
        return knots
    }

    private static func fit(_ points: [CGPoint], first: Int, last: Int, start: CGPoint, end: CGPoint, error: CGFloat,
                            into curves: inout [[CGPoint]]) {
        let from = points[first], to = points[last]
        if last - first == 1 {
            let third = distance(from, to) / 3
            curves.append([from, from + start * third, to + end * third, to])
            return
        }
        var parameters = chordLengths(points, first: first, last: last)
        var curve = bezier(points, first: first, last: last, parameters: parameters, start: start, end: end)
        var (worst, split) = maximumError(points, first: first, last: last, curve: curve, parameters: parameters)
        if worst < error { curves.append(curve); return }
        // Near enough that a better spacing of the points along the curve may be all it needs.
        if worst < error * 4 {
            for _ in 0..<4 {
                parameters = reparameterized(points, first: first, last: last, curve: curve, parameters: parameters)
                curve = bezier(points, first: first, last: last, parameters: parameters, start: start, end: end)
                (worst, split) = maximumError(points, first: first, last: last, curve: curve, parameters: parameters)
                if worst < error { curves.append(curve); return }
            }
        }
        // Otherwise two curves, meeting smoothly at the point that strayed furthest.
        var center = unit(points[split - 1] - points[split + 1])
        if center == .zero { center = unit(points[split - 1] - points[split]) }
        fit(points, first: first, last: split, start: start, end: center, error: error, into: &curves)
        fit(points, first: split, last: last, start: CGPoint(x: -center.x, y: -center.y), end: end, error: error, into: &curves)
    }

    /// The curve between the end points, leaving them along the given directions, closest to the points between (least
    /// squares, for how far along each handle reaches).
    private static func bezier(_ points: [CGPoint], first: Int, last: Int, parameters: [CGFloat], start: CGPoint,
                               end: CGPoint) -> [CGPoint] {
        let from = points[first], to = points[last]
        var c00: CGFloat = 0, c01: CGFloat = 0, c11: CGFloat = 0, x0: CGFloat = 0, x1: CGFloat = 0
        for (offset, u) in parameters.enumerated() {
            let a0 = start * basis1(u), a1 = end * basis2(u)
            c00 += dot(a0, a0); c01 += dot(a0, a1); c11 += dot(a1, a1)
            let fixed = from * (basis0(u) + basis1(u)) + to * (basis2(u) + basis3(u))
            let rest = points[first + offset] - fixed
            x0 += dot(a0, rest); x1 += dot(a1, rest)
        }
        let determinant = c00 * c11 - c01 * c01
        var left = determinant == 0 ? 0 : (x0 * c11 - x1 * c01) / determinant
        var right = determinant == 0 ? 0 : (c00 * x1 - c01 * x0) / determinant
        let length = distance(from, to)
        // A handle pointing backwards, or of no length, means the fit failed: fall back on a third of the way.
        if left < length * 1e-6 || right < length * 1e-6 || !left.isFinite || !right.isFinite {
            left = length / 3
            right = length / 3
        }
        return [from, from + start * left, to + end * right, to]
    }

    private static func chordLengths(_ points: [CGPoint], first: Int, last: Int) -> [CGFloat] {
        var lengths: [CGFloat] = [0]
        for index in (first + 1)...last { lengths.append(lengths[lengths.count - 1] + distance(points[index], points[index - 1])) }
        guard let total = lengths.last, total > 0 else { return lengths.indices.map { CGFloat($0) / CGFloat(max(1, lengths.count - 1)) } }
        return lengths.map { $0 / total }
    }

    private static func maximumError(_ points: [CGPoint], first: Int, last: Int, curve: [CGPoint],
                                     parameters: [CGFloat]) -> (CGFloat, Int) {
        var worst: CGFloat = 0, split = (first + last) / 2
        for index in (first + 1)..<last {
            let away = value(curve, at: parameters[index - first]) - points[index]
            let squared = dot(away, away)
            if squared >= worst { worst = squared; split = index }
        }
        return (worst, split)
    }

    /// Each point's place along the curve moved by a step of Newton's method towards the nearest point on it.
    private static func reparameterized(_ points: [CGPoint], first: Int, last: Int, curve: [CGPoint],
                                        parameters: [CGFloat]) -> [CGFloat] {
        let first1 = (0..<3).map { (curve[$0 + 1] - curve[$0]) * 3 }
        let second = (0..<2).map { (first1[$0 + 1] - first1[$0]) * 2 }
        return parameters.enumerated().map { offset, u in
            let away = value(curve, at: u) - points[first + offset]
            let d1 = first1[0] * ((1 - u) * (1 - u)) + first1[1] * (2 * u * (1 - u)) + first1[2] * (u * u)
            let d2 = second[0] * (1 - u) + second[1] * u
            let denominator = dot(d1, d1) + dot(away, d2)
            guard denominator != 0, denominator.isFinite else { return u }
            return u - dot(away, d1) / denominator
        }
    }

    private static func basis0(_ u: CGFloat) -> CGFloat { (1 - u) * (1 - u) * (1 - u) }
    private static func basis1(_ u: CGFloat) -> CGFloat { 3 * u * (1 - u) * (1 - u) }
    private static func basis2(_ u: CGFloat) -> CGFloat { 3 * u * u * (1 - u) }
    private static func basis3(_ u: CGFloat) -> CGFloat { u * u * u }

    // MARK: Segments

    /// The point `t` of the way along a cubic curve's four points.
    static func value(_ curve: [CGPoint], at t: CGFloat) -> CGPoint {
        curve[0] * basis0(t) + curve[1] * basis1(t) + curve[2] * basis2(t) + curve[3] * basis3(t)
    }

    /// A segment of a path: from knot `segment` to the next (round to the first, for a closed path's last).
    struct SegmentHit: Equatable {
        var subpath: Int
        var segment: Int
        var t: CGFloat
        var distance: CGFloat
    }

    static func segmentCount(_ subpath: ShapeOutline.Subpath) -> Int {
        subpath.knots.count < 2 ? 0 : subpath.closed ? subpath.knots.count : subpath.knots.count - 1
    }

    static func curve(_ subpath: ShapeOutline.Subpath, segment: Int) -> [CGPoint] {
        let from = subpath.knots[segment], to = subpath.knots[(segment + 1) % subpath.knots.count]
        return [from.anchor, from.outgoing, to.incoming, to.anchor]
    }

    /// The segment nearest `point`, if any is within `tolerance`, and how far along it.
    static func nearestSegment(_ subpaths: [ShapeOutline.Subpath], to point: CGPoint, tolerance: CGFloat) -> SegmentHit? {
        var best: SegmentHit?
        for (index, subpath) in subpaths.enumerated() {
            for segment in 0..<segmentCount(subpath) {
                let points = curve(subpath, segment: segment)
                // A coarse pass, then narrowing in on the nearest sample.
                let steps = 32
                var bestT: CGFloat = 0, bestDistance = CGFloat.infinity
                for step in 0...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let gap = distance(value(points, at: t), point)
                    if gap < bestDistance { bestDistance = gap; bestT = t }
                }
                var span = 1 / CGFloat(steps)
                for _ in 0..<12 {
                    for t in [bestT - span / 2, bestT + span / 2] where (0...1).contains(t) {
                        let gap = distance(value(points, at: t), point)
                        if gap < bestDistance { bestDistance = gap; bestT = t }
                    }
                    span /= 2
                }
                if bestDistance <= tolerance, bestDistance < (best?.distance ?? .infinity) {
                    best = SegmentHit(subpath: index, segment: segment, t: bestT, distance: bestDistance)
                }
            }
        }
        return best
    }

    /// The path with a point added where `hit` is, leaving its outline as it was (de Casteljau's split). A straight
    /// segment stays straight, and the new point has no handles.
    static func splitting(_ subpaths: [ShapeOutline.Subpath], at hit: SegmentHit) -> (subpaths: [ShapeOutline.Subpath], added: PathKnot)? {
        guard subpaths.indices.contains(hit.subpath), (0..<segmentCount(subpaths[hit.subpath])).contains(hit.segment) else { return nil }
        var result = subpaths
        var knots = result[hit.subpath].knots
        let next = (hit.segment + 1) % knots.count
        let from = knots[hit.segment], to = knots[next]
        let t = min(1, max(0, hit.t))
        let added: ShapeOutline.Knot
        if from.outgoing == from.anchor, to.incoming == to.anchor {
            added = ShapeOutline.Knot(anchor: from.anchor + (to.anchor - from.anchor) * t)
        } else {
            func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { a + (b - a) * t }
            let q0 = mix(from.anchor, from.outgoing), q1 = mix(from.outgoing, to.incoming), q2 = mix(to.incoming, to.anchor)
            let r0 = mix(q0, q1), r1 = mix(q1, q2)
            added = ShapeOutline.Knot(anchor: mix(r0, r1), incoming: r0, outgoing: r1)
            knots[hit.segment].outgoing = q0
            knots[next].incoming = q2
        }
        knots.insert(added, at: hit.segment + 1)
        result[hit.subpath].knots = knots
        return (result, PathKnot(subpath: hit.subpath, knot: hit.segment + 1))
    }

    /// The path without one of its points; nil when its subpath would be left with too few to draw (two for an open
    /// path, three for a closed one), which Delete Anchor Point refuses rather than delete the shape.
    static func removing(_ knot: PathKnot, from subpaths: [ShapeOutline.Subpath]) -> [ShapeOutline.Subpath]? {
        guard subpaths.indices.contains(knot.subpath), subpaths[knot.subpath].knots.indices.contains(knot.knot) else { return nil }
        var result = subpaths
        result[knot.subpath].knots.remove(at: knot.knot)
        let left = result[knot.subpath]
        return left.knots.count < (left.closed ? 3 : 2) ? nil : result
    }

    // MARK: Points

    private static func unit(_ vector: CGPoint) -> CGPoint {
        let length = hypot(vector.x, vector.y)
        return length > 0 ? CGPoint(x: vector.x / length, y: vector.y / length) : .zero
    }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

private extension CGPoint {
    nonisolated static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    nonisolated static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    nonisolated static func * (a: CGPoint, scale: CGFloat) -> CGPoint { CGPoint(x: a.x * scale, y: a.y * scale) }
}

extension EditorSession {
    /// What a pen path is filled and stroked with: the Shape tool's fill and stroke settings, on a path of its own.
    /// Its outline is set when the path is finished.
    var penShapeStyle: LayerShapeStyle {
        let color = foregroundColor
        var style = LayerShapeStyle(kind: .custom, red: color.red, green: color.green, blue: color.blue, cornerRadius: 0)
        style.fillGradient = shapeFillGradient
        if !shapeFilled { style.filled = false }
        if shapeStrokeEnabled, shapeStrokeWidth > 0 {
            style.stroke = ShapeStroke(color: shapeStrokeColor, width: CGFloat(shapeStrokeWidth), options: shapeStrokeOptions)
            style.stroke?.gradient = shapeStrokeGradient
        }
        return style
    }

    /// A press with the Pen tool, in document pixels. `tolerance` is how near, in document pixels, counts as on a
    /// point; `constrain` is Shift.
    func beginPen(at point: CGPoint, tolerance: CGFloat, constrain: Bool, clickCount: Int) {
        guard tool == .pen, document != nil, point.x.isFinite, point.y.isFinite else { return }
        switch penMode {
        case .addAnchor: addAnchorPoint(at: point, tolerance: tolerance)
        case .deleteAnchor: deleteAnchorPoint(at: point, tolerance: tolerance)
        case .freeform:
            guard canEditLayers else { return }
            penDraft = PenDraft(mode: .freeform, output: penOutput, samples: [point], press: point)
        case .pen, .curvature:
            guard canEditLayers else { return }
            guard var draft = penDraft, draft.mode == penMode else {
                penDraft = PenDraft(mode: penMode, output: penOutput, knots: [ShapeOutline.Knot(anchor: point)], press: point)
                return
            }
            draft.press = point
            draft.dragged = false
            draft.brokenIncoming = nil
            if draft.mode == .curvature, clickCount >= 2,
               let index = draft.knots.lastIndex(where: { PenGeometry.distance($0.anchor, point) <= tolerance }) {
                // The double-click's first click put a point here: the second turns it into a corner, or back.
                if draft.corners.contains(index) { draft.corners.remove(index) } else { draft.corners.insert(index) }
                draft.closing = false
                penDraft = draft
                return
            }
            if draft.knots.count >= 2, let first = draft.knots.first, PenGeometry.distance(first.anchor, point) <= tolerance {
                draft.closing = true
            } else {
                let last = draft.knots[draft.knots.count - 1].anchor
                draft.knots.append(ShapeOutline.Knot(anchor: constrain ? PenGeometry.constrained(point, around: last) : point))
            }
            penDraft = draft
        }
    }

    /// The press dragged. With the Pen, the new point's handles follow the pointer, the incoming one mirroring it
    /// unless `breaksHandle` (Option); on the first point, the closing curve's handle. The Curvature Pen moves the
    /// new point; the Freeform Pen follows the pointer, keeping samples at least `spacing` apart.
    func dragPen(to point: CGPoint, constrain: Bool, breaksHandle: Bool, threshold: CGFloat, spacing: CGFloat) {
        guard var draft = penDraft, let press = draft.press, point.x.isFinite, point.y.isFinite else { return }
        if draft.mode == .freeform {
            if let last = draft.samples.last, PenGeometry.distance(last, point) < spacing { return }
            draft.samples.append(point)
            penDraft = draft
            return
        }
        // A click with a little movement in it is still a click.
        if !draft.dragged {
            guard PenGeometry.distance(point, press) > threshold else { return }
            draft.dragged = true
        }
        if draft.mode == .curvature {
            guard !draft.closing else { return }
            let index = draft.knots.count - 1
            draft.knots[index].anchor = constrain && index > 0 ? PenGeometry.constrained(point, around: draft.knots[index - 1].anchor) : point
        } else {
            let index = draft.closing ? 0 : draft.knots.count - 1
            var knot = draft.knots[index]
            let handle = constrain ? PenGeometry.constrained(point, around: knot.anchor) : point
            let mirror = CGPoint(x: 2 * knot.anchor.x - handle.x, y: 2 * knot.anchor.y - handle.y)
            if draft.closing {
                // Back at the start, the drag shapes the closing curve, which arrives at the first point.
                knot.incoming = mirror
            } else {
                if breaksHandle, draft.brokenIncoming == nil { draft.brokenIncoming = knot.incoming }
                knot.outgoing = handle
                knot.incoming = draft.brokenIncoming ?? mirror
            }
            draft.knots[index] = knot
        }
        penDraft = draft
    }

    /// The press let go. Closing the path, or the Freeform Pen's one drag, finishes it; `tolerance` is how near its
    /// start a freeform path must end to close, and how closely its curves follow the pointer.
    func endPen(tolerance: CGFloat) {
        guard var draft = penDraft, draft.press != nil else { return }
        draft.press = nil
        draft.brokenIncoming = nil
        penDraft = draft
        if draft.mode == .freeform {
            let samples = draft.samples
            guard samples.count > 1, let first = samples.first, let last = samples.last else { cancelPen(); return }
            let closes = samples.count > 2 && PenGeometry.distance(first, last) <= tolerance * 4
            commitPen(PenGeometry.fitted(samples, tolerance: tolerance, closed: closes), closed: closes)
        } else if draft.closing {
            let knots = draft.mode == .curvature
                ? PenGeometry.curvatureKnots(draft.knots.map(\.anchor), corners: draft.corners, closed: true) : draft.knots
            commitPen(knots, closed: true)
        }
    }

    /// Where the pointer is between clicks, for the segment that shows where the next one goes.
    func movePenCursor(to point: CGPoint?) {
        guard var draft = penDraft, draft.press == nil, draft.cursor != point else { return }
        draft.cursor = point
        penDraft = draft
    }

    /// Return: the path as it is, open.
    func finishPen() {
        guard let draft = penDraft, draft.press == nil, draft.mode != .freeform else { return }
        commitPen(draft.subpath.knots, closed: false)
    }

    func cancelPen() {
        if penDraft != nil { penDraft = nil }
    }

    /// Delete while drawing: the last point placed goes, and with the last one, the path.
    func removeLastPenPoint() {
        guard var draft = penDraft, draft.press == nil, draft.mode != .freeform else { return }
        draft.knots.removeLast()
        draft.corners.remove(draft.knots.count)
        penDraft = draft.knots.isEmpty ? nil : draft
    }

    /// Shift-P (and Tab): the Pen tool steps through its modes, in the order of the tool rail's flyout.
    func cyclePenMode() {
        cancelPen()
        let modes = PenMode.allCases
        penMode = modes[((modes.firstIndex(of: penMode) ?? 0) + 1) % modes.count]
    }

    /// A finished pen path: a new shape layer above the active one, or the work path.
    private func commitPen(_ knots: [ShapeOutline.Knot], closed: Bool) {
        guard let draft = penDraft else { return }
        penDraft = nil
        guard knots.count >= 2 else { return }
        let subpath = ShapeOutline.Subpath(closed: closed, knots: knots)
        if draft.output == .path {
            workPath = ShapeOutline.path(of: [subpath])
            return
        }
        guard canEditLayers else { return }
        var style = penShapeStyle
        guard style.isFilled || style.stroke != nil else {
            brushError = "That path has no fill and no stroke. Turn one of them on in the tool bar."
            return
        }
        guard let outline = ShapeOutline.normalized([subpath]) else {
            brushError = "That path is a straight line across or down, with nothing to fill. Give it some width and height."
            return
        }
        style.outline = outline
        let box = ShapeOutline.path(of: [subpath]).boundingBoxOfPath.insetBy(dx: -style.reach, dy: -style.reach)
        let size = CGSize(width: max(1, box.width.rounded()), height: max(1, box.height.rounded()))
        guard Int(size.width) * Int(size.height) <= Self.maxShapePixels else {
            brushError = "That shape is too large. A shape can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels."
            return
        }
        do {
            let image = try Self.shapeImage(style, size: size)
            addPixelLayer(image, at: box.origin, name: nextShapeName("Shape"), editName: "Pen",
                          dropsSelection: false, shape: LayerShape(style: style, image: image))
        } catch { brushError = error.localizedDescription }
    }

    /// Shapes whose paths Add and Delete Anchor Point work on, in the order they're tried: the active one, then the
    /// rest from the top down. Lines have just their two ends, so they're left out.
    private var anchorEditCandidates: [ImageLayer] {
        guard let document else { return [] }
        let visible = document.effectiveVisibleIDs
        var layers = document.layers.reversed().filter { visible.contains($0.id) && $0.liveShape != nil && !$0.isGroup }
        if let index = layers.firstIndex(where: { $0.id == activeLayerID }) { layers.insert(layers.remove(at: index), at: 0) }
        return layers.filter { $0.liveShape?.style.kind != .line }
    }

    /// A shape's path in its layer's unit square, and in document pixels.
    private func editablePath(of layer: ImageLayer) -> (unit: [ShapeOutline.Subpath], document: [ShapeOutline.Subpath])? {
        guard let shape = layer.liveShape,
              let unit = Self.pathKnots(style: shape.style, transform: layer.transform, image: shape.image) else { return nil }
        let map = layer.transform.unitToDocument
        let placed = unit.map { subpath in
            ShapeOutline.Subpath(closed: subpath.closed, knots: subpath.knots.map {
                ShapeOutline.Knot(anchor: $0.anchor.applying(map), incoming: $0.incoming.applying(map), outgoing: $0.outgoing.applying(map))
            })
        }
        return (unit, placed)
    }

    /// The topmost shape's anchor point within `tolerance` of `point`.
    private func anchorHit(at point: CGPoint, tolerance: CGFloat) -> (layer: ImageLayer, knot: PathKnot)? {
        for layer in anchorEditCandidates {
            guard let path = editablePath(of: layer) else { continue }
            for (index, subpath) in path.document.enumerated() {
                if let found = subpath.knots.firstIndex(where: { PenGeometry.distance($0.anchor, point) <= tolerance }) {
                    return (layer, PathKnot(subpath: index, knot: found))
                }
            }
        }
        return nil
    }

    /// The topmost shape whose outline passes within `tolerance` of `point`, and where along it. Anchors themselves
    /// don't count, so a point isn't added on top of one.
    private func segmentHit(at point: CGPoint, tolerance: CGFloat) -> (layer: ImageLayer, hit: PenGeometry.SegmentHit)? {
        for layer in anchorEditCandidates {
            guard let path = editablePath(of: layer),
                  let hit = PenGeometry.nearestSegment(path.document, to: point, tolerance: tolerance) else { continue }
            let onAnchor = path.document.contains { $0.knots.contains { PenGeometry.distance($0.anchor, point) <= tolerance } }
            return onAnchor ? nil : (layer, hit)
        }
        return nil
    }

    /// What the pointer is over, for the Pen tool's cursor.
    func penHover(at point: CGPoint, tolerance: CGFloat) -> PenHover {
        guard tool == .pen, point.x.isFinite, point.y.isFinite else { return .none }
        switch penMode {
        case .addAnchor: return segmentHit(at: point, tolerance: tolerance) != nil ? .add : .none
        case .deleteAnchor: return anchorHit(at: point, tolerance: tolerance) != nil ? .delete : .none
        case .pen, .curvature:
            guard let draft = penDraft, draft.knots.count >= 2, let first = draft.knots.first,
                  PenGeometry.distance(first.anchor, point) <= tolerance else { return .none }
            return .close
        case .freeform: return .none
        }
    }

    /// Add Anchor Point: a point where the press is on a shape's outline, which the drag then moves, as one undo step.
    /// The shape keeps its outline, as a path of its own: a rectangle given a point is no longer a rectangle.
    private func addAnchorPoint(at point: CGPoint, tolerance: CGFloat) {
        guard canEditLayers, let found = segmentHit(at: point, tolerance: tolerance) else { return }
        let layer = found.layer, hit = found.hit
        guard let shape = layer.liveShape,
              let path = editablePath(of: layer), let split = PenGeometry.splitting(path.unit, at: hit),
              Self.reshaped(style: shape.style, transform: layer.transform, knots: split.subpaths) != nil else { return }
        if layer.id != activeLayerID { selectLayer(layer.id) }
        guard activeLayerID == layer.id, let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let drag = PathDrag(layerID: layer.id, hit: .anchor(split.added), start: point, style: shape.style, transform: layer.transform,
                            knots: split.subpaths, moving: [split.added])
        beginEdit("Add Anchor Point")
        applyPath(split.subpaths, from: drag, at: index)
        pathDrag = drag
    }

    /// Delete Anchor Point: the point clicked goes, unless its shape would be left with nothing to draw.
    private func deleteAnchorPoint(at point: CGPoint, tolerance: CGFloat) {
        guard canEditLayers, let found = anchorHit(at: point, tolerance: tolerance) else { return }
        let layer = found.layer, knot = found.knot
        guard let shape = layer.liveShape, let path = editablePath(of: layer), let knots = PenGeometry.removing(knot, from: path.unit),
              Self.reshaped(style: shape.style, transform: layer.transform, knots: knots) != nil else {
            NSSound.beep()
            return
        }
        if layer.id != activeLayerID { selectLayer(layer.id) }
        guard activeLayerID == layer.id, let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let drag = PathDrag(layerID: layer.id, hit: .shape(layer.id), start: point, style: shape.style, transform: layer.transform,
                            knots: knots, moving: [])
        beginEdit("Delete Anchor Point")
        applyPath(knots, from: drag, at: index)
        endEdit()
    }
}

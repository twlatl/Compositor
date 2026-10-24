import CoreGraphics
import Foundation

/// Writes a project as an 8-bit RGB Photoshop document, from Adobe’s 2019 Photoshop File Formats Specification:
/// folders, pixel layers, masks, clipping, blend modes, opacity, and Levels, Curves, Hue/Saturation and Invert
/// adjustment layers stay editable. What Photoshop can’t take as Pixegen has it — text, shapes and layer effects —
/// goes in as pixels that look the same, and each such change is reported.
nonisolated enum PSDWriter {
    struct Output: @unchecked Sendable {
        let data: Data
        let conversions: [PSDConversion]
    }

    /// `composite`: the flattened canvas (`ImageExporter.render`), stored as the file’s merged image.
    static func encode(_ snapshot: ProjectSnapshot, composite: CGImage) throws -> Output {
        let manifest = snapshot.manifest
        guard (1...DocumentLimits.maxSide).contains(manifest.width), (1...DocumentLimits.maxSide).contains(manifest.height) else {
            throw ProjectError.tooLarge
        }
        try LayerHierarchy.validate(manifest.layers)
        var conversions: [PSDConversion] = []
        let layers = try flatten(snapshot, conversions: &conversions)
        guard layers.count <= Int(Int16.max) else { throw ProjectError.tooLarge }
        var file = PSDWriteBuffer()
        file.string("8BPS")
        file.u16(1)
        file.bytes(Data(count: 6))
        file.u16(3)
        file.u32(UInt32(manifest.height))
        file.u32(UInt32(manifest.width))
        file.u16(8)
        file.u16(3) // RGB
        file.u32(0) // Color mode data
        let resources = imageResources(manifest)
        file.u32(UInt32(resources.count))
        file.bytes(resources)
        let section = layerSection(layers)
        file.u32(UInt32(section.count))
        file.bytes(section)
        try appendComposite(&file, composite, width: manifest.width, height: manifest.height)
        return Output(data: file.data, conversions: conversions)
    }

    // MARK: Layers

    /// One layer record as it goes into the file: its bounds on the document, and its channels already packed.
    private struct Written {
        var name: String
        var bounds = (top: 0, left: 0, bottom: 0, right: 0)
        var isVisible = true
        var opacity: Double = 1
        var blendKey = "norm"
        var clipping = false
        /// 1 for a folder, 3 for the hidden divider closing it.
        var section: UInt32?
        var pixelsIrrelevant = false
        var color: [(id: Int16, payload: Data)] = PSDWriter.emptyColor
        var mask: (payload: Data, bounds: (top: Int, left: Int, bottom: Int, right: Int), enabled: Bool, linked: Bool)?
        var adjustment: (key: String, payload: Data)?
    }

    private static let emptyColor: [(id: Int16, payload: Data)] = [(-1, Data([0, 0])), (0, Data([0, 0])), (1, Data([0, 0])), (2, Data([0, 0]))]

    /// File order is bottom to top; a folder is its divider, its children, then the folder record itself.
    private static func flatten(_ snapshot: ProjectSnapshot, conversions: inout [PSDConversion]) throws -> [Written] {
        let children = Dictionary(grouping: snapshot.manifest.layers, by: \.parentID)
        var result: [Written] = []
        func visit(_ parent: UUID?) throws {
            var base: UUID?
            for record in children[parent] ?? [] {
                if record.isGroup == true {
                    result.append(Written(name: "</Layer group>", blendKey: "norm", section: 3, pixelsIrrelevant: true))
                    try visit(record.id)
                    result.append(try folder(record, snapshot))
                    base = nil
                    continue
                }
                var written = try record.adjustment != nil
                    ? adjustmentLayer(record, snapshot, conversions: &conversions)
                    : pixelLayer(record, snapshot, conversions: &conversions)
                // Photoshop clips to the nearest unclipped layer below; Pixegen names its source.
                if let source = record.maskSourceID {
                    if source == base { written.clipping = true }
                    else { conversions.append(PSDConversion(layerName: record.name, message: "This clipping mask’s source isn’t the layer just below it, so it was saved unclipped.")) }
                } else {
                    base = record.adjustment == nil ? record.id : nil
                }
                result.append(written)
            }
        }
        try visit(nil)
        return result
    }

    private static func folder(_ record: ProjectLayerRecord, _ snapshot: ProjectSnapshot) throws -> Written {
        var written = Written(name: record.name, isVisible: record.isVisible, opacity: record.opacity ?? 1,
                              blendKey: "pass", section: 1, pixelsIrrelevant: true)
        written.mask = try canvasMask(record, snapshot)
        return written
    }

    private static func adjustmentLayer(_ record: ProjectLayerRecord, _ snapshot: ProjectSnapshot,
                                        conversions: inout [PSDConversion]) throws -> Written {
        var written = Written(name: record.name, isVisible: record.isVisible, opacity: record.opacity ?? 1,
                              blendKey: blendKey(record.blendMode ?? .normal), pixelsIrrelevant: true)
        if let adjustment = record.adjustment {
            switch adjustment.kind {
            case .levels: written.adjustment = ("levl", levels(adjustment.levels))
            case .curves: written.adjustment = ("curv", curves(adjustment.curves))
            case .hsv: written.adjustment = ("hue2", hue(adjustment.resolvedHSV))
            case .invert: written.adjustment = ("nvrt", Data())
            default:
                conversions.append(PSDConversion(layerName: record.name,
                    message: "Photoshop has no \(adjustment.kind.rawValue) adjustment layer, so this one was left out."))
                written.isVisible = false
            }
        }
        written.mask = try canvasMask(record, snapshot)
        return written
    }

    private static func pixelLayer(_ record: ProjectLayerRecord, _ snapshot: ProjectSnapshot,
                                   conversions: inout [PSDConversion]) throws -> Written {
        var written = Written(name: record.name, isVisible: record.isVisible, opacity: record.opacity ?? 1,
                              blendKey: blendKey(record.blendMode ?? .normal))
        if record.text != nil {
            conversions.append(PSDConversion(layerName: record.name, message: "Text was saved as pixels."))
        } else if record.shape != nil {
            conversions.append(PSDConversion(layerName: record.name, message: "The shape was saved as pixels."))
        }
        guard let asset = snapshot.images[record.id] else { return written }
        let image = asset.image
        let transform = record.transform
        let layerMask = snapshot.mask(for: record)
        // A disabled mask is still saved, switched off; `clipImage` only hands back enabled ones.
        let maskGrid = layerMask.flatMap {
            LayerMask(asset: $0.asset, isEnabled: true, placement: $0.placement, isLinked: $0.isLinked)
                .clipImage(placement: $0.placement, over: transform, width: image.width, height: image.height)
        }
        if let effects = LayerEffectsRenderer.cached(image, mask: layerMask?.isEnabled == true ? maskGrid : nil, effects: record.effects) {
            // Effects are drawn around the layer with its mask already applied, so the mask goes into the pixels too.
            conversions.append(PSDConversion(layerName: record.name, message: "Layer effects were saved as part of the layer’s pixels."))
            let grown = LayerEffectsRenderer.placed(transform, image: effects.image, inset: effects.inset)
            let (pixels, rect) = try rasterize(effects.image, transform: grown)
            written.bounds = rect
            written.color = try colorChannels(pixels)
            return written
        }
        let (pixels, rect) = try rasterize(image, transform: transform)
        written.bounds = rect
        written.color = try colorChannels(pixels)
        if let maskGrid, let layerMask {
            let context = try BrushRaster.context(width: rect.right - rect.left, height: rect.bottom - rect.top, mask: true)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.translateBy(x: CGFloat(-rect.left), y: CGFloat(-rect.top))
            LayerRenderer.drawCoverage(maskGrid, transform: transform, in: context)
            guard let placed = context.makeImage() else { throw ExportError.render }
            written.mask = (try packed(grayPlane(placed), width: placed.width, height: placed.height), rect,
                            layerMask.isEnabled, layerMask.isLinked)
        }
        return written
    }

    /// `image` drawn where `transform` puts it on the document, cropped to the whole pixels it touches.
    private static func rasterize(_ image: CGImage, transform: LayerTransform) throws -> (CGImage, (top: Int, left: Int, bottom: Int, right: Int)) {
        // Snapped first, so a quarter turn's rounding (4.0000001) doesn't add a row.
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(transform.point)
            .map { CGPoint(x: ($0.x * 1024).rounded() / 1024, y: ($0.y * 1024).rounded() / 1024) }
        let left = Int(floor(corners.map(\.x).min() ?? 0)), top = Int(floor(corners.map(\.y).min() ?? 0))
        let right = Int(ceil(corners.map(\.x).max() ?? 0)), bottom = Int(ceil(corners.map(\.y).max() ?? 0))
        let width = max(1, right - left), height = max(1, bottom - top)
        guard width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
              width * height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.translateBy(x: CGFloat(-left), y: CGFloat(-top))
        LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        guard let drawn = context.makeImage() else { throw ExportError.render }
        return (drawn, (top, left, top + height, left + width))
    }

    /// A folder’s or adjustment layer’s mask, which covers the canvas.
    private static func canvasMask(_ record: ProjectLayerRecord, _ snapshot: ProjectSnapshot) throws
        -> (payload: Data, bounds: (top: Int, left: Int, bottom: Int, right: Int), enabled: Bool, linked: Bool)? {
        guard let mask = snapshot.mask(for: record) else { return nil }
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        LayerRenderer.drawCoverage(mask.asset.image, transform: mask.placement ?? record.transform, in: context)
        guard let placed = context.makeImage() else { throw ExportError.render }
        return (try packed(grayPlane(placed), width: width, height: height), (0, 0, height, width), mask.isEnabled, mask.isLinked)
    }

    private static func blendKey(_ mode: LayerBlendMode) -> String {
        switch mode {
        case .normal: "norm"
        case .multiply: "mul "
        case .screen: "scrn"
        case .overlay: "over"
        case .softLight: "sLit"
        case .darken: "dark"
        case .lighten: "lite"
        case .difference: "diff"
        case .colorDodge: "div "
        case .colorBurn: "idiv"
        case .hue: "hue "
        case .saturation: "sat "
        case .color: "colr"
        case .luminosity: "lum "
        case .linearBurn: "lbrn"
        case .linearDodge: "lddg"
        case .hardLight: "hLit"
        case .vividLight: "vLit"
        case .linearLight: "lLit"
        case .pinLight: "pLit"
        case .hardMix: "hMix"
        case .exclusion: "smud"
        case .subtract: "fsub"
        case .divide: "fdiv"
        }
    }

    private static func layerSection(_ layers: [Written]) -> Data {
        var records = PSDWriteBuffer()
        var payloads = PSDWriteBuffer()
        records.i16(Int16(layers.count))
        for layer in layers {
            writeRecord(&records, layer)
            for channel in layer.color { payloads.bytes(channel.payload) }
            if let mask = layer.mask { payloads.bytes(mask.payload) }
        }
        var info = PSDWriteBuffer()
        info.bytes(records.data)
        info.bytes(payloads.data)
        if info.data.count % 2 == 1 { info.u8(0) }
        var section = PSDWriteBuffer()
        section.u32(UInt32(info.data.count))
        section.bytes(info.data)
        section.u32(0) // Global layer mask info
        return section.data
    }

    private static func writeRecord(_ buffer: inout PSDWriteBuffer, _ layer: Written) {
        buffer.i32(Int32(clamping: layer.bounds.top))
        buffer.i32(Int32(clamping: layer.bounds.left))
        buffer.i32(Int32(clamping: layer.bounds.bottom))
        buffer.i32(Int32(clamping: layer.bounds.right))
        let channels: [(id: Int16, payload: Data)] = layer.color + (layer.mask.map { [(id: Int16(-2), payload: $0.payload)] } ?? [])
        buffer.u16(UInt16(channels.count))
        for channel in channels {
            buffer.i16(channel.id)
            buffer.u32(UInt32(channel.payload.count))
        }
        buffer.string("8BIM")
        buffer.string(layer.blendKey)
        buffer.u8(UInt8(clamping: Int((min(1, max(0, layer.opacity)) * 255).rounded())))
        buffer.u8(layer.clipping ? 1 : 0)
        // Bit 1 hides the layer; bit 3 says bit 4 is meaningful, and bit 4 that the pixels don’t affect the look.
        var flags: UInt8 = 0x08
        if !layer.isVisible { flags |= 0x02 }
        if layer.pixelsIrrelevant { flags |= 0x10 }
        buffer.u8(flags)
        buffer.u8(0)
        var extra = PSDWriteBuffer()
        if let mask = layer.mask {
            extra.u32(20)
            extra.i32(Int32(clamping: mask.bounds.top))
            extra.i32(Int32(clamping: mask.bounds.left))
            extra.i32(Int32(clamping: mask.bounds.bottom))
            extra.i32(Int32(clamping: mask.bounds.right))
            extra.u8(0) // Black outside the stored rectangle, where the layer has no pixels anyway.
            var maskFlags: UInt8 = mask.linked ? 0 : 1
            if !mask.enabled { maskFlags |= 2 }
            extra.u8(maskFlags)
            extra.u16(0)
        } else {
            extra.u32(0)
        }
        extra.u32(0) // Blending ranges
        // The Pascal name is for older readers; `luni` carries the real one.
        let pascal = Array(layer.name.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(255))
        extra.u8(UInt8(pascal.count))
        extra.bytes(Data(pascal))
        extra.bytes(Data(count: (4 - (1 + pascal.count) % 4) % 4))
        var name = PSDWriteBuffer()
        name.utf16(layer.name)
        additional(&extra, key: "luni", payload: name.data)
        if let section = layer.section {
            var payload = PSDWriteBuffer()
            payload.u32(section)
            if section != 3 {
                payload.string("8BIM")
                payload.string(layer.blendKey)
            }
            additional(&extra, key: "lsct", payload: payload.data)
        }
        if let adjustment = layer.adjustment { additional(&extra, key: adjustment.key, payload: adjustment.payload) }
        buffer.u32(UInt32(extra.data.count))
        buffer.bytes(extra.data)
    }

    private static func additional(_ buffer: inout PSDWriteBuffer, key: String, payload: Data) {
        buffer.string("8BIM")
        buffer.string(key)
        let padded = payload.count + payload.count % 2
        buffer.u32(UInt32(padded))
        buffer.bytes(payload)
        if payload.count % 2 == 1 { buffer.u8(0) }
    }

    // MARK: Adjustments

    /// 'levl': version 2, then input black, input white, output black, output white and gamma in hundredths for RGB,
    /// red, green and blue, and 25 unused records.
    private static func levels(_ settings: LevelsSettings) -> Data {
        var data = PSDWriteBuffer()
        data.u16(2)
        for channel in 0..<29 {
            let range = channel < settings.ranges.count && channel < 4 ? settings.ranges[channel].normalized : LevelRange()
            data.u16(UInt16(range.black.rounded()))
            data.u16(UInt16(range.white.rounded()))
            data.u16(UInt16(range.outputBlack.rounded()))
            data.u16(UInt16(range.outputWhite.rounded()))
            data.u16(UInt16((range.gamma * 100).rounded()))
        }
        return data.data
    }

    /// 'curv' as Photoshop writes it: a pad byte, version 1, a bitmap of the channels that follow (RGB, red, green,
    /// blue), then each channel’s points as output, input.
    private static func curves(_ settings: CurvesSettings) -> Data {
        var data = PSDWriteBuffer()
        data.u8(0)
        data.u16(1)
        let channels = Array(settings.channels.prefix(4))
        data.u32(UInt32((1 << channels.count) - 1))
        for points in channels {
            let kept = Array(points.prefix(19))
            data.u16(UInt16(kept.count))
            for point in kept {
                data.u16(UInt16(min(255, max(0, point.y)).rounded()))
                data.u16(UInt16(min(255, max(0, point.x)).rounded()))
            }
        }
        return data.data
    }

    /// 'hue2': version 2, Colorize and a pad byte, the Colorize values, the Master’s, then Reds through Magentas,
    /// each its band in degrees and its hue, saturation and lightness.
    private static func hue(_ settings: HueSaturationSettings) -> Data {
        var data = PSDWriteBuffer()
        data.u16(2)
        data.u8(settings.colorize ? 1 : 0)
        data.u8(0)
        func values(_ adjustment: RangeAdjustment) {
            data.i16(Int16(clamping: Int(adjustment.hue.rounded())))
            data.i16(Int16(clamping: Int(adjustment.saturation.rounded())))
            data.i16(Int16(clamping: Int(adjustment.lightness.rounded())))
        }
        let master = settings.adjustments[.master] ?? RangeAdjustment()
        if settings.colorize {
            var colorize = master
            if colorize.hue > 180 { colorize.hue -= 360 }
            values(colorize)
            values(RangeAdjustment())
        } else {
            values(RangeAdjustment())
            values(master)
        }
        for range in ColorRange.colorRanges {
            let band = settings.bands[range] ?? range.defaultBand
            for degrees in [band.falloffStart, band.rangeStart, band.rangeEnd, band.falloffEnd] {
                data.i16(Int16(clamping: Int(degrees.rounded())))
            }
            values(settings.adjustments[range] ?? RangeAdjustment())
        }
        return data.data
    }

    // MARK: Resources and merged image

    private static func imageResources(_ manifest: ProjectManifest) -> Data {
        var data = PSDWriteBuffer()
        // 1005, ResolutionInfo: pixels per inch as 16.16 fixed point, shown in inches.
        var resolution = PSDWriteBuffer()
        let fixed = UInt32((min(9600, max(1, manifest.resolution ?? 72)) * 65536).rounded())
        resolution.u32(fixed); resolution.u16(1); resolution.u16(1)
        resolution.u32(fixed); resolution.u16(1); resolution.u16(1)
        resource(&data, id: 1005, payload: resolution.data)
        // 1039, the ICC profile: layers are written in sRGB, as Pixegen keeps them.
        if let profile = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? {
            resource(&data, id: 1039, payload: profile)
        }
        return data.data
    }

    private static func resource(_ buffer: inout PSDWriteBuffer, id: UInt16, payload: Data) {
        buffer.string("8BIM")
        buffer.u16(id)
        buffer.u16(0) // Empty Pascal name, padded to even.
        buffer.u32(UInt32(payload.count))
        buffer.bytes(payload)
        if payload.count % 2 == 1 { buffer.u8(0) }
    }

    /// The merged image, RLE compressed: red, green and blue over white, as Photoshop stores a canvas with
    /// transparency alongside its layers.
    private static func appendComposite(_ file: inout PSDWriteBuffer, _ image: CGImage, width: Int, height: Int) throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else { throw ExportError.render }
        let planes = try rgbaPlanes(flattened)
        file.u16(1)
        var counts = Data(), rows = Data()
        for plane in [planes.red, planes.green, planes.blue] {
            let encoded = rowEncoded(plane, width: width, height: height)
            counts.append(encoded.counts)
            rows.append(encoded.rows)
        }
        file.bytes(counts)
        file.bytes(rows)
    }

    // MARK: Pixels

    private static func colorChannels(_ image: CGImage) throws -> [(id: Int16, payload: Data)] {
        let planes = try rgbaPlanes(image)
        return try [(-1, planes.alpha), (0, planes.red), (1, planes.green), (2, planes.blue)].map {
            (Int16($0.0), try packed($0.1, width: image.width, height: image.height))
        }
    }

    /// A channel’s data: compression 1 (PackBits), each row’s packed length, then the rows.
    private static func packed(_ plane: [UInt8], width: Int, height: Int) throws -> Data {
        let encoded = rowEncoded(plane, width: width, height: height)
        var data = Data([0, 1])
        data.append(encoded.counts)
        data.append(encoded.rows)
        return data
    }

    private static func rowEncoded(_ plane: [UInt8], width: Int, height: Int) -> (counts: Data, rows: Data) {
        var counts = PSDWriteBuffer()
        var rows = Data()
        for row in 0..<height {
            let encoded = packBits(plane[row * width ..< (row + 1) * width])
            counts.u16(UInt16(encoded.count))
            rows.append(encoded)
        }
        return (counts.data, rows)
    }

    private static func packBits(_ row: ArraySlice<UInt8>) -> Data {
        let row = Array(row)
        var output = Data()
        var i = 0
        while i < row.count {
            if i + 1 < row.count, row[i] == row[i + 1] {
                var run = 2
                while i + run < row.count, row[i + run] == row[i], run < 128 { run += 1 }
                output.append(UInt8(bitPattern: Int8(1 - run)))
                output.append(row[i])
                i += run
            } else {
                let start = i
                i += 1
                while i < row.count, i - start < 128 {
                    if i + 1 < row.count, row[i] == row[i + 1] { break }
                    i += 1
                }
                output.append(UInt8(i - start - 1))
                output.append(contentsOf: row[start..<i])
            }
        }
        return output
    }

    /// Straight (unpremultiplied) planes, first row at the top.
    private static func rgbaPlanes(_ image: CGImage) throws -> (red: [UInt8], green: [UInt8], blue: [UInt8], alpha: [UInt8]) {
        let width = image.width, height = image.height
        let context = try BrushRaster.copy(image)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        let count = width * height
        var red = [UInt8](repeating: 0, count: count), green = red, blue = red, alpha = red
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x, p = y * stride + x * 4
                let a = Int(data[p + 3])
                alpha[i] = UInt8(a)
                guard a > 0 else { continue }
                red[i] = UInt8(min(255, (Int(data[p]) * 255 + a / 2) / a))
                green[i] = UInt8(min(255, (Int(data[p + 1]) * 255 + a / 2) / a))
                blue[i] = UInt8(min(255, (Int(data[p + 2]) * 255 + a / 2) / a))
            }
        }
        return (red, green, blue, alpha)
    }

    private static func grayPlane(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var plane = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { plane[y * width + x] = data[y * context.bytesPerRow + x] }
        }
        return plane
    }
}

/// Big-endian bytes, as every Photoshop field is stored.
nonisolated private struct PSDWriteBuffer {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xff)) }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { u16(UInt16(value >> 16)); u16(UInt16(value & 0xffff)) }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func string(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
    mutating func utf16(_ value: String) {
        let units = Array(value.utf16)
        u32(UInt32(units.count))
        for unit in units { u16(unit) }
    }
}

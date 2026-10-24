import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import zlib
import libwebp

/// Writes slices (File › Export for Web) from a flattened canvas: each slice cut out, scaled and encoded in each of its
/// formats.
actor SliceExporter {
    static let shared = SliceExporter()

    /// One slice in one format, as the file it writes.
    func data(for slice: CanvasSlice, format: SliceFormat, composite: CGImage) async throws -> Data {
        try Task.checkCancellation()
        let image = try Self.image(of: slice.rect, format: format, in: composite)
        return try await Self.encode(image, format: format)
    }

    /// The Export panel's picture of a slice, at most `side` points on its long side.
    func thumbnail(of rect: CGRect, in composite: CGImage, side: CGFloat) throws -> CGImage {
        let scale = min(1, side / max(rect.width, rect.height))
        var format = SliceFormat(scale: scale)
        format.keepsTransparency = true
        return try Self.image(of: rect, format: format, in: composite)
    }

    /// Writes every slice in every format into `folder`, returning the files' URLs. Names that would collide get a
    /// number added, so no file overwrites another from the same export.
    func export(_ slices: [CanvasSlice], composite: CGImage, to folder: URL) async throws -> [URL] {
        var written: [URL] = []
        for (url, slice, format) in Self.destinations(for: slices, in: folder) {
            let data = try await data(for: slice, format: format, composite: composite)
            try data.write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }

    /// Where each slice's formats go in `folder`, in order: the slice's file names, numbered where two would match.
    nonisolated static func destinations(for slices: [CanvasSlice], in folder: URL) -> [(URL, CanvasSlice, SliceFormat)] {
        var used = Set<String>()
        var result: [(URL, CanvasSlice, SliceFormat)] = []
        for slice in slices {
            for format in slice.formats {
                let name = slice.fileName(for: format)
                let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                var candidate = name, number = 2
                while used.contains(candidate.lowercased()) {
                    candidate = "\(stem) \(number).\(ext)"
                    number += 1
                }
                used.insert(candidate.lowercased())
                result.append((folder.appendingPathComponent(candidate), slice, format))
            }
        }
        return result
    }

    // MARK: Pixels

    /// The slice's pixels at the format's size, premultiplied sRGB, flattened onto white where the format keeps no
    /// transparency.
    nonisolated static func image(of rect: CGRect, format: SliceFormat, in composite: CGImage) throws -> CGImage {
        let size = format.outputSize(for: rect.size)
        guard size.width * size.height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: size.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if !format.keepsTransparency || !format.type.supportsTransparency {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
        }
        context.interpolationQuality = .high
        // The composite's pixels for the slice, placed so the slice fills the output.
        let canvas = CGRect(x: 0, y: 0, width: composite.width, height: composite.height)
        let source = rect.intersection(canvas)
        if !source.isNull, !source.isEmpty, let cut = composite.cropping(to: source) {
            let sx = CGFloat(size.width) / rect.width, sy = CGFloat(size.height) / rect.height
            // Core Graphics is y-up: the slice's top lands at the context's top.
            let placed = CGRect(x: (source.minX - rect.minX) * sx, y: (rect.maxY - source.maxY) * sy,
                                width: source.width * sx, height: source.height * sy)
            context.draw(cut, in: placed)
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// Unpremultiplied RGBA bytes, row by row with no padding.
    nonisolated static func rgba(of image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return bytes
    }

    // MARK: Encoding

    nonisolated static func encode(_ image: CGImage, format: SliceFormat) async throws -> Data {
        switch format.type {
        case .jpeg:
            return try imageIO(tagged(image, format), type: .jpeg,
                               properties: [kCGImageDestinationLossyCompressionQuality: format.quality])
        case .png: return try png(image, format: format)
        case .gif: return try imageIO(tagged(image, format), type: .gif)
        case .webP: return try webP(image, quality: format.quality)
        case .svg: return try svg(image, format: format)
        case .mp4: return try await mp4(image)
        }
    }

    /// Without Convert to sRGB, the same pixels carrying no profile.
    private nonisolated static func tagged(_ image: CGImage, _ format: SliceFormat) -> CGImage {
        format.convertsToSRGB ? image : image.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) ?? image
    }

    private nonisolated static func imageIO(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ExportError.encode
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    private nonisolated static func png(_ image: CGImage, format: SliceFormat) throws -> Data {
        guard format.limitedPalette || format.advancedCompression else { return try imageIO(tagged(image, format), type: .png) }
        let pixels = try rgba(of: image)
        let level: Int32 = format.advancedCompression ? 9 : 6
        if format.limitedPalette {
            let quantized = PaletteQuantizer.quantize(pixels, maxColors: 256)
            return try PNGWriter.indexed(width: image.width, height: image.height, indices: quantized.indices,
                                         palette: quantized.palette, level: level, sRGB: format.convertsToSRGB)
        }
        return try PNGWriter.truecolor(width: image.width, height: image.height, rgba: pixels, level: level, sRGB: format.convertsToSRGB)
    }

    private nonisolated static func webP(_ image: CGImage, quality: Double) throws -> Data {
        let pixels = try rgba(of: image)
        var output: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buffer in
            WebPEncodeRGBA(buffer.baseAddress, Int32(image.width), Int32(image.height), Int32(image.width * 4),
                           Float(min(1, max(0, quality)) * 100), &output)
        }
        defer { WebPFree(output) }
        guard size > 0, let output else { throw ExportError.encode }
        return Data(bytes: output, count: size)
    }

    /// An SVG holding the slice as an embedded PNG, at its exported size.
    private nonisolated static func svg(_ image: CGImage, format: SliceFormat) throws -> Data {
        var embedded = format
        embedded.type = .png
        let png = try png(image, format: embedded)
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(image.width)" height="\(image.height)" viewBox="0 0 \(image.width) \(image.height)">
          <image width="\(image.width)" height="\(image.height)" xlink:href="data:image/png;base64,\(png.base64EncodedString())"/>
        </svg>

        """
        return Data(svg.utf8)
    }

    /// A one-second H.264 video of the still slice, as a web page's looping or poster video starts from.
    private nonisolated static func mp4(_ image: CGImage) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: image.width, AVVideoHeightKey: image.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: image.width, kCVPixelBufferHeightKey as String: image.height,
        ])
        guard writer.canAdd(input) else { throw ExportError.encode }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.encode }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.encode }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw ExportError.encode }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard context != nil else { throw ExportError.render }
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        guard adaptor.append(buffer, withPresentationTime: .zero) else { throw writer.error ?? ExportError.encode }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.encode }
        return try Data(contentsOf: url)
    }
}

/// Reduces an image to a palette of at most 256 colors by median cut, transparency included, for an indexed PNG.
nonisolated enum PaletteQuantizer {
    struct Result {
        /// RGBA, unpremultiplied.
        var palette: [[UInt8]]
        var indices: [UInt8]
    }

    /// `rgba`: unpremultiplied, four bytes a pixel. Fully transparent pixels share one entry.
    static func quantize(_ rgba: [UInt8], maxColors: Int) -> Result {
        let count = rgba.count / 4
        // Colors bucketed at 5 bits of red, green and blue and 4 of alpha: few enough to sort, fine enough to look right.
        func key(_ i: Int) -> Int {
            (Int(rgba[i] >> 3) << 14) | (Int(rgba[i + 1] >> 3) << 9) | (Int(rgba[i + 2] >> 3) << 4) | Int(rgba[i + 3] >> 4)
        }
        var counts = [Int](repeating: 0, count: 1 << 19)
        var sums = [Int](repeating: 0, count: (1 << 19) * 4)
        var hasClear = false
        for pixel in 0..<count {
            let i = pixel * 4
            if rgba[i + 3] == 0 { hasClear = true; continue }
            let k = key(i)
            counts[k] += 1
            for channel in 0..<4 { sums[k * 4 + channel] += Int(rgba[i + channel]) }
        }
        let buckets = counts.indices.filter { counts[$0] > 0 }
        var palette: [[UInt8]] = hasClear ? [[0, 0, 0, 0]] : []
        let available = max(1, maxColors - palette.count)
        // Each bucket's average color.
        let colors = buckets.map { k in (0..<4).map { sums[k * 4 + $0] / counts[k] } }
        var boxes: [[Int]] = buckets.isEmpty ? [] : [Array(colors.indices)]
        func extent(_ box: [Int]) -> (channel: Int, range: Int) {
            var best = (channel: 0, range: -1)
            for channel in 0..<4 {
                var low = 255, high = 0
                for index in box { low = min(low, colors[index][channel]); high = max(high, colors[index][channel]) }
                if high - low > best.range { best = (channel, high - low) }
            }
            return best
        }
        while boxes.count < available {
            // Split the box spanning the widest range, weighted by how many pixels it holds.
            var choice: (box: Int, channel: Int, score: Double)?
            for (index, box) in boxes.enumerated() where box.count > 1 {
                let span = extent(box)
                let pixels = box.reduce(0) { $0 + counts[buckets[$1]] }
                let score = Double(span.range) * sqrt(Double(pixels))
                if span.range > 0, choice.map({ score > $0.score }) ?? true { choice = (index, span.channel, score) }
            }
            guard let choice else { break }
            let sorted = boxes[choice.box].sorted { colors[$0][choice.channel] < colors[$1][choice.channel] }
            let total = sorted.reduce(0) { $0 + counts[buckets[$1]] }
            var running = 0, split = 1
            for (position, index) in sorted.enumerated() {
                running += counts[buckets[index]]
                if running * 2 >= total { split = max(1, min(sorted.count - 1, position + 1)); break }
            }
            boxes[choice.box] = Array(sorted[..<split])
            boxes.append(Array(sorted[split...]))
        }
        for box in boxes {
            var total = 0, sum = [0, 0, 0, 0]
            for index in box {
                let weight = counts[buckets[index]]
                total += weight
                for channel in 0..<4 { sum[channel] += colors[index][channel] * weight }
            }
            palette.append(sum.map { UInt8(clamping: $0 / max(1, total)) })
        }
        if palette.isEmpty { palette = [[0, 0, 0, 0]] }
        // Each pixel takes its nearest entry, worked out once per bucket.
        var nearest = [Int16](repeating: -1, count: 1 << 19)
        var indices = [UInt8](repeating: 0, count: count)
        for pixel in 0..<count {
            let i = pixel * 4
            if rgba[i + 3] == 0 { indices[pixel] = 0; continue }
            let k = key(i)
            if nearest[k] < 0 {
                var best = 0, bestDistance = Int.max
                for (entry, color) in palette.enumerated() where !(hasClear && entry == 0) {
                    var distance = 0
                    for channel in 0..<4 {
                        let d = Int(rgba[i + channel]) - Int(color[channel])
                        distance += d * d
                    }
                    if distance < bestDistance { best = entry; bestDistance = distance }
                }
                nearest[k] = Int16(best)
            }
            indices[pixel] = UInt8(nearest[k])
        }
        return Result(palette: palette, indices: indices)
    }
}

/// A PNG encoder for what ImageIO can't write: indexed color with transparency, and the smallest deflate.
nonisolated enum PNGWriter {
    /// An 8-bit indexed PNG; `palette` entries are RGBA, and a transparency chunk is written only when one isn't opaque.
    static func indexed(width: Int, height: Int, indices: [UInt8], palette: [[UInt8]], level: Int32, sRGB: Bool) throws -> Data {
        var rows = Data(capacity: (width + 1) * height)
        for y in 0..<height {
            rows.append(0)
            rows.append(contentsOf: indices[(y * width)..<((y + 1) * width)])
        }
        var chunks: [(String, Data)] = [("IHDR", header(width: width, height: height, colorType: 3))]
        if sRGB { chunks.append(("sRGB", Data([0]))) }
        chunks.append(("PLTE", Data(palette.flatMap { $0.prefix(3) })))
        var alphas = palette.map { $0[3] }
        while alphas.last == 255 { alphas.removeLast() }
        if !alphas.isEmpty { chunks.append(("tRNS", Data(alphas))) }
        chunks.append(("IDAT", try deflate(rows, level: level)))
        return assemble(chunks)
    }

    /// An 8-bit RGBA PNG, or RGB when every pixel is opaque, each row filtered whichever way makes it smallest.
    static func truecolor(width: Int, height: Int, rgba: [UInt8], level: Int32, sRGB: Bool) throws -> Data {
        let opaque = stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 }
        let channels = opaque ? 3 : 4
        let stride = width * channels
        var pixels = [UInt8](repeating: 0, count: stride * height)
        if opaque {
            for pixel in 0..<(width * height) {
                pixels[pixel * 3] = rgba[pixel * 4]
                pixels[pixel * 3 + 1] = rgba[pixel * 4 + 1]
                pixels[pixel * 3 + 2] = rgba[pixel * 4 + 2]
            }
        } else { pixels = rgba }
        var rows = Data(capacity: (stride + 1) * height)
        var candidate = [UInt8](repeating: 0, count: stride)
        var best = [UInt8](repeating: 0, count: stride)
        for y in 0..<height {
            let row = y * stride, above = (y - 1) * stride
            var bestFilter: UInt8 = 0, bestScore = Int.max
            for filter in UInt8(0)...4 {
                var score = 0
                for x in 0..<stride {
                    let value = Int(pixels[row + x])
                    let left = x >= channels ? Int(pixels[row + x - channels]) : 0
                    let up = y > 0 ? Int(pixels[above + x]) : 0
                    let upLeft = y > 0 && x >= channels ? Int(pixels[above + x - channels]) : 0
                    let predicted: Int
                    switch filter {
                    case 1: predicted = left
                    case 2: predicted = up
                    case 3: predicted = (left + up) / 2
                    case 4: predicted = paeth(left, up, upLeft)
                    default: predicted = 0
                    }
                    let filtered = UInt8(truncatingIfNeeded: value - predicted)
                    candidate[x] = filtered
                    score += filtered < 128 ? Int(filtered) : 256 - Int(filtered)
                }
                if score < bestScore {
                    bestScore = score
                    bestFilter = filter
                    swap(&candidate, &best)
                }
            }
            rows.append(bestFilter)
            rows.append(contentsOf: best)
        }
        var chunks: [(String, Data)] = [("IHDR", header(width: width, height: height, colorType: opaque ? 2 : 6))]
        if sRGB { chunks.append(("sRGB", Data([0]))) }
        chunks.append(("IDAT", try deflate(rows, level: level)))
        return assemble(chunks)
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
    }

    private static func header(width: Int, height: Int, colorType: UInt8) -> Data {
        var data = Data()
        data.append(bigEndian: UInt32(width))
        data.append(bigEndian: UInt32(height))
        data.append(contentsOf: [8, colorType, 0, 0, 0])
        return data
    }

    private static func assemble(_ chunks: [(String, Data)]) -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for (type, body) in chunks + [("IEND", Data())] {
            png.append(bigEndian: UInt32(body.count))
            var typed = Data(type.utf8)
            typed.append(body)
            png.append(typed)
            let crc = typed.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            png.append(bigEndian: UInt32(crc))
        }
        return png
    }

    /// zlib-wrapped deflate, as PNG's image data is.
    static func deflate(_ input: Data, level: Int32) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ExportError.encode
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(input.count))))
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw ExportError.encode }
        output.count = Int(stream.total_out)
        return output
    }
}

private extension Data {
    nonisolated mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

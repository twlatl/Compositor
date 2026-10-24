import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Reads the swatch files Photoshop's Swatches panel loads: Adobe Color Swatch (.aco), Adobe Swatch Exchange (.ase),
/// Adobe Color Table (.act), and colors written in web files (.css, .html, .svg). Writes .ase for Export Swatches
/// for Exchange.
nonisolated enum SwatchFile {
    static let extensions = ["aco", "ase", "act", "css", "html", "htm", "svg"]
    static var contentTypes: [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }

    enum ReadError: LocalizedError {
        case unsupported(String)
        case damaged
        case empty
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): "Pixegen can't read “.\(ext)” swatch files. Choose an .aco, .ase, .act, .css, .html or .svg file."
            case .damaged: "The swatch file is damaged or isn't in the format its name says."
            case .empty: "The file holds no colors Pixegen can read."
            }
        }
    }

    /// The folders a file holds. Files without folders of their own give one, called `name`.
    static func read(_ data: Data, named name: String, extension ext: String) throws -> [SwatchGroup] {
        let groups: [SwatchGroup]
        switch ext.lowercased() {
        case "aco": groups = [SwatchGroup(name: name, swatches: try readACO(data))]
        case "ase": groups = try readASE(data, named: name)
        case "act": groups = [SwatchGroup(name: name, swatches: try readACT(data))]
        case "css", "html", "htm", "svg":
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw ReadError.damaged }
            groups = [SwatchGroup(name: name, swatches: readWebColors(text))]
        default: throw ReadError.unsupported(ext)
        }
        let kept = groups.filter { !$0.swatches.isEmpty }
        guard !kept.isEmpty else { throw ReadError.empty }
        return kept
    }

    // MARK: Adobe Color Swatch

    /// Version 1 holds colors only; a version 2 section after it repeats them with names, and is preferred.
    static func readACO(_ data: Data) throws -> [Swatch] {
        var reader = BigEndianReader(data)
        guard try reader.uint16() == 1 else { throw ReadError.damaged }
        let count = Int(try reader.uint16())
        var unnamed: [Swatch] = []
        for _ in 0..<count {
            let space = try reader.uint16()
            let values = try (0..<4).map { _ in try reader.uint16() }
            if let color = acoColor(space: space, values) { unnamed.append(Swatch(name: color.quantized.hex, color: color)) }
        }
        guard reader.remaining >= 4, (try? reader.uint16()) == 2 else { return unnamed }
        let namedCount = Int(try reader.uint16())
        var named: [Swatch] = []
        for _ in 0..<namedCount {
            let space = try reader.uint16()
            let values = try (0..<4).map { _ in try reader.uint16() }
            let name = try reader.utf16String(lengthBytes: 4)
            if let color = acoColor(space: space, values) {
                named.append(Swatch(name: name.isEmpty ? color.quantized.hex : name, color: color))
            }
        }
        return named
    }

    /// Color spaces other than RGB, HSB, CMYK, Lab and grayscale (Pantone, Focoltone and the like) are skipped.
    private static func acoColor(space: UInt16, _ v: [UInt16]) -> PaletteColor? {
        func unit(_ value: UInt16) -> Double { Double(value) / 65535 }
        switch space {
        case 0: return PaletteColor(red: unit(v[0]), green: unit(v[1]), blue: unit(v[2]))
        case 1: return PickerHSB(hue: unit(v[0]) * 360, saturation: unit(v[1]), brightness: unit(v[2])).rgb
        // 0 is full ink, 65535 none.
        case 2: return cmyk(1 - unit(v[0]), 1 - unit(v[1]), 1 - unit(v[2]), 1 - unit(v[3]))
        case 7: return lab(Double(v[0]) / 100, Double(Int16(bitPattern: v[1])) / 100, Double(Int16(bitPattern: v[2])) / 100)
        // 0–10000 is the percentage of black ink, as Photoshop's grayscale mode measures it.
        case 8: let gray = 1 - min(1, Double(v[0]) / 10000); return PaletteColor(red: gray, green: gray, blue: gray)
        default: return nil
        }
    }

    // MARK: Adobe Swatch Exchange

    static func readASE(_ data: Data, named name: String) throws -> [SwatchGroup] {
        var reader = BigEndianReader(data)
        guard try reader.bytes(4) == Data("ASEF".utf8) else { throw ReadError.damaged }
        _ = try reader.uint16(); _ = try reader.uint16() // Version 1.0.
        let blocks = Int(try reader.uint32())
        var loose = SwatchGroup(name: name)
        var groups: [SwatchGroup] = []
        var open: SwatchGroup?
        for _ in 0..<blocks {
            let type = try reader.uint16()
            let length = Int(try reader.uint32())
            var block = BigEndianReader(try reader.bytes(length))
            switch type {
            case 0xC001:
                if let open { groups.append(open) }
                open = SwatchGroup(name: try block.utf16String(lengthBytes: 2))
            case 0xC002:
                if let group = open { groups.append(group) }
                open = nil
            case 0x0001:
                let swatchName = try block.utf16String(lengthBytes: 2)
                let model = String(decoding: try block.bytes(4), as: UTF8.self)
                let color: PaletteColor?
                switch model {
                case "RGB ": color = PaletteColor(red: Double(try block.float32()), green: Double(try block.float32()), blue: Double(try block.float32()))
                case "CMYK": color = cmyk(Double(try block.float32()), Double(try block.float32()), Double(try block.float32()), Double(try block.float32()))
                case "Gray": let gray = Double(try block.float32()); color = PaletteColor(red: gray, green: gray, blue: gray)
                case "LAB ": color = lab(Double(try block.float32()) * 100, Double(try block.float32()), Double(try block.float32()))
                default: color = nil
                }
                guard let color = color.map(clamped) else { continue }
                let swatch = Swatch(name: swatchName.isEmpty ? color.quantized.hex : swatchName, color: color)
                if open != nil { open?.swatches.append(swatch) } else { loose.swatches.append(swatch) }
            default: continue
            }
        }
        if let open { groups.append(open) }
        return (loose.swatches.isEmpty ? [] : [loose]) + groups
    }

    /// Every folder as a group of RGB swatches.
    static func writeASE(_ groups: [SwatchGroup]) -> Data {
        var blocks = Data()
        var count: UInt32 = 0
        func block(_ type: UInt16, _ body: Data) {
            blocks.appendBigEndian(type)
            blocks.appendBigEndian(UInt32(body.count))
            blocks.append(body)
            count += 1
        }
        func utf16(_ text: String) -> Data {
            var body = Data()
            let units = Array(text.utf16) + [0]
            body.appendBigEndian(UInt16(units.count))
            for unit in units { body.appendBigEndian(unit) }
            return body
        }
        for group in groups {
            block(0xC001, utf16(group.name))
            for swatch in group.swatches {
                var body = utf16(swatch.name)
                body.append(Data("RGB ".utf8))
                for value in [swatch.red, swatch.green, swatch.blue] { body.appendBigEndian(Float32(value).bitPattern) }
                body.appendBigEndian(UInt16(2)) // Normal, neither global nor spot.
                block(0x0001, body)
            }
            block(0xC002, Data())
        }
        var data = Data("ASEF".utf8)
        data.appendBigEndian(UInt16(1)); data.appendBigEndian(UInt16(0))
        data.appendBigEndian(count)
        data.append(blocks)
        return data
    }

    // MARK: Adobe Color Table

    /// 256 RGB triplets, optionally followed by how many are used and which one is transparent.
    static func readACT(_ data: Data) throws -> [Swatch] {
        guard data.count == 768 || data.count == 772 else { throw ReadError.damaged }
        var count = 256
        var transparent: Int?
        if data.count == 772 {
            var tail = BigEndianReader(data.subdata(in: 768..<772))
            count = min(256, Int(try tail.uint16()))
            let index = Int(try tail.uint16())
            transparent = index == 0xFFFF ? nil : index
        }
        let bytes = [UInt8](data)
        return (0..<count).compactMap { index in
            guard index != transparent else { return nil }
            let color = PaletteColor(red: Double(bytes[index * 3]) / 255, green: Double(bytes[index * 3 + 1]) / 255,
                                     blue: Double(bytes[index * 3 + 2]) / 255)
            return Swatch(name: color.hex, color: color)
        }
    }

    // MARK: Web files

    /// Hex colors (`#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`) and `rgb()`/`rgba()` colors, in the order they first
    /// appear, each once; alpha is dropped. A color set on a CSS custom property (`--brand-red: #c00`) takes its name.
    /// Named colors (`red`, `teal`) are not read.
    static func readWebColors(_ text: String) -> [Swatch] {
        let pattern = #"(?:(--[A-Za-z0-9_-]+)\s*:\s*)?(#[0-9A-Fa-f]{3,8}\b|rgba?\(\s*[0-9.]+%?\s*[, ]\s*[0-9.]+%?\s*[, ]\s*[0-9.]+%?\s*(?:[,/]\s*[0-9.]+%?\s*)?\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        var seen = Set<String>()
        var swatches: [Swatch] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let token = source.substring(with: match.range(at: 2))
            guard let color = webColor(token) else { continue }
            let hex = color.hex
            guard seen.insert(hex).inserted else { continue }
            let property = match.range(at: 1).location == NSNotFound ? nil : String(source.substring(with: match.range(at: 1)).dropFirst(2))
            swatches.append(Swatch(name: property ?? "#" + hex, color: color))
        }
        return swatches
    }

    private static func webColor(_ token: String) -> PaletteColor? {
        if token.hasPrefix("#") {
            var digits = String(token.dropFirst())
            switch digits.count {
            case 3, 6: break
            case 4, 8: digits.removeLast(digits.count / 4)
            default: return nil
            }
            return PaletteColor(hex: digits)
        }
        let inside = token.drop { $0 != "(" }.dropFirst().dropLast()
        let parts = inside.split(whereSeparator: { ", /".contains($0) }).prefix(3)
        guard parts.count == 3 else { return nil }
        let channels = parts.compactMap { part -> Double? in
            if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
            return Double(part).map { $0 / 255 }
        }
        guard channels.count == 3 else { return nil }
        return clamped(PaletteColor(red: channels[0], green: channels[1], blue: channels[2])).quantized
    }

    // MARK: Color models

    /// Ink amounts 0–1, through the generic CMYK space, as Photoshop shows a CMYK swatch on screen.
    private static func cmyk(_ c: Double, _ m: Double, _ y: Double, _ k: Double) -> PaletteColor? {
        convert([c, m, y, k, 1], from: CGColorSpace(name: CGColorSpace.genericCMYK))
    }

    /// L 0–100, a and b about ±128, against D50 as Photoshop's Lab is.
    private static func lab(_ l: Double, _ a: Double, _ b: Double) -> PaletteColor? {
        let space = CGColorSpace(labWhitePoint: [0.9642, 1, 0.8249], blackPoint: [0, 0, 0], range: [-128, 127, -128, 127])
        return convert([l, a, b, 1], from: space)
    }

    private static func convert(_ components: [CGFloat], from space: CGColorSpace?) -> PaletteColor? {
        guard let space, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGColor(colorSpace: space, components: components)?.converted(to: srgb, intent: .relativeColorimetric, options: nil),
              let rgb = color.components, rgb.count >= 3 else { return nil }
        return clamped(PaletteColor(red: rgb[0], green: rgb[1], blue: rgb[2]))
    }

    private static func clamped(_ color: PaletteColor) -> PaletteColor {
        func unit(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(0, value)) : 0 }
        return PaletteColor(red: unit(color.red), green: unit(color.green), blue: unit(color.blue))
    }
}

/// Reads the big-endian fields Adobe's swatch formats are made of, throwing at the end of the data.
private nonisolated struct BigEndianReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; offset = data.startIndex }
    var remaining: Int { data.endIndex - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw SwatchFile.ReadError.damaged }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    mutating func uint16() throws -> UInt16 {
        try bytes(2).reduce(0) { $0 << 8 | UInt16($1) }
    }
    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
    mutating func float32() throws -> Float32 { Float32(bitPattern: try uint32()) }
    /// A UTF-16 string preceded by its length in code units, the terminating zero included.
    mutating func utf16String(lengthBytes: Int) throws -> String {
        let count = lengthBytes == 4 ? Int(try uint32()) : Int(try uint16())
        var units = try (0..<count).map { _ in try uint16() }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

private nonisolated extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

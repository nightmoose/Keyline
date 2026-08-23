import AppKit
import Foundation
import ImageIO

enum PSDParser {
    private static let largeLengthKeys: Set<String> = [
        "LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph",
        "FMsk", "lnk2", "FEid", "FXid", "PxSD", "lnkE", "extd", "cinf",
        "lnkD", "cinf"
    ]

    private static let adjustmentKeys: Set<String> = [
        "brit", "levl", "curv", "expA", "vibA", "hue2", "hue ", "blnc",
        "blwh", "phfl", "mixr", "clrL", "nvrt", "post", "thrs", "grdm",
        "selc", "infx"
    ]

    static func parse(_ data: Data) throws -> PhotoshopFile {
        var reader = BinaryReader(data: data)
        let header = try parseHeader(&reader)

        let colorModeLength = Int(try reader.u32("color mode length"))
        try reader.skip(colorModeLength, "color mode data")

        var dpi = 72.0
        var thumbnail: NSImage?
        var iccName: String?
        try parseImageResources(&reader, dpi: &dpi, thumbnail: &thumbnail, iccName: &iccName)

        var layers: [PSDLayer] = []
        var parseError: String?
        do {
            layers = try parseLayerAndMask(&reader, header: header)
        } catch {
            parseError = "Layer structure could not be fully parsed. The composite preview is still shown. (\(error.localizedDescription))"
        }

        let composite = ImageIOLoader.compositeImage(from: data) ?? thumbnail
        if iccName == nil {
            iccName = ImageIOLoader.colorProfileName(from: data)
        }

        return PhotoshopFile(
            header: header,
            layers: layers,
            compositeImage: composite,
            thumbnail: thumbnail,
            dpi: dpi,
            colorProfileName: iccName,
            parseError: parseError
        )
    }

    static func parseHeader(_ reader: inout BinaryReader) throws -> PSDHeader {
        let signature = try reader.fourCC("signature")
        guard signature == "8BPS" else { throw ArtworkError.notPhotoshop }
        let version = try reader.u16("version")
        guard version == 1 || version == 2 else {
            throw ArtworkError.unsupportedPhotoshop("Unknown PSD version \(version).")
        }
        try reader.skip(6, "reserved")
        let channels = Int(try reader.u16("channels"))
        let height = Int(try reader.u32("height"))
        let width = Int(try reader.u32("width"))
        let depth = Int(try reader.u16("depth"))
        let modeRaw = Int(try reader.u16("color mode"))
        let mode = PSDColorMode(rawValue: modeRaw) ?? .unknown
        return PSDHeader(
            isPSB: version == 2,
            channels: channels,
            height: height,
            width: width,
            depth: depth,
            colorMode: mode,
            hasMergedAlpha: false
        )
    }

    private static func parseImageResources(
        _ reader: inout BinaryReader,
        dpi: inout Double,
        thumbnail: inout NSImage?,
        iccName: inout String?
    ) throws {
        let length = Int(try reader.u32("image resources length"))
        let end = reader.offset + length
        try reader.require(length, "image resources")
        while reader.offset + 6 <= end {
            let signature = try reader.fourCC("resource signature")
            if signature != "8BIM" && signature != "MeSa" {
                break
            }
            let id = try reader.u16("resource id")
            _ = try reader.pascalStringPaddedEven("resource name")
            let size = Int(try reader.u32("resource size"))
            let data = try reader.read(size, "resource data")
            if size % 2 == 1 && reader.offset < end {
                try reader.skip(1, "resource pad")
            }
            switch id {
            case 1005:
                if data.count >= 4 {
                    var inner = BinaryReader(data: data)
                    let fixed = try inner.u32("hRes")
                    dpi = Double(fixed) / 65536.0
                    if dpi <= 0 { dpi = 72 }
                }
            case 1033, 1036:
                thumbnail = decodeThumbnail(data)
            case 1039:
                if let name = iccProfileDescription(data) {
                    iccName = name
                }
            default:
                break
            }
        }
        if reader.offset < end {
            try reader.seek(end, "end of image resources")
        }
    }

    private static func decodeThumbnail(_ data: Data) -> NSImage? {
        guard data.count > 28 else { return nil }
        let jpeg = data.subdata(in: 28..<data.count)
        return NSImage(data: jpeg) ?? ImageIOLoader.image(from: jpeg)
    }

    private static func iccProfileDescription(_ data: Data) -> String? {
        // ICC header is 128 bytes; description tag 'desc' is optional. Fall back to size.
        if data.count >= 128 {
            return "Embedded ICC profile (\(data.count) bytes)"
        }
        return nil
    }

    private static func parseLayerAndMask(_ reader: inout BinaryReader, header: PSDHeader) throws -> [PSDLayer] {
        let isPSB = header.isPSB
        let sectionLength = Int(isPSB ? try reader.u64("layer section length") : UInt64(try reader.u32("layer section length")))
        let sectionEnd = reader.offset + sectionLength
        if sectionLength == 0 {
            return []
        }
        try reader.require(sectionLength, "layer and mask section")

        var layers = try parseLayerInfo(&reader, isPSB: isPSB, depth: header.depth, colorMode: header.colorMode)

        if reader.offset + 4 <= sectionEnd {
            let globalMaskLength = Int(try reader.u32("global mask length"))
            if globalMaskLength > 0 {
                try reader.skip(min(globalMaskLength, max(0, sectionEnd - reader.offset)), "global mask")
            }
        }

        while reader.offset + 12 <= sectionEnd {
            let start = reader.offset
            let signature = try reader.fourCC("extra signature")
            if signature != "8BIM" && signature != "8B64" {
                reader.offset = start
                break
            }
            let key = try reader.fourCC("extra key")
            let useLong = isPSB && largeLengthKeys.contains(key)
            let length = Int(useLong ? try reader.u64("extra length") : UInt64(try reader.u32("extra length")))
            let block = try reader.read(min(length, max(0, sectionEnd - reader.offset)), "extra data")
            if length % 2 == 1 && reader.offset < sectionEnd {
                try reader.skip(1, "extra pad")
            }
            if layers.isEmpty && (key == "Layr" || key == "Lr16" || key == "Lr32") {
                var inner = BinaryReader(data: block)
                layers = try readLayerRecords(reader: &inner, isPSB: isPSB, depth: header.depth, colorMode: header.colorMode)
            }
        }

        if reader.offset < sectionEnd {
            try reader.seek(sectionEnd, "end of layer section")
        }
        return buildLayerTree(layers)
    }

    private static func parseLayerInfo(_ reader: inout BinaryReader, isPSB: Bool, depth: Int, colorMode: PSDColorMode) throws -> [PSDLayer] {
        let length = Int(isPSB ? try reader.u64("layer info length") : UInt64(try reader.u32("layer info length")))
        let end = reader.offset + length
        if length < 2 {
            if reader.offset < end { try reader.seek(end, "empty layer info") }
            return []
        }
        let layers = try readLayerRecords(reader: &reader, isPSB: isPSB, depth: depth, colorMode: colorMode)
        if reader.offset < end {
            try reader.seek(end, "end of layer info")
        }
        return layers
    }

    private struct ChannelInfo {
        var id: Int
        var dataLength: Int
    }

    private static func readLayerRecords(
        reader: inout BinaryReader,
        isPSB: Bool,
        depth: Int,
        colorMode: PSDColorMode
    ) throws -> [PSDLayer] {
        var count = Int(try reader.i16("layer count"))
        if count == 0 { return [] }
        if count < 0 { count = -count }

        var records: [(layer: PSDLayer, channels: [ChannelInfo])] = []
        records.reserveCapacity(count)

        for _ in 0..<count {
            let top = Int(try reader.i32("layer top"))
            let left = Int(try reader.i32("layer left"))
            let bottom = Int(try reader.i32("layer bottom"))
            let right = Int(try reader.i32("layer right"))
            let channelCount = Int(try reader.u16("layer channels"))
            var channels: [ChannelInfo] = []
            channels.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                let id = Int(try reader.i16("channel id"))
                let length = Int(isPSB ? try reader.u64("channel length") : UInt64(try reader.u32("channel length")))
                channels.append(ChannelInfo(id: id, dataLength: max(0, length)))
            }
            let blendSig = try reader.fourCC("blend signature")
            guard blendSig == "8BIM" else {
                throw ArtworkError.truncated("layer blend signature")
            }
            let blendMode = try reader.fourCC("blend mode")
            let opacity = try reader.u8("opacity")
            let clipping = try reader.u8("clipping")
            let flags = try reader.u8("flags")
            try reader.skip(1, "filler")
            let extraLength = Int(try reader.u32("layer extra"))
            let extraEnd = reader.offset + extraLength

            let maskLength = Int(try reader.u32("mask length"))
            if maskLength > 0 {
                try reader.skip(maskLength, "mask data")
            }
            let rangesLength = Int(try reader.u32("blend ranges"))
            if rangesLength > 0 {
                try reader.skip(rangesLength, "blend ranges")
            }
            var name = try reader.pascalStringPadded4("layer name")
            var sectionType = PSDSectionType.any
            var kind = PSDLayerKind.pixel
            var extraKeys: Set<String> = []

            while reader.offset + 12 <= extraEnd {
                let sig = try reader.fourCC("layer info sig")
                if sig != "8BIM" && sig != "8B64" {
                    break
                }
                let key = try reader.fourCC("layer info key")
                extraKeys.insert(key)
                let useLong = isPSB && largeLengthKeys.contains(key)
                let length = Int(useLong ? try reader.u64("layer info length") : UInt64(try reader.u32("layer info length")))
                let payload = try reader.read(min(length, max(0, extraEnd - reader.offset)), "layer info data")
                if length % 2 == 1 && reader.offset < extraEnd {
                    try reader.skip(1, "layer info pad")
                }
                switch key {
                case "luni":
                    var inner = BinaryReader(data: payload)
                    if let unicode = try? inner.adobeUnicodeString("luni"), !unicode.isEmpty {
                        name = unicode
                    }
                case "lsct", "lsdk":
                    if payload.count >= 4 {
                        var inner = BinaryReader(data: payload)
                        let type = Int(try inner.u32("section type"))
                        sectionType = PSDSectionType(rawValue: type) ?? .any
                    }
                default:
                    break
                }
            }
            if reader.offset < extraEnd {
                try reader.seek(extraEnd, "end of layer extra")
            }

            if sectionType == .openFolder || sectionType == .closedFolder {
                kind = .group
            } else if extraKeys.contains("TySh") || extraKeys.contains("tysh") {
                kind = .text
            } else if extraKeys.contains("SoLd") || extraKeys.contains("SoLE") || extraKeys.contains("SoCo") {
                kind = .smartObject
            } else if extraKeys.contains("vmsk") || extraKeys.contains("vsms") || extraKeys.contains("vogk") {
                kind = .shape
            } else if !extraKeys.isDisjoint(with: adjustmentKeys) {
                kind = .adjustment
            }

            let hidden = (flags & 0x02) != 0
            let layer = PSDLayer(
                id: UUID(),
                name: name.isEmpty ? "Layer" : name,
                kind: kind,
                blendMode: blendMode,
                opacity: opacity,
                isVisible: !hidden,
                isClip: clipping != 0,
                transparencyProtected: (flags & 0x01) != 0,
                top: top,
                left: left,
                bottom: bottom,
                right: right,
                sectionType: sectionType,
                children: [],
                image: nil,
                channelIDs: channels.map(\.id)
            )
            records.append((layer, channels))
        }

        var layers: [PSDLayer] = []
        layers.reserveCapacity(records.count)
        for i in 0..<records.count {
            var layer = records[i].layer
            if layer.sectionType != .boundingDivider && layer.width > 0 && layer.height > 0 {
                do {
                    layer.image = try decodeLayerImage(
                        reader: &reader,
                        channels: records[i].channels,
                        layer: layer,
                        isPSB: isPSB,
                        depth: depth,
                        colorMode: colorMode
                    )
                } catch {
                    try skipChannelData(reader: &reader, channels: records[i].channels)
                }
            } else {
                try skipChannelData(reader: &reader, channels: records[i].channels)
            }
            layers.append(layer)
        }
        return layers
    }

    private static func skipChannelData(reader: inout BinaryReader, channels: [ChannelInfo]) throws {
        for channel in channels {
            if channel.dataLength > 0 {
                try reader.skip(channel.dataLength, "skip channel")
            }
        }
    }

    private static func decodeLayerImage(
        reader: inout BinaryReader,
        channels: [ChannelInfo],
        layer: PSDLayer,
        isPSB: Bool,
        depth: Int,
        colorMode: PSDColorMode
    ) throws -> NSImage? {
        var planes: [Int: Data] = [:]
        for channel in channels {
            if channel.dataLength <= 0 { continue }
            let payload = try reader.read(channel.dataLength, "channel payload")
            if let decoded = decodeChannel(
                payload,
                width: layer.width,
                height: layer.height,
                depth: depth,
                isPSB: isPSB
            ) {
                planes[channel.id] = decoded
            }
        }
        return assembleImage(
            width: layer.width,
            height: layer.height,
            depth: depth,
            colorMode: colorMode,
            planes: planes
        )
    }

    private static func decodeChannel(_ data: Data, width: Int, height: Int, depth: Int, isPSB: Bool) -> Data? {
        guard width > 0, height > 0, data.count >= 2 else { return nil }
        var inner = BinaryReader(data: data)
        guard let compression = try? inner.u16("compression") else { return nil }
        let raw = (try? inner.read(inner.remaining, "channel bytes")) ?? Data()
        let bytesPerSample = max(1, depth / 8)
        let rowBytes = width * bytesPerSample
        let expected = rowBytes * height

        switch compression {
        case 0:
            if raw.count >= expected { return raw.prefix(expected) }
            var padded = raw
            padded.append(Data(repeating: 0, count: expected - raw.count))
            return padded
        case 1:
            return decodeRLE(raw, height: height, rowBytes: rowBytes, isPSB: isPSB)
        case 2:
            return ZlibInflate.decode(raw, expected: expected)
        case 3:
            guard var inflated = ZlibInflate.decode(raw, expected: expected) else { return nil }
            ZlibInflate.undoDeltaPrediction(&inflated, rowBytes: rowBytes)
            return inflated
        default:
            return nil
        }
    }

    private static func decodeRLE(_ data: Data, height: Int, rowBytes: Int, isPSB: Bool) -> Data? {
        var inner = BinaryReader(data: data)
        var rowSizes: [Int] = []
        rowSizes.reserveCapacity(height)
        do {
            for _ in 0..<height {
                let size = isPSB ? Int(try inner.u32("rle size")) : Int(try inner.u16("rle size"))
                rowSizes.append(max(0, size))
            }
            var output = Data()
            output.reserveCapacity(rowBytes * height)
            for size in rowSizes {
                let packed = try inner.read(size, "rle row")
                let decoded = try PackBits.decode(packed, expected: rowBytes)
                output.append(decoded)
            }
            return output
        } catch {
            return nil
        }
    }

    private static func assembleImage(
        width: Int,
        height: Int,
        depth: Int,
        colorMode: PSDColorMode,
        planes: [Int: Data]
    ) -> NSImage? {
        guard width > 0, height > 0 else { return nil }
        let pixelCount = width * height
        var rgba = Data(count: pixelCount * 4)

        func sample(_ plane: Data?, _ index: Int, default value: UInt8) -> UInt8 {
            guard let plane else { return value }
            if depth == 16 {
                let offset = index * 2
                guard offset + 1 < plane.count else { return value }
                return plane[offset]
            }
            if depth == 32 {
                let offset = index * 4
                guard offset + 3 < plane.count else { return value }
                // 32-bit channels are typically IEEE float 0...1, big endian.
                let bits = UInt32(plane[offset]) << 24
                    | UInt32(plane[offset + 1]) << 16
                    | UInt32(plane[offset + 2]) << 8
                    | UInt32(plane[offset + 3])
                let float = Float(bitPattern: bits)
                return UInt8(max(0, min(255, Int(float * 255.0))))
            }
            guard index < plane.count else { return value }
            return plane[index]
        }

        rgba.withUnsafeMutableBytes { raw in
            guard let out = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            switch colorMode {
            case .rgb, .indexed, .unknown:
                let r = planes[0]
                let g = planes[1]
                let b = planes[2]
                let a = planes[-1]
                for i in 0..<pixelCount {
                    let o = i * 4
                    out[o] = sample(r, i, default: 0)
                    out[o + 1] = sample(g, i, default: 0)
                    out[o + 2] = sample(b, i, default: 0)
                    out[o + 3] = sample(a, i, default: 255)
                }
            case .grayscale, .duotone, .bitmap:
                let g = planes[0]
                let a = planes[-1]
                for i in 0..<pixelCount {
                    let o = i * 4
                    let gray = sample(g, i, default: 0)
                    out[o] = gray
                    out[o + 1] = gray
                    out[o + 2] = gray
                    out[o + 3] = sample(a, i, default: 255)
                }
            case .cmyk:
                let c = planes[0]
                let m = planes[1]
                let y = planes[2]
                let k = planes[3]
                let a = planes[-1]
                for i in 0..<pixelCount {
                    let o = i * 4
                    let C = Double(sample(c, i, default: 0)) / 255.0
                    let M = Double(sample(m, i, default: 0)) / 255.0
                    let Y = Double(sample(y, i, default: 0)) / 255.0
                    let K = Double(sample(k, i, default: 0)) / 255.0
                    out[o] = UInt8(max(0, min(255, Int(255.0 * (1.0 - C) * (1.0 - K)))))
                    out[o + 1] = UInt8(max(0, min(255, Int(255.0 * (1.0 - M) * (1.0 - K)))))
                    out[o + 2] = UInt8(max(0, min(255, Int(255.0 * (1.0 - Y) * (1.0 - K)))))
                    out[o + 3] = sample(a, i, default: 255)
                }
            case .lab, .multichannel:
                let g = planes[0]
                let a = planes[-1]
                for i in 0..<pixelCount {
                    let o = i * 4
                    let gray = sample(g, i, default: 0)
                    out[o] = gray
                    out[o + 1] = gray
                    out[o + 2] = gray
                    out[o + 3] = sample(a, i, default: 255)
                }
            }
        }

        return cgImage(width: width, height: height, rgba: rgba).map { NSImage(cgImage: $0, size: .zero) }
    }

    static func cgImage(width: Int, height: Int, rgba: Data) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// File order is bottom-to-top. Group markers: type 3 opens a stack, type 1/2 close it.
    private static func buildLayerTree(_ fileOrder: [PSDLayer]) -> [PSDLayer] {
        var stack: [[PSDLayer]] = [[]]
        for layer in fileOrder {
            switch layer.sectionType {
            case .boundingDivider:
                stack.append([])
            case .openFolder, .closedFolder:
                let children = stack.popLast() ?? []
                var group = layer
                group.kind = .group
                group.children = children.reversed()
                if stack.isEmpty { stack.append([]) }
                stack[stack.count - 1].append(group)
            case .any:
                if stack.isEmpty { stack.append([]) }
                stack[stack.count - 1].append(layer)
            }
        }
        while stack.count > 1 {
            let orphan = stack.popLast() ?? []
            stack[stack.count - 1].append(contentsOf: orphan)
        }
        return (stack.first ?? []).reversed()
    }
}

enum PhotoshopLoader {
    static func load(data: Data, filename: String?) throws -> PhotoshopFile {
        guard !data.isEmpty else { throw ArtworkError.emptyFile }
        do {
            let parsed = try PSDParser.parse(data)
            if parsed.compositeImage == nil && parsed.layers.isEmpty {
                throw ArtworkError.unreadableImage
            }
            return parsed
        } catch let error as ArtworkError {
            if case .notPhotoshop = error {
                throw error
            }
            if let composite = ImageIOLoader.compositeImage(from: data) {
                return PhotoshopFile(
                    header: PSDHeader(
                        isPSB: (filename as NSString?)?.pathExtension.lowercased() == "psb",
                        channels: 0,
                        height: Int(composite.size.height),
                        width: Int(composite.size.width),
                        depth: 8,
                        colorMode: .rgb,
                        hasMergedAlpha: false
                    ),
                    layers: [],
                    compositeImage: composite,
                    thumbnail: nil,
                    dpi: 72,
                    colorProfileName: ImageIOLoader.colorProfileName(from: data),
                    parseError: error.localizedDescription
                )
            }
            throw error
        }
    }
}

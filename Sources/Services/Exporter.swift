import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import zlib

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case png
    case jpeg
    case tiff
    case openRaster

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .openRaster: return "OpenRaster (.ora)"
        }
    }

    var pathExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .openRaster: return "ora"
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf: return .pdf
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .openRaster: return UTType(filenameExtension: "ora") ?? .data
        }
    }

    var detail: String {
        switch self {
        case .pdf:
            return "Open interchange. Illustrator files stay vector when they contain a PDF stream."
        case .png:
            return "Lossless raster with transparency."
        case .jpeg:
            return "Compressed raster, no transparency."
        case .tiff:
            return "Lossless print-oriented raster."
        case .openRaster:
            return "Open layered raster (Krita, GIMP, MyPaint). Photoshop layers become PNG sheets."
        }
    }

    func isAvailable(for payload: ArtworkPayload) -> Bool {
        switch self {
        case .openRaster:
            return payload.photoshop != nil
        default:
            return payload.error == nil
        }
    }
}

struct ExportOptions {
    var format: ExportFormat = .pdf
    var pageIndex: Int = 0
    var allPages: Bool = true
    var scale: CGFloat = 2
    var jpegQuality: CGFloat = 0.92
    var includeHiddenLayers: Bool = false
}

enum ArtworkExporter {
    static func export(_ payload: ArtworkPayload, options: ExportOptions, to url: URL) throws {
        switch options.format {
        case .pdf:
            try exportPDF(payload, options: options, to: url)
        case .png, .jpeg, .tiff:
            try exportRaster(payload, options: options, to: url)
        case .openRaster:
            try exportOpenRaster(payload, options: options, to: url)
        }
    }

    static func suggestedName(for payload: ArtworkPayload, format: ExportFormat) -> String {
        let base = (payload.filename as NSString).deletingPathExtension
        return "\(base).\(format.pathExtension)"
    }

    private static func exportPDF(_ payload: ArtworkPayload, options: ExportOptions, to url: URL) throws {
        if let data = payload.illustrator?.pdfData {
            try data.write(to: url)
            return
        }
        if let pdf = payload.illustrator?.pdf, let data = pdf.dataRepresentation() {
            try data.write(to: url)
            return
        }
        guard let image = currentImage(payload, options: options) else {
            throw ArtworkError.exportFailed("Nothing to put on a PDF page.")
        }
        guard let page = PDFPage(image: image) else {
            throw ArtworkError.exportFailed("Could not wrap the image as a PDF page.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: url) else {
            throw ArtworkError.exportFailed("PDF write failed.")
        }
    }

    private static func exportRaster(_ payload: ArtworkPayload, options: ExportOptions, to url: URL) throws {
        guard let image = currentImage(payload, options: options) else {
            throw ArtworkError.exportFailed("No image is available to rasterize.")
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ArtworkError.exportFailed("Could not create a bitmap.")
        }
        let type: UTType
        switch options.format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .tiff: type = .tiff
        default: type = .png
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ArtworkError.exportFailed("Could not create the image file.")
        }
        let dpi = payload.metadata.dpi > 0 ? payload.metadata.dpi : 72
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi * Double(options.scale) / 2.0,
            kCGImagePropertyDPIHeight: dpi * Double(options.scale) / 2.0
        ]
        if options.format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ArtworkError.exportFailed("Image write failed.")
        }
    }

    private static func currentImage(_ payload: ArtworkPayload, options: ExportOptions) -> NSImage? {
        if let ai = payload.illustrator {
            return ai.pageImage(at: options.pageIndex, scale: options.scale) ?? ai.previewImage
        }
        if let ps = payload.photoshop {
            return ps.compositeImage
        }
        return payload.displayImage
    }

    private static func exportOpenRaster(_ payload: ArtworkPayload, options: ExportOptions, to url: URL) throws {
        guard let ps = payload.photoshop else {
            throw ArtworkError.exportFailed("OpenRaster export is for Photoshop documents.")
        }
        let width = ps.header.width
        let height = ps.header.height
        var archive = ZipStore()
        archive.add(name: "mimetype", data: Data("image/openraster".utf8), store: true)

        var stack = XMLNode()
        emitStack(ps.layers, into: &stack, includeHidden: options.includeHiddenLayers, archive: &archive)

        let xml = """
        <?xml version='1.0' encoding='UTF-8'?>
        <image w="\(width)" h="\(height)" xres="\(Int(ps.dpi.rounded()))" yres="\(Int(ps.dpi.rounded()))">
        \(stack.xml(indent: 1))
        </image>
        """
        archive.add(name: "stack.xml", data: Data(xml.utf8))

        if let merged = ps.compositeImage, let png = pngData(merged) {
            archive.add(name: "mergedimage.png", data: png)
            let thumb = thumbnail(merged, maxEdge: 256)
            if let thumbPNG = pngData(thumb) {
                archive.add(name: "Thumbnails/thumbnail.png", data: thumbPNG)
            }
        }

        try archive.finalize().write(to: url)
    }

    private struct XMLNode {
        var lines: [String] = []

        mutating func append(_ line: String) {
            lines.append(line)
        }

        func xml(indent: Int) -> String {
            lines.joined(separator: "\n")
        }
    }

    private static func emitStack(
        _ layers: [PSDLayer],
        into node: inout XMLNode,
        includeHidden: Bool,
        archive: inout ZipStore,
        indent: Int = 1
    ) {
        let pad = String(repeating: "  ", count: indent)
        node.append("\(pad)<stack>")
        for layer in layers {
            if layer.isSectionDivider { continue }
            if !includeHidden && !layer.isVisible && !layer.isGroup { continue }
            if layer.isGroup {
                let vis = layer.isVisible ? "visible" : "hidden"
                node.append("\(pad)  <stack name=\"\(escape(layer.name))\" visibility=\"\(vis)\" isolation=\"isolate\">")
                var child = XMLNode()
                emitStack(layer.children, into: &child, includeHidden: includeHidden, archive: &archive, indent: indent + 2)
                node.lines.append(contentsOf: child.lines)
                node.append("\(pad)  </stack>")
            } else if let image = layer.image, let png = pngData(image) {
                let filename = "data/layer-\(layer.id.uuidString.lowercased()).png"
                archive.add(name: filename, data: png)
                let vis = layer.isVisible ? "visible" : "hidden"
                let opacity = String(format: "%.3f", Double(layer.opacity) / 255.0)
                node.append("\(pad)  <layer name=\"\(escape(layer.name))\" src=\"\(filename)\" x=\"\(layer.left)\" y=\"\(layer.top)\" opacity=\"\(opacity)\" visibility=\"\(vis)\" composite-op=\"svg:src-over\"/>")
            }
        }
        node.append("\(pad)</stack>")
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func thumbnail(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }
}

enum ArtworkPrinter {
    static func print(_ payload: ArtworkPayload, pageIndex: Int) {
        if let pdf = payload.illustrator?.pdf {
            let view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
            view.document = pdf
            view.autoScales = true
            if let page = pdf.page(at: pageIndex) {
                view.go(to: page)
            }
            view.print(with: NSPrintInfo.shared, autoRotate: true)
            return
        }
        guard let image = payload.displayImage else { return }
        let view = PrintableImageView(image: image)
        let operation = NSPrintOperation(view: view, printInfo: NSPrintInfo.shared)
        operation.jobTitle = payload.filename
        operation.run()
    }
}

final class PrintableImageView: NSView {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
        let size = image.size.width > 0 ? image.size : NSSize(width: 612, height: 792)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }
}

struct ZipStore {
    private var entries: [(name: String, data: Data, store: Bool)] = []

    mutating func add(name: String, data: Data, store: Bool = true) {
        entries.append((name, data, store))
    }

    func finalize() -> Data {
        var locals = Data()
        var central = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = checksum(entry.data)
            let method: UInt16 = 0
            let compressed = entry.data

            var local = Data()
            local.appendLE32(0x04034b50)
            local.appendLE16(20)
            local.appendLE16(0)
            local.appendLE16(method)
            local.appendLE16(0)
            local.appendLE16(0)
            local.appendLE32(crc)
            local.appendLE32(UInt32(compressed.count))
            local.appendLE32(UInt32(entry.data.count))
            local.appendLE16(UInt16(nameData.count))
            local.appendLE16(0)
            local.append(nameData)
            local.append(compressed)

            var dir = Data()
            dir.appendLE32(0x02014b50)
            dir.appendLE16(20)
            dir.appendLE16(20)
            dir.appendLE16(0)
            dir.appendLE16(method)
            dir.appendLE16(0)
            dir.appendLE16(0)
            dir.appendLE32(crc)
            dir.appendLE32(UInt32(compressed.count))
            dir.appendLE32(UInt32(entry.data.count))
            dir.appendLE16(UInt16(nameData.count))
            dir.appendLE16(0)
            dir.appendLE16(0)
            dir.appendLE16(0)
            dir.appendLE16(0)
            dir.appendLE32(0)
            dir.appendLE32(offset)
            dir.append(nameData)

            offset += UInt32(local.count)
            locals.append(local)
            central.append(dir)
        }

        var eocd = Data()
        eocd.appendLE32(0x06054b50)
        eocd.appendLE16(0)
        eocd.appendLE16(0)
        eocd.appendLE16(UInt16(entries.count))
        eocd.appendLE16(UInt16(entries.count))
        eocd.appendLE32(UInt32(central.count))
        eocd.appendLE32(UInt32(locals.count))
        eocd.appendLE16(0)

        var result = Data()
        result.append(locals)
        result.append(central)
        result.append(eocd)
        return result
    }

    private func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            return UInt32(crc32(uLong(0), buffer.baseAddress, uInt(data.count)))
        }
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLE32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

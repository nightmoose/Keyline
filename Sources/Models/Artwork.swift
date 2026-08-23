import AppKit
import PDFKit
import UniformTypeIdentifiers

enum ArtworkUTTypes {
    static var illustrator: UTType {
        UTType("com.adobe.illustrator.ai-image")
            ?? UTType(filenameExtension: "ai")
            ?? .pdf
    }

    static var photoshop: UTType {
        UTType("com.adobe.photoshop-image")
            ?? UTType(filenameExtension: "psd")
            ?? .image
    }

    static var photoshopLarge: UTType {
        UTType("com.adobe.photoshop-large-image")
            ?? UTType(filenameExtension: "psb")
            ?? photoshop
    }

    static var eps: UTType {
        UTType("com.adobe.encapsulated-postscript")
            ?? UTType(filenameExtension: "eps")
            ?? .data
    }

    static var all: [UTType] {
        [illustrator, photoshop, photoshopLarge, eps, .pdf]
    }

    static func kind(for type: UTType, filename: String?) -> ArtworkKind {
        let ext = (filename as NSString?)?.pathExtension.lowercased() ?? ""
        if type.conforms(to: photoshop) || type.conforms(to: photoshopLarge)
            || ext == "psd" || ext == "psb" {
            return .photoshop
        }
        if type.conforms(to: illustrator) || ext == "ai" || ext == "ait" {
            return .illustrator
        }
        if type.conforms(to: eps) || ext == "eps" || ext == "epsf" {
            return .illustrator
        }
        if type.conforms(to: .pdf) || ext == "pdf" {
            return .pdf
        }
        return .unknown
    }
}

enum ArtworkKind: String, Equatable {
    case illustrator
    case photoshop
    case pdf
    case unknown

    var displayName: String {
        switch self {
        case .illustrator: return "Adobe Illustrator"
        case .photoshop: return "Adobe Photoshop"
        case .pdf: return "PDF"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .illustrator: return "pencil.and.outline"
        case .photoshop: return "square.stack.3d.up"
        case .pdf: return "doc.richtext"
        case .unknown: return "questionmark.folder"
        }
    }
}

enum ArtworkError: LocalizedError, Equatable {
    case emptyFile
    case truncated(String)
    case notPhotoshop
    case unsupportedPhotoshop(String)
    case illustratorNotPDFCompatible
    case unreadablePDF
    case unreadableImage
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The file is empty."
        case .truncated(let context):
            return "The file is truncated or corrupt\(context.isEmpty ? "." : ": \(context)")"
        case .notPhotoshop:
            return "This is not a Photoshop PSD or PSB file."
        case .unsupportedPhotoshop(let reason):
            return "This Photoshop file cannot be fully read. \(reason)"
        case .illustratorNotPDFCompatible:
            return "This Illustrator file was saved without PDF compatibility, and it does not contain a usable preview. Re-save it from Illustrator with “Create PDF Compatible File” enabled."
        case .unreadablePDF:
            return "The PDF content in this file could not be read."
        case .unreadableImage:
            return "No displayable image could be decoded from this file."
        case .exportFailed(let reason):
            return "Export failed. \(reason)"
        }
    }
}

enum CanvasViewMode: Equatable, Hashable {
    case composite
    case layer(UUID)
}

struct ArtworkMetadata: Equatable {
    var filename: String
    var kind: ArtworkKind
    var fileSize: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var dpi: Double
    var colorMode: String
    var bitDepth: Int
    var channelCount: Int
    var pageCount: Int
    var layerCount: Int
    var colorProfile: String?
    var notes: [String]

    var pixelSizeLabel: String {
        "\(pixelWidth) × \(pixelHeight) px"
    }

    var printSizeLabel: String {
        guard dpi > 0 else { return "—" }
        let w = Double(pixelWidth) / dpi
        let h = Double(pixelHeight) / dpi
        return String(format: "%.2f × %.2f in @ %.0f ppi", w, h, dpi)
    }

    var fileSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

final class ArtworkPayload {
    let filename: String
    let contentType: UTType
    let data: Data
    let kind: ArtworkKind
    let illustrator: IllustratorFile?
    let photoshop: PhotoshopFile?
    let error: Error?
    let warnings: [String]

    init(
        filename: String,
        contentType: UTType,
        data: Data,
        kind: ArtworkKind,
        illustrator: IllustratorFile? = nil,
        photoshop: PhotoshopFile? = nil,
        error: Error? = nil,
        warnings: [String] = []
    ) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
        self.kind = kind
        self.illustrator = illustrator
        self.photoshop = photoshop
        self.error = error
        self.warnings = warnings
    }

    var metadata: ArtworkMetadata {
        if let ai = illustrator {
            return ai.metadata(filename: filename, fileSize: data.count)
        }
        if let ps = photoshop {
            return ps.metadata(filename: filename, fileSize: data.count)
        }
        return ArtworkMetadata(
            filename: filename,
            kind: kind,
            fileSize: data.count,
            pixelWidth: 0,
            pixelHeight: 0,
            dpi: 72,
            colorMode: "—",
            bitDepth: 0,
            channelCount: 0,
            pageCount: 0,
            layerCount: 0,
            colorProfile: nil,
            notes: error.map { [$0.localizedDescription] } ?? []
        )
    }

    var displayImage: NSImage? {
        if let ps = photoshop { return ps.compositeImage }
        if let ai = illustrator { return ai.previewImage }
        return nil
    }

    var pdfDocument: PDFDocument? {
        illustrator?.pdf
    }
}

final class IllustratorFile {
    enum Source: String {
        case pdfCompatible = "PDF-compatible Illustrator"
        case embeddedPDF = "Embedded PDF stream"
        case epsPreview = "EPS/TIFF preview"
        case genericPDF = "PDF"
    }

    let pdf: PDFDocument?
    let pdfData: Data?
    let previewImage: NSImage?
    let source: Source
    let extractedText: String

    init(pdf: PDFDocument?, pdfData: Data?, previewImage: NSImage?, source: Source) {
        self.pdf = pdf
        self.pdfData = pdfData
        self.previewImage = previewImage
        self.source = source
        if let pdf {
            var parts: [String] = []
            for i in 0..<pdf.pageCount {
                if let page = pdf.page(at: i), let text = page.string, !text.isEmpty {
                    parts.append(text)
                }
            }
            self.extractedText = parts.joined(separator: "\n\n")
        } else {
            self.extractedText = ""
        }
    }

    var pageCount: Int { pdf?.pageCount ?? (previewImage == nil ? 0 : 1) }

    func pageImage(at index: Int, scale: CGFloat) -> NSImage? {
        guard let pdf, let page = pdf.page(at: index) else {
            return index == 0 ? previewImage : nil
        }
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        return page.thumbnail(of: size, for: .mediaBox)
    }

    func metadata(filename: String, fileSize: Int) -> ArtworkMetadata {
        var width = 0
        var height = 0
        if let page = pdf?.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            width = Int(round(bounds.width))
            height = Int(round(bounds.height))
        } else if let image = previewImage {
            width = Int(round(image.size.width))
            height = Int(round(image.size.height))
        }
        var notes = [source.rawValue]
        if pdf != nil {
            notes.append("Vectors are preserved in the embedded PDF.")
        } else {
            notes.append("Only a raster preview is available for this file.")
        }
        return ArtworkMetadata(
            filename: filename,
            kind: source == .genericPDF ? .pdf : .illustrator,
            fileSize: fileSize,
            pixelWidth: width,
            pixelHeight: height,
            dpi: 72,
            colorMode: "PDF / vector",
            bitDepth: 0,
            channelCount: 0,
            pageCount: pageCount,
            layerCount: 0,
            colorProfile: pdf?.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
            notes: notes
        )
    }
}

final class PhotoshopFile {
    let header: PSDHeader
    let layers: [PSDLayer]
    let compositeImage: NSImage?
    let thumbnail: NSImage?
    let dpi: Double
    let colorProfileName: String?
    let parseError: String?

    init(
        header: PSDHeader,
        layers: [PSDLayer],
        compositeImage: NSImage?,
        thumbnail: NSImage?,
        dpi: Double,
        colorProfileName: String?,
        parseError: String?
    ) {
        self.header = header
        self.layers = layers
        self.compositeImage = compositeImage
        self.thumbnail = thumbnail
        self.dpi = dpi
        self.colorProfileName = colorProfileName
        self.parseError = parseError
    }

    var flatLayers: [PSDLayer] {
        var result: [PSDLayer] = []
        func walk(_ items: [PSDLayer]) {
            for layer in items {
                result.append(layer)
                walk(layer.children)
            }
        }
        walk(layers)
        return result
    }

    func layer(id: UUID) -> PSDLayer? {
        flatLayers.first { $0.id == id }
    }

    func metadata(filename: String, fileSize: Int) -> ArtworkMetadata {
        var notes: [String] = []
        notes.append(header.isPSB ? "Photoshop Large Document (PSB)" : "Photoshop Document (PSD)")
        if header.hasMergedAlpha {
            notes.append("Merged transparency channel is present.")
        }
        if let parseError {
            notes.append(parseError)
        }
        notes.append("The composite view is the flattened image Photoshop saved with the file.")
        return ArtworkMetadata(
            filename: filename,
            kind: .photoshop,
            fileSize: fileSize,
            pixelWidth: header.width,
            pixelHeight: header.height,
            dpi: dpi,
            colorMode: header.colorMode.displayName,
            bitDepth: header.depth,
            channelCount: header.channels,
            pageCount: 1,
            layerCount: flatLayers.filter { !$0.isSectionDivider }.count,
            colorProfile: colorProfileName,
            notes: notes
        )
    }
}

struct PSDHeader: Equatable {
    var isPSB: Bool
    var channels: Int
    var height: Int
    var width: Int
    var depth: Int
    var colorMode: PSDColorMode
    var hasMergedAlpha: Bool
}

enum PSDColorMode: Int, Equatable {
    case bitmap = 0
    case grayscale = 1
    case indexed = 2
    case rgb = 3
    case cmyk = 4
    case multichannel = 7
    case duotone = 8
    case lab = 9
    case unknown = -1

    var displayName: String {
        switch self {
        case .bitmap: return "Bitmap"
        case .grayscale: return "Grayscale"
        case .indexed: return "Indexed Color"
        case .rgb: return "RGB"
        case .cmyk: return "CMYK"
        case .multichannel: return "Multichannel"
        case .duotone: return "Duotone"
        case .lab: return "Lab"
        case .unknown: return "Unknown"
        }
    }
}

enum PSDSectionType: Int, Equatable {
    case any = 0
    case openFolder = 1
    case closedFolder = 2
    case boundingDivider = 3
}

enum PSDLayerKind: String, Equatable {
    case pixel
    case group
    case text
    case smartObject
    case adjustment
    case shape
    case unknown
}

struct PSDLayer: Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: PSDLayerKind
    var blendMode: String
    var opacity: UInt8
    var isVisible: Bool
    var isClip: Bool
    var transparencyProtected: Bool
    var top: Int
    var left: Int
    var bottom: Int
    var right: Int
    var sectionType: PSDSectionType
    var children: [PSDLayer]
    var image: NSImage?
    var channelIDs: [Int]

    var width: Int { max(0, right - left) }
    var height: Int { max(0, bottom - top) }
    var isGroup: Bool { kind == .group || sectionType == .openFolder || sectionType == .closedFolder }
    var isSectionDivider: Bool { sectionType == .boundingDivider }
    var opacityPercent: Int { Int(round(Double(opacity) / 255.0 * 100.0)) }

    var blendModeName: String {
        Self.blendModeNames[blendMode] ?? blendMode
    }

    static let blendModeNames: [String: String] = [
        "pass": "Pass Through",
        "norm": "Normal",
        "diss": "Dissolve",
        "dark": "Darken",
        "mul ": "Multiply",
        "idiv": "Color Burn",
        "lbrn": "Linear Burn",
        "dkCl": "Darker Color",
        "lite": "Lighten",
        "scrn": "Screen",
        "div ": "Color Dodge",
        "lddg": "Linear Dodge",
        "lgCl": "Lighter Color",
        "over": "Overlay",
        "sLit": "Soft Light",
        "hLit": "Hard Light",
        "vLit": "Vivid Light",
        "lLit": "Linear Light",
        "pLit": "Pin Light",
        "hMix": "Hard Mix",
        "diff": "Difference",
        "smud": "Exclusion",
        "fsub": "Subtract",
        "fdiv": "Divide",
        "hue ": "Hue",
        "sat ": "Saturation",
        "colr": "Color",
        "lum ": "Luminosity"
    ]
}

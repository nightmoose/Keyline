import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFExtractor {
    static func extractPDF(from data: Data) -> Data? {
        if isPDF(data) {
            return data
        }
        if let fromEPS = extractFromBinaryEPS(data), isPDF(fromEPS) || PDFDocument(data: fromEPS) != nil {
            return isPDF(fromEPS) ? fromEPS : (extractPDFMarker(fromEPS) ?? fromEPS)
        }
        return extractPDFMarker(data)
    }

    static func isPDF(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        return data.starts(with: Array("%PDF-".utf8))
    }

    static func extractPDFMarker(_ data: Data) -> Data? {
        guard let start = findASCII(data, pattern: "%PDF-") else { return nil }
        let slice = data.subdata(in: start..<data.count)
        if PDFDocument(data: slice) != nil {
            return slice
        }
        if let end = findLastASCII(slice, pattern: "%%EOF") {
            let closed = slice.subdata(in: 0..<min(slice.count, end + 5))
            if PDFDocument(data: closed) != nil {
                return closed
            }
        }
        return PDFDocument(data: slice) == nil ? nil : slice
    }

    /// DOS EPS binary header (`C5 D0 D3 C6`) can wrap a PostScript body and a TIFF preview.
    static func extractFromBinaryEPS(_ data: Data) -> Data? {
        guard data.count >= 30 else { return nil }
        var reader = BinaryReader(data: data)
        do {
            let magic = try reader.u32LE()
            guard magic == 0xC6D3D0C5 else { return nil }
            let psOffset = Int(try reader.u32LE())
            let psLength = Int(try reader.u32LE())
            guard psOffset > 0, psLength > 0, psOffset + psLength <= data.count else { return nil }
            return data.subdata(in: psOffset..<(psOffset + psLength))
        } catch {
            return nil
        }
    }

    static func extractTIFFPreview(from data: Data) -> Data? {
        guard data.count >= 30 else { return nil }
        var reader = BinaryReader(data: data)
        do {
            let magic = try reader.u32LE()
            guard magic == 0xC6D3D0C5 else { return nil }
            _ = try reader.u32LE()
            _ = try reader.u32LE()
            _ = try reader.u32LE()
            _ = try reader.u32LE()
            let tiffOffset = Int(try reader.u32LE())
            let tiffLength = Int(try reader.u32LE())
            guard tiffOffset > 0, tiffLength > 0, tiffOffset + tiffLength <= data.count else { return nil }
            return data.subdata(in: tiffOffset..<(tiffOffset + tiffLength))
        } catch {
            return nil
        }
    }

    private static func findASCII(_ data: Data, pattern: String) -> Int? {
        let needle = Array(pattern.utf8)
        guard !needle.isEmpty, data.count >= needle.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let limit = data.count - needle.count
            var i = 0
            while i <= limit {
                var match = true
                var j = 0
                while j < needle.count {
                    if base[i + j] != needle[j] {
                        match = false
                        break
                    }
                    j += 1
                }
                if match { return i }
                i += 1
            }
            return nil
        }
    }

    private static func findLastASCII(_ data: Data, pattern: String) -> Int? {
        let needle = Array(pattern.utf8)
        guard !needle.isEmpty, data.count >= needle.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let limit = data.count - needle.count
            var i = limit
            while i >= 0 {
                var match = true
                var j = 0
                while j < needle.count {
                    if base[i + j] != needle[j] {
                        match = false
                        break
                    }
                    j += 1
                }
                if match { return i }
                i -= 1
            }
            return nil
        }
    }
}

enum IllustratorLoader {
    static func load(data: Data, filename: String?, type: UTType) throws -> IllustratorFile {
        guard !data.isEmpty else { throw ArtworkError.emptyFile }

        if let pdfData = PDFExtractor.extractPDF(from: data), let pdf = PDFDocument(data: pdfData) {
            let source: IllustratorFile.Source
            if type.conforms(to: .pdf) && (filename as NSString?)?.pathExtension.lowercased() == "pdf" {
                source = .genericPDF
            } else if PDFExtractor.isPDF(data) {
                source = .pdfCompatible
            } else {
                source = .embeddedPDF
            }
            let preview = pdf.page(at: 0)?.thumbnail(
                of: CGSize(width: 1600, height: 1600),
                for: .mediaBox
            )
            return IllustratorFile(pdf: pdf, pdfData: pdfData, previewImage: preview, source: source)
        }

        if let tiff = PDFExtractor.extractTIFFPreview(from: data),
           let image = ImageIOLoader.image(from: tiff) {
            return IllustratorFile(pdf: nil, pdfData: nil, previewImage: image, source: .epsPreview)
        }

        if let image = ImageIOLoader.image(from: data) {
            return IllustratorFile(pdf: nil, pdfData: nil, previewImage: image, source: .epsPreview)
        }

        throw ArtworkError.illustratorNotPDFCompatible
    }
}

enum ImageIOLoader {
    static func image(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: true
        ] as CFDictionary) else { return nil }
        return image(from: source, index: 0)
    }

    static func compositeImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: true
        ] as CFDictionary) else { return nil }

        if let full = image(from: source, index: 0) {
            return full
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return NSImage(cgImage: thumb, size: .zero)
        }
        return nil
    }

    static func image(from source: CGImageSource, index: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let cg = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: .zero)
    }

    static func colorProfileName(from data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        if let profile = props[kCGImagePropertyProfileName as String] as? String {
            return profile
        }
        return nil
    }
}

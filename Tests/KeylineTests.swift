import XCTest
@testable import Keyline

final class PackBitsTests: XCTestCase {
    func testLiteralAndRepeat() throws {
        // 3 literal bytes AAA, then repeat B 4 times (header -3)
        var input = Data([0x02, 0x10, 0x20, 0x30])
        input.append(contentsOf: [0xFD, 0xBB])
        let decoded = try PackBits.decode(input, expected: 7)
        XCTAssertEqual(Array(decoded), [0x10, 0x20, 0x30, 0xBB, 0xBB, 0xBB, 0xBB])
    }

    func testPadsShortOutput() throws {
        let decoded = try PackBits.decode(Data([0x00, 0x11]), expected: 4)
        XCTAssertEqual(Array(decoded), [0x11, 0, 0, 0])
    }
}

final class PDFExtractorTests: XCTestCase {
    func testExtractsBarePDF() {
        let pdf = SampleFactory.pdfData(pages: 1)
        XCTAssertTrue(PDFExtractor.isPDF(pdf))
        XCTAssertNotNil(PDFExtractor.extractPDF(from: pdf))
    }

    func testExtractsPDFAfterPreamble() {
        var wrapped = Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator\n".utf8)
        wrapped.append(SampleFactory.pdfData(pages: 1))
        let extracted = PDFExtractor.extractPDF(from: wrapped)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.starts(with: Array("%PDF-".utf8)) ?? false)
    }
}

final class PhotoshopRoundTripTests: XCTestCase {
    func testParsesLayeredPSD() throws {
        let data = try SampleFactory.layeredPSD()
        let file = try PhotoshopLoader.load(data: data, filename: "sample.psd")
        XCTAssertEqual(file.header.width, 64)
        XCTAssertEqual(file.header.height, 64)
        XCTAssertEqual(file.header.colorMode, .rgb)
        XCTAssertEqual(file.header.depth, 8)
        XCTAssertGreaterThanOrEqual(file.layers.count, 2)
        XCTAssertEqual(file.layers.map(\.name).sorted(), ["Circle", "Paper"].sorted())
        XCTAssertNotNil(file.compositeImage)
        XCTAssertNotNil(file.layers.first(where: { $0.name == "Circle" })?.image)
    }

    func testRejectsNonPSD() {
        XCTAssertThrowsError(try PhotoshopLoader.load(data: Data("not a psd".utf8), filename: "x.psd"))
    }
}

final class IllustratorLoaderTests: XCTestCase {
    func testLoadsPDFCompatibleAI() throws {
        var data = Data("%!PS-Adobe-3.0\n".utf8)
        data.append(SampleFactory.pdfData(pages: 2))
        let file = try IllustratorLoader.load(
            data: data,
            filename: "poster.ai",
            type: ArtworkUTTypes.illustrator
        )
        XCTAssertEqual(file.pageCount, 2)
        XCTAssertNotNil(file.pdf)
        XCTAssertNotNil(file.pdfData)
    }
}

final class OpenRasterTests: XCTestCase {
    func testExportsORAZip() throws {
        let psd = try SampleFactory.layeredPSD()
        let payload = ArtworkLoader.load(data: psd, type: ArtworkUTTypes.photoshop, filename: "sample.psd")
        XCTAssertNotNil(payload.photoshop)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyline-test.ora")
        try? FileManager.default.removeItem(at: url)
        try ArtworkExporter.export(payload, options: ExportOptions(format: .openRaster), to: url)
        let exported = try Data(contentsOf: url)
        XCTAssertTrue(exported.starts(with: Array("PK".utf8)))
        // First local header entry name should be mimetype.
        let nameLength = Int(exported[26]) | Int(exported[27]) << 8
        let name = String(bytes: exported[30..<(30 + nameLength)], encoding: .utf8)
        XCTAssertEqual(name, "mimetype")
        try? FileManager.default.removeItem(at: url)
    }
}

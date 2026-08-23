#!/usr/bin/env swift
import Foundation
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Samples")

try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func pdfData(pages: Int, width: CGFloat, height: CGFloat) -> Data {
    let data = NSMutableData()
    var media = CGRect(x: 0, y: 0, width: width, height: height)
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
        return Data()
    }
    for index in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(media)
        context.setStrokeColor(CGColor(srgbRed: 0.08, green: 0.72, blue: 0.86, alpha: 1))
        context.setLineWidth(1.5)
        context.stroke(media.insetBy(dx: 36, dy: 36))
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.72, blue: 0.86, alpha: 1))
        let inset = 120 + CGFloat(index) * 20
        context.fillEllipse(in: media.insetBy(dx: inset, dy: inset + 40))
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 72, y: height - 90, width: 180, height: 8))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

func wrapAsIllustrator(_ pdf: Data, title: String) -> Data {
    var wrapped = Data()
    wrapped.append(contentsOf: """
    %!PS-Adobe-3.0
    %%Creator: Adobe Illustrator (Keyline sample)
    %%Title: \(title)
    %%BoundingBox: 0 0 612 792
    %%HiResBoundingBox: 0 0 612 792

    """.utf8)
    wrapped.append(pdf)
    return wrapped
}

try wrapAsIllustrator(pdfData(pages: 2, width: 612, height: 792), title: "Artboards")
    .write(to: root.appendingPathComponent("Artboards.ai"))
try pdfData(pages: 1, width: 612, height: 792)
    .write(to: root.appendingPathComponent("Mark.pdf"))

struct Layer {
    var name: String
    var left: Int
    var top: Int
    var width: Int
    var height: Int
    var rgba: [UInt8]
}

struct DataBuilder {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func skip(_ count: Int) { data.append(Data(count: count)) }
    mutating func u16(_ value: UInt16) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func ascii(_ string: String) { data.append(contentsOf: string.utf8) }
    mutating func pascalPadded4(_ string: String) {
        let bytes = Array(string.utf8.prefix(255))
        u8(UInt8(bytes.count))
        data.append(contentsOf: bytes)
        let total = 1 + bytes.count
        let pad = (4 - (total % 4)) % 4
        if pad > 0 { skip(pad) }
    }
}

func extractChannel(_ rgba: [UInt8], channel: Int) -> [UInt8] {
    stride(from: channel, to: rgba.count, by: 4).map { rgba[$0] }
}

func writePSD(width: Int, height: Int, layers: [Layer]) -> Data {
    var out = DataBuilder()
    out.ascii("8BPS")
    out.u16(1)
    out.skip(6)
    out.u16(3)
    out.u32(UInt32(height))
    out.u32(UInt32(width))
    out.u16(8)
    out.u16(3)
    out.u32(0)
    out.u32(0)

    var body = DataBuilder()
    var info = DataBuilder()
    info.i16(Int16(layers.count))
    var channelPayloads: [Data] = []
    for layer in layers {
        info.i32(Int32(layer.top))
        info.i32(Int32(layer.left))
        info.i32(Int32(layer.top + layer.height))
        info.i32(Int32(layer.left + layer.width))
        info.u16(4)
        for channelID in [Int16(0), 1, 2, -1] {
            let plane = extractChannel(layer.rgba, channel: channelID == -1 ? 3 : Int(channelID))
            var packed = DataBuilder()
            packed.u16(0)
            packed.data.append(contentsOf: plane)
            channelPayloads.append(packed.data)
            info.i16(channelID)
            info.u32(UInt32(packed.data.count))
        }
        info.ascii("8BIM")
        info.ascii("norm")
        info.u8(255)
        info.u8(0)
        info.u8(0)
        info.u8(0)
        var extra = DataBuilder()
        extra.u32(0)
        extra.u32(0)
        extra.pascalPadded4(layer.name)
        info.u32(UInt32(extra.data.count))
        info.data.append(extra.data)
    }
    for payload in channelPayloads { info.data.append(payload) }
    if info.data.count % 2 == 1 { info.u8(0) }
    body.u32(UInt32(info.data.count))
    body.data.append(info.data)
    body.u32(0)
    out.u32(UInt32(body.data.count))
    out.data.append(body.data)

    var composite = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) { composite[i * 4 + 3] = 255 }
    for layer in layers {
        for ly in 0..<layer.height {
            for lx in 0..<layer.width {
                let dx = layer.left + lx
                let dy = layer.top + ly
                guard dx >= 0, dy >= 0, dx < width, dy < height else { continue }
                let si = (ly * layer.width + lx) * 4
                let di = (dy * width + dx) * 4
                let srcA = Double(layer.rgba[si + 3]) / 255.0
                guard srcA > 0 else { continue }
                for c in 0..<3 {
                    let s = Double(layer.rgba[si + c])
                    let d = Double(composite[di + c])
                    composite[di + c] = UInt8(s * srcA + d * (1 - srcA))
                }
                let destA = Double(composite[di + 3]) / 255.0
                composite[di + 3] = UInt8(min(255, (srcA + destA * (1 - srcA)) * 255))
            }
        }
    }
    out.u16(0)
    for channel in 0..<3 {
        for i in 0..<(width * height) {
            out.u8(composite[i * 4 + channel])
        }
    }
    return out.data
}

let width = 256
let height = 256
var paper = [UInt8](repeating: 0, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        paper[i] = 245
        paper[i + 1] = 242
        paper[i + 2] = 232
        paper[i + 3] = 255
    }
}
var circle = [UInt8](repeating: 0, count: 128 * 128 * 4)
for y in 0..<128 {
    for x in 0..<128 {
        let dx = Double(x) - 63.5
        let dy = Double(y) - 63.5
        if dx * dx + dy * dy <= 60 * 60 {
            let i = (y * 128 + x) * 4
            circle[i] = 20
            circle[i + 1] = 184
            circle[i + 2] = 220
            circle[i + 3] = 255
        }
    }
}
var bar = [UInt8](repeating: 0, count: 200 * 24 * 4)
for y in 0..<24 {
    for x in 0..<200 {
        let i = (y * 200 + x) * 4
        bar[i] = 28
        bar[i + 1] = 32
        bar[i + 2] = 38
        bar[i + 3] = 255
    }
}

try writePSD(width: width, height: height, layers: [
    Layer(name: "Paper", left: 0, top: 0, width: width, height: height, rgba: paper),
    Layer(name: "Mark", left: 64, top: 48, width: 128, height: 128, rgba: circle),
    Layer(name: "Rule", left: 28, top: 200, width: 200, height: 24, rgba: bar)
]).write(to: root.appendingPathComponent("Layers.psd"))

print("Wrote samples to \(root.path)")
for name in ["Artboards.ai", "Mark.pdf", "Layers.psd"] {
    let url = root.appendingPathComponent(name)
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    print("  \(name)  \(size) bytes")
}

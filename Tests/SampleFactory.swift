import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum SampleFactory {
    static func pdfData(pages: Int) -> Data {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            return Data()
        }
        for index in 0..<max(1, pages) {
            context.beginPDFPage(nil)
            let hue = CGFloat(index) * 0.27
            context.setFillColor(CGColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1))
            context.fill(media)
            context.setFillColor(CGColor(
                srgbRed: 0.1 + 0.5 * hue,
                green: 0.65,
                blue: 0.85 - 0.3 * hue,
                alpha: 1
            ))
            let inset = CGFloat(40 + index * 12)
            context.fillEllipse(in: media.insetBy(dx: inset, dy: inset))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func layeredPSD() throws -> Data {
        let width = 64
        let height = 64
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
        var circle = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let radius = 15.0
        for y in 0..<32 {
            for x in 0..<32 {
                let dx = Double(x) - 15.5
                let dy = Double(y) - 15.5
                let i = (y * 32 + x) * 4
                if dx * dx + dy * dy <= radius * radius {
                    circle[i] = 20
                    circle[i + 1] = 184
                    circle[i + 2] = 220
                    circle[i + 3] = 255
                }
            }
        }
        return try PSDWriter.document(
            width: width,
            height: height,
            layers: [
                PSDWriter.Layer(name: "Paper", left: 0, top: 0, width: width, height: height, rgba: paper),
                PSDWriter.Layer(name: "Circle", left: 16, top: 16, width: 32, height: 32, rgba: circle)
            ]
        )
    }
}

enum PSDWriter {
    struct Layer {
        var name: String
        var left: Int
        var top: Int
        var width: Int
        var height: Int
        var rgba: [UInt8]
        var opacity: UInt8 = 255
        var visible: Bool = true
    }

    static func document(width: Int, height: Int, layers: [Layer]) throws -> Data {
        var out = DataBuilder()
        out.ascii("8BPS")
        out.u16(1)
        out.skip(6)
        out.u16(3)
        out.u32(UInt32(height))
        out.u32(UInt32(width))
        out.u16(8)
        out.u16(3)
        out.u32(0) // color mode
        out.u32(0) // resources

        var body = DataBuilder()
        var info = DataBuilder()
        info.i16(Int16(layers.count))

        var channelPayloads: [Data] = []
        for layer in layers {
            let right = layer.left + layer.width
            let bottom = layer.top + layer.height
            info.i32(Int32(layer.top))
            info.i32(Int32(layer.left))
            info.i32(Int32(bottom))
            info.i32(Int32(right))
            info.u16(4)

            var packedChannels: [Data] = []
            for channelID in [Int16(0), 1, 2, -1] {
                let plane = extractChannel(layer.rgba, channel: channelID == -1 ? 3 : Int(channelID))
                var packed = DataBuilder()
                packed.u16(0)
                packed.data.append(contentsOf: plane)
                packedChannels.append(packed.data)
                info.i16(channelID)
                info.u32(UInt32(packed.data.count))
            }
            channelPayloads.append(contentsOf: packedChannels)

            info.ascii("8BIM")
            info.ascii("norm")
            info.u8(layer.opacity)
            info.u8(0)
            info.u8(layer.visible ? 0 : 2)
            info.u8(0)

            var extra = DataBuilder()
            extra.u32(0) // mask
            extra.u32(0) // ranges
            extra.pascalPadded4(layer.name)
            info.u32(UInt32(extra.data.count))
            info.data.append(extra.data)
        }
        for payload in channelPayloads {
            info.data.append(payload)
        }
        if info.data.count % 2 == 1 {
            info.u8(0)
        }
        body.u32(UInt32(info.data.count))
        body.data.append(info.data)
        body.u32(0) // global mask

        out.u32(UInt32(body.data.count))
        out.data.append(body.data)

        var composite = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<(width * height) {
            composite[y * 4 + 3] = 255
        }
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

    private static func extractChannel(_ rgba: [UInt8], channel: Int) -> [UInt8] {
        stride(from: channel, to: rgba.count, by: 4).map { rgba[$0] }
    }
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

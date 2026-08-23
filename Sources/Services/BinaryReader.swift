import Compression
import Foundation

struct BinaryReader {
    let data: Data
    var offset: Int = 0

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset >= data.count }

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    mutating func require(_ count: Int, _ context: String) throws {
        guard count >= 0, offset >= 0, offset + count <= data.count else {
            throw ArtworkError.truncated(context)
        }
    }

    mutating func skip(_ count: Int, _ context: String = "skip") throws {
        try require(count, context)
        offset += count
    }

    mutating func seek(_ position: Int, _ context: String = "seek") throws {
        guard position >= 0, position <= data.count else {
            throw ArtworkError.truncated(context)
        }
        offset = position
    }

    mutating func u8(_ context: String = "u8") throws -> UInt8 {
        try require(1, context)
        let value = data[offset]
        offset += 1
        return value
    }

    mutating func i8(_ context: String = "i8") throws -> Int8 {
        Int8(bitPattern: try u8(context))
    }

    mutating func u16(_ context: String = "u16") throws -> UInt16 {
        try require(2, context)
        let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    mutating func i16(_ context: String = "i16") throws -> Int16 {
        Int16(bitPattern: try u16(context))
    }

    mutating func u32(_ context: String = "u32") throws -> UInt32 {
        try require(4, context)
        let value = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    mutating func i32(_ context: String = "i32") throws -> Int32 {
        Int32(bitPattern: try u32(context))
    }

    mutating func u64(_ context: String = "u64") throws -> UInt64 {
        try require(8, context)
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        offset += 8
        return value
    }

    mutating func i64(_ context: String = "i64") throws -> Int64 {
        Int64(bitPattern: try u64(context))
    }

    mutating func u16LE(_ context: String = "u16le") throws -> UInt16 {
        try require(2, context)
        let value = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        offset += 2
        return value
    }

    mutating func u32LE(_ context: String = "u32le") throws -> UInt32 {
        try require(4, context)
        let value = UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
        offset += 4
        return value
    }

    mutating func ascii(_ count: Int, _ context: String = "ascii") throws -> String {
        let bytes = try read(count, context)
        return String(bytes: bytes, encoding: .ascii) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    mutating func fourCC(_ context: String = "fourCC") throws -> String {
        try ascii(4, context)
    }

    mutating func read(_ count: Int, _ context: String = "read") throws -> Data {
        try require(count, context)
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func pascalStringPaddedEven(_ context: String = "pascal") throws -> String {
        let length = Int(try u8(context))
        let text = try ascii(length, context)
        if (1 + length) % 2 == 1 {
            try skip(1, context)
        }
        return text
    }

    mutating func pascalStringPadded4(_ context: String = "pascal4") throws -> String {
        let length = Int(try u8(context))
        let text = try ascii(length, context)
        let total = 1 + length
        let pad = (4 - (total % 4)) % 4
        if pad > 0 {
            try skip(pad, context)
        }
        return text
    }

    mutating func adobeUnicodeString(_ context: String = "unicode") throws -> String {
        let count = Int(try u32(context))
        guard count > 0 else { return "" }
        try require(count * 2, context)
        var scalars: [UInt16] = []
        scalars.reserveCapacity(count)
        for _ in 0..<count {
            scalars.append(try u16(context))
        }
        if scalars.last == 0 {
            scalars.removeLast()
        }
        return String(utf16CodeUnits: scalars, count: scalars.count)
    }
}

enum PackBits {
    static func decode(_ input: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var output = Data()
        output.reserveCapacity(expected)
        var index = 0
        let count = input.count
        while index < count && output.count < expected {
            let header = Int8(bitPattern: input[index])
            index += 1
            if header >= 0 {
                let run = Int(header) + 1
                guard index + run <= count else {
                    throw ArtworkError.truncated("PackBits literal run")
                }
                output.append(input.subdata(in: index..<(index + run)))
                index += run
            } else if header != -128 {
                let run = 1 - Int(header)
                guard index < count else {
                    throw ArtworkError.truncated("PackBits repeat run")
                }
                let byte = input[index]
                index += 1
                output.append(contentsOf: repeatElement(byte, count: run))
            }
        }
        if output.count < expected {
            output.append(Data(repeating: 0, count: expected - output.count))
        } else if output.count > expected {
            output.removeSubrange(expected...)
        }
        return output
    }
}

enum ZlibInflate {
    static func decode(_ input: Data, expected: Int) -> Data? {
        guard !input.isEmpty, expected > 0 else { return nil }
        let capacity = expected + 16
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { dest -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let destBase = dest.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destBase,
                    capacity,
                    srcBase,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        if written < destination.count {
            destination.removeSubrange(written...)
        }
        return destination
    }

    static func undoDeltaPrediction(_ data: inout Data, rowBytes: Int) {
        guard rowBytes > 0 else { return }
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset + rowBytes <= total {
                var i = 1
                while i < rowBytes {
                    base[offset + i] = base[offset + i] &+ base[offset + i - 1]
                    i += 1
                }
                offset += rowBytes
            }
        }
    }
}

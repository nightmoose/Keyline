import Foundation
import UniformTypeIdentifiers

enum ArtworkLoader {
    static func load(data: Data, type: UTType, filename: String?) -> ArtworkPayload {
        let name = filename ?? "Untitled"
        let kind = ArtworkUTTypes.kind(for: type, filename: name)
        do {
            switch kind {
            case .photoshop:
                let file = try PhotoshopLoader.load(data: data, filename: name)
                return ArtworkPayload(
                    filename: name,
                    contentType: type,
                    data: data,
                    kind: .photoshop,
                    photoshop: file,
                    warnings: file.parseError.map { [$0] } ?? []
                )
            case .illustrator, .pdf:
                let file = try IllustratorLoader.load(data: data, filename: name, type: type)
                return ArtworkPayload(
                    filename: name,
                    contentType: type,
                    data: data,
                    kind: kind,
                    illustrator: file
                )
            case .unknown:
                if data.starts(with: Array("8BPS".utf8)) {
                    let file = try PhotoshopLoader.load(data: data, filename: name)
                    return ArtworkPayload(
                        filename: name,
                        contentType: type,
                        data: data,
                        kind: .photoshop,
                        photoshop: file,
                        warnings: file.parseError.map { [$0] } ?? []
                    )
                }
                let file = try IllustratorLoader.load(data: data, filename: name, type: type)
                return ArtworkPayload(
                    filename: name,
                    contentType: type,
                    data: data,
                    kind: .illustrator,
                    illustrator: file
                )
            }
        } catch {
            return ArtworkPayload(
                filename: name,
                contentType: type,
                data: data,
                kind: kind,
                error: error
            )
        }
    }
}

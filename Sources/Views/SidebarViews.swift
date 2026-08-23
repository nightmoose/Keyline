import SwiftUI

struct LayerSidebar: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        VStack(spacing: 0) {
            if let ps = session.payload.photoshop {
                List(selection: $session.selectedLayerID) {
                    Section("Layers") {
                        OutlineGroup(ps.layers.filter { !$0.isSectionDivider }, children: \.optionalChildren) { layer in
                            LayerRow(layer: layer)
                                .tag(layer.id)
                                .contextMenu {
                                    Button("View Isolated") {
                                        session.selectedLayerID = layer.id
                                        session.viewMode = .layer(layer.id)
                                    }
                                    .disabled(layer.image == nil)
                                    Button("View Composite") {
                                        session.viewMode = .composite
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
            } else if let ai = session.payload.illustrator, ai.pageCount > 1 {
                List(selection: Binding(
                    get: { Optional(session.selectedPageIndex) },
                    set: { session.selectedPageIndex = $0 ?? 0 }
                )) {
                    Section("Artboards") {
                        ForEach(0..<ai.pageCount, id: \.self) { index in
                            HStack(spacing: 10) {
                                pageThumb(ai, index: index)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Artboard \(index + 1)")
                                    if let page = ai.pdf?.page(at: index) {
                                        let bounds = page.bounds(for: .mediaBox)
                                        Text("\(Int(bounds.width)) × \(Int(bounds.height)) pt")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .tag(index)
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: session.payload.kind.symbolName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No layer tree")
                        .font(.headline)
                    Text("Illustrator files are shown as PDF artboards. Layer names live in Adobe’s private data and are not part of the open PDF stream.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: session.selectedLayerID) { _, id in
            if session.viewMode != .composite, let id {
                session.viewMode = .layer(id)
            }
        }
    }

    @ViewBuilder
    private func pageThumb(_ ai: IllustratorFile, index: Int) -> some View {
        if let image = ai.pageImage(at: index, scale: 0.12) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .background(CheckerboardBackground(cell: 4))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 40, height: 40)
        }
    }
}

private struct LayerRow: View {
    let layer: PSDLayer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(layer.isVisible ? Color.primary : Color.secondary)
                .frame(width: 14)
            if let image = layer.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .background(CheckerboardBackground(cell: 3))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            Text(layer.name)
                .lineLimit(1)
                .foregroundStyle(layer.isVisible ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            if !layer.isVisible {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(layer.isVisible ? 1 : 0.65)
        .help(helpText)
    }

    private var symbol: String {
        switch layer.kind {
        case .group: return layer.sectionType == .closedFolder ? "folder" : "folder.fill"
        case .text: return "textformat"
        case .smartObject: return "shippingbox"
        case .adjustment: return "slider.horizontal.3"
        case .shape: return "square.on.circle"
        case .pixel, .unknown: return "photo"
        }
    }

    private var helpText: String {
        var parts = [layer.kind.rawValue.capitalized, layer.blendModeName, "\(layer.opacityPercent)%"]
        if layer.isClip { parts.append("clipped") }
        return parts.joined(separator: " · ")
    }
}

private extension PSDLayer {
    var optionalChildren: [PSDLayer]? {
        children.isEmpty ? nil : children
    }
}

struct InspectorView: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        let meta = session.payload.metadata
        Form {
            Section("File") {
                LabeledContent("Name", value: meta.filename)
                LabeledContent("Kind", value: meta.kind.displayName)
                LabeledContent("Size", value: meta.fileSizeLabel)
            }
            Section("Document") {
                LabeledContent("Pixels", value: meta.pixelSizeLabel)
                LabeledContent("Print", value: meta.printSizeLabel)
                LabeledContent("Color", value: meta.colorMode)
                if meta.bitDepth > 0 {
                    LabeledContent("Depth", value: "\(meta.bitDepth)-bit")
                }
                if meta.channelCount > 0 {
                    LabeledContent("Channels", value: "\(meta.channelCount)")
                }
                if meta.pageCount > 0 {
                    LabeledContent("Pages", value: "\(meta.pageCount)")
                }
                if meta.layerCount > 0 {
                    LabeledContent("Layers", value: "\(meta.layerCount)")
                }
                if let profile = meta.colorProfile, !profile.isEmpty {
                    LabeledContent("Profile", value: profile)
                }
            }
            if let layer = session.selectedLayer, session.payload.photoshop != nil {
                Section("Selected layer") {
                    LabeledContent("Name", value: layer.name)
                    LabeledContent("Kind", value: layer.kind.rawValue.capitalized)
                    LabeledContent("Blend", value: layer.blendModeName)
                    LabeledContent("Opacity", value: "\(layer.opacityPercent)%")
                    LabeledContent("Visible", value: layer.isVisible ? "Yes" : "No")
                    LabeledContent("Bounds", value: "\(layer.width) × \(layer.height) at (\(layer.left), \(layer.top))")
                    if layer.image == nil && !layer.isGroup {
                        Text("No pixel data was decoded for this layer (adjustment, empty, or unsupported compression).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !meta.notes.isEmpty {
                Section("Notes") {
                    ForEach(meta.notes, id: \.self) { note in
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let text = session.payload.illustrator?.extractedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Extracted text") {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 260)
    }
}

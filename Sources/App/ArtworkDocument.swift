import SwiftUI
import UniformTypeIdentifiers

struct ArtworkDocument: FileDocument {
    static var readableContentTypes: [UTType] { ArtworkUTTypes.all }
    static var writableContentTypes: [UTType] { [] }

    let payload: ArtworkPayload

    init(payload: ArtworkPayload) {
        self.payload = payload
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, !data.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let filename = configuration.file.filename ?? "Untitled"
        payload = ArtworkLoader.load(data: data, type: configuration.contentType, filename: filename)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: payload.data)
    }
}

@MainActor
final class DocumentSession: ObservableObject {
    let payload: ArtworkPayload
    @Published var zoom: Double = 1.0
    @Published var selectedLayerID: UUID?
    @Published var selectedPageIndex: Int = 0
    @Published var viewMode: CanvasViewMode = .composite
    @Published var showSidebar = true
    @Published var showInspector = true
    @Published var exportError: String?

    init(payload: ArtworkPayload) {
        self.payload = payload
        if let firstVisible = payload.photoshop?.flatLayers.first(where: { !$0.isSectionDivider }) {
            selectedLayerID = firstVisible.id
        }
    }

    var selectedLayer: PSDLayer? {
        guard let id = selectedLayerID else { return nil }
        return payload.photoshop?.layer(id: id)
    }

    var displayedImage: NSImage? {
        switch viewMode {
        case .composite:
            return payload.displayImage
        case .layer(let id):
            return payload.photoshop?.layer(id: id)?.image ?? payload.displayImage
        }
    }

    func zoomIn() {
        zoom = min(16, (zoom * 1.25 * 100).rounded() / 100)
    }

    func zoomOut() {
        zoom = max(0.05, (zoom / 1.25 * 100).rounded() / 100)
    }

    func actualSize() {
        zoom = 1
    }

    func fit(in size: CGSize) {
        let art = artworkSize
        guard art.width > 0, art.height > 0, size.width > 0, size.height > 0 else { return }
        let scale = min(size.width / art.width, size.height / art.height)
        zoom = min(16, max(0.05, scale * 0.96))
    }

    var artworkSize: CGSize {
        if let pdf = payload.pdfDocument, let page = pdf.page(at: selectedPageIndex) {
            return page.bounds(for: .mediaBox).size
        }
        if let image = payload.displayImage {
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return CGSize(width: cg.width, height: cg.height)
            }
            return image.size
        }
        return .zero
    }

    func export() {
        presentExportPanel()
    }

    func exportPDF() {
        var options = ExportOptions()
        options.format = .pdf
        presentSavePanel(options: options)
    }

    func printDocument() {
        ArtworkPrinter.print(payload, pageIndex: selectedPageIndex)
    }

    func presentExportPanel() {
        let formats = ExportFormat.allCases.filter { $0.isAvailable(for: payload) }
        guard let first = formats.first else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = ArtworkExporter.suggestedName(for: payload, format: first)

        let currentPayload = payload
        let accessory = ExportAccessoryController(formats: formats, defaultFormat: first) { format in
            panel.allowedContentTypes = [format.contentType]
            panel.nameFieldStringValue = ArtworkExporter.suggestedName(for: currentPayload, format: format)
        }
        panel.accessoryView = accessory.view
        panel.allowedContentTypes = [first.contentType]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        var options = ExportOptions()
        options.format = accessory.selectedFormat
        options.pageIndex = selectedPageIndex
        options.scale = accessory.scale
        options.includeHiddenLayers = accessory.includeHidden
        do {
            try ArtworkExporter.export(payload, options: options, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func presentSavePanel(options: ExportOptions) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [options.format.contentType]
        panel.nameFieldStringValue = ArtworkExporter.suggestedName(for: payload, format: options.format)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ArtworkExporter.export(payload, options: options, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct DocumentSessionKey: FocusedValueKey {
    typealias Value = DocumentSession
}

extension FocusedValues {
    var documentSession: DocumentSession? {
        get { self[DocumentSessionKey.self] }
        set { self[DocumentSessionKey.self] = newValue }
    }
}

final class ExportAccessoryController: NSObject {
    let formats: [ExportFormat]
    private(set) var selectedFormat: ExportFormat
    private(set) var scale: CGFloat = 2
    private(set) var includeHidden = false
    let view: NSView
    private let onChange: (ExportFormat) -> Void
    private let popup: NSPopUpButton
    private let scalePopup: NSPopUpButton
    private let hiddenButton: NSButton

    init(formats: [ExportFormat], defaultFormat: ExportFormat, onChange: @escaping (ExportFormat) -> Void) {
        self.formats = formats
        self.selectedFormat = defaultFormat
        self.onChange = onChange

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let formatRow = NSStackView()
        formatRow.orientation = .horizontal
        formatRow.spacing = 8
        let formatLabel = NSTextField(labelWithString: "Format")
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in formats {
            popup.addItem(withTitle: format.displayName)
        }
        popup.selectItem(at: formats.firstIndex(of: defaultFormat) ?? 0)
        formatRow.addArrangedSubview(formatLabel)
        formatRow.addArrangedSubview(popup)

        let scaleRow = NSStackView()
        scaleRow.orientation = .horizontal
        scaleRow.spacing = 8
        let scaleLabel = NSTextField(labelWithString: "Raster scale")
        scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        scalePopup.addItems(withTitles: ["1× (72 ppi)", "2× (144 ppi)", "3× (216 ppi)", "4× (288 ppi)"])
        scalePopup.selectItem(at: 1)
        scaleRow.addArrangedSubview(scaleLabel)
        scaleRow.addArrangedSubview(scalePopup)

        hiddenButton = NSButton(checkboxWithTitle: "Include hidden layers (OpenRaster)", target: nil, action: nil)
        hiddenButton.state = .off

        stack.addArrangedSubview(formatRow)
        stack.addArrangedSubview(scaleRow)
        stack.addArrangedSubview(hiddenButton)
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 110)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(formatChanged)
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)
        hiddenButton.target = self
        hiddenButton.action = #selector(hiddenChanged)
    }

    @objc private func formatChanged() {
        let index = popup.indexOfSelectedItem
        guard formats.indices.contains(index) else { return }
        selectedFormat = formats[index]
        onChange(selectedFormat)
    }

    @objc private func scaleChanged() {
        let values: [CGFloat] = [1, 2, 3, 4]
        let index = scalePopup.indexOfSelectedItem
        scale = values.indices.contains(index) ? values[index] : 2
    }

    @objc private func hiddenChanged() {
        includeHidden = hiddenButton.state == .on
    }
}

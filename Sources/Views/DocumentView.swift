import SwiftUI
import PDFKit

struct DocumentView: View {
    let document: ArtworkDocument
    @StateObject private var session: DocumentSession
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init(document: ArtworkDocument) {
        self.document = document
        _session = StateObject(wrappedValue: DocumentSession(payload: document.payload))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LayerSidebar(session: session)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        } detail: {
            canvas
                .background(CheckerboardBackground())
                .inspector(isPresented: $session.showInspector) {
                    InspectorView(session: session)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
        }
        .navigationTitle(session.payload.filename)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .focusedSceneValue(\.documentSession, session)
        .alert("Export Failed", isPresented: Binding(
            get: { session.exportError != nil },
            set: { if !$0 { session.exportError = nil } }
        )) {
            Button("OK", role: .cancel) { session.exportError = nil }
        } message: {
            Text(session.exportError ?? "")
        }
        .onChange(of: session.showSidebar) { _, visible in
            columnVisibility = visible ? .all : .detailOnly
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if let error = session.payload.error {
            EmptyCanvasState(
                title: "Can’t display this file",
                detail: error.localizedDescription
            )
        } else if let pdf = session.payload.pdfDocument {
            PDFKitCanvas(
                document: pdf,
                pageIndex: $session.selectedPageIndex,
                zoom: $session.zoom
            )
        } else if let image = session.displayedImage {
            ZoomableImageCanvas(image: image, zoom: $session.zoom)
        } else {
            EmptyCanvasState(
                title: "No preview",
                detail: "The file opened, but Keyline could not build a displayable image."
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if session.payload.photoshop != nil {
                Picker("View", selection: viewModeBinding) {
                    Text("Composite").tag(CanvasViewMode.composite)
                    if let id = session.selectedLayerID, session.payload.photoshop?.layer(id: id)?.image != nil {
                        Text("Layer").tag(CanvasViewMode.layer(id))
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
        ToolbarItemGroup(placement: .principal) {
            HStack(spacing: 6) {
                Button {
                    session.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom Out")
                Text("\(Int((session.zoom * 100).rounded()))%")
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .frame(minWidth: 54)
                Button {
                    session.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom In")
                Button("100%") {
                    session.actualSize()
                }
            }
        }
        ToolbarItemGroup(placement: .automatic) {
            Button {
                session.export()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export PDF, PNG, TIFF, JPEG, or OpenRaster")
            Button {
                session.printDocument()
            } label: {
                Label("Print", systemImage: "printer")
            }
            .help("Print or save as PDF from the print panel")
            Button {
                session.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }

    private var viewModeBinding: Binding<CanvasViewMode> {
        Binding(
            get: { session.viewMode },
            set: { session.viewMode = $0 }
        )
    }

    private var subtitle: String {
        let meta = session.payload.metadata
        var parts = [meta.kind.displayName, meta.pixelSizeLabel]
        if meta.layerCount > 0 {
            parts.append("\(meta.layerCount) layers")
        } else if meta.pageCount > 1 {
            parts.append("\(meta.pageCount) artboards")
        }
        return parts.joined(separator: "  ·  ")
    }
}

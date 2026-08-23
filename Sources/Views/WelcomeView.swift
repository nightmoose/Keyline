import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct WelcomeView: View {
    @Environment(\.openDocument) private var openDocument
    @Environment(\.openWindow) private var openWindow

    @State private var isTargeted = false
    @State private var openError: String?
    @State private var recents: [URL] = NSDocumentController.shared.recentDocumentURLs

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            header
            Spacer(minLength: 20)
            dropZone
            if !recents.isEmpty {
                recentList
            }
            Spacer(minLength: 16)
            footer
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground())
        .onAppear {
            recents = NSDocumentController.shared.recentDocumentURLs
        }
        .alert("Couldn’t Open File", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("OK", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            Text("Keyline")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text("View Adobe Illustrator and Photoshop files — then print or export to open formats.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text(isTargeted ? "Release to open" : "Drop an .ai, .psd, .psb, .eps, or .pdf file here")
                .font(.headline)
            Button("Open File…") {
                presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                ForEach(["AI", "PSD", "PSB", "EPS", "PDF"], id: \.self) { ext in
                    Text(ext)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 560)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 5])
                )
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 22)
            ForEach(recents.prefix(5), id: \.self) { url in
                Button {
                    Task { await open(url: url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: url))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                        Spacer()
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: 560)
    }

    private var footer: some View {
        Text("Illustrator files need PDF compatibility (the Illustrator default). Photoshop files show the flattened composite plus a layer tree.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .padding(.top, 16)
    }

    private func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "ai", "ait", "eps", "epsf": return "pencil.and.outline"
        case "psd", "psb": return "square.stack.3d.up"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ArtworkUTTypes.all
        panel.message = "Choose Illustrator, Photoshop, EPS, or PDF files."
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls {
                await open(url: url)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await open(url: url)
                }
            }
            handled = true
        }
        return handled
    }

    @MainActor
    private func open(url: URL) async {
        do {
            try await openDocument(at: url)
            recents = NSDocumentController.shared.recentDocumentURLs
        } catch {
            openError = error.localizedDescription
        }
    }
}

struct WindowBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.08),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

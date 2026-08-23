import SwiftUI
import UniformTypeIdentifiers

@main
struct KeylineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WelcomeView()
        }
        .defaultSize(width: 780, height: 540)
        .commands {
            KeylineCommands()
        }

        DocumentGroup(viewing: ArtworkDocument.self) { file in
            DocumentView(document: file.document)
        }
        .commands {
            KeylineCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presentOpenPanel),
            name: .keylineOpen,
            object: nil
        )
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ArtworkUTTypes.all
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }
}

struct KeylineCommands: Commands {
    @FocusedValue(\.documentSession) private var session

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                NotificationCenter.default.post(name: .keylineOpen, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
        CommandGroup(after: .saveItem) {
            Button("Export…") {
                session?.export()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(session == nil)
            Button("Export PDF…") {
                session?.exportPDF()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(session == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                session?.printDocument()
            }
            .keyboardShortcut("p")
            .disabled(session == nil)
        }
        CommandMenu("View") {
            Button("Zoom In") { session?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(session == nil)
            Button("Zoom Out") { session?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(session == nil)
            Button("Actual Size") { session?.actualSize() }
                .keyboardShortcut("0")
                .disabled(session == nil)
            Divider()
            Button(session?.viewMode == .composite ? "Viewing Composite" : "Show Composite") {
                session?.viewMode = .composite
            }
            .disabled(session == nil)
        }
    }
}

extension Notification.Name {
    static let keylineOpen = Notification.Name("KeylineOpenDocument")
}

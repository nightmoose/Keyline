import SwiftUI
import PDFKit
import AppKit

struct CheckerboardBackground: View {
    var cell: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let light = Color(nsColor: NSColor.controlBackgroundColor)
            let dark = Color(nsColor: NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: .black) ?? .gray)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col) % 2 == 1 {
                        context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(dark))
                    }
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
        }
    }
}

struct PDFKitCanvas: NSViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int
    @Binding var zoom: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(pageIndex: $pageIndex, zoom: $zoom)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayBox = .mediaBox
        view.backgroundColor = .clear
        view.document = document
        view.scaleFactor = zoom
        view.delegate = context.coordinator
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.isApplying = true
        if view.document !== document {
            view.document = document
        }
        if let page = document.page(at: pageIndex), view.currentPage != page {
            view.go(to: page)
        }
        if abs(view.scaleFactor - CGFloat(zoom)) > 0.002 {
            view.scaleFactor = CGFloat(zoom)
        }
        context.coordinator.isApplying = false
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        var pageIndex: Binding<Int>
        var zoom: Binding<Double>
        var isApplying = false
        private var observers: [NSObjectProtocol] = []

        init(pageIndex: Binding<Int>, zoom: Binding<Double>) {
            self.pageIndex = pageIndex
            self.zoom = zoom
        }

        func observe(_ view: PDFView) {
            let scale = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged,
                object: view,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isApplying else { return }
                self.zoom.wrappedValue = Double(view.scaleFactor)
            }
            let page = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isApplying, let document = view.document, let current = view.currentPage else { return }
                self.pageIndex.wrappedValue = document.index(for: current)
            }
            observers = [scale, page]
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

struct ZoomableImageCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var zoom: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: $zoom)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.backgroundColor = .clear

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.animates = false
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageView.frame = NSRect(x: 0, y: 0, width: cg.width, height: cg.height)
        } else {
            imageView.frame = NSRect(origin: .zero, size: image.size)
        }
        scroll.documentView = imageView
        scroll.magnification = CGFloat(zoom)
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.isApplying = true
        if let imageView = scroll.documentView as? NSImageView, imageView.image !== image {
            imageView.image = image
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imageView.frame = NSRect(x: 0, y: 0, width: cg.width, height: cg.height)
            } else {
                imageView.frame = NSRect(origin: .zero, size: image.size)
            }
        }
        if abs(scroll.magnification - CGFloat(zoom)) > 0.002 {
            scroll.magnification = CGFloat(zoom)
        }
        context.coordinator.isApplying = false
    }

    final class Coordinator {
        var zoom: Binding<Double>
        var isApplying = false
        private var observer: NSObjectProtocol?

        init(zoom: Binding<Double>) {
            self.zoom = zoom
        }

        func observe(_ scroll: NSScrollView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification,
                object: scroll,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isApplying else { return }
                self.zoom.wrappedValue = Double(scroll.magnification)
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

struct EmptyCanvasState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

//
//  ContentView.swift
//  Typst Preview
//
//  Created by David Harwardt on 09.03.26.
//

import AppKit
import Combine
import Darwin
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class PreviewController: ObservableObject {
    struct PreviewDocument: Equatable {
        enum Kind {
            case pdf
            case svg
        }

        let url: URL
        let kind: Kind
        let revision: Int
    }

    @Published private(set) var document: PreviewDocument?
    @Published private(set) var statusMessage = "Open a rendered Typst `.pdf` or `.svg` file to start previewing."

    private var fileDescriptor: Int32 = -1
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var accessedURL: URL?
    private var isAccessingSecurityScopedResource = false
    private var revision = 0
    private let reloadDelay: TimeInterval = 0.03

    func openLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()

        for argument in arguments {
            guard !argument.hasPrefix("-") else { continue }

            if let url = url(from: argument) {
                open(url: url)
                return
            }
        }
    }

    func open(url: URL) {
        let standardizedURL = normalize(url)
        let fileManager = FileManager.default
        let shouldRestartWatcher = document?.url != standardizedURL || fileWatcher == nil

        guard fileManager.fileExists(atPath: standardizedURL.path) else {
            statusMessage = "File not found: \(standardizedURL.lastPathComponent)"
            return
        }

        guard let kind = PreviewDocument.Kind(url: standardizedURL) else {
            statusMessage = "Unsupported file type: \(standardizedURL.lastPathComponent)"
            return
        }

        beginAccessingDocument(at: standardizedURL)

        revision += 1
        document = PreviewDocument(url: standardizedURL, kind: kind, revision: revision)
        statusMessage = standardizedURL.lastPathComponent

        if shouldRestartWatcher {
            startWatching(url: standardizedURL)
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .svg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.prompt = "Open Preview"
        panel.message = "Choose a rendered Typst PDF or SVG file."

        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func reloadCurrentDocument() {
        guard let currentURL = document?.url else { return }
        open(url: currentURL)
    }

    func scheduleReloadCurrentDocument() {
        pendingReload?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.reloadCurrentDocument()
        }

        pendingReload = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + reloadDelay, execute: workItem)
    }

    private func url(from argument: String) -> URL? {
        if argument.hasPrefix("file://"), let url = URL(string: argument) {
            return url
        }

        let candidate = URL(fileURLWithPath: argument)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func normalize(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    private func beginAccessingDocument(at url: URL) {
        if accessedURL == url {
            return
        }

        endAccessingDocument()
        accessedURL = url
        isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
    }

    private func endAccessingDocument() {
        if isAccessingSecurityScopedResource {
            accessedURL?.stopAccessingSecurityScopedResource()
        }

        accessedURL = nil
        isAccessingSecurityScopedResource = false
    }

    private func startWatching(url: URL) {
        stopWatching()

        fileDescriptor = Darwin.open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            statusMessage = "Previewing \(url.lastPathComponent) without live reload."
            return
        }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main
        )

        watcher.setEventHandler { [weak self] in
            guard let self else { return }

            self.scheduleReloadCurrentDocument()

            let data = watcher.data
            if data.contains(.delete) || data.contains(.rename) {
                self.restartWatchingSoon()
            }
        }

        watcher.setCancelHandler { [fileDescriptor] in
            guard fileDescriptor >= 0 else { return }
            Darwin.close(fileDescriptor)
        }

        fileWatcher = watcher
        watcher.resume()
    }

    private func restartWatchingSoon() {
        stopWatching()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let currentURL = self.document?.url else { return }
            self.startWatching(url: currentURL)
        }
    }

    private func stopWatching() {
        pendingReload?.cancel()
        pendingReload = nil
        fileWatcher?.cancel()
        fileWatcher = nil
        fileDescriptor = -1
    }
}

private extension PreviewController.PreviewDocument.Kind {
    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf":
            self = .pdf
        case "svg":
            self = .svg
        default:
            return nil
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: PreviewController
    @State private var isTopChromeHovered = false
    @State private var window: NSWindow?

    var body: some View {
        ZStack(alignment: .top) {
            PreviewBackdrop()

            ZStack {
                if let document = controller.document {
                    DocumentSurface {
                        PreviewDocumentView(document: document)
                    }
                        .padding(.top, 28)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                } else {
                    EmptyPreviewState(controller: controller)
                        .padding(.top, 72)
                }
            }
            .padding(6)

            TopChrome(isHovered: isTopChromeHovered, window: window)
                .padding(.top, 10)
                .padding(.horizontal, 14)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.16)) {
                        isTopChromeHovered = hovering
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .background(WindowAccessor { window in
            self.window = window
            configure(window: window)
        })
        .modifier(WindowShellTreatment())
        .compositingGroup()
        .padding(8)
    }

    private func configure(window: NSWindow) {
        guard window.identifier?.rawValue != "typst-preview-window" else { return }

        window.identifier = NSUserInterfaceItemIdentifier("typst-preview-window")
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hasShadow = false

        if let screen = window.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let width = max(420, visibleFrame.width * 0.34)
            let height = max(480, visibleFrame.height * 0.92)
            let origin = NSPoint(
                x: visibleFrame.maxX - width - 24,
                y: visibleFrame.midY - (height / 2)
            )

            window.setContentSize(NSSize(width: width, height: height))
            window.setFrameOrigin(origin)
        }
    }
}

private struct PreviewBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.27, green: 0.49, blue: 0.78).opacity(0.12),
                    Color.clear,
                    Color(red: 0.22, green: 0.63, blue: 0.54).opacity(0.1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .background(.clear)
    }
}

private struct EmptyPreviewState: View {
    @ObservedObject var controller: PreviewController

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.primary)

            Text(controller.statusMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button("Open Preview File") {
                controller.presentOpenPanel()
            }
            .modifier(GlassButtonTreatment())
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .modifier(GlassCardTreatment())
    }
}

private struct TopChrome: View {
    let isHovered: Bool
    let window: NSWindow?

    var body: some View {
        ZStack {
            HStack {
                Spacer()
                CloseButton(isVisible: isHovered, window: window)
            }

            HStack {
                Spacer()
                DragHandle(isHovered: isHovered)
                Spacer()
            }
        }
        .frame(height: 24)
    }
}

private struct DragHandle: View {
    let isHovered: Bool

    var body: some View {
        WindowDragHandle()
            .frame(width: 76, height: 20)
            .overlay {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.34 : 0.16))
                    .frame(width: isHovered ? 44 : 36, height: 4)
            }
            .opacity(isHovered ? 1 : 0.84)
            .scaleEffect(isHovered ? 1 : 0.96)
    }
}

private struct CloseButton: View {
    let isVisible: Bool
    let window: NSWindow?

    var body: some View {
        Button {
            window?.performClose(nil)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.9)
        .allowsHitTesting(isVisible)
    }
}

private struct DocumentSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(0.03),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }

            content
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(1)
        }
    }
}

private struct GlassCardTreatment: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(Color.primary.opacity(0.03)), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

private struct GlassButtonTreatment: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
        } else {
            content
                .buttonStyle(.bordered)
        }
    }
}

private struct WindowShellTreatment: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(Color.primary.opacity(0.03)), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        } else {
            content
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
    }
}

private struct PreviewDocumentView: View {
    let document: PreviewController.PreviewDocument

    var body: some View {
        switch document.kind {
        case .pdf:
            PDFPreview(url: document.url, revision: document.revision)
        case .svg:
            SVGPreview(url: document.url, revision: document.revision)
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL
    let revision: Int

    final class Coordinator {
        var lastLoadedData = Data()
        var hasAppliedInitialFit = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ZoomablePDFView {
        let pdfView = ZoomablePDFView(frame: .zero)
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = false
        pdfView.backgroundColor = .clear
        pdfView.maxScaleFactor = 8
        pdfView.minScaleFactor = 0.1
        return pdfView
    }

    func updateNSView(_ pdfView: ZoomablePDFView, context: Context) {
        let _ = revision
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return
        }

        if context.coordinator.lastLoadedData == data {
            return
        }

        let previousScale = pdfView.scaleFactor
        let previousPageIndex = pdfView.currentPage.flatMap { currentPage in
            pdfView.document?.index(for: currentPage)
        }

        guard let document = PDFDocument(data: data) else {
            return
        }

        context.coordinator.lastLoadedData = data
        pdfView.document = document

        DispatchQueue.main.async {
            pdfView.layoutDocumentView()

            if let previousPageIndex,
               let page = document.page(at: previousPageIndex) {
                pdfView.go(to: page)
            }

            if context.coordinator.hasAppliedInitialFit,
               previousScale.isFinite,
               previousScale > 0 {
                pdfView.scaleFactor = min(max(previousScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
            } else {
                let fittedScale = pdfView.scaleFactorForSizeToFit
                if fittedScale.isFinite, fittedScale > 0 {
                    pdfView.minScaleFactor = min(fittedScale, 0.1)
                    pdfView.scaleFactor = fittedScale
                    context.coordinator.hasAppliedInitialFit = true
                }
            }
        }
    }
}

private final class ZoomablePDFView: PDFView {
    override func magnify(with event: NSEvent) {
        let updatedScale = scaleFactor * (1 + event.magnification)
        scaleFactor = min(max(updatedScale, minScaleFactor), maxScaleFactor)
    }
}

private struct SVGPreview: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let _ = revision
        let svgMarkup = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        webView.loadHTMLString(htmlDocument(for: svgMarkup), baseURL: url.deletingLastPathComponent())
    }

    private func htmlDocument(for svgMarkup: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=8.0, user-scalable=yes">
        <style>
        :root { color-scheme: dark; }
        html, body {
            margin: 0;
            min-height: 100%;
            background: #000;
        }
        body {
            display: flex;
            justify-content: center;
            align-items: flex-start;
            padding: 0;
            overflow: auto;
        }
        svg {
            display: block;
            width: 100%;
            height: auto;
            max-width: none;
            background: transparent;
        }
        </style>
        </head>
        <body>
        \(svgMarkup)
        </body>
        </html>
        """
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                callback(window)
            }
        }
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {
    }
}

private final class DragHandleView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

#Preview {
    ContentView(controller: PreviewController())
}

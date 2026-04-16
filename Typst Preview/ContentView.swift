//
//  ContentView.swift
//  Typst Preview
//
//  Created by David Harwardt on 09.03.26.
//

import AppKit
import Darwin
import PDFKit
import SwiftUI
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
    private var revision = 0

    deinit {
        stopWatching()
    }

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

        guard let kind = PreviewDocument.Kind(url: standardizedURL) else {
            statusMessage = "Unsupported file type: \(standardizedURL.lastPathComponent)"
            return
        }

        revision += 1
        document = PreviewDocument(url: standardizedURL, kind: kind, revision: revision)
        statusMessage = standardizedURL.lastPathComponent
        startWatching(url: standardizedURL)
    }

    func reloadCurrentDocument() {
        guard let currentURL = document?.url else { return }
        open(url: currentURL)
    }

    private func url(from argument: String) -> URL? {
        if argument.hasPrefix("file://"), let url = URL(string: argument) {
            return url
        }

        let candidate = URL(fileURLWithPath: argument)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func startWatching(url: URL) {
        stopWatching()

        fileDescriptor = open(url.path, O_EVTONLY)
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

            self.reloadCurrentDocument()

            let data = watcher.data
            if data.contains(.delete) || data.contains(.rename) {
                self.restartWatchingSoon()
            }
        }

        watcher.setCancelHandler { [fileDescriptor] in
            guard fileDescriptor >= 0 else { return }
            close(fileDescriptor)
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

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let document = controller.document {
                PreviewDocumentView(document: document)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.9))

                    Text(controller.statusMessage)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                .padding(24)
            }
        }
        .background(WindowAccessor { window in
            configure(window: window)
        })
    }

    private func configure(window: NSWindow) {
        guard window.identifier?.rawValue != "typst-preview-window" else { return }

        window.identifier = NSUserInterfaceItemIdentifier("typst-preview-window")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true

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

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView(frame: .zero)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = false
        pdfView.backgroundColor = .black
        pdfView.maxScaleFactor = 8
        pdfView.minScaleFactor = 0.1
        pdfView.usePageViewController(false)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        let _ = revision
        pdfView.document = PDFDocument(url: url)

        let fittedScale = pdfView.scaleFactorForSizeToFit
        if fittedScale.isFinite, fittedScale > 0 {
            pdfView.minScaleFactor = min(fittedScale, 0.1)
            pdfView.scaleFactor = fittedScale
        }
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

#Preview {
    ContentView(controller: PreviewController())
}

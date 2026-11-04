import AppKit
import WebKit
import UniformTypeIdentifiers
import BlinkShared

/// Builds a page that can't reach the network unless asked: the CSP meta is
/// prepended to the email's own HTML, and the HTML parser hoists it into <head>.
func lockedDownHTML(_ body: String, allowRemoteImages: Bool = false, localFiles: Bool = false, css: String = "") -> String {
    var img = "data:"
    if localFiles { img += " file:" }
    if allowRemoteImages { img += " https: http:" }
    let csp = "default-src 'none'; img-src \(img); style-src 'unsafe-inline' data:\(allowRemoteImages ? " https: http:" : ""); font-src data:"
    return """
    <meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(csp)">
    <style>\(css)</style>
    \(body)
    """
}

/// Links open in the default browser; nothing navigates inside the viewer.
final class ExternalLinkDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

func makeWebView(javaScript: Bool) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = javaScript
    let web = WKWebView(frame: .zero, configuration: config)
    web.setValue(false, forKey: "drawsBackground")
    return web
}

@objc(BlinkEmailViewer) final class EmailViewer: NSObject, BlinkPlugin {
    private let container = NSView()
    private let web = makeWebView(javaScript: false)
    private let links = ExternalLinkDelegate()
    private let content: EmailContent
    private var zoom: CGFloat = 1
    private var remoteButton: NSButton?

    var view: NSView { container }
    var preferredSize: NSSize { NSSize(width: 860, height: 900) }
    var supportsZoom: Bool { true }

    required init(url: URL) {
        content = EmailContent(MIMEParser.parse((try? Data(contentsOf: url)) ?? Data()))
        super.init()
        web.navigationDelegate = links

        let header = buildHeader()
        let line = NSBox()
        line.boxType = .separator
        for v in [header, line, web] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: line.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        render(allowRemote: false)
    }

    private func buildHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        for (name, value) in content.headers {
            let s = NSMutableAttributedString(string: name + ":  ", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
            let font = name == "Subject" ? NSFont.systemFont(ofSize: 15, weight: .semibold) : NSFont.systemFont(ofSize: 12)
            s.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            let label = NSTextField(labelWithAttributedString: s)
            label.isSelectable = true
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(label)
        }
        var buttons: [NSView] = content.attachments.enumerated().map { i, a in
            let b = NSButton(title: "\(a.name)  (\(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file)))",
                             target: self, action: #selector(openAttachment(_:)))
            b.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.tag = i
            return b
        }
        if let html = content.html, html.range(of: #"src\s*=\s*["']?https?:"#, options: .regularExpression) != nil {
            let b = NSButton(title: "Load Remote Images", target: self, action: #selector(loadRemote(_:)))
            b.bezelStyle = .recessed
            b.controlSize = .small
            remoteButton = b
            buttons.append(b)
        }
        if !buttons.isEmpty {
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = 6
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func render(allowRemote: Bool) {
        var body: String
        if var html = content.html {
            for (cid, part) in content.inline {
                html = html.replacingOccurrences(of: "cid:" + cid,
                                                 with: "data:\(part.type);base64,\(part.data.base64EncodedString())")
            }
            body = html
        } else {
            let escaped = (content.plain ?? "")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            body = "<pre>\(escaped)</pre>"
        }
        // Inline images that the HTML doesn't reference (common with plain-text mail).
        for (cid, part) in content.inline where part.type.hasPrefix("image/") && !(content.html ?? "").contains("cid:" + cid) {
            body += "<p><img src=\"data:\(part.type);base64,\(part.data.base64EncodedString())\"></p>"
        }
        let css = """
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, sans-serif; margin: 16px; word-wrap: break-word; }
        pre { white-space: pre-wrap; font: 13px ui-monospace, Menlo, monospace; }
        img { max-width: 100%; height: auto; }
        """
        web.loadHTMLString(lockedDownHTML(body, allowRemoteImages: allowRemote, css: css), baseURL: nil)
    }

    @objc private func loadRemote(_ sender: NSButton) {
        sender.isHidden = true
        render(allowRemote: true)
    }

    @objc private func openAttachment(_ sender: NSButton) {
        let a = content.attachments[sender.tag]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Blink-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = a.name.replacingOccurrences(of: "/", with: "-")
        let file = dir.appendingPathComponent(safe)
        do {
            try a.data.write(to: file)
            // Never launch something runnable straight out of an email: show it in Finder instead.
            let type = UTType(filenameExtension: file.pathExtension) ?? .data
            if [.executable, .application, .script, .package, .diskImage].contains(where: { type.conforms(to: $0) }) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                NSWorkspace.shared.open(file)
            }
        } catch {
            NSSound.beep()
        }
    }

    func zoomIn() { zoom = min(zoom * 1.2, 5); web.pageZoom = zoom }
    func zoomOut() { zoom = max(zoom / 1.2, 0.3); web.pageZoom = zoom }
    func zoomToFit() { zoom = 1; web.pageZoom = 1 }
    func actualSize() { zoomToFit() }
    func didAppear() {}
    func tearDown() {}
}

import AppKit
import WebKit
import cmark_gfm
import cmark_gfm_extensions
import BlinkShared

/// GitHub-flavoured markdown → HTML (tables, task lists, strikethrough, autolinks, footnotes).
func renderMarkdown(_ markdown: String) -> String {
    cmark_gfm_core_extensions_ensure_registered()
    let options = CMARK_OPT_UNSAFE | CMARK_OPT_GITHUB_PRE_LANG | CMARK_OPT_FOOTNOTES
    guard let parser = cmark_parser_new(options) else { return "" }
    defer { cmark_parser_free(parser) }
    for name in ["table", "strikethrough", "autolink", "tasklist", "tagfilter"] {
        if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
    }
    cmark_parser_feed(parser, markdown, markdown.utf8.count)
    guard let doc = cmark_parser_finish(parser) else { return "" }
    defer { cmark_node_free(doc) }
    guard let html = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
    defer { free(html) }
    return String(cString: html)
}

private let markdownCSS = """
:root { color-scheme: light dark; }
body { font: 15px/1.55 -apple-system, sans-serif; max-width: 860px; margin: 0 auto; padding: 20px 28px 60px;
       color: #1f2328; word-wrap: break-word; }
h1, h2 { border-bottom: 1px solid #d1d9e0; padding-bottom: .3em; }
h1, h2, h3, h4 { margin: 1.4em 0 .6em; line-height: 1.25; }
a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
code { font: 85% ui-monospace, Menlo, monospace; background: rgba(129,139,152,.15); padding: .2em .4em; border-radius: 6px; }
pre { background: #f6f8fa; padding: 14px 16px; border-radius: 6px; overflow: auto; line-height: 1.45; }
pre code { background: none; padding: 0; font-size: 85%; }
blockquote { margin: 0; padding: 0 1em; color: #59636e; border-left: .25em solid #d1d9e0; }
table { border-collapse: collapse; margin: 1em 0; display: block; overflow: auto; }
th, td { border: 1px solid #d1d9e0; padding: 6px 13px; } tr:nth-child(2n) { background: #f6f8fa; }
th { font-weight: 600; }
img { max-width: 100%; }
hr { border: 0; height: 1px; background: #d1d9e0; margin: 24px 0; }
li:has(> input[type=checkbox]) { list-style: none; } li > input[type=checkbox] { margin: 0 .4em 0 -1.4em; }
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; } a { color: #4493f8; }
  h1, h2, th, td, hr { border-color: #3d444d; } hr { background: #3d444d; }
  pre, tr:nth-child(2n) { background: #151b23; } blockquote { color: #9198a1; border-color: #3d444d; }
}
"""

/// Source on the left, rendered page on the right. The two scroll together (by
/// position through the document), and both refresh when the file changes on disk.
@objc(BlinkMarkdownViewer) final class MarkdownViewer: NSObject, BlinkPlugin, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    private let split = NSSplitView()
    private let sourceScroll: NSScrollView
    private let sourceText: NSTextView
    private let web: WKWebView
    private var zoom = FontZoom()
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingWebFraction: CGFloat?
    /// Which side we last scrolled programmatically, and when, so its echo is ignored.
    private var ignoreSourceUntil = Date.distantPast
    private var ignoreWebUntil = Date.distantPast

    var view: NSView { split }
    var preferredSize: NSSize { NSSize(width: 1500, height: 1000) }
    var supportsZoom: Bool { true }

    required init(url: URL) {
        self.url = url
        (sourceScroll, sourceText) = makeTextScrollView(wrap: true)
        web = makeWebView(javaScript: false)   // page scripts off; ours below still run
        super.init()

        // Report the page's scroll position. Runs in our own script world, so the
        // page's CSP and the "no page JavaScript" setting don't block it.
        let report = WKUserScript(source: """
            addEventListener('scroll', () => {
              const max = document.documentElement.scrollHeight - innerHeight;
              webkit.messageHandlers.scroll.postMessage(max > 0 ? scrollY / max : 0);
            }, {passive: true});
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        web.configuration.userContentController.addUserScript(report)
        web.configuration.userContentController.add(self, contentWorld: .defaultClient, name: "scroll")
        web.navigationDelegate = self

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sourceScroll)
        split.addArrangedSubview(web)
        sourceText.font = zoom.font

        sourceScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sourceScrolled),
                                               name: NSView.boundsDidChangeNotification, object: sourceScroll.contentView)
        load(keepPosition: false)
        watch()
    }

    func didAppear() {
        split.setPosition(split.bounds.width * 0.45, ofDividerAt: 0)
    }

    func tearDown() {
        watcher?.cancel()
        watcher = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "scroll", contentWorld: .defaultClient)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Loading

    private func load(keepPosition: Bool) {
        let fraction = keepPosition ? sourceFraction : 0
        let text = readText(url)
        sourceText.string = text
        sourceText.font = zoom.font
        if keepPosition { setSourceFraction(fraction) }
        pendingWebFraction = keepPosition ? fraction : nil
        let html = lockedDownHTML("<body>" + renderMarkdown(text) + "</body>", localFiles: true, css: markdownCSS)
        // A file base URL lets relative image paths load (read access is granted to that folder).
        web.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.pageZoom = zoom.size / FontZoom.defaultSize
        if let f = pendingWebFraction { setWebFraction(f) }
        pendingWebFraction = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let link = action.request.url {
            if link.fragment != nil, link.path == url.deletingLastPathComponent().path || link.path.isEmpty {
                decisionHandler(.allow)   // in-page anchor (#heading, footnotes)
                return
            }
            if link.isFileURL {
                blinkOpen(link)   // relative link to another local file
            } else {
                NSWorkspace.shared.open(link)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Editors usually save by writing a new file and renaming it over the old one,
    /// which orphans the descriptor we were watching, so re-arm after every event.
    private func watch() {
        watcher?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.watch() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let replaced = !src.data.isDisjoint(with: [.rename, .delete])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.load(keepPosition: true)
                if replaced { self.watch() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    // MARK: Scroll sync

    private var sourceFraction: CGFloat {
        let doc = sourceScroll.documentView?.frame.height ?? 0
        let visible = sourceScroll.contentView.bounds.height
        return doc > visible ? sourceScroll.contentView.bounds.minY / (doc - visible) : 0
    }

    private func setSourceFraction(_ f: CGFloat) {
        guard let doc = sourceScroll.documentView else { return }
        sourceText.layoutManager?.ensureLayout(for: sourceText.textContainer!)
        let max = doc.frame.height - sourceScroll.contentView.bounds.height
        ignoreSourceUntil = Date().addingTimeInterval(0.15)
        sourceScroll.contentView.scroll(to: NSPoint(x: 0, y: Swift.max(0, max * f)))
        sourceScroll.reflectScrolledClipView(sourceScroll.contentView)
    }

    private func setWebFraction(_ f: CGFloat) {
        ignoreWebUntil = Date().addingTimeInterval(0.15)
        web.evaluateJavaScript("scrollTo(0, \(f) * (document.documentElement.scrollHeight - innerHeight))",
                               in: nil, in: .defaultClient) { _ in }
    }

    @objc private func sourceScrolled() {
        guard Date() > ignoreSourceUntil else { return }
        setWebFraction(sourceFraction)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "scroll", Date() > ignoreWebUntil, let f = message.body as? Double else { return }
        setSourceFraction(CGFloat(f))
    }

    // MARK: Zoom (both columns together)

    private func applyZoom() {
        sourceText.font = zoom.font
        web.pageZoom = zoom.size / FontZoom.defaultSize
    }

    func zoomIn() { zoom.step(true); applyZoom() }
    func zoomOut() { zoom.step(false); applyZoom() }
    func zoomToFit() { zoom.reset(); applyZoom() }
    func actualSize() { zoomToFit() }
}

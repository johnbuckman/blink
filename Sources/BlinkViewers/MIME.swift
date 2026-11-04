import Foundation

/// Just enough MIME to show an .eml/.emlx: headers (RFC 2047 encoded words), nested
/// multiparts, base64 / quoted-printable, charsets, inline cid: images, attachments.
struct MIMEPart {
    var headers: [(name: String, value: String)] = []
    var body = Data()      // still transfer-encoded
    var children: [MIMEPart] = []

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// "text/html; charset=utf-8" → ("text/html", ["charset": "utf-8"])
    static func split(_ value: String?) -> (String, [String: String]) {
        guard let value else { return ("text/plain", [:]) }
        var parts = splitOutsideQuotes(value, on: ";")
        let main = parts.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var params: [String: String] = [:]
        for p in parts {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let k = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            // RFC 2231 continuation/charset forms (name*=utf-8''…) — take the decoded value.
            if k.hasSuffix("*") || k.contains("*0") {
                let base = String(k.prefix { $0 != "*" })
                let decoded = v.components(separatedBy: "''").last?.removingPercentEncoding ?? v
                params[base, default: ""] += decoded
            } else {
                params[k] = decodeWords(v)
            }
        }
        return (main.isEmpty ? "text/plain" : main, params)
    }

    var contentType: (String, [String: String]) { Self.split(header("Content-Type")) }
    var disposition: (String, [String: String]) { Self.split(header("Content-Disposition") ?? "inline") }
    var filename: String? { disposition.1["filename"] ?? contentType.1["name"] }
    var isAttachment: Bool { disposition.0 == "attachment" || (filename != nil && !contentType.0.hasPrefix("text/")) }
    var contentID: String? {
        header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
    }

    /// Body with the transfer encoding removed.
    var decoded: Data {
        switch header("Content-Transfer-Encoding")?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let clean = body.filter { !($0 == 10 || $0 == 13 || $0 == 32 || $0 == 9) }
            return Data(base64Encoded: clean, options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    var text: String { decodeString(decoded, charset: contentType.1["charset"]) }
}

func splitOutsideQuotes(_ s: String, on sep: Character) -> [String] {
    var out: [String] = [], cur = "", quoted = false
    for c in s {
        if c == "\"" { quoted.toggle() }
        if c == sep && !quoted { out.append(cur); cur = "" } else { cur.append(c) }
    }
    out.append(cur)
    return out
}

func decodeString(_ data: Data, charset: String?) -> String {
    if let charset {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cf != kCFStringEncodingInvalidId {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let s = String(data: data, encoding: enc) { return s }
        }
    }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        ?? String(decoding: data, as: UTF8.self)
}

func decodeQuotedPrintable(_ data: Data) -> Data {
    var out = Data(capacity: data.count)
    let b = [UInt8](data)
    var i = 0
    func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
    while i < b.count {
        if b[i] == 61 {  // "="
            if i + 1 < b.count, b[i + 1] == 10 { i += 2; continue }                 // soft break \n
            if i + 2 < b.count, b[i + 1] == 13, b[i + 2] == 10 { i += 3; continue }  // soft break \r\n
            if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(h << 4 | l); i += 3; continue
            }
        }
        out.append(b[i]); i += 1
    }
    return out
}

/// RFC 2047: =?charset?B|Q?text?=, with whitespace between adjacent encoded words dropped.
func decodeWords(_ s: String) -> String {
    guard s.contains("=?") else { return s }
    let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
    let ns = s as NSString
    var result = ""
    var last = 0
    var lastWasWord = false
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let between = ns.substring(with: NSRange(location: last, length: m.range.location - last))
        if !(lastWasWord && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { result += between }
        let charset = ns.substring(with: m.range(at: 1)).components(separatedBy: "*").first
        let enc = ns.substring(with: m.range(at: 2)).uppercased()
        let payload = ns.substring(with: m.range(at: 3))
        let data: Data
        if enc == "B" {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data(payload.utf8)
        } else {
            data = decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
        }
        result += decodeString(data, charset: charset)
        last = m.range.location + m.range.length
        lastWasWord = true
    }
    result += ns.substring(from: last)
    return result
}

enum MIMEParser {
    static func parse(_ raw: Data) -> MIMEPart {
        var data = raw
        // .emlx: first line is the message length in bytes; a plist follows the message.
        if let nl = data.firstIndex(of: 10), nl - data.startIndex < 12,
           let n = Int(String(decoding: data[data.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)) {
            let start = data.index(after: nl)
            data = data[start..<min(data.endIndex, start + n)]
        }
        return parsePart(Data(data))
    }

    private static func parsePart(_ data: Data) -> MIMEPart {
        var part = MIMEPart()
        let bytes = [UInt8](data)
        // Header block ends at the first empty line.
        var split = bytes.count
        var bodyStart = bytes.count
        var i = 0
        while i < bytes.count {
            if bytes[i] == 10 {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { split = i; bodyStart = i + 2; break }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { split = i; bodyStart = i + 3; break }
            }
            i += 1
        }
        if i == 0, !bytes.isEmpty, bytes[0] == 10 || bytes[0] == 13 { split = 0 }  // no headers at all
        let headerText = String(decoding: bytes[0..<split], as: UTF8.self)
        var lines: [String] = []
        for line in headerText.components(separatedBy: "\n") {
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if let f = l.first, f == " " || f == "\t", !lines.isEmpty {
                lines[lines.count - 1] += " " + l.trimmingCharacters(in: .whitespaces)
            } else if !l.isEmpty {
                lines.append(l)
            }
        }
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            let name = String(l[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            part.headers.append((name, value))
        }
        part.body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()

        let (type, params) = part.contentType
        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            part.children = splitMultipart(part.body, boundary: boundary).map(parsePart)
        } else if type == "message/rfc822" {
            part.children = [parsePart(part.decoded)]
        }
        return part
    }

    private static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delim = Array(("--" + boundary).utf8)
        let b = [UInt8](body)
        var parts: [Data] = []
        var start: Int? = nil
        var lineStart = 0
        while lineStart < b.count {
            var lineEnd = lineStart
            while lineEnd < b.count, b[lineEnd] != 10 { lineEnd += 1 }
            let isDelim = lineEnd - lineStart >= delim.count && Array(b[lineStart..<lineStart + delim.count]) == delim
            if isDelim {
                if let s = start {
                    var e = lineStart
                    if e > s, b[e - 1] == 10 { e -= 1 }
                    if e > s, b[e - 1] == 13 { e -= 1 }
                    parts.append(Data(b[s..<max(s, e)]))
                }
                let closing = lineStart + delim.count + 1 < b.count && b[lineStart + delim.count] == 45
                    && b[lineStart + delim.count + 1] == 45
                if closing { return parts }
                start = lineEnd + 1
            }
            lineStart = lineEnd + 1
        }
        if let s = start, s < b.count { parts.append(Data(b[s...])) }
        return parts
    }
}

/// What an email viewer needs out of a parsed message.
struct EmailContent {
    var headers: [(String, String)] = []
    var html: String?
    var plain: String?
    var inline: [String: (type: String, data: Data)] = [:]
    var attachments: [(name: String, data: Data)] = []

    init(_ root: MIMEPart) {
        for name in ["From", "To", "Cc", "Date", "Subject"] {
            if let v = root.header(name) { headers.append((name, decodeWords(v))) }
        }
        walk(root)
    }

    private mutating func walk(_ part: MIMEPart) {
        let type = part.contentType.0
        if !part.children.isEmpty {
            // message/rfc822 attachments are walked like the body: forwarded mail shows inline.
            for c in part.children { walk(c) }
            return
        }
        if let cid = part.contentID, !type.hasPrefix("text/") {
            inline[cid] = (type, part.decoded)
            if part.disposition.0 != "attachment" { return }
        }
        if part.isAttachment {
            attachments.append((part.filename ?? "attachment", part.decoded))
        } else if type == "text/html", html == nil {
            html = part.text
        } else if type == "text/plain", plain == nil {
            plain = part.text
        } else if type.hasPrefix("text/") {
            attachments.append((part.filename ?? "part.\(type.split(separator: "/").last ?? "txt")", part.decoded))
        } else {
            attachments.append((part.filename ?? "attachment", part.decoded))
        }
    }
}

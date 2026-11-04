import AppKit
import MapKit
import CoreLocation
import BlinkShared

// MARK: GPX

struct GPXPoint {
    var coordinate: CLLocationCoordinate2D
    var elevation: Double?
    var time: Date?
}

struct GPXFile {
    var tracks: [[GPXPoint]] = []      // one array per track segment / route
    var waypoints: [(coordinate: CLLocationCoordinate2D, name: String)] = []
    var name: String?
}

final class GPXParser: NSObject, XMLParserDelegate {
    private var file = GPXFile()
    private var segment: [GPXPoint]?
    private var point: GPXPoint?
    private var waypoint: (CLLocationCoordinate2D, String)?
    private var text = ""
    private let iso = ISO8601DateFormatter()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ url: URL) -> GPXFile {
        let p = GPXParser()
        let xml = XMLParser(contentsOf: url)
        xml?.delegate = p
        xml?.parse()
        return p.file
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        let coord = { () -> CLLocationCoordinate2D? in
            guard let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        switch element {
        case "trkseg", "rte": segment = []
        case "trkpt", "rtept": if let c = coord() { point = GPXPoint(coordinate: c) }
        case "wpt": if let c = coord() { waypoint = (c, "") }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "ele": point?.elevation = Double(value)
        case "time": point?.time = isoFrac.date(from: value) ?? iso.date(from: value)
        case "name":
            if waypoint != nil { waypoint!.1 = value } else if segment == nil, file.name == nil { file.name = value }
        case "trkpt", "rtept":
            if let p = point { segment?.append(p) }
            point = nil
        case "trkseg", "rte":
            if let s = segment, !s.isEmpty { file.tracks.append(s) }
            segment = nil
        case "wpt":
            if let w = waypoint { file.waypoints.append((w.0, w.1)) }
            waypoint = nil
        default: break
        }
        text = ""
    }
}

// MARK: OSM tiles

/// Same tile policy as StayOnTrack: identify ourselves, never ask a server for a zoom
/// level it doesn't really have (OpenTopoMap answers past z17 with a placeholder PNG),
/// and magnify the deepest real tile instead so zooming in never shows a blank map.
enum MapStyle: Int {
    case standard, topo

    var urlTemplate: String {
        switch self {
        case .standard: return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .topo: return "https://a.tile.opentopomap.org/{z}/{x}/{y}.png"
        }
    }
    var serverMaximumZ: Int { self == .standard ? 19 : 17 }
    var cacheName: String { self == .standard ? "osm" : "topo" }
    var attribution: String {
        self == .standard ? "© OpenStreetMap contributors"
                          : "© OpenStreetMap contributors, SRTM · style © OpenTopoMap (CC-BY-SA)"
    }
}

let osmUserAgent = "Blink/1.0 (personal macOS file viewer; +https://github.com/johnbuckman/blink)"

final class OSMTileOverlay: MKTileOverlay {
    let style: MapStyle
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 2   // OSM tile policy
        c.httpAdditionalHeaders = ["User-Agent": osmUserAgent]
        return URLSession(configuration: c)
    }()
    private static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Blink/Tiles", isDirectory: true)

    init(style: MapStyle) {
        self.style = style
        super.init(urlTemplate: style.urlTemplate)
        canReplaceMapContent = true
        maximumZ = 22   // claim every level; past the server's limit we magnify
    }

    private func cacheURL(z: Int, x: Int, y: Int) -> URL {
        Self.cacheRoot.appendingPathComponent("\(style.cacheName)/\(z)/\(x)/\(y).png")
    }

    private func fetch(z: Int, x: Int, y: Int, done: @escaping (Data?) -> Void) {
        let file = cacheURL(z: z, x: x, y: y)
        if let data = try? Data(contentsOf: file) { done(data); return }
        let remote = URL(string: style.urlTemplate
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))!
        Self.session.dataTask(with: remote) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { done(nil); return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
            done(data)
        }.resume()
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let maxZ = style.serverMaximumZ
        guard path.z > maxZ else {
            fetch(z: path.z, x: path.x, y: path.y) { result($0, nil) }
            return
        }
        // Crop this tile's share out of its ancestor at the deepest real level and scale it up.
        let dz = path.z - maxZ
        let ax = path.x >> dz, ay = path.y >> dz
        fetch(z: maxZ, x: ax, y: ay) { data in
            guard let data, let src = NSBitmapImageRep(data: data)?.cgImage else { result(nil, nil); return }
            let n = 1 << dz
            let sub = CGFloat(src.width) / CGFloat(n)
            let crop = CGRect(x: CGFloat(path.x - ax * n) * sub, y: CGFloat(path.y - ay * n) * sub, width: sub, height: sub)
            guard let piece = src.cropping(to: crop.integral) else { result(nil, nil); return }
            let size = 256
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { result(nil, nil); return }
            ctx.interpolationQuality = .high
            ctx.draw(piece, in: CGRect(x: 0, y: 0, width: size, height: size))
            let out = ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
            result(out, nil)
        }
    }
}

// MARK: Viewer

@objc(BlinkGPXViewer) final class GPXViewer: NSObject, BlinkPlugin, MKMapViewDelegate {
    private let container = NSView()
    private let map = MKMapView()
    private let gpx: GPXFile
    private var overlay: OSMTileOverlay
    private let stats = NSTextField(labelWithString: "")
    private let attribution = NSTextField(labelWithString: "")
    private var routeRect = MKMapRect.null

    var view: NSView { container }
    var preferredSize: NSSize { NSSize(width: 1100, height: 800) }
    var supportsZoom: Bool { true }

    required init(url: URL) {
        gpx = GPXParser.parse(url)
        overlay = OSMTileOverlay(style: .standard)
        super.init()
        map.delegate = self
        map.showsZoomControls = false
        map.showsCompass = true
        map.showsScale = true
        map.addOverlay(overlay, level: .aboveLabels)

        for seg in gpx.tracks {
            var coords = seg.map(\.coordinate)
            let line = MKPolyline(coordinates: &coords, count: coords.count)
            map.addOverlay(line, level: .aboveLabels)
            routeRect = routeRect.union(line.boundingMapRect)
        }
        for w in gpx.waypoints {
            let a = MKPointAnnotation()
            a.coordinate = w.coordinate
            a.title = w.name
            map.addAnnotation(a)
            routeRect = routeRect.union(MKMapRect(origin: MKMapPoint(w.coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        if let first = gpx.tracks.first?.first, let last = gpx.tracks.last?.last {
            let start = MKPointAnnotation(); start.coordinate = first.coordinate; start.title = "Start"
            let a = CLLocation(latitude: first.coordinate.latitude, longitude: first.coordinate.longitude)
            let b = CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
            if a.distance(from: b) < 100 {
                start.title = "Start · End"   // a loop: one marker, not End hiding Start
                map.addAnnotation(start)
            } else {
                let end = MKPointAnnotation(); end.coordinate = last.coordinate; end.title = "End"
                map.addAnnotations([start, end])
            }
        }

        let styleControl = NSSegmentedControl(labels: ["Map", "Topo"], trackingMode: .selectOne,
                                              target: self, action: #selector(changeStyle(_:)))
        styleControl.selectedSegment = 0
        stats.stringValue = summary()
        attribution.stringValue = MapStyle.standard.attribution
        for label in [stats, attribution] {
            label.font = .systemFont(ofSize: label === stats ? 12 : 10, weight: label === stats ? .medium : .regular)
            label.drawsBackground = true
            label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
            label.isBezeled = false
        }
        for v in [map, styleControl, stats, attribution] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: container.topAnchor),
            map.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            map.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            styleControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
            styleControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stats.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stats.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            attribution.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            attribution.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        stats.isHidden = stats.stringValue.isEmpty
    }

    func didAppear() { zoomToFit() }
    func tearDown() { map.delegate = nil }

    private func summary() -> String {
        var meters = 0.0, climb = 0.0
        var times: [Date] = []
        for seg in gpx.tracks {
            for (a, b) in zip(seg, seg.dropFirst()) {
                meters += CLLocation(latitude: a.coordinate.latitude, longitude: a.coordinate.longitude)
                    .distance(from: CLLocation(latitude: b.coordinate.latitude, longitude: b.coordinate.longitude))
            }
            // Smooth GPS elevation noise (5-point moving average) before summing the climbs.
            let ele = seg.compactMap(\.elevation)
            if ele.count > 1 {
                let smooth = ele.indices.map { i -> Double in
                    let w = ele[max(0, i - 2)...min(ele.count - 1, i + 2)]
                    return w.reduce(0, +) / Double(w.count)
                }
                for (a, b) in zip(smooth, smooth.dropFirst()) where b > a { climb += b - a }
            }
            times += seg.compactMap(\.time)
        }
        var parts: [String] = []
        if let name = gpx.name, !name.isEmpty { parts.append(name) }
        if meters > 0 { parts.append(String(format: "%.2f km", meters / 1000)) }
        if climb > 0 { parts.append(String(format: "↑ %.0f m", climb)) }
        if let a = times.min(), let b = times.max(), b > a {
            let f = DateComponentsFormatter()
            f.allowedUnits = [.hour, .minute]
            f.unitsStyle = .abbreviated
            parts.append(f.string(from: a, to: b) ?? "")
        }
        if !gpx.waypoints.isEmpty { parts.append("\(gpx.waypoints.count) waypoints") }
        return parts.isEmpty ? "" : "  " + parts.joined(separator: "  ·  ") + "  "
    }

    @objc private func changeStyle(_ sender: NSSegmentedControl) {
        let style = MapStyle(rawValue: sender.selectedSegment) ?? .standard
        guard style != overlay.style else { return }
        map.removeOverlay(overlay)
        overlay = OSMTileOverlay(style: style)
        map.insertOverlay(overlay, at: 0, level: .aboveLabels)
        attribution.stringValue = style.attribution
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
        if let line = overlay as? MKPolyline {
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = NSColor(red: 0.9, green: 0.1, blue: 0.35, alpha: 0.9)
            r.lineWidth = 4
            r.lineJoin = .round
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
        switch annotation.title ?? nil {
        case "Start", "Start · End": v.markerTintColor = .systemGreen; v.glyphImage = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)
        case "End": v.markerTintColor = .systemRed; v.glyphImage = NSImage(systemSymbolName: "flag.checkered", accessibilityDescription: nil)
        default: v.markerTintColor = .systemBlue
        }
        v.titleVisibility = .adaptive
        return v
    }

    // MARK: Zoom

    private func scale(_ factor: Double) {
        var r = map.region
        r.span.latitudeDelta = min(r.span.latitudeDelta * factor, 170)
        r.span.longitudeDelta = min(r.span.longitudeDelta * factor, 350)
        map.setRegion(r, animated: true)
    }

    func zoomIn() { scale(0.5) }
    func zoomOut() { scale(2) }
    func zoomToFit() {
        guard !routeRect.isNull else { return }
        map.setVisibleMapRect(routeRect, edgePadding: NSEdgeInsets(top: 60, left: 40, bottom: 50, right: 40), animated: false)
    }
    func actualSize() { zoomToFit() }
}

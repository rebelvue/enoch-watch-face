import CoreText
import SwiftUI
import CoreLocation
import WatchKit
import CoreMotion

final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coord = CLLocationCoordinate2D(latitude: 47.0682, longitude: 21.8548) // fallback: Santandrei, Bihor, Romania (home)
    @Published var live = false
    @Published var place: String? = nil
    private var placeAt: CLLocation? = nil
    private let geo = CLGeocoder()
    private let m = CLLocationManager()
    override init() { super.init(); m.delegate = self; m.desiredAccuracy = kCLLocationAccuracyKilometer
        m.distanceFilter = 500
        if !ProcessInfo.processInfo.arguments.contains("-noLocPrompt") { m.requestWhenInUseAuthorization(); m.startUpdatingLocation() }
        Borders.shared.locate(coord) }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { if let L = l.last { coord = L.coordinate; live = true
            // reverse-geocode (CLGeocoder) only after moving more than 5 km
            if placeAt.map({ L.distance(from: $0) > 5000 }) ?? true, !geo.isGeocoding {
                placeAt = L; geo.reverseGeocodeLocation(L) { [weak self] pm, _ in
                    guard let f = pm?.first else { return }
                    let city = (f.locality ?? f.administrativeArea)?.uppercased(), country = (f.country ?? Borders.shared.country?.name)?.uppercased()
                    DispatchQueue.main.async { self?.place = [city, country].compactMap { $0 }.joined(separator: ", ")
                        if let c = f.locality { Borders.shared.fetchCity(c, L.coordinate) } } } }
            // country borders: point-in-polygon on every GPS fix (bundled Natural Earth 1:110m, public domain)
            Borders.shared.locate(L.coordinate) } }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}

/// Country (Natural Earth 1:110m admin-0, bundled countries.json: [[NAME, [polygon [ring [[lon,lat]]]]]])
/// and city boundary (Nominatim polygon_geojson, fetched once per city change, skipped when unavailable).
final class Borders: ObservableObject {
    static let shared = Borders()
    typealias Ring = [[Double]]
    struct Country { let name: String; let polys: [[Ring]] }
    private let all: [Country] = {
        guard let u = Bundle.main.url(forResource: "countries", withExtension: "json"), let d = try? Data(contentsOf: u),
              let a = try? JSONSerialization.jsonObject(with: d) as? [[Any]] else { return [] }
        return a.compactMap { e in guard let n = e.first as? String, let p = e.last as? [[[[Double]]]] else { return nil }; return Country(name: n, polys: p) }
    }()
    @Published var country: Country? = nil
    @Published var city: [Ring] = []
    private var cityName: String? = nil
    static func inside(_ r: Ring, _ x: Double, _ y: Double) -> Bool {
        var c = false, j = r.count - 1
        for i in 0..<r.count { let a = r[i], b = r[j]
            if (a[1] > y) != (b[1] > y), x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0] { c.toggle() }; j = i }
        return c
    }
    static func inPolys(_ ps: [[Ring]], _ x: Double, _ y: Double) -> Bool {
        ps.contains { p in inside(p[0], x, y) && !p.dropFirst().contains { inside($0, x, y) } } }
    func locate(_ c: CLLocationCoordinate2D) {
        if let k = country, Borders.inPolys(k.polys, c.longitude, c.latitude) { return }
        country = all.first { Borders.inPolys($0.polys, c.longitude, c.latitude) }
    }
    func fetchCity(_ name: String, _ c: CLLocationCoordinate2D) {
        guard name != cityName else { return }; cityName = name; city = []
        var u = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        u.queryItems = [.init(name: "format", value: "jsonv2"), .init(name: "lat", value: String(c.latitude)), .init(name: "lon", value: String(c.longitude)),
                        .init(name: "zoom", value: "10"), .init(name: "polygon_geojson", value: "1"), .init(name: "polygon_threshold", value: "0.002")]
        var rq = URLRequest(url: u.url!); rq.setValue("EnochWatch/1.0 (github.com/rebelvue/enoch-watch-face)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: rq) { d, _, _ in
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let g = j["geojson"] as? [String: Any], let t = g["type"] as? String else { return }
            var rings: [Ring] = []
            if t == "Polygon", let p = g["coordinates"] as? [Ring] { rings = p }
            if t == "MultiPolygon", let mp = g["coordinates"] as? [[Ring]] { rings = mp.flatMap { $0 } }
            DispatchQueue.main.async { self.city = rings }
        }.resume()
    }
}

struct FaceView: View {
    @ObservedObject private var borders = Borders.shared
    @StateObject private var loc = Locator()
    @StateObject private var hr = HeartRate()
    @StateObject private var motion = Motion()
    // map zoom: 1 = whole disc, fillZoom = disc covers the whole screen (radius = half the diagonal)
    @FocusState private var crownFocus: Bool
    @AppStorage("enochZoom") private var zoom: Double = 1
    private let fillZoom: Double = {
        let b = WKInterfaceDevice.current().screenBounds.size
        return hypot(b.width, b.height) / 2 / (min(b.width, b.height) / 2 - 4)
    }()
    // real bright stars (HYG catalogue, mag < 4.5): [RA deg, Dec deg, mag, B-V]
    private let stars: [[Double]] = {
        guard let u = Bundle.main.url(forResource: "stars", withExtension: "json"), let d = try? Data(contentsOf: u),
              let a = try? JSONDecoder().decode([[Double]].self, from: d) else { return [] }
        return a
    }()
    private let moonTex: CGImage? = UIImage(named: "moon")?.cgImage

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { ctx in
            ZStack {
                // bottom to top: map + day/night + borders + grid, glass digits, stars + sun + moon + tags, corners and text
                Canvas { g, size in draw(&g, size, ctx.date, 0) }
                GlassTime(date: ctx.date, tilt: motion.tilt).zIndex(1)
                Canvas { g, size in draw(&g, size, ctx.date, 1) }.zIndex(2).allowsHitTesting(false)
                Canvas { g, size in draw(&g, size, ctx.date, 2) }.zIndex(3).allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
        // crown attached to a concrete, framed, focused view (avoids "Crown Sequencer was set up without a view property")
        .focusable(true)
        .focused($crownFocus)
        .digitalCrownRotation($zoom, from: 1, through: fillZoom, by: 0.02, sensitivity: .low,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: zoom) { z in
            if z <= 1.0001 || z >= fillZoom - 0.0001 { WKInterfaceDevice.current().play(.click) } // detent at both ends
        }
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.3)) { zoom = zoom < (1 + fillZoom) / 2 ? fillZoom : 1 }
        }
        .background(Color.black)
        .onAppear { motion.start(); crownFocus = true; WKInterfaceDevice.current().isBatteryMonitoringEnabled = true }
        // weather fetch lives outside the draw path: every 12 min, and when the location moves
        .task { while !Task.isCancelled { fetchTemp(loc.coord); try? await Task.sleep(nanoseconds: 720_000_000_000) } }
        .onChange(of: loc.live) { _ in fetchTemp(loc.coord) }
        .onDisappear { motion.stop() }
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        // hides the watchOS status-bar time (SwiftUI underscored modifier, present in the public SDK interface)
        ._statusBarHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ date: Date, _ layer: Int) {
        let sky = Sky(date: date), d = Double.pi / 180
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = (min(size.width, size.height) / 2 - 4) * min(fillZoom, max(1, zoom))
        // World of Enoch projection: r = (90 - lat)/180 * R, lon 0 pointing down, east to the right
        func P(_ lat: Double, _ lon: Double) -> CGPoint {
            let r = (90 - lat) / 180 * R; return CGPoint(x: c.x + r * sin(lon * d), y: c.y + r * cos(lon * d)) }
        func dot(_ p: CGPoint, _ r: Double, _ col: Color) { g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(col)) }

        if layer == 0 {
        // beyond the ice wall: pure black (OLED)
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black))
        // map
        let disc = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
        g.drawLayer { l in
            l.clip(to: Path(ellipseIn: disc))
            // original map, natural colours; lighting below only changes exposure
            l.draw(Image("disc"), in: disc)
            // night side: solar elevation on the globe, sampled on a coarse grid
            // smooth shading: per-cell values go into two small bitmaps that are drawn scaled up with
            // interpolation, so there are no cell squares or seams (filled cells used to overlap into a visible grid)
            if let sh = Self.shade(n: 64, sunLat: sky.sunLat * d, sunLon: sky.sunLon * d) {
                l.draw(Image(decorative: sh.0, scale: 1).interpolation(.high), in: disc)
                l.blendMode = .screen; l.draw(Image(decorative: sh.1, scale: 1).interpolation(.high), in: disc); l.blendMode = .normal
            }
            // current country (thin orange) and city (thinner orange) boundaries, projected like the map
            let orange = Color(red: 1, green: 0.55, blue: 0.1)
            func ringPath(_ rg: [[Double]]) -> Path { var p = Path()
                for (k, v) in rg.enumerated() { let rr = (90 - v[1]) / 180 * R, a = v[0] * d, pt = CGPoint(x: c.x + rr * sin(a), y: c.y + rr * cos(a)); k == 0 ? p.move(to: pt) : p.addLine(to: pt) }
                p.closeSubpath(); return p }
            if let k = borders.country { for poly in k.polys { for rg in poly { l.stroke(ringPath(rg), with: .color(orange), lineWidth: 0.9) } } }
            for rg in borders.city { l.stroke(ringPath(rg), with: .color(orange.opacity(0.9)), lineWidth: 0.5) }
            // firmament dome from above: clear crown, pale blue sheen at the rim resting on the ice wall
            l.fill(Path(ellipseIn: disc), with: .radialGradient(Gradient(stops: [
                .init(color: Color(red: 0.75, green: 0.94, blue: 0.82).opacity(0.03), location: 0),
                .init(color: Color(red: 0.75, green: 0.94, blue: 0.82).opacity(0.07), location: 0.75),
                .init(color: Color(red: 0.78, green: 0.92, blue: 0.84).opacity(0.32), location: 1)]), center: c, startRadius: 0, endRadius: R * 1.03))
        }

        // tactical overlay: range rings, radials, rim ticks
        let acc = Color(red: 0.75, green: 0.96, blue: 0.82)
        g.drawLayer { l in
            l.clip(to: Path(ellipseIn: disc))
            for la in [60.0, 30, 0, -30, -60] { let r = (90 - la) / 180 * R
                l.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(acc.opacity(0.22)), lineWidth: 0.6) }
            for k in 0..<12 { let a = Double(k) * 30 * d; var p = Path(); p.move(to: c); p.addLine(to: CGPoint(x: c.x + R * sin(a), y: c.y + R * cos(a)))
                l.stroke(p, with: .color(acc.opacity(0.22)), lineWidth: 0.6) }
        }
        g.stroke(Path(ellipseIn: disc), with: .color(Color(red: 0.75, green: 0.86, blue: 1).opacity(0.9)), lineWidth: 1.2)
        for k in 0..<36 { let a = Double(k) * 10 * d, len = k % 3 == 0 ? 6.0 : 3.0; var p = Path()
            p.move(to: CGPoint(x: c.x + (R - len) * sin(a), y: c.y + (R - len) * cos(a))); p.addLine(to: CGPoint(x: c.x + R * sin(a), y: c.y + R * cos(a)))
            g.stroke(p, with: .color(acc), lineWidth: k % 3 == 0 ? 1 : 0.6) }
        }
        if layer == 1 {
        let disc = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R), sl = sky.sunLat * d, so = sky.sunLon * d
        g.drawLayer { l in
            l.clip(to: Path(ellipseIn: disc))
            // real stars over the ground point lat = Dec, lon = RA - GST (same as sun and moon); faint by day
            for st in stars {
                let r = (90 - st[1]) / 180; if r > 1 { continue }
                let lo = (st[0] - sky.siderealDeg) * d, e = sin(st[1] * d) * sin(sl) + cos(st[1] * d) * cos(sl) * cos(lo - so)
                let night = min(1, max(0, (0.08 - e) * 4)), rad = max(0.4, 1.8 - st[2] * 0.32)
                let p = CGPoint(x: c.x + r * R * sin(lo), y: c.y + r * R * cos(lo))
                let col = st[3] < 0 ? Color(red: 0.81, green: 0.88, blue: 1) : st[3] < 1.2 ? Color(red: 1, green: 0.96, blue: 0.88) : Color(red: 1, green: 0.79, blue: 0.63)
                l.fill(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: 2 * rad, height: 2 * rad)), with: .color(col.opacity(min(1, (0.15 + 0.85 * night) * (1.15 - st[2] * 0.18)))))
            }
        }
        // labels try right-up, left-up, right-down, left-down; keep clear of the top text band, bottom line and corner comps
        func tag(_ p: CGPoint, _ t: String, _ col: Color) {
            let rt = g.resolve(Text(t).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(col))
            let w = rt.measure(in: CGSize(width: 200, height: 20)).width, W = size.width, H = size.height
            let ko = [CGRect(x: 0, y: 0, width: W, height: 28), CGRect(x: 0, y: H - 20, width: W, height: 20),
                      CGRect(x: 0, y: 0, width: 68, height: 72), CGRect(x: W - 72, y: 0, width: 72, height: 92),
                      CGRect(x: 0, y: H - 64, width: 68, height: 64), CGRect(x: W - 68, y: H - 64, width: 68, height: 64)]
            let opts = [CGPoint(x: p.x + 9, y: p.y - 9), CGPoint(x: p.x - 9 - w, y: p.y - 9), CGPoint(x: p.x + 9, y: p.y + 9), CGPoint(x: p.x - 9 - w, y: p.y + 9)]
            var o = CGPoint(x: min(W - 4 - w, max(4, p.x + 9)), y: min(H - 26, max(34, p.y - 9)))
            for q in opts where q.x >= 2 && q.x + w <= W - 2 {
                let r = CGRect(x: q.x, y: q.y - 5, width: w, height: 10)
                if !ko.contains(where: { $0.intersects(r) }) { o = q; break } }
            g.draw(rt, at: o, anchor: .leading) }
        // sun: warm corona bloom, anamorphic streak, white-hot limb-darkened photosphere
        let amb = Color(red: 1, green: 0.69, blue: 0.23), sp = P(sky.sunLat, sky.sunLon)
        var sg = g; sg.blendMode = .plusLighter
        sg.fill(Path(ellipseIn: CGRect(x: sp.x - 32, y: sp.y - 32, width: 64, height: 64)), with: .radialGradient(Gradient(stops: [
            .init(color: Color(red: 1, green: 0.84, blue: 0.55).opacity(0.55), location: 0), .init(color: Color(red: 1, green: 0.66, blue: 0.27).opacity(0.18), location: 0.3),
            .init(color: .clear, location: 1)]), center: sp, startRadius: 0, endRadius: 32))
        sg.fill(Path(CGRect(x: sp.x - 34, y: sp.y - 0.6, width: 68, height: 1.2)), with: .linearGradient(Gradient(colors: [.clear, Color(red: 0.86, green: 0.92, blue: 1).opacity(0.55), .clear]),
            startPoint: CGPoint(x: sp.x - 34, y: sp.y), endPoint: CGPoint(x: sp.x + 34, y: sp.y)))
        g.fill(Path(ellipseIn: CGRect(x: sp.x - 4.5, y: sp.y - 4.5, width: 9, height: 9)), with: .radialGradient(Gradient(stops: [
            .init(color: .white, location: 0), .init(color: Color(red: 1, green: 0.96, blue: 0.86), location: 0.55), .init(color: Color(red: 1, green: 0.82, blue: 0.48), location: 0.85),
            .init(color: Color(red: 0.95, green: 0.6, blue: 0.23), location: 1)]), center: sp, startRadius: 0, endRadius: 4.5))
        tag(sp, "SUN", amb)

        // moon: NASA LRO nearside texture, sphere-shaded terminator, earthshine and limb darkening
        let mp = P(sky.moonLat, sky.moonLon), mr = 6.0
        if let img = shadedMoon(sky.phase) {
            g.draw(Image(decorative: img, scale: 1), in: CGRect(x: mp.x - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)) }
        tag(mp, "MOON \(Int((1 - cos(sky.phase)) / 2 * 100))%", amb)
        }
        if layer == 2 {
        let amb = Color(red: 1, green: 0.69, blue: 0.23)

        // you: position (no marker; borders and top line show it), LOC and HOME distance / bearing (great circle)
        let la = loc.coord.latitude, lo = loc.coord.longitude

        // top: live place name, then local date; bottom: coordinates
        let dfm = DateFormatter(); dfm.locale = Locale(identifier: "en_US_POSIX"); dfm.dateFormat = "EEE dd MMM yyyy"
        g.draw(g.resolve(Text(loc.place ?? "SANTANDREI, ROMANIA").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundColor(.white)), at: CGPoint(x: c.x, y: 11), anchor: .center)
        let dl = g.resolve(Text(dfm.string(from: date).uppercased()).font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(amb))
        g.draw(dl, at: CGPoint(x: c.x, y: 21), anchor: .center) // resolved text has no width limit: always one line
        g.draw(Text(String(format: "%.3f%@ / %07.3f%@%@", abs(la), la >= 0 ? "N" : "S", abs(lo), lo >= 0 ? "E" : "W", loc.live ? "" : " FALLBACK")).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: c.x, y: size.height - 12))

        corners(&g, size, date, sky)
        for y in stride(from: 0.0, to: size.height, by: 3) { g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.03))) }

        }
    }

    /// Night (black, alpha 0.9*(1-t)) and day (grey 0.32 screen, alpha t) shading maps over the disc's bounding square.
    private static func shade(n: Int, sunLat sl: Double, sunLon so: Double) -> (CGImage, CGImage)? {
        let d = Double.pi / 180
        var night = [UInt8](repeating: 0, count: n * n * 4), day = [UInt8](repeating: 0, count: n * n * 4)
        for j in 0..<n { for i in 0..<n {
            let dx = (Double(i) + 0.5) / Double(n) * 2 - 1, dy = (Double(j) + 0.5) / Double(n) * 2 - 1, r = hypot(dx, dy)
            let la = (90 - min(r, 1) * 180) * d, lo = atan2(dx, dy)
            let e = sin(la) * sin(sl) + cos(la) * cos(sl) * cos(lo - so)
            var t = min(1, max(0, (e + 0.309) / 0.517)); t = t * t * (3 - 2 * t)
            let k = (j * n + i) * 4
            night[k + 3] = UInt8(255 * 0.93 * (1 - t))                   // premultiplied black
            let a = 255 * t, v = UInt8(a * 0.12); day[k] = v; day[k + 1] = v; day[k + 2] = v; day[k + 3] = UInt8(a)
        } }
        func img(_ px: [UInt8]) -> CGImage? {
            guard let p = CGDataProvider(data: Data(px) as CFData) else { return nil }
            return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let a = img(night), let b = img(day) else { return nil }
        return (a, b)
    }

    // ---- four corner complications ----
    @State private var temp: Int? = nil
    @State private var rain: Int? = nil
    @State private var wxAt = Date.distantPast
    @State private var wxOk: Date? = nil
    private let home = CLLocationCoordinate2D(latitude: 47.0682, longitude: 21.8548)

    /// CoD MW-inspired original HUD icons (flat, angular), 16x16 box with origin at top-left.
    private enum Icon { case sun(up: Bool), heart, rain, battery(level: Double, charging: Bool) }
    private static let mint = Color(red: 0.75, green: 0.96, blue: 0.82), amber = Color(red: 1, green: 0.69, blue: 0.23), alert = Color(red: 1, green: 0.29, blue: 0.24)
    private func poly(_ o: CGPoint, _ pts: [(Double, Double)], close: Bool = true) -> Path {
        var p = Path(); p.addLines(pts.map { CGPoint(x: o.x + $0.0, y: o.y + $0.1) }); if close { p.closeSubpath() }; return p }
    /// SF Symbols (Apple, licensed for use in apps on Apple platforms), always orange like the borders; red only in alert states.
    private func drawIcon(_ g: inout GraphicsContext, _ icon: Icon, _ o: CGPoint, alertOn: Bool = false) {
        let orange = Color(red: 1, green: 0.55, blue: 0.1)
        var name = "", col = alertOn ? FaceView.alert : orange
        switch icon {
        case .sun(let up): name = up ? "sunrise.fill" : "sunset.fill"
        case .heart: name = "heart.fill"
        case .rain: name = "drop.fill"
        case .battery(let lv, let chg):
            if lv >= 0 && lv < 0.2 { col = FaceView.alert }
            name = chg ? "battery.100.bolt" : lv < 0 ? "battery.0" : lv > 0.875 ? "battery.100" : lv > 0.625 ? "battery.75" : lv > 0.375 ? "battery.50" : lv > 0.1 ? "battery.25" : "battery.0"
        }
        var im = g.resolve(Image(systemName: name)); im.shading = .color(col)
        let sz = im.size, k = 15 / max(sz.width, sz.height)
        g.draw(im, in: CGRect(x: o.x + 8 - sz.width * k / 2, y: o.y + 8 - sz.height * k / 2, width: sz.width * k, height: sz.height * k))
    }
    /// Curved complication: icon + value laid along the disc rim (no frame). `deg` = centre angle from the screen centre
    /// (0 = right, 90 = down). Icon on the outer side; value always white.
    private func chip(_ g: inout GraphicsContext, _ size: CGSize, deg: Double, leading: Bool, _ icon: Icon, _ val: String, _ vcol: Color, alertOn: Bool = false) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R0 = min(size.width, size.height) / 2 - 4
        let rm = R0 + 6.0, top = sin(deg * .pi / 180) < 0, dir = top ? 1.0 : -1.0
        let glyphs = val.map { g.resolve(Text(String($0)).font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundColor(.white)) }
        let gw = glyphs.map { $0.measure(in: CGSize(width: 40, height: 40)).width }
        let iconL = 16.0, gap = 3.0, total = iconL + gap + gw.reduce(0, +), s0 = deg * .pi / 180 - dir * total / rm / 2
        func place(_ len: Double, _ body: (inout GraphicsContext) -> Void) {
            let t = s0 + dir * len / rm; var l = g
            l.translateBy(x: c.x + rm * cos(t), y: c.y + rm * sin(t)); l.rotate(by: .radians(t + dir * .pi / 2)); body(&l) }
        var pos = 0.0
        func drawText() { for (k, t) in glyphs.enumerated() { place(pos + gw[k] / 2) { $0.draw(t, at: .zero, anchor: .center) }; pos += gw[k] } }
        func drawIc() { place(pos + iconL / 2) { l in drawIcon(&l, icon, CGPoint(x: -8, y: -8), alertOn: alertOn) }; pos += iconL }
        if leading { drawIc(); pos += gap; drawText() } else { drawText(); pos += gap; drawIc() }
    }

    private func corners(_ g: inout GraphicsContext, _ size: CGSize, _ date: Date, _ sky: Sky) {
        let me = loc.coord, d = Double.pi / 180, tf = DateFormatter(); tf.dateFormat = "HH:mm"
        // top-left: next sunrise/sunset here, from the subsolar point
        var up = true, sunTxt = "--"
        let cc = (sin(-0.833 * d) - sin(me.latitude * d) * sin(sky.sunLat * d)) / (cos(me.latitude * d) * cos(sky.sunLat * d))
        if abs(cc) <= 1 {
            let h0 = acos(cc) / d / 15, dn = ((sky.sunLon - me.longitude) / 15).truncatingRemainder(dividingBy: 24)
            let dn2 = dn > 12 ? dn - 24 : (dn < -12 ? dn + 24 : dn), noon = date.addingTimeInterval(dn2 * 3600)
            var ev: [(Date, Bool)] = []
            for k in -1...1 {
                let base: Double = Double(k) * 86400, half: Double = h0 * 3600
                ev.append((noon.addingTimeInterval(base - half), true))
                ev.append((noon.addingTimeInterval(base + half), false))
            }
            ev = ev.filter { $0.0 > date }.sorted { $0.0 < $1.0 }
            if let e = ev.first { up = e.1; sunTxt = tf.string(from: e.0) }
        }
        chip(&g, size, deg: -126, leading: true, .sun(up: up), sunTxt, .white)
        // top-right: live heart rate (HealthKit); red only when abnormal (<40 or >120 BPM)
        let bpm = hr.bpm.flatMap { v in hr.at.map { date.timeIntervalSince($0) < 900 } == true ? v : nil }
        let bad = bpm.map { $0 < 40 || $0 > 120 } == true
        // shifted down the rim (toward 3 o'clock) to stay clear of the watchOS system clock in the top-right corner
        chip(&g, size, deg: -31, leading: false, .heart, bpm.map { "\($0)" } ?? "--", bad ? FaceView.alert : .white, alertOn: bad)
        // bottom-left: rain chance (Open-Meteo, free, no key); amber when older than 20 min
        let stale = wxOk.map { date.timeIntervalSince($0) > 1200 } ?? false
        chip(&g, size, deg: 126, leading: true, .rain, rain.map { "\($0)%" } ?? "--", stale ? FaceView.amber : .white)
        // bottom-right: watch battery (segments, bolt while charging, red below 20%)
        let dev = WKInterfaceDevice.current()
        let b = Double(dev.batteryLevel), chg = dev.batteryState == .charging || dev.batteryState == .full
        chip(&g, size, deg: 54, leading: false, .battery(level: b, charging: chg), b < 0 ? "--" : "\(Int(b * 100))%", b >= 0 && b < 0.2 ? FaceView.alert : .white)
    }

    /// Lambert-shaded moon sphere from the LRO texture for the current elongation (soft terminator, earthshine, limb darkening).
    private func shadedMoon(_ ph: Double) -> CGImage? {
        guard let t = moonTex else { return nil }
        let n = 32, cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(t, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let px = ctx.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }
        let lx = sin(ph), lz = -cos(ph)
        for j in 0..<n { for i in 0..<n {
            let u = (Double(i) + 0.5) / Double(n) * 2 - 1, v = (Double(j) + 0.5) / Double(n) * 2 - 1, q = u * u + v * v
            if q > 1 { continue }
            let z = sqrt(1 - q), lit = min(1, max(0, (u * lx + z * lz + 0.06) / 0.16)), f = (0.16 + 0.84 * lit) * (0.62 + 0.38 * sqrt(z)), k = (j * n + i) * 4
            for ch in 0..<3 { px[k + ch] = UInt8(min(255, Double(px[k + ch]) * f)) }
        } }
        return ctx.makeImage()
    }

    private func fetchTemp(_ c: CLLocationCoordinate2D) {
        wxAt = Date()
        let u = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f&current=temperature_2m&hourly=precipitation_probability&forecast_hours=1", c.latitude, c.longitude))!
        URLSession.shared.dataTask(with: u) { data, _, _ in
            struct R: Decodable { struct C: Decodable { let temperature_2m: Double }; struct H: Decodable { let precipitation_probability: [Int?] }; let current: C; let hourly: H? }
            if let data, let r = try? JSONDecoder().decode(R.self, from: data) { DispatchQueue.main.async { temp = Int(r.current.temperature_2m.rounded()); wxOk = Date(); rain = r.hourly?.precipitation_probability.first ?? nil } }
        }.resume()
    }
}

/// Wrist motion (CoreMotion gravity, 30 Hz, low-pass filtered) for the digits' rim light and parallax.
final class Motion: ObservableObject {
    @Published var tilt: CGPoint = .zero
    private let mm = CMMotionManager()
    func start() {
        guard mm.isDeviceMotionAvailable, !mm.isDeviceMotionActive else { return }
        mm.deviceMotionUpdateInterval = 1.0 / 30
        mm.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let gr = m?.gravity else { return }
            let k = 0.12, x = max(-1, min(1, gr.x)), y = max(-1, min(1, gr.y))
            let n = CGPoint(x: self.tilt.x + (x - self.tilt.x) * k, y: self.tilt.y + (y - self.tilt.y) * k)
            if abs(n.x - self.tilt.x) + abs(n.y - self.tilt.y) > 0.002 { self.tilt = n }
        }
    }
    func stop() { mm.stopDeviceMotionUpdates() }
}

@main struct EnochWatchApp: App { var body: some Scene { WindowGroup { FaceView().ignoresSafeArea() } } }

/// Stacked HH over MM, as large as fits between the corners, in a translucent "Liquid Glass" style:
/// the map shows through the glyphs. watchOS 26+: real .glassEffect masked by the digits; earlier: .ultraThinMaterial.
/// Outline of the stacked HH/MM glyphs as a SwiftUI Shape (CoreText glyph paths), so the documented
/// `glassEffect(_:in:)` modifier can render Liquid Glass in the exact shape of the digits.
struct DigitsShape: Shape {
    let hh: String, mm: String, fs: CGFloat
    func path(in rect: CGRect) -> Path {
        // slanted sporty digits: Chakra Petch Bold Italic (OFL, bundled, UIAppFonts), placed on fixed tabular cells
        let heavy = CTFontCreateWithName("ChakraPetch-BoldItalic" as CFString, fs, nil), adv = fs * 0.68
        func line(_ s: String) -> (CGMutablePath, CGRect) {
            let out = CGMutablePath()
            for (k, ch) in s.utf16.enumerated() {
                var u = ch, gl: CGGlyph = 0; CTFontGetGlyphsForCharacters(heavy, &u, &gl, 1)
                var w = CGSize.zero; CTFontGetAdvancesForGlyphs(heavy, .horizontal, &gl, &w, 1)
                if let gp = CTFontCreatePathForGlyph(heavy, gl, nil) { out.addPath(gp, transform: CGAffineTransform(translationX: Double(k) * adv + (adv - w.width) / 2, y: 0)) }
            }
            return (out, out.boundingBoxOfPath)
        }
        let gap = fs * 0.1, (a, ba) = line(hh), (b, bb) = line(mm), total = ba.height + gap + bb.height
        var p = Path()
        // CoreText is y-up: flip each row and centre it in rect
        let ta = CGAffineTransform(translationX: rect.midX - ba.midX, y: rect.midY - total / 2 + ba.maxY).scaledBy(x: 1, y: -1)
        let tb = CGAffineTransform(translationX: rect.midX - bb.midX, y: rect.midY - total / 2 + ba.height + gap + bb.maxY).scaledBy(x: 1, y: -1)
        p.addPath(Path(a), transform: ta); p.addPath(Path(b), transform: tb)
        return p
    }
}

/// Time as Liquid Glass per Apple's docs: `glassEffect(.clear, in: shape)`; the system draws the blur,
/// lensing, adaptive tint and light-following rim itself. No extra shadows, strokes or fills.
struct GlassTime: View {
    let date: Date
    var tilt: CGPoint = .zero // low-pass filtered gravity x/y, -1...1
    var body: some View {
        GeometryReader { geo in
            let cal = Calendar.current
            let hh = String(format: "%02d", cal.component(.hour, from: date)), mm = String(format: "%02d", cal.component(.minute, from: date))
            let fs = min(geo.size.width * 0.78 / 1.2, geo.size.height * 0.36)
            let shape = DigitsShape(hh: hh, mm: mm, fs: fs)
            // Liquid Glass, clear variant: no white fill; the system lenses and refracts the map through the glyphs.
            // Thin specular rim: bright top-left, faint bottom-right.
            ZStack {
                if #available(watchOS 26.0, *) {
                    Color.clear.glassEffect(.clear, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial.opacity(0.5))
                }
                // the light source follows the wrist: tilting moves the bright edge around the glyphs
                let lx = min(1, max(0, 0.1 - Double(tilt.x) * 0.9)), ly = min(1, max(0, 0.1 + Double(tilt.y) * 0.9))
                shape.stroke(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35), .white.opacity(0.6)],
                                            startPoint: UnitPoint(x: lx, y: ly), endPoint: UnitPoint(x: 1 - lx, y: 1 - ly)), lineWidth: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // parallax: digits float a few points above the map
            .offset(x: tilt.x * 3.5, y: -tilt.y * 3.5)
        }
        .allowsHitTesting(false)
    }
}

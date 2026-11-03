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
        // deferred: @StateObject builds this during a view update, so publishing here directly would warn
        let c = coord; DispatchQueue.main.async { Borders.shared.locate(c) } }
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
    @State private var motion = Motion()
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

    // Digital Crown scrubs time (velocity based); zoom is double-tap only, spring overshoots and settles
    // always-on: any of luminance reduced, a non-live timeline cadence, or the scene not active (wrist down)
    @Environment(\.isLuminanceReduced) private var lum
    @Environment(\.scenePhase) private var phase
    @State private var lowCadence = false
    private var aod: Bool { lum || lowCadence || phase != .active }
    @State private var crown: Double = 0
    @State private var zt: Double = 1                       // zoom target
    @State private var zs = ZoomSpring()
    @State private var sc = ZoomSpring(response: 0.7, damping: 0.9)  // shown scrub offset (hours), follows `scrub`
    @State private var scrub: Double = 0                    // target scrub offset, hours; 0 = live
    @State private var fast = false
    @State private var crownAt = Date.distantPast
    @State private var detail: Comp? = nil
    @State private var detailAt = Date.distantPast
    enum Comp { case sun, bpm, rain, battery }

    private func setCadence(_ c: TimelineViewDefaultContext.Cadence) {
        let low = c != .live; if low != lowCadence { lowCadence = low; logAOD(c) } }
    private func logAOD(_ c: Any? = nil) { print("AOD flag changed: lum=\(lum) cadence=\(c.map { "\($0)" } ?? (lowCadence ? "low" : "live")) phase=\(phase) -> aod=\(aod)") }

    var body: some View {
        Group {
            if aod { TimelineView(.everyMinute) { ctx in face(ctx.date).onChange(of: ctx.cadence, initial: true) { _, c in setCadence(c) } } }
            else { TimelineView(.animation(minimumInterval: fast ? 1.0 / 60 : 1.0 / 30)) { ctx in face(ctx.date).onChange(of: ctx.cadence, initial: true) { _, c in setCadence(c) } } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .ignoresSafeArea()
        // crown attached to a concrete, framed, focused view (avoids "Crown Sequencer was set up without a view property")
        .focusable(true)
        .focused($crownFocus)
        .digitalCrownRotation($crown, from: -1000, through: 1000, by: 0.1, sensitivity: .medium,
                              isContinuous: true, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { old, v in
            let now = Date(), dt = max(0.016, now.timeIntervalSince(crownAt)); crownAt = now; fast = true
            if detail != nil { detail = nil; return }
            if aod { return }
            // acceleration curve: slow turn = minutes, fast spin = hours, very fast = days
            // bounded range (a huge range / tiny step made SwiftUI allocate ~2e9 detents and crash); ignore the wrap jump
            let dv = v - old; if !dv.isFinite || abs(dv) > 500 { return }
            let speed = abs(dv) / dt
            let hoursPerUnit = min(12, 0.17 * (1 + pow(speed, 1.6) * 0.6))
            scrub = max(-720, min(720, scrub + dv * hoursPerUnit))
        }
        .onTapGesture(count: 2) {
            detail = nil
            zt = zt < (1 + fillZoom) / 2 ? fillZoom : 1; zoom = zt; fast = true
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { p in tap(p) }
        // crown idle 2 s: spring back to now; detail card times out after 6 s; drop to 30 fps once settled
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if aod { continue }
                let now = Date()
                if scrub != 0 && now.timeIntervalSince(crownAt) > 2 { scrub = 0 }
                if detail != nil && now.timeIntervalSince(detailAt) > 6 { detail = nil }
                let f = zs.moving || sc.moving || now.timeIntervalSince(crownAt) < 0.3
                if f != fast { fast = f }
            }
        }
        .background(Color.black)
        .onAppear { zt = min(fillZoom, max(1, zoom)); zs.reset(zt); if !aod { motion.start() }; crownFocus = true; WKInterfaceDevice.current().isBatteryMonitoringEnabled = true }
        .onChange(of: lum) { logAOD() }
        .onChange(of: phase) { logAOD() }
        .onChange(of: aod) { _, v in if v { motion.stop(); hr.pause(); scrub = 0; detail = nil } else { motion.start(); hr.resume(); fetchTemp(loc.coord) } }
        // weather fetch lives outside the draw path: every 12 min, and when the location moves
        .task { while !Task.isCancelled { if !aod { fetchTemp(loc.coord) }; try? await Task.sleep(nanoseconds: 720_000_000_000) } }
        .onChange(of: loc.live) { _ in fetchTemp(loc.coord) }
        .onDisappear { motion.stop() }
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        // hides the watchOS status-bar time (SwiftUI underscored modifier, present in the public SDK interface)
        ._statusBarHidden(true)
    }

    private static func px(_ t: CGPoint, _ k: Double) -> CGSize { CGSize(width: t.x * k, height: -t.y * k) }

    /// One frame. Map, grid and day/night stay fixed; overlays float at different depths with wrist tilt
    /// (digits 11 pt, outlines 6 pt, sky 4 pt, comps and text 3 pt). AOD: no motion, no scrub.
    @ViewBuilder private func face(_ now: Date) -> some View {
        let tilt = aod ? CGPoint.zero : motion.read(now)
        let _ = zs.step(to: zt, at: now)
        let off = aod ? 0 : sc.step(to: scrub, at: now)
        let date = now.addingTimeInterval(off * 3600)
        ZStack {
            // bottom to top: map + day/night + grid, glass digits, country/city outlines, stars + sun + moon, comps and text
            // always-on: everything greyscale and flat, except the sun and moon (layer 5, full colour)
            Canvas { g, size in draw(&g, size, date, 0) }.aodGrey(aod)
            GlassTime(date: date, tilt: tilt, aod: aod).offset(Self.px(tilt, 11)).aodGrey(aod).zIndex(1)
            Canvas { g, size in draw(&g, size, date, 3) }.offset(Self.px(tilt, 6)).aodGrey(aod).zIndex(2).allowsHitTesting(false)
            Canvas { g, size in draw(&g, size, date, 1) }.offset(Self.px(tilt, 4)).aodGrey(aod).zIndex(3).allowsHitTesting(false)
            if aod { Canvas { g, size in draw(&g, size, date, 5) }.zIndex(3.5).allowsHitTesting(false) }
            Canvas { g, size in draw(&g, size, date, 2, off) }.offset(Self.px(tilt, 3)).aodGrey(aod).zIndex(4).allowsHitTesting(false)
            if let k = detail { card(k, date).zIndex(5) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func tap(_ p: CGPoint) {
        if detail != nil { detail = nil; return }
        let b = WKInterfaceDevice.current().screenBounds.size, dx = p.x - b.width / 2, dy = p.y - b.height / 2
        guard hypot(dx, dy) > (min(b.width, b.height) / 2 - 4) * 0.6 else { return }
        let a = atan2(dy, dx) * 180 / .pi
        func dist(_ x: Double) -> Double { abs((x - a + 540).truncatingRemainder(dividingBy: 360) - 180) }
        let opts: [(Double, Comp)] = [(-126, .sun), (-54, .bpm), (126, .rain), (54, .battery)]
        if let m = opts.min(by: { dist($0.0) < dist($1.0) }), dist(m.0) < 40 {
            detail = m.1; detailAt = Date(); WKInterfaceDevice.current().play(.click) }
    }

    /// Detail card: clear Liquid Glass rounded rect (no frost, no shadow), orange labels, white values.
    private func card(_ k: Comp, _ date: Date) -> some View {
        let o = FaceView.orange, mono = { (s: CGFloat) in Font.system(size: s, weight: .heavy, design: .monospaced) }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        func row(_ l: String, _ v: String) -> some View {
            HStack { Text(l).font(mono(9)).foregroundColor(o); Spacer(); Text(v).font(mono(13)).foregroundColor(.white) } }
        return VStack(alignment: .leading, spacing: 5) {
            switch k {
            case .rain:
                Text("RAIN NEXT 6H").font(mono(9)).foregroundColor(o)
                if rain6.isEmpty { Text("NO DATA").font(mono(12)).foregroundColor(.white) }
                else {
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(Array(rain6.prefix(6).enumerated()), id: \.offset) { i, p in
                            VStack(spacing: 2) {
                                Text("\(p)").font(mono(8)).foregroundColor(.white)
                                RoundedRectangle(cornerRadius: 1.5).fill(Color.white).frame(width: 12, height: 2 + 34 * Double(p) / 100)
                                Text(String(format: "%02d", (Calendar.current.component(.hour, from: Date()) + i) % 24)).font(mono(7)).foregroundColor(o)
                            }
                        }
                    }
                }
            case .battery:
                let dev = WKInterfaceDevice.current(), b = Double(dev.batteryLevel)
                let st: String = { switch dev.batteryState { case .charging: return "CHARGING"; case .full: return "FULL"; case .unplugged: return "ON BATTERY"; default: return "UNKNOWN" } }()
                Text("BATTERY").font(mono(9)).foregroundColor(o)
                Text(b < 0 ? "--" : "\(Int(b * 100))%").font(mono(24)).foregroundColor(b >= 0 && b < 0.2 ? FaceView.alert : .white)
                Text(st).font(mono(10)).foregroundColor(.white)
            case .bpm:
                Text("HEART RATE").font(mono(9)).foregroundColor(o)
                Text(hr.bpm.map { "\($0)" } ?? "--").font(mono(24)).foregroundColor(.white)
                if let lo = hr.lo, let hi = hr.hi { row("1H MIN", "\(lo)"); row("1H MAX", "\(hi)") }
            case .sun:
                if let sd = sunDay(date) {
                    let r = sd.0, s = sd.1
                    let m = Int(s.timeIntervalSince(r) / 60)
                    row("SUNRISE", tf.string(from: r)); row("SUNSET", tf.string(from: s)); row("DAY", "\(m / 60)h \(String(format: "%02d", m % 60))m")
                } else { row("SUN", "POLAR") }
            }
        }
        .padding(12).frame(width: 156)
        .background { cardBG }
        .contentShape(Rectangle())
        .onTapGesture { detail = nil }
    }
    @ViewBuilder private var cardBG: some View {
        let r = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(watchOS 26.0, *) { Color.black.opacity(0.45).clipShape(r).glassEffect(.clear, in: r) }
        else { r.fill(Color.black.opacity(0.45)).overlay(r.stroke(Color.white.opacity(0.6), lineWidth: 0.8)) }
    }

    /// Today's sunrise and sunset at your position (local solar calc from the subsolar point); nil in polar day/night.
    private func sunDay(_ date: Date) -> (Date, Date)? {
        let sky = Sky(date: date), d = Double.pi / 180, me = loc.coord
        let cc = (sin(-0.833 * d) - sin(me.latitude * d) * sin(sky.sunLat * d)) / (cos(me.latitude * d) * cos(sky.sunLat * d))
        guard abs(cc) <= 1 else { return nil }
        let h0 = acos(cc) / d / 15, dn = ((sky.sunLon - me.longitude) / 15).truncatingRemainder(dividingBy: 24)
        let dn2 = dn > 12 ? dn - 24 : (dn < -12 ? dn + 24 : dn), noon = date.addingTimeInterval(dn2 * 3600)
        return (noon.addingTimeInterval(-h0 * 3600), noon.addingTimeInterval(h0 * 3600))
    }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ date: Date, _ layer: Int, _ scrubH: Double = 0) {
        let sky = Sky(date: date), d = Double.pi / 180
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = (min(size.width, size.height) / 2 - 4) * zs.x
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
            if let sh = Self.shade(n: 64, sunLat: sky.sunLat * d, sunLon: sky.sunLon * d, nightMax: aod ? 0.93 : 0.78) {
                l.draw(Image(decorative: sh.0, scale: 1).interpolation(.high), in: disc)
                l.blendMode = .screen; l.draw(Image(decorative: sh.1, scale: 1).interpolation(.high), in: disc); l.blendMode = .normal
            }
            if !aod {
            // firmament dome from above: clear crown, pale blue sheen at the rim resting on the ice wall
            l.fill(Path(ellipseIn: disc), with: .radialGradient(Gradient(stops: [
                .init(color: Color(red: 0.75, green: 0.94, blue: 0.82).opacity(0.03), location: 0),
                .init(color: Color(red: 0.75, green: 0.94, blue: 0.82).opacity(0.07), location: 0.75),
                .init(color: Color(red: 0.78, green: 0.92, blue: 0.84).opacity(0.32), location: 1)]), center: c, startRadius: 0, endRadius: R * 1.03))
            }
        }

        // always-on: keep the active day/night shading and grid, just about 0.65x brightness (greyscale comes from .saturation(0))
        if aod { g.fill(Path(ellipseIn: disc), with: .color(.black.opacity(0.35))) }
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
        if layer == 3 {
        // current country and city outlines, drawn above the glass digits so your location reads through them
        let disc = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
        if aod { g.opacity = 0.7 }
        g.drawLayer { l in
            l.clip(to: Path(ellipseIn: disc))
            // current country (thin orange) and city (thinner orange) boundaries, projected like the map
            let orange = FaceView.orange
            func ringPath(_ rg: [[Double]]) -> Path { var p = Path()
                for (k, v) in rg.enumerated() { let rr = (90 - v[1]) / 180 * R, a = v[0] * d, pt = CGPoint(x: c.x + rr * sin(a), y: c.y + rr * cos(a)); k == 0 ? p.move(to: pt) : p.addLine(to: pt) }
                p.closeSubpath(); return p }
            if let k = borders.country { for poly in k.polys { for rg in poly { l.stroke(ringPath(rg), with: .color(orange), lineWidth: 0.9) } } }
            for rg in borders.city { l.stroke(ringPath(rg), with: .color(orange.opacity(0.9)), lineWidth: 0.5) }
        }
        }
        if layer == 1 || layer == 5 {
        let disc = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R), sl = sky.sunLat * d, so = sky.sunLon * d
        if aod { g.opacity = 0.45 }
        if layer == 1 { g.drawLayer { l in
            l.clip(to: Path(ellipseIn: disc))
            // real stars over the ground point lat = Dec, lon = RA - GST (same as sun and moon); faint by day
            for st in stars {
                let r = (90 - st[1]) / 180; if r > 1 { continue }
                let lo = (st[0] - sky.siderealDeg) * d, e = sin(st[1] * d) * sin(sl) + cos(st[1] * d) * cos(sl) * cos(lo - so)
                // flat dome sky: every star the same small white dot (about 1 pt), no colour or size variation
                let night = min(1, max(0, (0.08 - e) * 4))
                let p = CGPoint(x: c.x + r * R * sin(lo), y: c.y + r * R * cos(lo))
                l.fill(Path(ellipseIn: CGRect(x: p.x - 0.5, y: p.y - 0.5, width: 1, height: 1)), with: .color(.white.opacity(0.2 + 0.8 * night)))
            }
        } }
        // always-on: sun and moon are drawn in their own full-colour layer (5) above the greyscale layers
        if aod == (layer == 5) {
        g.opacity = 1
        // labels try right-up, left-up, right-down, left-down; keep clear of the top text band, bottom line and corner comps
        func tag(_ p: CGPoint, _ t: String, _ col: Color) {
            let rt = g.resolve(Text(t).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(col))
            let w = rt.measure(in: CGSize(width: 200, height: 20)).width, W = size.width, H = size.height
            let ko = [CGRect(x: 0, y: 0, width: W, height: 28), CGRect(x: 0, y: H - 20, width: W, height: 20),
                      CGRect(x: 0, y: 0, width: 68, height: 72), CGRect(x: W - 68, y: 0, width: 68, height: 72),
                      CGRect(x: 0, y: H - 64, width: 68, height: 64), CGRect(x: W - 68, y: H - 64, width: 68, height: 64)]
            let opts = [CGPoint(x: p.x + 9, y: p.y - 9), CGPoint(x: p.x - 9 - w, y: p.y - 9), CGPoint(x: p.x + 9, y: p.y + 9), CGPoint(x: p.x - 9 - w, y: p.y + 9)]
            var o = CGPoint(x: min(W - 4 - w, max(4, p.x + 9)), y: min(H - 26, max(34, p.y - 9)))
            for q in opts where q.x >= 2 && q.x + w <= W - 2 {
                let r = CGRect(x: q.x, y: q.y - 5, width: w, height: 10)
                if !ko.contains(where: { $0.intersects(r) }) { o = q; break } }
            g.draw(rt, at: o, anchor: .leading) }
        // sun: warm corona bloom, anamorphic streak, white-hot limb-darkened photosphere
        let amb = FaceView.orange, sp = P(sky.sunLat, sky.sunLon)
        var sg = g; sg.blendMode = .plusLighter
        sg.fill(Path(ellipseIn: CGRect(x: sp.x - 32, y: sp.y - 32, width: 64, height: 64)), with: .radialGradient(Gradient(stops: [
            .init(color: Color(red: 1, green: 0.84, blue: 0.55).opacity(0.55), location: 0), .init(color: Color(red: 1, green: 0.66, blue: 0.27).opacity(0.18), location: 0.3),
            .init(color: .clear, location: 1)]), center: sp, startRadius: 0, endRadius: 32))
        sg.fill(Path(CGRect(x: sp.x - 34, y: sp.y - 0.6, width: 68, height: 1.2)), with: .linearGradient(Gradient(colors: [.clear, Color(red: 0.86, green: 0.92, blue: 1).opacity(0.55), .clear]),
            startPoint: CGPoint(x: sp.x - 34, y: sp.y), endPoint: CGPoint(x: sp.x + 34, y: sp.y)))
        g.fill(Path(ellipseIn: CGRect(x: sp.x - 4.5, y: sp.y - 4.5, width: 9, height: 9)), with: .radialGradient(Gradient(stops: [
            .init(color: .white, location: 0), .init(color: Color(red: 1, green: 0.96, blue: 0.86), location: 0.55), .init(color: Color(red: 1, green: 0.82, blue: 0.48), location: 0.85),
            .init(color: Color(red: 0.95, green: 0.6, blue: 0.23), location: 1)]), center: sp, startRadius: 0, endRadius: 4.5))
        // no SUN/MOON tags (Levi, 2026-11-03)

        // moon: NASA LRO nearside texture, sphere-shaded terminator, earthshine and limb darkening
        let mp = P(sky.moonLat, sky.moonLon), mr = 6.0
        if let img = shadedMoon(sky.phase) {
            g.draw(Image(decorative: img, scale: 1), in: CGRect(x: mp.x - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)) }
        _ = amb
        }
        }
        if layer == 2 {
        let amb = FaceView.orange
        if aod { g.opacity = 0.6 }

        // you: position (no marker; borders and top line show it), LOC and HOME distance / bearing (great circle)
        let la = loc.coord.latitude, lo = loc.coord.longitude

        // top: live place name, then local date; bottom: coordinates
        let dfm = DateFormatter(); dfm.locale = Locale(identifier: "en_US_POSIX"); dfm.dateFormat = "EEE dd MMM yyyy"
        g.draw(g.resolve(Text(loc.place ?? "SANTANDREI, ROMANIA").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundColor(.white)), at: CGPoint(x: c.x, y: 11), anchor: .center)
        let dl = g.resolve(Text(dfm.string(from: date).uppercased()).font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(amb))
        g.draw(dl, at: CGPoint(x: c.x, y: 21), anchor: .center) // resolved text has no width limit: always one line
        g.draw(Text(String(format: "%.3f%@ / %07.3f%@%@", abs(la), la >= 0 ? "N" : "S", abs(lo), lo >= 0 ? "E" : "W", loc.live ? "" : " FALLBACK")).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: c.x, y: size.height - 12))

        // time scrub indicator under the date: orange sign, white offset
        if abs(scrubH) * 60 >= 1 {
            let m = Int((abs(scrubH) * 60).rounded()), dd = m / 1440, hh = (m % 1440) / 60, mi = m % 60
            let body = dd > 0 ? "\(dd)d \(hh)h" : hh > 0 ? "\(hh)h \(String(format: "%02d", mi))m" : "\(mi)m"
            let f = Font.system(size: 7, weight: .bold, design: .monospaced)
            g.draw(g.resolve(Text(scrubH > 0 ? "+" : "-").font(f).foregroundColor(amb) + Text(body).font(f).foregroundColor(.white)), at: CGPoint(x: c.x, y: 30), anchor: .center)
        }
        corners(&g, size, date, sky)
        if !aod { for y in stride(from: 0.0, to: size.height, by: 3) { g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.03))) } }

        }
    }

    /// Night (black, alpha 0.9*(1-t)) and day (grey 0.32 screen, alpha t) shading maps over the disc's bounding square.
    /// Day/night shading cache: rebuilt only when the sun moves about 0.25 deg (once a minute or so; always-on reuses it).
    private static var shadeCache: (key: String, img: (CGImage, CGImage))?
    private static func shade(n: Int, sunLat sl: Double, sunLon so: Double, nightMax: Double) -> (CGImage, CGImage)? {
        guard sl.isFinite, so.isFinite, n > 0, n <= 256 else { return nil }
        let key = "\(nightMax):\(n):\(Int((sl * 229.18).rounded())):\(Int((so * 229.18).rounded()))"
        if let c = shadeCache, c.key == key { return c.img }
        let r = shadeBuild(n: n, sunLat: sl, sunLon: so, nightMax: nightMax); if let r { shadeCache = (key, r) }; return r
    }
    private static func shadeBuild(n: Int, sunLat sl: Double, sunLon so: Double, nightMax: Double) -> (CGImage, CGImage)? {
        let d = Double.pi / 180
        var night = [UInt8](repeating: 0, count: n * n * 4), day = [UInt8](repeating: 0, count: n * n * 4)
        for j in 0..<n { for i in 0..<n {
            let dx = (Double(i) + 0.5) / Double(n) * 2 - 1, dy = (Double(j) + 0.5) / Double(n) * 2 - 1, r = hypot(dx, dy)
            let la = (90 - min(r, 1) * 180) * d, lo = atan2(dx, dy)
            let e = sin(la) * sin(sl) + cos(la) * cos(sl) * cos(lo - so)
            var t = min(1, max(0, (e + 0.309) / 0.517)); t = t * t * (3 - 2 * t)
            let k = (j * n + i) * 4
            // night: deep navy (8, 14, 32), premultiplied; active 0.78 (lands faintly visible), always-on 0.93
            let na = 255 * nightMax * (1 - t)
            night[k] = UInt8(na * 8 / 255); night[k + 1] = UInt8(na * 14 / 255); night[k + 2] = UInt8(na * 32 / 255); night[k + 3] = UInt8(na)
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
    @State private var rain6: [Int] = []
    @State private var wxAt = Date.distantPast
    @State private var wxOk: Date? = nil
    private let home = CLLocationCoordinate2D(latitude: 47.0682, longitude: 21.8548)

    private static let mint = Color(red: 0.75, green: 0.96, blue: 0.82), amber = FaceView.orange, alert = Color(red: 1, green: 0.29, blue: 0.24)
    /// the one UI orange (#FF8C1A) used by every orange element: borders, labels, date, tags
    static let orange = Color(red: 1, green: 140.0 / 255, blue: 26.0 / 255)
    /// Text laid along a circle of radius r around the screen centre, centred on angle `deg` (0 = right, 90 = down),
    /// always reading left to right and upright (top half: glyph tops point outward; bottom half: inward).
    private func arcText(_ g: inout GraphicsContext, _ size: CGSize, _ s: String, _ font: Font, _ col: Color, deg: Double, r: Double, track: Double = 0) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2), top = sin(deg * .pi / 180) < 0, dir = top ? 1.0 : -1.0
        let glyphs = s.map { g.resolve(Text(String($0)).font(font).foregroundColor(col)) }
        let gw = glyphs.map { $0.measure(in: CGSize(width: 40, height: 40)).width + track }
        var pos = deg * .pi / 180 - dir * gw.reduce(0, +) / r / 2
        for (k, t) in glyphs.enumerated() {
            let a = pos + dir * gw[k] / 2 / r; var l = g
            l.translateBy(x: c.x + r * cos(a), y: c.y + r * sin(a)); l.rotate(by: .radians(a + dir * .pi / 2))
            l.draw(t, at: .zero, anchor: .center); pos += dir * gw[k] / r }
    }
    /// Curved complication: small orange label stacked over a bigger white value, both following the rim (no icon, no frame).
    /// Value colour carries the alert state.
    private func chip(_ g: inout GraphicsContext, _ size: CGSize, deg: Double, _ label: String, _ val: String, _ vcol: Color) {
        let R0 = min(size.width, size.height) / 2 - 4, top = sin(deg * .pi / 180) < 0
        // "on top" = outward on the upper rim, inward on the lower rim (glyphs are upright on both)
        let rl = top ? R0 + 16 : R0 + 1, rv = top ? R0 + 4 : R0 + 12
        arcText(&g, size, label, .system(size: 7.5, weight: .heavy, design: .monospaced), FaceView.orange, deg: deg, r: rl, track: 0.6)
        arcText(&g, size, val, .system(size: 14, weight: .heavy, design: .monospaced), vcol, deg: deg, r: rv)
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
        chip(&g, size, deg: -126, up ? "SUNRISE" : "SUNSET", sunTxt, .white)
        // top-right: live heart rate (HealthKit); red only when abnormal (<40 or >120 BPM)
        let bpm = hr.bpm.flatMap { v in hr.at.map { date.timeIntervalSince($0) < 900 } == true ? v : nil }
        let bad = bpm.map { $0 < 40 || $0 > 120 } == true
        // mirrored with the sunrise comp (the status-bar clock is hidden, so both top comps sit at the same height)
        chip(&g, size, deg: -54, "BPM", bpm.map { "\($0)" } ?? "--", bad ? FaceView.alert : .white)
        // bottom-left: rain chance (Open-Meteo, free, no key); amber when older than 20 min
        let stale = wxOk.map { date.timeIntervalSince($0) > 1200 } ?? false
        chip(&g, size, deg: 126, "RAIN", rain.map { "\($0)%" } ?? "--", stale ? FaceView.amber : .white)
        // bottom-right: watch battery (red below 20%)
        let dev = WKInterfaceDevice.current()
        let b = Double(dev.batteryLevel)
        chip(&g, size, deg: 54, "BATTERY", b < 0 ? "--" : "\(Int(b * 100))%", b >= 0 && b < 0.2 ? FaceView.alert : .white)
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
        let u = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f&current=temperature_2m&hourly=precipitation_probability&forecast_hours=6", c.latitude, c.longitude))!
        URLSession.shared.dataTask(with: u) { data, _, _ in
            struct R: Decodable { struct C: Decodable { let temperature_2m: Double }; struct H: Decodable { let precipitation_probability: [Int?] }; let current: C; let hourly: H? }
            if let data, let r = try? JSONDecoder().decode(R.self, from: data) { DispatchQueue.main.async { temp = Int(r.current.temperature_2m.rounded()); wxOk = Date(); let h = (r.hourly?.precipitation_probability ?? []).map { $0 ?? 0 }; rain6 = h; rain = h.first } }
        }.resume()
    }
}

/// Wrist motion for the digits' moving light and parallax. Plain reference model (not @Published): the TimelineView
/// reads it every frame, so no SwiftUI state is written from the sensor callback or the draw path.
/// deviceMotion gravity when available, raw accelerometer otherwise; low-pass filtered.
final class Motion {
    private var raw: CGPoint = .zero, sp: CGPoint = .zero, v: CGPoint = .zero, last: Date? = nil
    private let mm = CMMotionManager()
    private(set) var source = "none"
    func start() {
        #if targetEnvironment(simulator)
        source = "simulator"; return
        #else
        // 60 Hz sensor; light pre-filter here, critically damped spring per frame in read()
        let feed: (Double, Double) -> Void = { [weak self] x, y in
            guard let self else { return }
            let x = max(-1, min(1, x)), y = max(-1, min(1, y)), k = 0.35
            self.raw = CGPoint(x: self.raw.x + (x - self.raw.x) * k, y: self.raw.y + (y - self.raw.y) * k) }
        if mm.isDeviceMotionAvailable {
            guard !mm.isDeviceMotionActive else { return }
            source = "deviceMotion"; mm.deviceMotionUpdateInterval = 1.0 / 60
            mm.startDeviceMotionUpdates(to: .main) { m, _ in if let gr = m?.gravity { feed(gr.x, gr.y) } }
        } else if mm.isAccelerometerAvailable {
            guard !mm.isAccelerometerActive else { return }
            source = "accelerometer"; mm.accelerometerUpdateInterval = 1.0 / 60
            mm.startAccelerometerUpdates(to: .main) { a, _ in if let a = a?.acceleration { feed(a.x, a.y) } }
        }
        print("EnochWatch motion source:", source)
        #endif
    }
    private func target(_ date: Date) -> CGPoint {
        #if targetEnvironment(simulator)
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-fakeTilt"), i + 1 < a.count {
            let v = a[i + 1].split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { return CGPoint(x: v[0], y: v[1]) } }
        let t = date.timeIntervalSinceReferenceDate
        return CGPoint(x: 0.6 * sin(t * 0.9), y: 0.5 * cos(t * 0.7))
        #else
        return raw
        #endif
    }
    /// Smoothed tilt, -1...1: critically damped spring (response 0.4 s) toward the sensor value, no jitter.
    /// Simulator: "-fakeTilt x,y" pins it, otherwise a slow sine so the effect is visible.
    func read(_ date: Date) -> CGPoint {
        let t = target(date)
        var dt = last.map { date.timeIntervalSince($0) } ?? 1; last = date; dt = min(max(dt, 0), 0.25)
        if dt >= 0.25 { sp = t; v = .zero; return sp }
        let w = 2 * Double.pi / 0.4, n = max(1, Int(ceil(dt / (1.0 / 240)))), h = dt / Double(n)
        for _ in 0..<n {
            v.x += (-w * w * (sp.x - t.x) - 2 * w * v.x) * h; v.y += (-w * w * (sp.y - t.y) - 2 * w * v.y) * h
            sp.x += v.x * h; sp.y += v.y * h }
        return sp
    }
    func stop() { mm.stopDeviceMotionUpdates(); mm.stopAccelerometerUpdates() }
}

/// Critically-tuned spring (response 0.35 s, damping 0.65: a small visible overshoot), integrated per frame.
final class ZoomSpring {
    private(set) var x: Double = 1
    private var v: Double = 0, t: Double = 1, last: Date? = nil
    private let resp: Double, damp: Double
    init(response: Double = 0.35, damping: Double = 0.65) { resp = response; damp = damping; x = 1 }
    var moving: Bool { abs(v) > 0.002 || abs(x - t) > 0.001 }
    func reset(_ z: Double) { x = z; t = z; v = 0; last = nil }
    @discardableResult func step(to target: Double, at now: Date) -> Double {
        t = target
        var dt = last.map { now.timeIntervalSince($0) } ?? 0; last = now
        dt = min(max(dt, 0), 0.1)
        let w = 2 * Double.pi / resp, z = damp, n = max(1, Int(ceil(dt / (1.0 / 240))))
        let h = dt / Double(n)
        for _ in 0..<n { v += (-w * w * (x - t) - 2 * z * w * v) * h; x += v * h }
        if !moving { x = t; v = 0 }
        return x
    }
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
    var tilt: CGPoint = .zero // smoothed gravity x/y, -1...1
    var aod = false
    var body: some View {
        GeometryReader { geo in
            let cal = Calendar.current
            let hh = String(format: "%02d", cal.component(.hour, from: date)), mm = String(format: "%02d", cal.component(.minute, from: date))
            let fs = min(geo.size.width * 0.78 / 1.2, geo.size.height * 0.36)
            let shape = DigitsShape(hh: hh, mm: mm, fs: fs)
            // Liquid Glass, clear variant: no white fill; the system lenses and refracts the map through the glyphs.
            // Thin specular rim: bright top-left, faint bottom-right.
            if aod {
                // always-on: thin dim outline only, no glass, no light
                shape.stroke(Color.white.opacity(0.55), lineWidth: 1).frame(width: geo.size.width, height: geo.size.height)
            } else {
            ZStack {
                if #available(watchOS 26.0, *) {
                    Color.clear.glassEffect(.clear, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial.opacity(0.5))
                }
                // light follows the wrist. Drawn on top of the glass, because the system glass rim does not react to custom light:
                // a bright rim stroke whose hot spot rotates around the glyphs with tilt, and a soft specular sheen sweeping across.
                let ang = atan2(Double(tilt.y) + 0.35, -Double(tilt.x) - 0.35), mag = min(1, 0.45 + hypot(tilt.x, tilt.y))
                let hot = UnitPoint(x: 0.5 + 0.5 * cos(ang), y: 0.5 - 0.5 * sin(ang)), cold = UnitPoint(x: 1 - hot.x, y: 1 - hot.y)
                shape.stroke(LinearGradient(colors: [.white.opacity(0.95 * mag + 0.05), .white.opacity(0.18), .white.opacity(0.45)],
                                            startPoint: hot, endPoint: cold), lineWidth: 1.4)
                let sweep = 0.5 + Double(tilt.x) * 0.55 - Double(tilt.y) * 0.25
                shape.fill(LinearGradient(stops: [.init(color: .clear, location: max(0, sweep - 0.22)),
                                                  .init(color: .white.opacity(0.32), location: min(1, max(0, sweep))),
                                                  .init(color: .clear, location: min(1, sweep + 0.22))],
                                          startPoint: UnitPoint(x: 0, y: 0.15), endPoint: UnitPoint(x: 1, y: 0.85)))
                    .blendMode(.plusLighter)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            } // parallax offset is applied by FaceView (depth layers)
        }
        .allowsHitTesting(false)
    }
}


/// Always-on only: greyscale. In active mode the view is returned untouched (no saturation pass at all),
/// so the wrist-up face is exactly the full-colour render.
extension View {
    @ViewBuilder func aodGrey(_ on: Bool) -> some View { if on { self.saturation(0) } else { self } }
}

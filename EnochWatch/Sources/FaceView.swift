import CoreText
import SwiftUI
import CoreLocation
import WatchKit
import CoreMotion

/// Position from the watch's own GPS (satellites) only: no wifi, cellular or internet lookups.
/// City label comes from the bundled GeoNames list (cities.tsv, CC BY 4.0), country from countries.json, so both work offline and mid-flight.
/// Updates run only while the face is active (wrist up); always-on stops them (battery rule).
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coord = CLLocationCoordinate2D(latitude: 47.0682, longitude: 21.8548) // fallback: Santandrei, Bihor, Romania (home)
    @Published var live = false
    @Published var place: String? = nil
    /// compass heading, degrees clockwise from true north (magnetic when there is no fix yet); nil until the first reading
    @Published var heading: Double? = nil
    /// heading accuracy in degrees; negative = invalid, the compass needs calibration
    @Published var headingAcc: Double = 0   // 0 until the first reading, so no CAL before the compass reports
    private var placeAt: CLLocation? = nil
    private let m = CLLocationManager()
    private var wanted = false
    /// battery: a satellite fix is kept 10 min; GPS turns off as soon as one arrives and only restarts on a wrist raise after that
    private var fixAt = Date.distantPast
    private static let fixLife: TimeInterval = 600
    private let noPrompt = ProcessInfo.processInfo.arguments.contains("-noLocPrompt")
    /// a fix this precise and this fresh can only come from satellites, not cell or wifi positioning
    private static let maxError: CLLocationAccuracy = 100, maxAge: TimeInterval = 120
    override init() { super.init(); m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest // turns the GPS receiver on
        m.distanceFilter = 50
        m.activityType = .other
        m.headingFilter = 1
        if !noPrompt { m.requestWhenInUseAuthorization() }
        // deferred: @StateObject builds this during a view update, so publishing here directly would warn
        let c = coord; DispatchQueue.main.async { Borders.shared.locate(c) } }
    private var authorized: Bool { let s = m.authorizationStatus; return s == .authorizedWhenInUse || s == .authorizedAlways }
    /// wrist up / app active: restart so a stale or suspended session gets a fresh satellite fix
    func wake() { wanted = true
        if CLLocationManager.headingAvailable() { m.startUpdatingHeading() } // compass runs only with the wrist up
        guard authorized, !noPrompt, Date().timeIntervalSince(fixAt) > Locator.fixLife else { return }
        m.stopUpdatingLocation(); m.startUpdatingLocation() }
    /// always-on / inactive: GPS off
    func sleep() { wanted = false; m.stopUpdatingLocation(); m.stopUpdatingHeading() }
    /// wrist shake: restart the compass so it re-reads the magnetometer right away (the system does the calibration itself;
    /// the shake's motion helps it). Keeps the last heading on screen until the fresh one arrives.
    func resync() { guard wanted, CLLocationManager.headingAvailable() else { return }; m.stopUpdatingHeading(); m.startUpdatingHeading() }
    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        if abs(h.headingAccuracy - headingAcc) >= 1 || (h.headingAccuracy < 0) != (headingAcc < 0) { headingAcc = h.headingAccuracy }
        guard h.headingAccuracy >= 0 else { return } // negative = invalid (needs calibration)
        heading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { if wanted { wake() } }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let L = l.last(where: { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= Locator.maxError && -$0.timestamp.timeIntervalSinceNow < Locator.maxAge }) else { return }
        coord = L.coordinate; live = true
        fixAt = Date(); m.stopUpdatingLocation() // got a good fix: GPS off until the next wrist raise after 10 min
        // country borders: point-in-polygon on every fix (bundled Natural Earth 1:110m, public domain)
        Borders.shared.locate(L.coordinate)
        // offline city name, recomputed after moving more than 2 km
        if placeAt.map({ L.distance(from: $0) > 2000 }) ?? true {
            placeAt = L
            let city = Cities.shared.nearest(L.coordinate)
            place = [city?.uppercased(), Borders.shared.country?.name.uppercased()].compactMap { $0 }.joined(separator: ", ")
            // city outline is decoration: fetched only when there is internet, retried on the next city change if it fails
            if let city { Borders.shared.fetchCity(city, L.coordinate) }
        } }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        // locationUnknown is temporary (no satellites yet, e.g. inside a plane): updates keep running and retry on their own
        if (e as? CLError)?.code == .denied { m.stopUpdatingLocation() }
    }
}

/// Nearest populated place from the bundled GeoNames cities5000 list (name, lat, lon per line). Fully offline.
final class Cities {
    static let shared = Cities()
    private let names: [String]; private let lat: [Double]; private let lon: [Double]
    private init() {
        var n: [String] = [], a: [Double] = [], o: [Double] = []
        if let u = Bundle.main.url(forResource: "cities", withExtension: "tsv"), let t = try? String(contentsOf: u, encoding: .utf8) {
            n.reserveCapacity(70_001); a.reserveCapacity(70_001); o.reserveCapacity(70_001)
            for line in t.split(separator: "\n") { let f = line.split(separator: "\t")
                if f.count == 3, let y = Double(f[1]), let x = Double(f[2]) { n.append(String(f[0])); a.append(y); o.append(x) } }
        }
        names = n; lat = a; lon = o
    }
    func nearest(_ c: CLLocationCoordinate2D) -> String? {
        let k = cos(c.latitude * .pi / 180); var best = -1, bd = Double.infinity
        for i in 0..<names.count { let dy = lat[i] - c.latitude; var dx = abs(lon[i] - c.longitude); if dx > 180 { dx = 360 - dx }; dx *= k
            let d = dy * dy + dx * dx; if d < bd { bd = d; best = i } }
        // farther than about 50 km (open sea, mid-ocean flight): no city name, the country alone shows
        return best >= 0 && bd < 0.2 ? names[best] : nil
    }
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
        guard name != cityName else { return }; city = []
        var u = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        u.queryItems = [.init(name: "format", value: "jsonv2"), .init(name: "lat", value: String(c.latitude)), .init(name: "lon", value: String(c.longitude)),
                        .init(name: "zoom", value: "10"), .init(name: "polygon_geojson", value: "1"), .init(name: "polygon_threshold", value: "0.002")]
        var rq = URLRequest(url: u.url!); rq.setValue("EnochWatch/1.0 (github.com/rebelvue/enoch-watch-face)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: rq) { d, _, _ in
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let g = j["geojson"] as? [String: Any], let t = g["type"] as? String else { return }
            var rings: [Ring] = []
            if t == "Polygon", let p = g["coordinates"] as? [Ring] { rings = p }
            if t == "MultiPolygon", let mp = g["coordinates"] as? [[Ring]] { rings = mp.flatMap { $0 } }
            DispatchQueue.main.async { self.city = rings; self.cityName = name } // only a successful fetch marks the city done
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
    /// system always-on: luminance reduced, low timeline cadence, or the scene not active
    private var sysAOD: Bool { lum || lowCadence || phase != .active }
    /// wrist turned away / arm down (gravity), detected while the screen is still awake: switch to the always-on look right away
    /// instead of waiting for watchOS. Motion keeps running only until the system itself enters always-on.
    @State private var away = false
    @State private var awayDet = AwayDetector()
    private var aod: Bool { sysAOD || away }
    @State private var crown: Double = 0
    @State private var zt: Double = 1                       // zoom target
    @State private var zs = ZoomSpring()
    @State private var sc = ZoomSpring(response: 0.7, damping: 0.9)  // shown scrub offset (hours), follows `scrub`
    @State private var rs = ZoomSpring(response: 0.45, damping: 1)   // shown compass rotation (deg, unwrapped)
    @State private var rot = CompassTarget()
    @State private var scrub: Double = 0                    // target scrub offset, hours; 0 = live
    @State private var fast = false
    @State private var crownAt = Date.distantPast
    @State private var detail: Comp? = nil
    @State private var detailAt = Date.distantPast
    enum Comp { case sun, bpm, rain, battery }
    // smooth cross-fade between the active and always-on looks (0.5 s); distantPast = no fade running
    @State private var fadeAt = Date.distantPast
    // north frame: orange border, full when facing north, fading out with the angle; flash when locking on (under 4 deg)
    @State private var northOn = false
    @State private var northAt = Date.distantPast
    @State private var northOffAt = Date.distantPast
    @State private var northFrom = 0.0
    // dead on north: the frame thickens and fades in (0.35 s), then thins and fades out (0.45 s) when you drift off
    @State private var deadOn = false
    @State private var deadAt = Date.distantPast
    @State private var deadFrom = 0.0
    // compass marks: smoothed screen angle of real north on the rim
    @State private var ns = ZoomSpring(response: 0.45, damping: 1)
    @State private var nrot = CompassTarget()
    // red night mode: on while the sun is more than 4 degrees below the horizon where you are
    @State private var red = false
    // calibration hint: only when the compass is really off. Heading invalid, or worse than 45 deg, for 5 s straight;
    // hidden again once it is better than 30 deg for 2 s. Ordinary 10-30 deg wobble never shows it.
    @State private var calShow = false
    // sun lock: flash when you lock onto the real sun (under 5 deg, released over 8 deg)
    @State private var sunOn = false
    @State private var sunAt = Date.distantPast
    @State private var calSince: Date? = nil
    // wrist shake: quick compass resync instead of the early always-on look
    @State private var shakeSeen = Date.distantPast
    @State private var syncAt = Date.distantPast

    private func setCadence(_ c: TimelineViewDefaultContext.Cadence) {
        let low = c != .live; if low != lowCadence { lowCadence = low; logAOD(c) } }
    private func logAOD(_ c: Any? = nil) { print("AOD flag changed: lum=\(lum) cadence=\(c.map { "\($0)" } ?? (lowCadence ? "low" : "live")) phase=\(phase) away=\(away) -> aod=\(aod)") }

    var body: some View {
        Group {
            if aod && fadeAt == .distantPast { TimelineView(.everyMinute) { ctx in face(ctx.date, true).onChange(of: ctx.cadence, initial: true) { _, c in setCadence(c) } } }
            else { TimelineView(.animation(minimumInterval: fast ? 1.0 / 60 : 1.0 / 24)) { ctx in blend(ctx.date).onChange(of: ctx.cadence, initial: true) { _, c in setCadence(c) } } }
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
        .onTapGesture(count: 2) { toggleZoom() }
        .onTapGesture(count: 1, coordinateSpace: .local) { p in tap(p) }
        // crown idle 2 s: spring back to now; detail card times out after 6 s; drop to 30 fps once settled
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let now = Date()
                if !sysAOD {
                    if motion.shakeAt > shakeSeen {   // new shake: resync the compass, show SYNC, cancel any early dim
                        shakeSeen = motion.shakeAt; syncAt = now; loc.resync(); calSince = nil
                        awayDet.reset(); if away { away = false }
                    }
                    if motion.shaking(now) { awayDet.reset() }
                    else { let a = awayDet.update(motion.gz, now); if a != away { away = a } }
                }
                if fadeAt != .distantPast && now.timeIntervalSince(fadeAt) > 0.55 { fadeAt = .distantPast }
                let alt = sunAlt(now), r = red ? alt < -3 : alt < -4   // 1 degree of hysteresis
                if r != red { red = r }
                if aod { if northOn { northOn = false; northOffAt = .distantPast }; if deadOn { deadOn = false; deadFrom = 0; deadAt = .distantPast }; continue }
                let ca = loc.headingAcc, flip = calShow ? (ca >= 0 && ca < 30) : (ca < 0 || ca > 45)
                if flip { if calSince == nil { calSince = now } else if now.timeIntervalSince(calSince!) >= (calShow ? 2 : 5) { calShow.toggle(); calSince = nil } }
                else { calSince = nil }
                if let sd = sunDev(now) { let on = sunOn ? sd < 8 : sd < 5; if on != sunOn { if on { sunAt = now }; sunOn = on } }
                else if sunOn { sunOn = false }
                if let h = loc.heading {
                    let dv = min(Self.m360(h), 360 - Self.m360(h)), on = northOn ? dv < 7 : dv < 4
                    if on != northOn { if on { northAt = now } else { northFrom = northLevel(now).0; northOffAt = now }; northOn = on }
                    let d = deadOn ? dv < 3 : dv < 1.5
                    if d != deadOn { deadFrom = deadLevel(now); deadAt = now; deadOn = d }
                } else if deadOn { deadFrom = deadLevel(now); deadAt = now; deadOn = false }
                if scrub != 0 && now.timeIntervalSince(crownAt) > 2 { scrub = 0 }
                if detail != nil && now.timeIntervalSince(detailAt) > 6 { detail = nil }
                let f = zs.moving || sc.moving || rs.moving || now.timeIntervalSince(crownAt) < 0.3
                if f != fast { fast = f }
            }
        }
        .redNight(red)
        .background {
            // Series 9/10 and Ultra 2 double tap (index finger + thumb): same zoom as tapping the screen twice
            if #available(watchOS 11.0, *) {
                Button("Zoom") { toggleZoom() }.buttonStyle(.plain).foregroundStyle(.clear).handGestureShortcut(.primaryAction)
            }
        }
        .background(Color.black)
        .onAppear { zt = min(fillZoom, max(1, zoom)); zs.reset(zt); if !aod { motion.start(); loc.wake() }; crownFocus = true; WKInterfaceDevice.current().isBatteryMonitoringEnabled = true }
        .onChange(of: lum) { logAOD() }
        .onChange(of: phase) { logAOD() }
        .onChange(of: aod) { _, v in logAOD(); fadeAt = sysAOD ? .distantPast : Date(); if v { hr.pause(); loc.sleep(); scrub = 0; detail = nil } else { hr.resume(); loc.wake() } }
        // battery rule: no motion once watchOS is in always-on; back on wrist raise (which also clears the early-dim flag)
        .onChange(of: sysAOD) { _, v in if v { motion.stop() } else { away = false; awayDet.reset(); motion.start(); fetchTemp(loc.coord) } }
        // weather fetch lives outside the draw path: every 12 min, and when the location moves
        .task { while !Task.isCancelled { if !aod { fetchTemp(loc.coord) }; try? await Task.sleep(nanoseconds: 720_000_000_000) } }
        .onChange(of: loc.live) { _ in fetchTemp(loc.coord) }
        .onDisappear { motion.stop(); loc.sleep() }
        .toolbar(.hidden, for: .navigationBar)
        // hides the watchOS status-bar time (SwiftUI underscored modifier, present in the public SDK interface)
        ._statusBarHidden(true)
    }

    static let scr = WKInterfaceDevice.current().screenBounds.size

    private func toggleZoom() {
        detail = nil
        zt = zt < (1 + fillZoom) / 2 ? fillZoom : 1; zoom = zt; fast = true
    }

    /// Sun altitude (deg) at your position, live time.
    private func sunAlt(_ now: Date) -> Double {
        let d = Double.pi / 180, sky = Sky(date: now), la = loc.coord.latitude * d, dec = sky.sunLat * d
        let ha = (loc.coord.longitude - sky.sunLon) * d
        return asin(sin(la) * sin(dec) + cos(la) * cos(dec) * cos(ha)) / d
    }

    /// Compass readout (active look, fixed to the screen): the heading in degrees above the coordinates, and a pulsing CAL tag
    /// only when the compass is really off (see calShow).
    private func compassMarks(_ g: inout GraphicsContext, _ size: CGSize, _ now: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2), o = FaceView.orange
        let mono = { (s: CGFloat) in Font.system(size: s, weight: .heavy, design: .monospaced) }
        if let h = loc.heading {
            let hd = Int(Self.m360(h).rounded()) % 360, card = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((Double(hd) + 22.5) / 45) % 8]
            g.draw(g.resolve(Text("\(card) ").font(mono(9)).foregroundColor(o) + Text("\(hd)\u{00B0}").font(mono(9)).foregroundColor(.white)),
                   at: CGPoint(x: c.x, y: size.height - 24), anchor: .center)
        }
        let st = now.timeIntervalSince(syncAt)
        if st < 1.2 {
            let p = st < 0.15 ? st / 0.15 : max(0, 1 - (st - 0.6) / 0.6)
            g.draw(g.resolve(Text("SYNC").font(mono(8)).foregroundColor(.white.opacity(min(1, p)))), at: CGPoint(x: c.x, y: size.height - 34), anchor: .center)
        } else if calShow {
            let p = 0.55 + 0.45 * sin(now.timeIntervalSince1970 * 4)
            g.draw(g.resolve(Text("CAL \u{221E}").font(mono(8)).foregroundColor(o.opacity(p))), at: CGPoint(x: c.x, y: size.height - 34), anchor: .center)
        }
    }
    static func m360(_ x: Double) -> Double { let y = fmod(x, 360); return y < 0 ? y + 360 : y }

    /// Degrees between where the watch points and the real sun; nil without a heading, with the sun down, or while scrubbing.
    private func sunDev(_ now: Date) -> Double? {
        guard let h = loc.heading, scrub == 0, sunAlt(now) > -0.833 else { return nil }
        let d = Double.pi / 180, sky = Sky(date: now), p1 = loc.coord.latitude * d, p2 = sky.sunLat * d, dl = (sky.sunLon - loc.coord.longitude) * d
        let az = atan2(sin(dl) * cos(p2), cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)) / d
        let x = Self.m360(h - az); return min(x, 360 - x)
    }

    /// Sun lock level: (opacity, flash). Full within 3 deg of the real sun, fading out by 25 deg; flash on locking on.
    private func sunLevel(_ now: Date) -> (Double, Double) {
        guard let dv = sunDev(now) else { return (0, 0) }
        let x = max(0, min(1, 1 - (dv - 3) / 22)), base = x * x * (3 - 2 * x)
        var f = 0.0
        if sunOn { let t = now.timeIntervalSince(sunAt); f = t < 0.12 ? t / 0.12 : max(0, 1 - (t - 0.12) / 0.8) }
        return (base, f)
    }

    /// Sun lock (active look): when you face the real sun, a warm line runs from your position to the sun on the fixed map
    /// and the sun flares, the same way the north frame lights up when you face north.
    private func sunLock(_ g: inout GraphicsContext, _ size: CGSize, _ now: Date) {
        let (al, f) = sunLevel(now); if al <= 0.001 { return }
        let d = Double.pi / 180, sky = Sky(date: now), c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = (min(Self.scr.width, Self.scr.height) / 2 - 4) * zs.x
        func P(_ lat: Double, _ lon: Double) -> CGPoint { let r = (90 - lat) / 180 * R; return CGPoint(x: c.x + r * sin(lon * d), y: c.y + r * cos(lon * d)) }
        let u = P(loc.coord.latitude, loc.coord.longitude), sp = P(sky.sunLat, sky.sunLon)
        let o = FaceView.orange, gold = Color(red: 1, green: 0.84, blue: 0.55)
        var line = Path(); line.move(to: u); line.addLine(to: sp)
        var gl = g; gl.blendMode = .plusLighter
        gl.drawLayer { l in
            l.addFilter(.blur(radius: 3 + 3 * f))
            l.stroke(line, with: .linearGradient(Gradient(colors: [o.opacity(0.25 * al), o.opacity(0.7 * al)]), startPoint: u, endPoint: sp), lineWidth: 5 + 4 * f)
        }
        gl.stroke(line, with: .linearGradient(Gradient(colors: [o.opacity(0.55 * al), gold.opacity(al)]), startPoint: u, endPoint: sp),
                  style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        let fr = 22 + 26 * f
        gl.fill(Path(ellipseIn: CGRect(x: sp.x - fr, y: sp.y - fr, width: 2 * fr, height: 2 * fr)), with: .radialGradient(Gradient(stops: [
            .init(color: .white.opacity(0.7 * al), location: 0), .init(color: gold.opacity(0.45 * al), location: 0.25),
            .init(color: o.opacity(0.18 * al), location: 0.6), .init(color: .clear, location: 1)]), center: sp, startRadius: 0, endRadius: fr))
        gl.fill(Path(ellipseIn: CGRect(x: u.x - 2, y: u.y - 2, width: 4, height: 4)), with: .color(o.opacity(al)))
    }

    /// 0 = active look, 1 = always-on look; eased over 0.5 s after every switch (no fade when watchOS itself dims)
    private func mix(_ now: Date) -> Double {
        let t = fadeAt == .distantPast ? 1 : min(1, max(0, now.timeIntervalSince(fadeAt) / 0.5)), e = t * t * (3 - 2 * t)
        return aod ? e : 1 - e
    }

    /// Animated frame: the active face, the always-on face, or both cross-fading; north frame on top (active only).
    @ViewBuilder private func blend(_ now: Date) -> some View {
        let m = mix(now)
        ZStack {
            if m < 1 { face(now, false).opacity(1 - m) }
            if m > 0 { face(now, true).opacity(m) }
            if m < 1 { Canvas { g, size in northFrame(&g, size, now) }.opacity(1 - m).allowsHitTesting(false).zIndex(10) }
        }
    }

    /// North frame level: (opacity 0...1, flash 0...1). Full orange when facing true north (within 2 deg), fading smoothly to
    /// nothing at 45 deg away. Locking on (within 4 deg) adds a short flash that settles over 0.7 s.
    private func northLevel(_ now: Date) -> (Double, Double) {
        guard let h = loc.heading else { return (0, 0) }
        let dv = min(Self.m360(h), 360 - Self.m360(h)), x = max(0, min(1, 1 - (dv - 2) / 43)), base = x * x * (3 - 2 * x)
        var f = 0.0
        if northOn { let t = now.timeIntervalSince(northAt); f = t < 0.12 ? t / 0.12 : max(0, 1 - (t - 0.12) / 0.7) }
        return (min(1, base), f)
    }

    /// Dead-on-north thickness 0...1, animated in time: thicken + fade in over 0.35 s on lock (under 1.5 deg),
    /// thin + fade out over 0.45 s on release (over 3 deg), each starting from wherever the last one stopped.
    private func deadLevel(_ now: Date) -> Double {
        let t = now.timeIntervalSince(deadAt), x = max(0, min(1, t / (deadOn ? 0.35 : 0.45))), e = x * x * (3 - 2 * x)
        return deadOn ? deadFrom + (1 - deadFrom) * e : deadFrom * (1 - e)
    }

    /// Orange frame around the screen while facing north (the centre of the map): flash in, fade out.
    private func northFrame(_ g: inout GraphicsContext, _ size: CGSize, _ now: Date) {
        let (al, f) = northLevel(now); if al <= 0.001 { return }
        let lk = deadLevel(now)
        let o = FaceView.orange, cr = min(size.width, size.height) * 0.21
        let r = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5), cornerRadius: cr, style: .continuous)
        g.drawLayer { l in
            l.addFilter(.blur(radius: 5 + 5 * f))
            l.stroke(r, with: .color(o.opacity((0.45 + 0.45 * f + 0.15 * lk) * al)), lineWidth: 8 + 10 * f + 6 * lk)
        }
        g.stroke(r, with: .color(o.opacity(al)), lineWidth: 2.5 + 1.5 * f)
        if lk > 0.001 { g.stroke(r, with: .color(o.opacity(al * lk)), lineWidth: 2.5 + 1.5 * f + 4.5 * lk) }
        if f > 0 { g.stroke(r, with: .color(.white.opacity(0.5 * f * al)), lineWidth: 1) }
    }

    /// Full-hour flash: for the first 4 s of every hour, a soft orange glow blooms under the digits with one expanding ring.
    /// Live time (not the crown-scrubbed one). Active look only.
    private func hourGlow(_ g: inout GraphicsContext, _ size: CGSize, _ now: Date) {
        let k = Calendar.current.dateComponents([.minute, .second, .nanosecond], from: now)
        let t = Double((k.minute ?? 0) * 60 + (k.second ?? 0)) + Double(k.nanosecond ?? 0) / 1e9
        if t >= 4 { return }
        let up = min(1, t / 0.35), env = up * up * (3 - 2 * up) * pow(max(0, (4 - t) / 3.65), 2)
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = min(Self.scr.width, Self.scr.height) / 2 - 4, o = FaceView.orange
        g.fill(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)), with: .radialGradient(Gradient(stops: [
            .init(color: o.opacity(0.6 * env), location: 0), .init(color: o.opacity(0.28 * env), location: 0.45), .init(color: .clear, location: 1)]),
            center: c, startRadius: 0, endRadius: R * 0.75))
        if t < 1.6 {
            let p = t / 1.6, rr = R * (0.2 + 0.8 * (1 - (1 - p) * (1 - p)))
            g.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(o.opacity(0.8 * (1 - p))), lineWidth: 2)
        }
    }

    /// Radar sweep as the seconds hand: one turn a minute from 12 o'clock, fixed to the screen (does not turn with the compass),
    /// live time (not crown-scrubbed), with a fading trail behind the beam. Not drawn in always-on.
    private func sweep(_ g: inout GraphicsContext, _ size: CGSize, _ now: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = (min(Self.scr.width, Self.scr.height) / 2 - 4) * zs.x
        let sec = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        let a = (sec * 6 - 90) * Double.pi / 180            // screen angle, 0 = 3 o'clock, clockwise
        let acc = FaceView.orange, trail = 50.0 / 360
        let disc = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        g.drawLayer { l in
            l.clip(to: disc)
            // trail: conic gradient starting at the beam, so the part just behind it (counter-clockwise) is the brightest
            l.fill(disc, with: .conicGradient(Gradient(stops: [
                .init(color: .clear, location: 0), .init(color: .clear, location: 1 - trail),
                .init(color: acc.opacity(0.28), location: 1)]), center: c, angle: .radians(a)))
            var beam = Path(); beam.move(to: c); beam.addLine(to: CGPoint(x: c.x + R * cos(a), y: c.y + R * sin(a)))
            l.stroke(beam, with: .color(acc.opacity(0.35)), lineWidth: 3)   // soft glow
            l.stroke(beam, with: .color(acc), lineWidth: 1)
        }
    }

    private static func px(_ t: CGPoint, _ k: Double) -> CGSize { CGSize(width: t.x * k, height: -t.y * k) }

    /// One frame. Map, grid, day/night shading, stars, sun and moon stay fixed; only digits, outlines and text float with wrist tilt
    /// (digits 11 pt, outlines 6 pt, sky 4 pt, comps and text 3 pt). AOD: no motion, no scrub.
    @ViewBuilder private func face(_ now: Date, _ a: Bool) -> some View {
        let tilt = a ? CGPoint.zero : motion.read(now)
        let _ = zs.step(to: zt, at: now)
        let off = a ? 0 : sc.step(to: scrub, at: now)
        let date = now.addingTimeInterval(off * 3600)
        // compass: the whole disc (map, shading, outlines, sky) turns so the way you face points up; digits and text stay put
        // map stays fixed (Levi, 2026-11-05): direction comes from the north frame, the sun lock and the heading readout
        let spin = 0.0
        ZStack {
            // bottom to top: map + day/night + grid, glass digits, country/city outlines, stars + sun + moon, comps and text
            // always-on: everything greyscale and flat, except the sun and moon (layer 5, full colour)
            Canvas { g, size in draw(&g, size, date, 0, 0, a) }.spun(spin).aodGrey(a)
            if !a { Canvas { g, size in sweep(&g, size, now) }.zIndex(0.5).allowsHitTesting(false) }
            if !a { Canvas { g, size in hourGlow(&g, size, now) }.zIndex(0.7).allowsHitTesting(false) }
            if !a { Canvas { g, size in compassMarks(&g, size, now) }.zIndex(4.2).allowsHitTesting(false) }
            if !a { Canvas { g, size in sunLock(&g, size, now) }.zIndex(3.2).allowsHitTesting(false) }
            GlassTime(date: date, tilt: tilt, aod: a).offset(Self.px(tilt, 11)).aodGrey(a).zIndex(1)
            Canvas { g, size in draw(&g, size, date, 3, 0, a) }.spun(spin).offset(Self.px(tilt, 6)).aodGrey(a).zIndex(2).allowsHitTesting(false)
            Canvas { g, size in draw(&g, size, date, 1, 0, a) }.spun(spin).aodGrey(a).zIndex(3).allowsHitTesting(false)
            if a { Canvas { g, size in draw(&g, size, date, 5, 0, a) }.spun(spin).zIndex(3.5).allowsHitTesting(false) }
            Canvas { g, size in draw(&g, size, date, 2, off, a) }.offset(Self.px(tilt, 3)).aodGrey(a).zIndex(4).allowsHitTesting(false)
            if let k = detail { card(k, date).zIndex(5) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// Screen rotation (deg, clockwise) for the compass. On the Enoch map, "north" from you is the line to the centre, but the
    /// map bends directions, so the line from you to the sun is not the sun's real compass bearing. Two anchors keep both true:
    /// facing north puts the centre straight ahead, facing the real sun puts the sun's map point straight ahead;
    /// headings in between are spread evenly between those two map directions. Uses the live sun, not the crown-scrubbed one.
    private func compassAngle(_ now: Date) -> Double? {
        guard let h = loc.heading else { return nil }
        let d = Double.pi / 180, sky = Sky(date: now), la = loc.coord.latitude, lo = loc.coord.longitude
        func pt(_ lat: Double, _ lon: Double) -> (Double, Double) { let r = (90 - lat) / 180; return (r * sin(lon * d), r * cos(lon * d)) }
        func brg(_ x: Double, _ y: Double) -> Double { atan2(x, -y) / d }                // screen bearing, clockwise from up
        func m360(_ x: Double) -> Double { let y = fmod(x, 360); return y < 0 ? y + 360 : y }
        let u = pt(la, lo), s = pt(sky.sunLat, sky.sunLon)
        let dl = (sky.sunLon - lo) * d, p1 = la * d, p2 = sky.sunLat * d
        let sunAz = atan2(sin(dl) * cos(p2), cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)) / d  // real bearing to the sun
        let haveSun = hypot(s.0 - u.0, s.1 - u.1) > 1e-4, haveN = hypot(u.0, u.1) > 1e-4
        let sB = brg(s.0 - u.0, s.1 - u.1), nB = brg(-u.0, -u.1)
        var f: Double
        if !haveSun { f = nB + h }
        else {
            let a = m360(sunAz), b = m360(sB - nB), hh = m360(h)
            if !haveN || a < 1 || a > 359 || b < 1 || b > 359 { f = sB + (h - sunAz) }
            else if hh <= a { f = nB + hh * b / a }
            else { f = nB + b + (hh - a) * (360 - b) / (360 - a) }
        }
        return -f
    }

    private func tap(_ p: CGPoint) {
        if detail != nil { detail = nil; return }
        let b = WKInterfaceDevice.current().screenBounds.size, dx = p.x - b.width / 2, dy = p.y - b.height / 2
        // hit-test only the comps' actual rendered curved text bands (+6 pt), never quadrants or empty space
        let r = hypot(dx, dy), a = atan2(dy, dx) * 180 / .pi
        func dist(_ x: Double) -> Double { abs((x - a + 540).truncatingRemainder(dividingBy: 360) - 180) * .pi / 180 }
        let opts: [(Double, Comp)] = [(-126, .sun), (-54, .bpm), (126, .rain), (54, .battery)]
        for (deg, c) in opts { guard let h = CompHits.bands[deg] else { continue }
            if r >= h.0 && r <= h.1 && dist(deg) <= h.2 { detail = c; detailAt = Date(); WKInterfaceDevice.current().play(.click); return } }
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

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ date: Date, _ layer: Int, _ scrubH: Double = 0, _ ao: Bool = false) {
        let sky = Sky(date: date), d = Double.pi / 180
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = (min(Self.scr.width, Self.scr.height) / 2 - 4) * zs.x // radius from the screen, not the canvas (rotating canvases are larger)
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
            if let sh = Self.shade(n: 64, sunLat: sky.sunLat * d, sunLon: sky.sunLon * d, nightMax: ao ? 0.93 : 0.80) {
                l.draw(Image(decorative: sh.0, scale: 1).interpolation(.high), in: disc)
                l.blendMode = .screen; l.draw(Image(decorative: sh.1, scale: 1).interpolation(.high), in: disc); l.blendMode = .normal
            }
            if !ao {
            // firmament dome from above: clear crown, pale blue sheen at the rim resting on the ice wall
            l.fill(Path(ellipseIn: disc), with: .radialGradient(Gradient(stops: [
                .init(color: Color(red: 0.75, green: 0.94, blue: 0.82).opacity(0.03), location: 0),
                .init(color: Color(red: 0.75, green: 0.94, blue: 0.82).opacity(0.07), location: 0.75),
                .init(color: Color(red: 0.78, green: 0.92, blue: 0.84).opacity(0.32), location: 1)]), center: c, startRadius: 0, endRadius: R * 1.03))
            }
        }

        // always-on: keep the active day/night shading and grid, just about 0.65x brightness (greyscale comes from .saturation(0))
        if ao { g.fill(Path(ellipseIn: disc), with: .color(.black.opacity(0.35))) }
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
        if ao { g.opacity = 0.7 }
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
        if ao { g.opacity = 0.45 }
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
        if ao == (layer == 5) {
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
        // sun the same size as the moon (radius 6; flat-earth sun and moon look equal), glow and streak scaled to match
        sg.fill(Path(ellipseIn: CGRect(x: sp.x - 40, y: sp.y - 40, width: 80, height: 80)), with: .radialGradient(Gradient(stops: [
            .init(color: Color(red: 1, green: 0.84, blue: 0.55).opacity(0.55), location: 0), .init(color: Color(red: 1, green: 0.66, blue: 0.27).opacity(0.18), location: 0.3),
            .init(color: .clear, location: 1)]), center: sp, startRadius: 0, endRadius: 40))
        // anamorphic streak is a lens effect: counter-rotate it so it stays level on screen while the disc turns with the compass
        var fl = sg; fl.translateBy(x: sp.x, y: sp.y)
        fl.fill(Path(CGRect(x: -44, y: -0.7, width: 88, height: 1.4)), with: .linearGradient(Gradient(colors: [.clear, Color(red: 0.86, green: 0.92, blue: 1).opacity(0.55), .clear]),
            startPoint: CGPoint(x: -44, y: 0), endPoint: CGPoint(x: 44, y: 0)))
        g.fill(Path(ellipseIn: CGRect(x: sp.x - 6, y: sp.y - 6, width: 12, height: 12)), with: .radialGradient(Gradient(stops: [
            .init(color: .white, location: 0), .init(color: Color(red: 1, green: 0.96, blue: 0.86), location: 0.55), .init(color: Color(red: 1, green: 0.82, blue: 0.48), location: 0.85),
            .init(color: Color(red: 0.95, green: 0.6, blue: 0.23), location: 1)]), center: sp, startRadius: 0, endRadius: 6))
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
        if ao { g.opacity = 0.6 }

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
        if !ao { for y in stride(from: 0.0, to: size.height, by: 3) { g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.03))) } }

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
            // night: deep navy (8, 14, 32), premultiplied; active 0.80 (lands visible but still night, Levi 2026-11-05), always-on 0.93
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
    @State private var wxCoord: CLLocationCoordinate2D? = nil
    private let home = CLLocationCoordinate2D(latitude: 47.0682, longitude: 21.8548)

    private static let mint = Color(red: 0.75, green: 0.96, blue: 0.82), amber = FaceView.orange, alert = Color(red: 1, green: 0.29, blue: 0.24)
    /// the one UI orange (#FF8C1A) used by every orange element: borders, labels, date, tags
    static let orange = Color(red: 1, green: 140.0 / 255, blue: 26.0 / 255)
    /// Text laid along a circle of radius r around the screen centre, centred on angle `deg` (0 = right, 90 = down),
    /// always reading left to right and upright (top half: glyph tops point outward; bottom half: inward).
    @discardableResult private func arcText(_ g: inout GraphicsContext, _ size: CGSize, _ s: String, _ font: Font, _ col: Color, deg: Double, r: Double, track: Double = 0) -> Double {
        let c = CGPoint(x: size.width / 2, y: size.height / 2), top = sin(deg * .pi / 180) < 0, dir = top ? 1.0 : -1.0
        let glyphs = s.map { g.resolve(Text(String($0)).font(font).foregroundColor(col)) }
        let gw = glyphs.map { $0.measure(in: CGSize(width: 40, height: 40)).width + track }
        var pos = deg * .pi / 180 - dir * gw.reduce(0, +) / r / 2
        for (k, t) in glyphs.enumerated() {
            let a = pos + dir * gw[k] / 2 / r; var l = g
            l.translateBy(x: c.x + r * cos(a), y: c.y + r * sin(a)); l.rotate(by: .radians(a + dir * .pi / 2))
            l.draw(t, at: .zero, anchor: .center); pos += dir * gw[k] / r }
        return gw.reduce(0, +) / r // angular width (radians), used for tap hit-testing
    }
    /// Curved complication: small orange label stacked over a bigger white value, both following the rim (no icon, no frame).
    /// Value colour carries the alert state.
    private func chip(_ g: inout GraphicsContext, _ size: CGSize, deg: Double, _ label: String, _ val: String, _ vcol: Color) {
        let R0 = min(size.width, size.height) / 2 - 4, top = sin(deg * .pi / 180) < 0
        // "on top" = outward on the upper rim, inward on the lower rim (glyphs are upright on both)
        let rl = top ? R0 + 16 : R0 + 1, rv = top ? R0 + 4 : R0 + 12
        let wl = arcText(&g, size, label, .system(size: 7.5, weight: .heavy, design: .monospaced), FaceView.orange, deg: deg, r: rl, track: 0.6)
        let wv = arcText(&g, size, val, .system(size: 14, weight: .heavy, design: .monospaced), vcol, deg: deg, r: rv)
        // record the rendered curved band (label + value) with ~6 pt padding; taps outside every band do nothing
        let pad = 6.0, rIn = min(rl - 4.5, rv - 8.5) - pad, rOut = max(rl + 4.5, rv + 8.5) + pad
        CompHits.bands[deg] = (rIn, rOut, max(wl, wv) / 2 + pad / ((rIn + rOut) / 2))
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
        // battery/data: no refetch on every wrist raise; only when the last good one is 10+ min old or you moved 5+ km
        let moved = wxCoord.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) > 5000 } ?? true
        if !moved, let ok = wxOk, Date().timeIntervalSince(ok) < 600 { return }
        wxAt = Date(); wxCoord = c
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
    /// gravity along the screen normal, smoothed: about -1 face up toward you, 0 on edge (arm hanging), +1 face down
    private(set) var gz: Double = -1
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
            source = "deviceMotion"; mm.deviceMotionUpdateInterval = 1.0 / 30 // battery: 30 Hz is plenty for tilt, wrist-away and shake
            mm.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
                guard let m else { return }
                feed(m.gravity.x, m.gravity.y); self?.feedZ(m.gravity.z)
                let u = m.userAcceleration; self?.feedShake(sqrt(u.x * u.x + u.y * u.y + u.z * u.z)) }
        } else if mm.isAccelerometerAvailable {
            guard !mm.isAccelerometerActive else { return }
            source = "accelerometer"; mm.accelerometerUpdateInterval = 1.0 / 30
            mm.startAccelerometerUpdates(to: .main) { [weak self] a, _ in if let a = a?.acceleration { feed(a.x, a.y); self?.feedZ(a.z) } }
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
    private func feedZ(_ z: Double) { gz += (max(-1, min(1, z)) - gz) * 0.25 }
    /// shake = 3 strong jolts (over 1.4 g of wrist acceleration, at least 0.08 s apart) within 1 s
    private(set) var shakeAt = Date.distantPast
    private var peaks: [Date] = [], above = false
    private func feedShake(_ a: Double) {
        let now = Date()
        if a > 1.4 && !above { above = true
            if peaks.last.map({ now.timeIntervalSince($0) > 0.08 }) ?? true { peaks.append(now) }
            peaks.removeAll { now.timeIntervalSince($0) > 1 }
            if peaks.count >= 3 { shakeAt = now; peaks.removeAll() }
        } else if a < 0.8 { above = false }
        // keep the wrist-away check quiet while still shaking
        if now.timeIntervalSince(shakeAt) < 1.5 && a > 0.8 { quietTo = now.addingTimeInterval(1.2) }
    }
    private var quietTo = Date.distantPast
    /// shaking now or in the last moment (1.5 s after the shake, extended while the wrist keeps jolting)
    func shaking(_ now: Date) -> Bool { now.timeIntervalSince(shakeAt) < 1.5 || now < quietTo }
    func stop() { mm.stopDeviceMotionUpdates(); mm.stopAccelerometerUpdates(); gz = -1; peaks.removeAll(); above = false; quietTo = .distantPast }
}

/// Critically-tuned spring (response 0.35 s, damping 0.65: a small visible overshoot), integrated per frame.
extension View {
    /// Compass layers draw on a square as wide as the screen diagonal, so the zoomed-in disc still covers every corner
    /// after rotation (a screen-sized canvas clipped the disc to a rectangle, which showed as cut corners when turned).
    /// The outer frame keeps the layout screen-sized; nothing clips, so the overflow is simply off-screen.
    func spun(_ deg: Double) -> some View {
        let s = FaceView.scr, d = ceil(hypot(s.width, s.height)) + 4
        return self.frame(width: d, height: d).rotationEffect(.degrees(deg)).frame(width: s.width, height: s.height)
    }
}

/// Early always-on: "away" once the screen tilts more than about 70 degrees from facing you (wrist turned, arm by your side)
/// for 0.4 s; back once it faces you again (under about 55 degrees) for 0.15 s. The gap between the two stops flicker.
final class AwayDetector {
    private var away = false, since: Date? = nil
    func reset() { away = false; since = nil }
    func update(_ gz: Double, _ now: Date) -> Bool {
        let flip = away ? gz < -0.57 : gz > -0.34
        if flip { if since == nil { since = now }; if now.timeIntervalSince(since!) >= (away ? 0.15 : 0.4) { away.toggle(); since = nil } }
        else { since = nil }
        return away
    }
}

/// Keeps the compass target continuous (no spin the long way round when the angle wraps 359 -> 0).
final class CompassTarget {
    private(set) var last: Double = 0
    private var started = false
    func unwrap(_ a: Double) -> Double {
        if !started { started = true; last = a; return a }
        var dd = fmod(a - last + 180, 360); if dd < 0 { dd += 360 }
        last += dd - 180; return last
    }
}

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
    /// Red night mode: brightness kept as luminance, re-coloured to a dim red (no blue or green light).
    /// Off = view untouched (no extra render pass over the Liquid Glass digits).
    @ViewBuilder func redNight(_ on: Bool) -> some View {
        if on { self.saturation(0).colorMultiply(Color(red: 0.82, green: 0.07, blue: 0.03)) } else { self }
    }
    @ViewBuilder func aodGrey(_ on: Bool) -> some View { if on { self.saturation(0) } else { self } }
}

/// Rendered comp text bands keyed by rim angle: (inner radius, outer radius, half angular width in radians). Written while drawing.
enum CompHits { static var bands: [Double: (Double, Double, Double)] = [:] }

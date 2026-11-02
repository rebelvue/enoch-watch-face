import CoreText
import SwiftUI
import CoreLocation
import WatchKit

final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coord = CLLocationCoordinate2D(latitude: 47.0682, longitude: 21.8548) // fallback: Santandrei, Bihor, Romania (home)
    @Published var live = false
    @Published var place: String? = nil
    private var placeAt: CLLocation? = nil
    private let geo = CLGeocoder()
    private let m = CLLocationManager()
    override init() { super.init(); m.delegate = self; m.desiredAccuracy = kCLLocationAccuracyKilometer
        m.distanceFilter = 500; m.requestWhenInUseAuthorization(); m.startUpdatingLocation() }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { if let L = l.last { coord = L.coordinate; live = true
            // reverse-geocode (CLGeocoder) only after moving more than 5 km
            if placeAt.map({ L.distance(from: $0) > 5000 }) ?? true, !geo.isGeocoding {
                placeAt = L; geo.reverseGeocodeLocation(L) { [weak self] pm, _ in
                    if let n = pm?.first.flatMap({ $0.locality ?? $0.administrativeArea ?? $0.country }) { DispatchQueue.main.async { self?.place = n.uppercased() } } } } } }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}

struct FaceView: View {
    @StateObject private var loc = Locator()
    @StateObject private var hr = HeartRate()
    // map zoom: 1 = whole disc, fillZoom = disc covers the whole screen (radius = half the diagonal)
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
                Canvas { g, size in draw(&g, size, ctx.date) }
                GlassTime(date: ctx.date).zIndex(1)   // top layer: digits over map, sun, moon, tags, diamond, sweep, grid, stars
            }
        }
        .ignoresSafeArea()
        .focusable()
        .digitalCrownRotation($zoom, from: 1, through: fillZoom, by: 0.02, sensitivity: .low,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: zoom) { z in
            if z <= 1.0001 || z >= fillZoom - 0.0001 { WKInterfaceDevice.current().play(.click) } // detent at both ends
        }
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.3)) { zoom = zoom < (1 + fillZoom) / 2 ? fillZoom : 1 }
        }
        .background(Color.black)
    }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ date: Date) {
        let sky = Sky(date: date), d = Double.pi / 180
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = (min(size.width, size.height) / 2 - 4) * min(fillZoom, max(1, zoom))
        // World of Enoch projection: r = (90 - lat)/180 * R, lon 0 pointing down, east to the right
        func P(_ lat: Double, _ lon: Double) -> CGPoint {
            let r = (90 - lat) / 180 * R; return CGPoint(x: c.x + r * sin(lon * d), y: c.y + r * cos(lon * d)) }
        func dot(_ p: CGPoint, _ r: Double, _ col: Color) { g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(col)) }

        // beyond the ice wall: pure black (OLED)
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black))
        // map
        let disc = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
        g.drawLayer { l in
            l.clip(to: Path(ellipseIn: disc))
            // tactical grading: desaturated olive / slate, geography kept readable
            var m = l; m.addFilter(.saturation(0.35)); m.addFilter(.brightness(0.08)); m.addFilter(.contrast(1.12)); m.draw(Image("disc"), in: disc)
            l.blendMode = .multiply; l.fill(Path(ellipseIn: disc), with: .color(Color(red: 0.6, green: 0.65, blue: 0.54))); l.blendMode = .normal
            // night side: solar elevation on the globe, sampled on a coarse grid
            let n = 40, cell = 2 * R / Double(n), sl = sky.sunLat * d, so = sky.sunLon * d
            for j in 0..<n { for i in 0..<n {
                let dx = (Double(i) + 0.5) / Double(n) * 2 - 1, dy = (Double(j) + 0.5) / Double(n) * 2 - 1, r = hypot(dx, dy)
                if r > 1.03 { continue }
                let la = (90 - min(r, 1) * 180) * d, lo = atan2(dx, dy)
                let e = sin(la) * sin(sl) + cos(la) * cos(sl) * cos(lo - so)
                // sun's spotlight: lit within ~90 deg of the subsolar point, soft terminator (smoothstep)
                var t = min(1, max(0, (e + 0.05) / 0.1)); t = t * t * (3 - 2 * t)
                let cellR = Path(CGRect(x: disc.minX + Double(i) * cell, y: disc.minY + Double(j) * cell, width: cell + 0.5, height: cell + 0.5))
                if t < 1 { l.blendMode = .normal; l.fill(cellR, with: .color(Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.78 * (1 - t)))) } // night: ~20-25% brightness, cool slate
                if t > 0 { l.blendMode = .screen; l.fill(cellR, with: .color(Color(red: 0.6, green: 0.45, blue: 0.14).opacity(0.85 * t))); l.blendMode = .normal } // day: full brightness, warm golden
            } }
            // terminator (sun elevation 0): great circle 90 deg from the subsolar point, thin amber dashed contour
            var term = Path()
            for q in stride(from: 0.0, through: 360.0, by: 3.0) {
                let b = q * d, la2 = asin(cos(sl) * cos(b)), lo2 = so + atan2(sin(b) * cos(sl), -sin(sl) * sin(la2)), rr = (90 - la2 / d) / 180 * R
                let pt = CGPoint(x: c.x + rr * sin(lo2), y: c.y + rr * cos(lo2)); q == 0 ? term.move(to: pt) : term.addLine(to: pt) }
            l.stroke(term, with: .color(Color(red: 1, green: 0.69, blue: 0.23).opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            // real stars over the ground point lat = Dec, lon = RA - GST (same as sun and moon); faint by day
            for st in stars {
                let r = (90 - st[1]) / 180; if r > 1 { continue }
                let lo = (st[0] - sky.siderealDeg) * d, e = sin(st[1] * d) * sin(sl) + cos(st[1] * d) * cos(sl) * cos(lo - so)
                let night = min(1, max(0, (0.08 - e) * 4)), rad = max(0.4, 1.8 - st[2] * 0.32)
                let p = CGPoint(x: c.x + r * R * sin(lo), y: c.y + r * R * cos(lo))
                let col = st[3] < 0 ? Color(red: 0.81, green: 0.88, blue: 1) : st[3] < 1.2 ? Color(red: 1, green: 0.96, blue: 0.88) : Color(red: 1, green: 0.79, blue: 0.63)
                l.fill(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: 2 * rad, height: 2 * rad)), with: .color(col.opacity(min(1, (0.15 + 0.85 * night) * (1.15 - st[2] * 0.18)))))
            }
            // firmament dome from above: clear crown, pale blue sheen at the rim resting on the ice wall
            l.fill(Path(ellipseIn: disc), with: .radialGradient(Gradient(stops: [
                .init(color: Color(red: 0.55, green: 0.75, blue: 1).opacity(0.05), location: 0),
                .init(color: Color(red: 0.63, green: 0.78, blue: 1).opacity(0.12), location: 0.75),
                .init(color: Color(red: 0.8, green: 0.9, blue: 1).opacity(0.5), location: 1)]), center: c, startRadius: 0, endRadius: R))
        }

        // tactical overlay: range rings, radials, rim ticks, radar sweep
        let acc = Color(red: 0.75, green: 0.96, blue: 0.82)
        g.drawLayer { l in
            l.clip(to: Path(ellipseIn: disc))
            for la in [60.0, 30, 0, -30, -60] { let r = (90 - la) / 180 * R
                l.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(acc.opacity(0.22)), lineWidth: 0.6) }
            for k in 0..<12 { let a = Double(k) * 30 * d; var p = Path(); p.move(to: c); p.addLine(to: CGPoint(x: c.x + R * sin(a), y: c.y + R * cos(a)))
                l.stroke(p, with: .color(acc.opacity(0.22)), lineWidth: 0.6) }
            let sw = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 2 * .pi
            for k in 0..<24 { let a = sw - Double(k) * 0.025; var p = Path(); p.move(to: c); p.addLine(to: CGPoint(x: c.x + R * sin(a), y: c.y - R * cos(a)))
                l.stroke(p, with: .color(acc.opacity(0.45 * (1 - Double(k) / 24))), lineWidth: 1.5) }
        }
        g.stroke(Path(ellipseIn: disc), with: .color(Color(red: 0.75, green: 0.86, blue: 1).opacity(0.9)), lineWidth: 1.2)
        for k in 0..<36 { let a = Double(k) * 10 * d, len = k % 3 == 0 ? 6.0 : 3.0; var p = Path()
            p.move(to: CGPoint(x: c.x + (R - len) * sin(a), y: c.y + (R - len) * cos(a))); p.addLine(to: CGPoint(x: c.x + R * sin(a), y: c.y + R * cos(a)))
            g.stroke(p, with: .color(acc), lineWidth: k % 3 == 0 ? 1 : 0.6) }

        // stacked time is drawn by GlassTime (SwiftUI overlay) so it can use Liquid Glass / material

        func tag(_ p: CGPoint, _ t: String, _ col: Color) {
            g.draw(Text(t).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(col), at: CGPoint(x: p.x + 10, y: p.y - 10), anchor: .leading) }
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

        // you: waypoint diamond, LOC and HOME distance / bearing (great circle)
        let me = P(loc.coord.latitude, loc.coord.longitude), la = loc.coord.latitude, lo = loc.coord.longitude
        var dm = Path(); dm.move(to: CGPoint(x: me.x, y: me.y - 7)); dm.addLine(to: CGPoint(x: me.x + 7, y: me.y)); dm.addLine(to: CGPoint(x: me.x, y: me.y + 7)); dm.addLine(to: CGPoint(x: me.x - 7, y: me.y)); dm.closeSubpath()
        g.fill(dm, with: .color(amb.opacity(0.18))); g.stroke(dm, with: .color(amb), lineWidth: 1.3); dot(me, 1.8, .white)
        // position marker: diamond only, no labels

        // top: live place name, then local date; bottom: coordinates
        let dfm = DateFormatter(); dfm.locale = Locale(identifier: "en_US_POSIX"); dfm.dateFormat = "EEE dd MMM yyyy"
        g.draw(Text(loc.place ?? "SANTANDREI").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: c.x, y: 10))
        g.draw(Text(dfm.string(from: date).uppercased()).font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(amb), at: CGPoint(x: c.x, y: 20))
        g.draw(Text(String(format: "%.3f%@ / %07.3f%@%@", abs(la), la >= 0 ? "N" : "S", abs(lo), lo >= 0 ? "E" : "W", loc.live ? "" : " FALLBACK")).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: c.x, y: size.height - 12))

        corners(&g, size, date, sky)
        for y in stride(from: 0.0, to: size.height, by: 3) { g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.06))) }

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
    private func drawIcon(_ g: inout GraphicsContext, _ icon: Icon, _ o: CGPoint, alertOn: Bool = false) {
        let m = FaceView.mint, a = FaceView.amber
        switch icon {
        case .sun(let up):
            var s = Path(); s.addArc(center: CGPoint(x: o.x + 8, y: o.y + 12), radius: 4.5, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false); s.closeSubpath()
            g.fill(s, with: .color(a))
            for k in 0..<5 { let t = Double.pi * (1 + Double(k) / 4); g.stroke(poly(o, [(8 + 6.5 * cos(t), 12 + 6.5 * sin(t)), (8 + 8.5 * cos(t), 12 + 8.5 * sin(t))], close: false), with: .color(a), lineWidth: 1.2) }
            g.stroke(poly(o, [(0, 12.5), (16, 12.5)], close: false), with: .color(m), lineWidth: 1.4)
            g.stroke(poly(o, up ? [(5, 3), (8, 0), (11, 3)] : [(5, 0), (8, 3), (11, 0)], close: false), with: .color(m), lineWidth: 1.4)
        case .heart:
            let c = alertOn ? FaceView.alert : m
            g.stroke(poly(o, [(8, 15), (1, 8), (1, 4), (4, 1), (8, 4), (12, 1), (15, 4), (15, 8)]), with: .color(c), lineWidth: 1.4)
            g.stroke(poly(o, [(2, 8.5), (5.5, 8.5), (7, 5), (9, 12), (10.5, 8.5), (14, 8.5)], close: false), with: .color(alertOn ? c : a), lineWidth: 1.3)
        case .rain:
            g.stroke(poly(o, [(8, 0), (13.5, 8), (13.5, 11), (11, 15), (5, 15), (2.5, 11), (2.5, 8)]), with: .color(m), lineWidth: 1.4)
            g.stroke(poly(o, [(5.5, 10), (6, 12.5), (8, 13)], close: false), with: .color(a), lineWidth: 1.2)
        case .battery(let lv, let chg):
            let c = lv >= 0 && lv < 0.2 ? FaceView.alert : m
            g.stroke(poly(o, [(0, 3), (14, 3), (14, 13), (0, 13)]), with: .color(c), lineWidth: 1.3)
            g.fill(Path(CGRect(x: o.x + 14.5, y: o.y + 6, width: 1.8, height: 4)), with: .color(c))
            let n = lv < 0 ? 0 : Int((lv * 4).rounded(.up))
            for k in 0..<n { g.fill(Path(CGRect(x: o.x + 2 + Double(k) * 3, y: o.y + 5, width: 2.2, height: 6)), with: .color(c)) }
            if chg { g.fill(poly(o, [(8.5, 0), (4, 9), (7.5, 9), (6, 16), (11, 6.5), (7.5, 6.5)]), with: .color(a)) }
        }
    }
    /// Icon + value chip inside angled brackets; icon on the outer side, value only (no text label).
    private func chip(_ g: inout GraphicsContext, _ p: CGPoint, leading: Bool, _ icon: Icon, _ val: String, _ vcol: Color, alertOn: Bool = false) {
        let t = g.resolve(Text(val).font(.system(size: 15, weight: .heavy, design: .monospaced)).foregroundColor(vcol))
        let tw = t.measure(in: CGSize(width: 200, height: 40)).width, w = 16 + 5 + tw + 10, h = 26.0
        let x0 = leading ? p.x - 5 : p.x - w + 5, y0 = p.y - h / 2
        let ix = leading ? x0 + 5 : x0 + w - 21
        drawIcon(&g, icon, CGPoint(x: ix, y: p.y - 8), alertOn: alertOn)
        g.draw(t, at: CGPoint(x: leading ? ix + 21 : ix - 5, y: p.y), anchor: leading ? .leading : .trailing)
        var b = Path(); let k = 5.0
        for (x, y, sx, sy) in [(x0, y0, 1.0, 1.0), (x0 + w, y0, -1, 1), (x0, y0 + h, 1, -1), (x0 + w, y0 + h, -1, -1)] {
            b.move(to: CGPoint(x: x + sx * (k + 3), y: y)); b.addLine(to: CGPoint(x: x + sx * 3, y: y)); b.addLine(to: CGPoint(x: x, y: y + sy * 3)); b.addLine(to: CGPoint(x: x, y: y + sy * (k + 1))) }
        g.stroke(b, with: .color(.white.opacity(0.75)), lineWidth: 0.8)
    }

    private func corners(_ g: inout GraphicsContext, _ size: CGSize, _ date: Date, _ sky: Sky) {
        let me = loc.coord, d = Double.pi / 180, tf = DateFormatter(); tf.dateFormat = "HH:mm"
        // top-left: next sunrise/sunset here, from the subsolar point
        var up = true, sunTxt = "--"
        let cc = (sin(-0.833 * d) - sin(me.latitude * d) * sin(sky.sunLat * d)) / (cos(me.latitude * d) * cos(sky.sunLat * d))
        if abs(cc) <= 1 {
            let h0 = acos(cc) / d / 15, dn = ((sky.sunLon - me.longitude) / 15).truncatingRemainder(dividingBy: 24)
            let dn2 = dn > 12 ? dn - 24 : (dn < -12 ? dn + 24 : dn), noon = date.addingTimeInterval(dn2 * 3600)
            let ev = (-1...1).flatMap { k in [(noon.addingTimeInterval(Double(k) * 86400 - h0 * 3600), true), (noon.addingTimeInterval(Double(k) * 86400 + h0 * 3600), false)] }
                .filter { $0.0 > date }.sorted { $0.0 < $1.0 }
            if let e = ev.first { up = e.1; sunTxt = tf.string(from: e.0) }
        }
        chip(&g, CGPoint(x: 26, y: 46), leading: true, .sun(up: up), sunTxt, .white)
        // top-right: live heart rate (HealthKit); red only when abnormal (<40 or >120 BPM)
        let bpm = hr.bpm.flatMap { v in hr.at.map { date.timeIntervalSince($0) < 900 } == true ? v : nil }
        let bad = bpm.map { $0 < 40 || $0 > 120 } == true
        chip(&g, CGPoint(x: size.width - 26, y: 46), leading: false, .heart, bpm.map { "\($0)" } ?? "--", bad ? FaceView.alert : .white, alertOn: bad)
        // bottom-left: rain chance (Open-Meteo, free, no key); amber when older than 20 min
        let stale = wxOk.map { date.timeIntervalSince($0) > 1200 } ?? false
        chip(&g, CGPoint(x: 26, y: size.height - 34), leading: true, .rain, rain.map { "\($0)%" } ?? "--", stale ? FaceView.amber : .white)
        if date.timeIntervalSince(wxAt) > 720 { DispatchQueue.main.async { fetchTemp(me) } }
        // bottom-right: watch battery (segments, bolt while charging, red below 20%)
        let dev = WKInterfaceDevice.current(); dev.isBatteryMonitoringEnabled = true
        let b = Double(dev.batteryLevel), chg = dev.batteryState == .charging || dev.batteryState == .full
        chip(&g, CGPoint(x: size.width - 26, y: size.height - 34), leading: false, .battery(level: b, charging: chg), b < 0 ? "--" : "\(Int(b * 100))%", b >= 0 && b < 0.2 ? FaceView.alert : .white)
    }
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

@main struct EnochWatchApp: App { var body: some Scene { WindowGroup { FaceView() } } }

/// Stacked HH over MM, as large as fits between the corners, in a translucent "Liquid Glass" style:
/// the map shows through the glyphs. watchOS 26+: real .glassEffect masked by the digits; earlier: .ultraThinMaterial.
/// Outline of the stacked HH/MM glyphs as a SwiftUI Shape (CoreText glyph paths), so the documented
/// `glassEffect(_:in:)` modifier can render Liquid Glass in the exact shape of the digits.
struct DigitsShape: Shape {
    let hh: String, mm: String, fs: CGFloat
    func path(in rect: CGRect) -> Path {
        let font = CTFontCreateUIFontForLanguage(.system, fs, nil)!
        let heavy = CTFontCreateCopyWithSymbolicTraits(font, fs, nil, [.traitBold, .traitMonoSpace], [.traitBold, .traitMonoSpace]) ?? font
        func line(_ s: String) -> (CGMutablePath, CGRect) {
            let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): heavy])
            let ln = CTLineCreateWithAttributedString(attr), out = CGMutablePath()
            for run in CTLineGetGlyphRuns(ln) as! [CTRun] {
                let n = CTRunGetGlyphCount(run); var gl = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: n), &gl); CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
                for k in 0..<n { if let gp = CTFontCreatePathForGlyph(heavy, gl[k], nil) { out.addPath(gp, transform: CGAffineTransform(translationX: pos[k].x, y: pos[k].y)) } }
            }
            return (out, out.boundingBoxOfPath)
        }
        let gap = fs * 0.06, (a, ba) = line(hh), (b, bb) = line(mm), total = ba.height + gap + bb.height
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
    var body: some View {
        GeometryReader { geo in
            let cal = Calendar.current
            let hh = String(format: "%02d", cal.component(.hour, from: date)), mm = String(format: "%02d", cal.component(.minute, from: date))
            let fs = min(geo.size.width * 0.78 / 1.2, geo.size.height * 0.36)
            let shape = DigitsShape(hh: hh, mm: mm, fs: fs)
            Group {
                if #available(watchOS 26.0, *) {
                    Color.clear.glassEffect(.clear, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

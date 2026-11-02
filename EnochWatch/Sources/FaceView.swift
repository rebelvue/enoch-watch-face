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
            Canvas { g, size in draw(&g, size, ctx.date) }
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
                let a = min(0.5, max(0, (0.08 - e) * 2.5)); if a <= 0 { continue }
                l.fill(Path(CGRect(x: disc.minX + Double(i) * cell, y: disc.minY + Double(j) * cell, width: cell + 0.5, height: cell + 0.5)),
                       with: .color(Color(red: 0.04, green: 0.06, blue: 0.08).opacity(a)))
            } }
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

        // stacked time: fixed size (does not zoom), heavy monospaced, white with a phosphor glow
        let cal = Calendar.current, hh = String(format: "%02d", cal.component(.hour, from: date)), mm = String(format: "%02d", cal.component(.minute, from: date))
        let base = min(size.width, size.height) / 2 - 4
        let font = Font.system(size: base * 0.6, weight: .heavy, design: .monospaced)
        var tg = g; tg.addFilter(.shadow(color: acc.opacity(0.55), radius: 7)); tg.addFilter(.shadow(color: .black.opacity(0.9), radius: 4))
        tg.draw(Text(hh).font(font).foregroundColor(.white), at: CGPoint(x: c.x, y: c.y - base * 0.28))
        tg.draw(Text(mm).font(font).foregroundColor(.white), at: CGPoint(x: c.x, y: c.y + base * 0.28))

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
        tag(sp, "SOL", amb)

        // moon: NASA LRO nearside texture, sphere-shaded terminator, earthshine and limb darkening
        let mp = P(sky.moonLat, sky.moonLon), mr = 6.0
        if let img = shadedMoon(sky.phase) {
            g.draw(Image(decorative: img, scale: 1), in: CGRect(x: mp.x - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)) }
        tag(mp, "LUNA \(Int((1 - cos(sky.phase)) / 2 * 100))%", amb)

        // you: waypoint diamond, LOC and HOME distance / bearing (great circle)
        let me = P(loc.coord.latitude, loc.coord.longitude), la = loc.coord.latitude, lo = loc.coord.longitude
        var dm = Path(); dm.move(to: CGPoint(x: me.x, y: me.y - 7)); dm.addLine(to: CGPoint(x: me.x + 7, y: me.y)); dm.addLine(to: CGPoint(x: me.x, y: me.y + 7)); dm.addLine(to: CGPoint(x: me.x - 7, y: me.y)); dm.closeSubpath()
        g.fill(dm, with: .color(amb.opacity(0.18))); g.stroke(dm, with: .color(amb), lineWidth: 1.3); dot(me, 1.8, .white)
        // position marker: diamond only, no labels

        // top: live place name + countdown to next sunrise/sunset, then local date; bottom: coordinates
        let cc = (sin(-0.833 * d) - sin(la * d) * sin(sky.sunLat * d)) / (cos(la * d) * cos(sky.sunLat * d))
        var cd = ""
        if abs(cc) <= 1 {
            let h0 = acos(cc) / d / 15, dn = ((sky.sunLon - lo) / 15).truncatingRemainder(dividingBy: 24)
            let noon = date.addingTimeInterval((dn > 12 ? dn - 24 : (dn < -12 ? dn + 24 : dn)) * 3600)
            if let e = (-1...1).flatMap({ k in [(noon.addingTimeInterval(Double(k) * 86400 - h0 * 3600), "SUNRISE"), (noon.addingTimeInterval(Double(k) * 86400 + h0 * 3600), "SUNSET")] }).filter({ $0.0 > date }).min(by: { $0.0 < $1.0 }) {
                let m = Int(e.0.timeIntervalSince(date) / 60); cd = String(format: " \u{00B7} %@ IN %dH%02d", e.1, m / 60, m % 60) }
        }
        let dfm = DateFormatter(); dfm.locale = Locale(identifier: "en_US_POSIX"); dfm.dateFormat = "EEE dd MMM yyyy"
        g.draw(Text((loc.place ?? "SANTANDREI") + cd).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: c.x, y: 10))
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

    private func corner(_ g: inout GraphicsContext, _ p: CGPoint, _ anchor: UnitPoint, _ top: String, _ big: String, _ col: Color) {
        let acc = Color(red: 0.75, green: 0.96, blue: 0.82), mono = { (s: Double, w: Font.Weight) in Font.system(size: s, weight: w, design: .monospaced) }
        let t1 = g.resolve(Text(top).font(mono(9, .bold)).foregroundColor(acc)), t2 = g.resolve(Text(big).font(mono(16, .heavy)).foregroundColor(.white))
        g.draw(t1, at: p, anchor: anchor); g.draw(t2, at: CGPoint(x: p.x, y: p.y + 16), anchor: anchor)
        // thin bracket frame
        let w = max(t1.measure(in: CGSize(width: 200, height: 40)).width, t2.measure(in: CGSize(width: 200, height: 40)).width) + 8
        let x0 = anchor == .leading ? p.x - 4 : p.x - w + 4, y0 = p.y - 8, h = 32.0, k = 5.0
        var b = Path()
        for (x, y, sx, sy) in [(x0, y0, 1.0, 1.0), (x0 + w, y0, -1, 1), (x0, y0 + h, 1, -1), (x0 + w, y0 + h, -1, -1)] {
            b.move(to: CGPoint(x: x + sx * (k + 3), y: y)); b.addLine(to: CGPoint(x: x + sx * 3, y: y)); b.addLine(to: CGPoint(x: x, y: y + sy * 3)); b.addLine(to: CGPoint(x: x, y: y + sy * (k + 1))) }
        g.stroke(b, with: .color(.white.opacity(0.75)), lineWidth: 0.8)
    }

    private func corners(_ g: inout GraphicsContext, _ size: CGSize, _ date: Date, _ sky: Sky) {
        let me = loc.coord, d = Double.pi / 180, tf = DateFormatter(); tf.dateFormat = "HH:mm"
        // top-left: next sunrise/sunset here, from the subsolar point
        var sunTop = "SUN", sunTxt = "--"
        let cc = (sin(-0.833 * d) - sin(me.latitude * d) * sin(sky.sunLat * d)) / (cos(me.latitude * d) * cos(sky.sunLat * d))
        if abs(cc) <= 1 {
            let h0 = acos(cc) / d / 15, dn = ((sky.sunLon - me.longitude) / 15).truncatingRemainder(dividingBy: 24)
            let dn2 = dn > 12 ? dn - 24 : (dn < -12 ? dn + 24 : dn), noon = date.addingTimeInterval(dn2 * 3600)
            let ev = (-1...1).flatMap { k in [(noon.addingTimeInterval(Double(k) * 86400 - h0 * 3600), "SUNRISE"), (noon.addingTimeInterval(Double(k) * 86400 + h0 * 3600), "SUNSET")] }
                .filter { $0.0 > date }.sorted { $0.0 < $1.0 }
            if let e = ev.first { sunTop = e.1; sunTxt = tf.string(from: e.0) }
        }
        corner(&g, CGPoint(x: 30, y: 26), .leading, sunTop, sunTxt, Color(red: 0.78, green: 0.47, blue: 0.1))
        // top-right: moon phase name and % lit
        let f = sky.phase / (2 * .pi), names = ["NEW", "WAX CRES", "1ST QTR", "WAX GIBB", "FULL", "WAN GIBB", "3RD QTR", "WAN CRES"]
        let name = "LUNA " + (f < 0.03 || f > 0.97 ? names[0] : f < 0.22 ? names[1] : f < 0.28 ? names[2] : f < 0.47 ? names[3] : f < 0.53 ? names[4] : f < 0.72 ? names[5] : f < 0.78 ? names[6] : names[7])
        corner(&g, CGPoint(x: size.width - 30, y: 26), .trailing, name, "\(Int((1 - cos(sky.phase)) / 2 * 100))%", Color(red: 0.29, green: 0.34, blue: 0.5))
        // bottom-left: weekday + day, and temperature (Open-Meteo, free, no key)
        let df = DateFormatter(); df.dateFormat = "EEE d"
        corner(&g, CGPoint(x: 30, y: size.height - 46), .leading, "WX // PRECIP" + (wxOk.map { date.timeIntervalSince($0) > 1200 ? " \(Int(date.timeIntervalSince($0) / 60))M" : "" } ?? ""), (temp.map { "\($0)°C" } ?? "--°C") + " " + (rain.map { "\($0)%" } ?? "--%"), Color(red: 0.24, green: 0.18, blue: 0.13))
        if date.timeIntervalSince(wxAt) > 720 { DispatchQueue.main.async { fetchTemp(me) } }
        // bottom-right: battery here; HOME (Santandrei) time instead when you are away from home
        // bottom-right: watch battery, always (level bar, bolt while charging)
        let dev = WKInterfaceDevice.current(); dev.isBatteryMonitoringEnabled = true
        let b = dev.batteryLevel, chg = dev.batteryState == .charging || dev.batteryState == .full
        let bp = CGPoint(x: size.width - 30, y: size.height - 46)
        corner(&g, bp, .trailing, "PWR", b < 0 ? "--" : "\(Int(b * 100))%" + (chg ? " \u{26A1}" : ""), .white)
        if b >= 0 {
            g.stroke(Path(CGRect(x: bp.x - 34, y: bp.y + 27, width: 34, height: 3)), with: .color(.white.opacity(0.75)), lineWidth: 0.7)
            g.fill(Path(CGRect(x: bp.x - 34, y: bp.y + 27, width: 34 * Double(b), height: 3)), with: .color(b < 0.2 ? Color(red: 1, green: 0.29, blue: 0.24) : Color(red: 0.75, green: 0.96, blue: 0.82)))
        }
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

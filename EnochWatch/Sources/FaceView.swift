import SwiftUI
import CoreLocation
import WatchKit

final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coord = CLLocationCoordinate2D(latitude: 47.0682, longitude: 21.8548) // Santandrei, Bihor, Romania (home)
    private let m = CLLocationManager()
    override init() { super.init(); m.delegate = self; m.desiredAccuracy = kCLLocationAccuracyKilometer
        m.requestWhenInUseAuthorization(); m.requestLocation() }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { if let c = l.last?.coordinate { coord = c } }
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
    // stars sit on the firmament's inner surface (as in world-of-enoch-3d-map); from above a star at
    // height u projects to radius sqrt(1-u^2) of the dome rim, so every star lies over the disc
    private let stars: [(Double, Double, Double, Double)] = {
        var s: UInt64 = 7; func r() -> Double { s = s &* 6364136223846793005 &+ 1; return Double(s >> 11) / Double(1 << 53) }
        return (0..<260).map { _ in let u = 0.04 + r() * 0.96, mg = pow(r(), 3.2); return (r() * 360, sqrt(1 - u * u), 0.5 + mg * 1.3, 0.3 + mg * 0.7) }
    }()

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
            l.draw(Image("disc"), in: disc)
            // night side: solar elevation on the globe, sampled on a coarse grid
            let n = 40, cell = 2 * R / Double(n), sl = sky.sunLat * d, so = sky.sunLon * d
            for j in 0..<n { for i in 0..<n {
                let dx = (Double(i) + 0.5) / Double(n) * 2 - 1, dy = (Double(j) + 0.5) / Double(n) * 2 - 1, r = hypot(dx, dy)
                if r > 1.03 { continue }
                let la = (90 - min(r, 1) * 180) * d, lo = atan2(dx, dy)
                let e = sin(la) * sin(sl) + cos(la) * cos(sl) * cos(lo - so)
                let a = min(0.6, max(0, (0.08 - e) * 2.5)); if a <= 0 { continue }
                l.fill(Path(CGRect(x: disc.minX + Double(i) * cell, y: disc.minY + Double(j) * cell, width: cell + 0.5, height: cell + 0.5)),
                       with: .color(Color(red: 0.03, green: 0.05, blue: 0.18).opacity(a)))
            } }
            // stars inside the firmament, turning with sidereal time: faint by day, bright at night
            for st in stars {
                let ang = st.0 * d - sky.siderealDeg * d, rr = st.1 * 1.03, dx = rr * sin(ang), dy = rr * cos(ang), r = hypot(dx, dy)
                if r > 1 { continue }
                let la = (90 - r * 180) * d, e = sin(la) * sin(sl) + cos(la) * cos(sl) * cos(atan2(dx, dy) - so)
                let night = min(1, max(0, (0.08 - e) * 4))
                l.fill(Path(ellipseIn: CGRect(x: c.x + dx * R - st.2, y: c.y + dy * R - st.2, width: 2 * st.2, height: 2 * st.2)),
                       with: .color(Color(red: 1, green: 0.97, blue: 0.9).opacity(st.3 * (0.12 + 0.88 * night))))
            }
            // firmament dome from above: clear crown, pale blue sheen at the rim resting on the ice wall
            l.fill(Path(ellipseIn: disc), with: .radialGradient(Gradient(stops: [
                .init(color: Color(red: 0.55, green: 0.75, blue: 1).opacity(0.05), location: 0),
                .init(color: Color(red: 0.63, green: 0.78, blue: 1).opacity(0.12), location: 0.75),
                .init(color: Color(red: 0.8, green: 0.9, blue: 1).opacity(0.5), location: 1)]), center: c, startRadius: 0, endRadius: R))
        }

        // tactical overlay: range rings, radials, rim ticks, radar sweep
        let acc = Color(red: 0.36, green: 1, blue: 0.6)
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
        // sun with glow + SOL tag
        let sp = P(sky.sunLat, sky.sunLon)
        g.fill(Path(ellipseIn: CGRect(x: sp.x - 36, y: sp.y - 36, width: 72, height: 72)),
               with: .radialGradient(Gradient(colors: [Color.yellow.opacity(0.45), .clear]), center: sp, startRadius: 0, endRadius: 36))
        dot(sp, 5, Color(red: 1, green: 0.82, blue: 0.4)); g.stroke(Path(ellipseIn: CGRect(x: sp.x - 8, y: sp.y - 8, width: 16, height: 16)), with: .color(.white), lineWidth: 0.8)
        tag(sp, "SOL", .white)

        // moon with phase (lit disc, offset shadow disc) + LUNA tag
        let mp = P(sky.moonLat, sky.moonLon), mr = 5.0
        g.drawLayer { l in
            l.clip(to: Path(ellipseIn: CGRect(x: mp.x - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)))
            l.fill(Path(CGRect(x: mp.x - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)), with: .color(Color(red: 0.96, green: 0.94, blue: 0.88)))
            let f = (1 - cos(sky.phase)) / 2, off = (sky.phase < .pi ? -1.0 : 1.0) * 2 * mr * f
            l.fill(Path(ellipseIn: CGRect(x: mp.x + off - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)), with: .color(Color(red: 0.17, green: 0.19, blue: 0.31)))
        }
        tag(mp, "LUNA \(Int((1 - cos(sky.phase)) / 2 * 100))%", .white)

        // you: reticle + LOC readout
        let me = P(loc.coord.latitude, loc.coord.longitude), la = loc.coord.latitude, lo = loc.coord.longitude
        g.stroke(Path(ellipseIn: CGRect(x: me.x - 7, y: me.y - 7, width: 14, height: 14)), with: .color(acc), lineWidth: 1.1)
        for v in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] { var p = Path(); p.move(to: CGPoint(x: me.x + v.0 * 4, y: me.y + v.1 * 4))
            p.addLine(to: CGPoint(x: me.x + v.0 * 12, y: me.y + v.1 * 12)); g.stroke(p, with: .color(acc), lineWidth: 1.1) }
        dot(me, 1.5, .white)
        tag(me, String(format: "LOC %.3f%@ %07.3f%@", abs(la), la >= 0 ? "N" : "S", abs(lo), lo >= 0 ? "E" : "W"), acc)

        // status line + zulu
        var z = Calendar(identifier: .gregorian); z.timeZone = TimeZone(identifier: "UTC")!
        g.draw(Text("TS//SCI  EYES ONLY").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(acc), at: CGPoint(x: c.x, y: 14))
        g.draw(Text(String(format: "ZULU %02d%02dZ", z.component(.hour, from: date), z.component(.minute, from: date))).font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: c.x, y: size.height - 12))

        corners(&g, size, date, sky)

    }

    // ---- four corner complications ----
    @State private var temp: Int? = nil
    @State private var rain: Int? = nil
    @State private var wxAt = Date.distantPast
    private let home = CLLocationCoordinate2D(latitude: 47.0682, longitude: 21.8548)

    private func corner(_ g: inout GraphicsContext, _ p: CGPoint, _ anchor: UnitPoint, _ top: String, _ big: String, _ col: Color) {
        let acc = Color(red: 0.36, green: 1, blue: 0.6), mono = { (s: Double, w: Font.Weight) in Font.system(size: s, weight: w, design: .monospaced) }
        let t1 = g.resolve(Text(top).font(mono(9, .bold)).foregroundColor(acc)), t2 = g.resolve(Text(big).font(mono(16, .heavy)).foregroundColor(.white))
        g.draw(t1, at: p, anchor: anchor); g.draw(t2, at: CGPoint(x: p.x, y: p.y + 16), anchor: anchor)
        // thin bracket frame
        let w = max(t1.measure(in: CGSize(width: 200, height: 40)).width, t2.measure(in: CGSize(width: 200, height: 40)).width) + 8
        let x0 = anchor == .leading ? p.x - 4 : p.x - w + 4, y0 = p.y - 8, h = 32.0, k = 5.0
        var b = Path()
        for (x, y, sx, sy) in [(x0, y0, 1.0, 1.0), (x0 + w, y0, -1, 1), (x0, y0 + h, 1, -1), (x0 + w, y0 + h, -1, -1)] {
            b.move(to: CGPoint(x: x + sx * k, y: y)); b.addLine(to: CGPoint(x: x, y: y)); b.addLine(to: CGPoint(x: x, y: y + sy * k)) }
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
        corner(&g, CGPoint(x: 30, y: size.height - 46), .leading, "WX // PRECIP", (temp.map { "\($0)°C" } ?? "--°C") + " " + (rain.map { "\($0)%" } ?? "--%"), Color(red: 0.24, green: 0.18, blue: 0.13))
        if date.timeIntervalSince(wxAt) > 1800 { DispatchQueue.main.async { fetchTemp(me) } }
        // bottom-right: battery here; HOME (Santandrei) time instead when you are away from home
        let away = hypot(me.latitude - home.latitude, me.longitude - home.longitude) > 1
        if away {
            tf.timeZone = TimeZone(identifier: "Europe/Bucharest")
            corner(&g, CGPoint(x: size.width - 30, y: size.height - 46), .trailing, "HOME RO", tf.string(from: date), Color(red: 0.24, green: 0.18, blue: 0.13))
        } else {
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
            let b = WKInterfaceDevice.current().batteryLevel
            corner(&g, CGPoint(x: size.width - 30, y: size.height - 46), .trailing, "PWR", b < 0 ? "--" : "\(Int(b * 100))%", Color(red: 0.24, green: 0.18, blue: 0.13))
        }
    }

    private func fetchTemp(_ c: CLLocationCoordinate2D) {
        wxAt = Date()
        let u = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f&current=temperature_2m&hourly=precipitation_probability&forecast_hours=1", c.latitude, c.longitude))!
        URLSession.shared.dataTask(with: u) { data, _, _ in
            struct R: Decodable { struct C: Decodable { let temperature_2m: Double }; struct H: Decodable { let precipitation_probability: [Int?] }; let current: C; let hourly: H? }
            if let data, let r = try? JSONDecoder().decode(R.self, from: data) { DispatchQueue.main.async { temp = Int(r.current.temperature_2m.rounded()); rain = r.hourly?.precipitation_probability.first ?? nil } }
        }.resume()
    }
}

@main struct EnochWatchApp: App { var body: some Scene { WindowGroup { FaceView() } } }

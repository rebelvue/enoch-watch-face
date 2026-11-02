import SwiftUI
import CoreLocation

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
    private let stars: [(Double, Double, Double)] = {
        var s: UInt64 = 7; func r() -> Double { s = s &* 6364136223846793005 &+ 1; return Double(s >> 11) / Double(1 << 53) }
        return (0..<220).map { _ in (r() * 360, sqrt(r()), r() * 1.2 + 0.4) }
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Canvas { g, size in draw(&g, size, ctx.date) }
        }
        .ignoresSafeArea()
        .background(Color(red: 0.04, green: 0.06, blue: 0.19))
    }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ date: Date) {
        let sky = Sky(date: date), d = Double.pi / 180
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = min(size.width, size.height) / 2 - 4
        // World of Enoch projection: r = (90 - lat)/180 * R, lon 0 pointing down, east to the right
        func P(_ lat: Double, _ lon: Double) -> CGPoint {
            let r = (90 - lat) / 180 * R; return CGPoint(x: c.x + r * sin(lon * d), y: c.y + r * cos(lon * d)) }
        func dot(_ p: CGPoint, _ r: Double, _ col: Color) { g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(col)) }

        // stars turn with sidereal time
        let half = hypot(size.width, size.height) / 2
        for s in stars { let a = (s.0 - sky.siderealDeg) * d
            dot(CGPoint(x: c.x + s.1 * half * sin(a), y: c.y + s.1 * half * cos(a)), s.2, .white.opacity(0.8)) }

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
        }

        // stacked time
        let cal = Calendar.current, hh = String(format: "%02d", cal.component(.hour, from: date)), mm = String(format: "%02d", cal.component(.minute, from: date))
        let font = Font.system(size: R * 0.36, weight: .heavy, design: .rounded)
        g.draw(Text(hh).font(font).foregroundColor(.white), at: CGPoint(x: c.x, y: c.y - R * 0.17))
        g.draw(Text(mm).font(font).foregroundColor(Color(red: 1, green: 0.85, blue: 0.54)), at: CGPoint(x: c.x, y: c.y + R * 0.17))

        // sun with glow
        let sp = P(sky.sunLat, sky.sunLon)
        g.fill(Path(ellipseIn: CGRect(x: sp.x - 36, y: sp.y - 36, width: 72, height: 72)),
               with: .radialGradient(Gradient(colors: [Color.yellow.opacity(0.5), .clear]), center: sp, startRadius: 0, endRadius: 36))
        dot(sp, 7, Color(red: 1, green: 0.79, blue: 0.24))

        // moon with phase (lit disc, offset shadow disc)
        let mp = P(sky.moonLat, sky.moonLon), mr = 6.0
        g.drawLayer { l in
            l.clip(to: Path(ellipseIn: CGRect(x: mp.x - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)))
            l.fill(Path(CGRect(x: mp.x - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)), with: .color(Color(red: 0.96, green: 0.94, blue: 0.88)))
            let f = (1 - cos(sky.phase)) / 2, off = (sky.phase < .pi ? -1.0 : 1.0) * 2 * mr * f
            l.fill(Path(ellipseIn: CGRect(x: mp.x + off - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)), with: .color(Color(red: 0.17, green: 0.19, blue: 0.31)))
        }

        // you
        let me = P(loc.coord.latitude, loc.coord.longitude)
        dot(me, 6, .white); dot(me, 4, Color(red: 1, green: 0.3, blue: 0.37))
    }
}

@main struct EnochWatchApp: App { var body: some Scene { WindowGroup { FaceView() } } }

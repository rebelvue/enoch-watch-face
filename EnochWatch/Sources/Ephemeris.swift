import Foundation

/// Low-precision ephemeris (about 0.5 degree), same formulas as the World of Enoch map.
struct Sky {
    var sunLat: Double, sunLon: Double, moonLat: Double, moonLon: Double
    var siderealDeg: Double, phase: Double   // phase: 0 new, pi full

    init(date: Date) {
        let d = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86400 - 10957.5
        let e = (23.439 - 4e-7 * n) * d
        let gst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
        func eq(_ l: Double, _ b: Double) -> (Double, Double) {
            let dec = asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
            let ra = atan2(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
            var lon = (ra / d - gst).truncatingRemainder(dividingBy: 360)
            if lon > 180 { lon -= 360 }; if lon < -180 { lon += 360 }
            return (dec / d, lon)
        }
        let g = (357.528 + 0.9856003 * n) * d
        let ls = (280.46 + 0.9856474 * n + 1.915 * sin(g) + 0.02 * sin(2 * g)) * d
        let mm = (134.963 + 13.064993 * n) * d, f = (93.272 + 13.22935 * n) * d, dd = (297.85 + 12.190749 * n) * d
        let lm = (218.316 + 13.176396 * n + 6.289 * sin(mm) + 1.274 * sin(2 * dd - mm) + 0.658 * sin(2 * dd)) * d
        let bm = 5.128 * sin(f) * d
        (sunLat, sunLon) = eq(ls, 0)
        (moonLat, moonLon) = eq(lm, bm)
        siderealDeg = gst
        let p = (lm - ls).truncatingRemainder(dividingBy: 2 * .pi)
        phase = p < 0 ? p + 2 * .pi : p
    }
}

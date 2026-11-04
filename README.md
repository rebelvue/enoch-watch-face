# Enoch Watch Face

A watch face prototype built on the World of Enoch flat-earth map (https://github.com/rebelvue/world-of-enoch-3d-map), seen from directly above: an azimuthal equidistant disc centred on the North Pole, with Antarctica as the outer ice ring.

- The local time sits in the centre as stacked numbers, hours over minutes.
- The sun sits over its subsolar point. A soft night shade covers the side where the sun is below the horizon.
- The moon sits over its sublunar point and shows its current phase.
- The stars turn around the pole with sidereal time.
- A red dot marks your position from the watch's own GPS (satellites only, no wifi, cellular or internet), refreshed whenever you raise your wrist. Before the first fix it shows home in Santandrei, Bihor (47.0682 N, 21.8548 E). The city name comes offline from the bundled GeoNames list (`cities.tsv`, CC BY 4.0, cities over 5,000 people).

## Web version
Live: https://rebelvue.github.io/enoch-watch-face/

On an iPhone, open it in Safari, tap Share, then Add to Home Screen. It redraws every second.

## watchOS app (`EnochWatch/`)
SwiftUI source: a full-screen `Canvas` inside a `TimelineView` that updates every second, with CoreLocation for your position.

Build steps (you need a Mac with Xcode 15 or newer; a free Apple ID works for personal installs, which must be re-signed every 7 days):
1. `brew install xcodegen`, then `cd EnochWatch && xcodegen`.
2. Open `EnochWatch.xcodeproj`, choose your Team under Signing, and set a unique bundle id.
3. Pair the Watch with the iPhone, connect the iPhone, select the Watch as the run destination, and press Run.

There's no free way to install it without a Mac and Xcode.

### Limitation: Apple doesn't allow fully custom watch faces
watchOS doesn't let third parties make their own watch faces. This runs as a watch app instead. You can:
- open it from the app grid,
- add a complication or Smart Stack widget that launches it (a WidgetKit extension; not included yet),
- set Settings > General > Return to Clock to keep it on screen longer.

## How the sky is computed
These are the same low-precision formulas the main map uses, accurate to about 0.5 degree.
- **Sun:** mean anomaly and ecliptic longitude, converted to declination and right ascension. Its map longitude is RA minus Greenwich sidereal time.
- **Moon:** ecliptic longitude with the three main periodic terms, plus latitude, converted the same way. The phase is the moon's ecliptic longitude minus the sun's.
- **Stars:** set inside the firmament, on the dome's inner surface, as in world-of-enoch-3d-map. Seen from above they all fall over the disc and turn around the pole with Greenwich sidereal time. They are faint over the day side and bright over the night side. They're decorative, not real catalogue stars.
- **Firmament:** a translucent dome over the disc, with its rim on the ice wall. Outside the ice wall the screen is pure black (OLED), with no stars; corner texts are white.

## Corner complications
- **Top-left:** the next sunrise or sunset at your position, computed locally from the subsolar point.
- **Top-right:** the moon phase name and the percent illuminated.
- **Bottom-left:** weekday and day, plus the current temperature and the chance of rain in the next hour from Open-Meteo (free, no key, refreshed every 30 minutes).
- **Bottom-right:** HOME (Santandrei, Europe/Bucharest) time when you're more than about 1 degree away from home. At home it shows battery level instead: WKInterfaceDevice on the Watch, or the Battery API in browsers that have it (Safari doesn't).
- **Map projection:** r = (90 - lat) / 180 * R. Longitude 0 points down and east runs to the right.

## Zoom
- Double-tap toggles between the whole-disc view and the fill view, with a spring. Web uses localStorage and the watch uses @AppStorage to remember it.

## Time scrub
- **Watch:** turn the Digital Crown to scrub time. Faster turns move faster (acceleration curve, up to 12 h per unit, clamped to 30 days). A "+3h 20m" readout appears under the date with the sign in orange. After 2 s idle it springs back to now.
- **Web:** the mouse wheel does the same.

## Always-on
- When the watch dims (`isLuminanceReduced`, wrist down) the face goes black-and-white and flat. Map, digits, outlines, comps, text, stars and grid are all greyscale (no orange), with no parallax, glass, rim light or sheen. Only the sun and the moon keep their colour, drawn in their own layer above the greyscale layers. On the web, press A to preview it.
- Battery: in always-on the watch
  - redraws once a minute (`TimelineView(.everyMinute)`, no animation schedule, no seconds),
  - stops CoreMotion (device motion and accelerometer) and restarts it on wake,
  - stops the HealthKit heart-rate query and keeps the last value, resuming on wake,
  - skips weather fetches and refreshes on wake,
  - runs no springs or animations, and skips the crown, scrub and detail-card timers,
  - reuses the cached day/night shading render (rebuilt only when the sun moves about 0.25 deg),
  - keeps the same day/night shading, map and grid as active mode, only at about 0.65x brightness, so the night side stays visible in grey.
- The web preview also drops to one redraw a minute and pauses tilt, springs and weather.

## Detail cards
- Tap a comp to open a clear glass card. RAIN shows the next 6 h as bars (Open-Meteo), BATTERY shows level and charging, BPM shows now plus last-hour min and max (watch only), and SUN shows sunrise, sunset and day length. Tap, turn the crown, or wait 6 s to close it.

## Parallax
- Tilt moves only the time digits (about 11 pt, with their rim light and sheen), the country/city outlines (about 6 pt) and the comps, date and location text (about 3 pt). The earth map, grid, day/night shading, stars, sun and moon (including its dark side) never move with parallax. It runs at 60 Hz through a critically damped spring and is off in always-on.

## Stars
- All white, about 1 pt, the same size. No galaxies.

## Tactical HUD style

Generic tactical-map look in the spirit of modern military-shooter minimaps (style inspiration only: no game or agency logos, seals, fonts or assets).

- Map: the real disc image graded to desaturated olive / slate (filter + multiply tint), live night shade, pure black outside the ice wall.
- No SUN or MOON text tags (removed 2026-11-03); the sun and moon are drawn as they are. No position marker, your location is shown by the orange country/city borders and the top CITY, COUNTRY line. Red only for alerts. One UI orange everywhere: #FF8C1A.
- Time: stacked HH/MM in JetBrains Mono ExtraBold (self-hosted `jbm800.woff2`, SIL OFL, `OFL-JetBrainsMono.txt`); watchOS uses the system monospaced heavy font. Top line: live place name of your GPS position plus a countdown to the next sunrise/sunset (e.g. `WARSAW`), with the local date under it (`MON 02 NOV 2026`). Bottom line: your coordinates (`FALLBACK` when not live).
- Corners are curved two-line comps laid along the rim, no icons and no frames: a small orange label stacked over a bigger white value. SUNRISE or SUNSET (whichever is next) + time; BPM + heart rate (red only below 40 or above 120; `--` on the web because browsers cannot read heart rate); RAIN + chance for the coming hour (amber when older than 20 min); BATTERY + charge (red below 20%). Top comps are mirrored at the same height; the watch hides the system status-bar clock.
- Time: large stacked HH over MM in flat Liquid Glass (clear variant, per Apple's docs and HIG). Watch: `Color.clear.glassEffect(.clear, in: DigitsShape)`, where DigitsShape is the glyph outline built with CoreText, because `glassEffect(_:in:)` takes a Shape and Text is not one. Older watchOS falls back to `.ultraThinMaterial` in the same shape. No extra shadows or strokes. Web: the digits act as a lens, with the map lightly blurred and magnified 6%, a faint luminosity lift and a thin specular rim that is brightest toward the light. No bevel, inner shadow, drop shadow or grey fill.
- Day/night (Enoch spotlight): every disc point is lit by the sun's elevation there. Sunlit areas are the original map with exposure raised (natural colours, no tint or glow); dark areas are the same map darkened to about 10%. The transition is a wide smooth falloff from 18 deg below to 12 deg above the horizon, with no visible edge.
- Borders: the country you are in is outlined in thin orange (point-in-polygon on bundled Natural Earth 1:110m admin-0, public domain, `countries.json`, rechecked on every GPS fix), and your city in a thinner orange line (Nominatim `polygon_geojson`, cached, refetched only when the city changes, skipped if unavailable). Top line reads `CITY, COUNTRY`. Test a place with `?lat=52.2297&lon=21.0122`.
- Subtle scanlines and film grain.
- Sun: white-hot core with limb darkening, warm corona bloom, a short anamorphic streak. Moon: NASA LRO WAC nearside mosaic (public domain, NASA/GSFC/Arizona State University), `moon.webp` / `moon.png` 64 px, Lambert-shaded for the current elongation with a soft terminator, earthshine and limb darkening.
- Zoom is double-tap only; the crown and wheel scrub time.

## Live data: computed vs fetched

| Item | Source |
|---|---|
| Local time, date | device clock, every redraw (10 per second) |
| Place name | fetched: web uses BigDataCloud reverse-geocode-client (free, no key), watch uses CLGeocoder; refetched only after moving more than 5 km; fallback `SANTANDREI` |
| Sunrise/sunset countdown | computed live from the sun position |
| Sun and moon positions, moon phase and %, sunrise/sunset | computed on the device from the ephemeris at the current instant |
| Stars | real catalogue: 913 stars of magnitude < 4.5 from the HYG database v4.0 (CC BY-SA 4.0, astronexus/HYG-Database), `stars.json`, placed by RA/Dec, rotated by live sidereal time, colour from B-V |
| Night shade | computed live from the subsolar point |
| Position | live GPS / browser geolocation (watched continuously); Santandrei only as fallback, labelled `default` (web) / `FALLBACK` (watch) |
| Weather | fetched from Open-Meteo (free, no key), refreshed every 12 min and when you move; shows data age in minutes if older than 20 min |
| Heart rate | live on the watch: HealthKit `HKAnchoredObjectQuery` on heart rate (read permission, HealthKit entitlement); not available in browsers, shown as `--` |
| Battery | live: Battery API in the browser (`--` where unsupported), WKInterfaceDevice on the watch |

- Time digits use Chakra Petch Bold Italic (SIL Open Font License, see EnochWatch/Sources/OFL-ChakraPetch.txt), tabular fixed cells. The radar sweep and position marker were removed.
- Layering, bottom to top: map, day/night and grid; Liquid Glass time digits; current country and city outlines; stars, sun and moon; corners and top/bottom text.
- Self-test: add ?debug=1 to draw a magenta crosshair at the computed subsolar point and a cyan ring at the sublunar point, with their lat/lon. Day/night grading uses plain canvas compositing (no ctx.filter), so it renders the same in Safari.
- Time legibility: Liquid Glass (clear), not frosted. Web: digits are thick glass lenses; the map inside is magnified about 1.2x and bent toward the edges along the gradient of a blurred glyph alpha, with a slight chromatic fringe, an 8% tint and a thin specular rim (bright top-left, faint bottom-right). Pixel work runs on a half-res offscreen without ctx.filter (Safari-safe); edge field cached per minute, refraction every 10 s. watchOS 26: .glassEffect(.clear) plus a 1 pt gradient rim. FALLBACK appears only when there is no GPS fix.

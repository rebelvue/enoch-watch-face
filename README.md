# Enoch Watch Face

A watch face prototype built on the World of Enoch flat-earth map (https://github.com/rebelvue/world-of-enoch-3d-map), seen from directly above: an azimuthal equidistant disc centred on the North Pole, with Antarctica as the outer ice ring.

- The local time sits in the centre as stacked numbers, hours over minutes.
- The sun sits over its subsolar point. A soft night shade covers the side where the sun is below the horizon.
- The moon sits over its sublunar point and shows its current phase.
- The stars turn around the pole with sidereal time.
- A red dot marks your position: GPS when allowed, otherwise home in Santandrei, Bihor (47.0682 N, 21.8548 E).

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
- **Web:** pinch with two fingers, double-tap, or use the mouse wheel or a trackpad pinch to zoom. It moves between the whole-disc view and a fill view where the map covers the whole screen. The last zoom is remembered in localStorage.
- **Watch:** turn the Digital Crown to zoom, between the same two views, with a click at each end. Double-tap toggles between them. The last zoom is saved with @AppStorage.

## Tactical HUD style

Generic tactical-map look in the spirit of modern military-shooter minimaps (style inspiration only: no game or agency logos, seals, fonts or assets).

- Map: the real disc image graded to desaturated olive / slate (filter + multiply tint), live night shade, pure black outside the ice wall.
- Lines: thin pale-mint range rings (every 30° of latitude), 30° radials, compass ticks every 10° on the rim with longitude labels, a slow radar sweep (decorative only).
- Markers in amber: `SOL` and `LUNA nn%` objective tags; your position as a waypoint diamond with `LOC` and `HOME <km> BRG <deg>` (great-circle distance and bearing to Santandrei). Red only for alerts (battery below 20%).
- Time: stacked HH/MM in JetBrains Mono ExtraBold (self-hosted `jbm800.woff2`, SIL OFL, `OFL-JetBrainsMono.txt`); watchOS uses the system monospaced heavy font. Status line `TS//SCI  EYES ONLY`, `ZULU hhmmZ`.
- Corners: white values, mint labels, angled bracket frames: `SUNRISE`/`SUNSET`, `LUNA <phase> nn%`, `WX // PRECIP`, `PWR nn%` with a level bar and a bolt while charging (always battery).
- Subtle scanlines and film grain.
- Sun: white-hot core with limb darkening, warm corona bloom, a short anamorphic streak. Moon: NASA LRO WAC nearside mosaic (public domain, NASA/GSFC/Arizona State University), `moon.webp` / `moon.png` 64 px, Lambert-shaded for the current elongation with a soft terminator, earthshine and limb darkening.
- Zoom (pinch, double-tap, wheel, Digital Crown) unchanged; digits and corners stay fixed.

## Live data: computed vs fetched

| Item | Source |
|---|---|
| Local time, ZULU | device clock, every redraw (10 per second) |
| Sun and moon positions, moon phase and %, sunrise/sunset | computed on the device from the ephemeris at the current instant |
| Stars | real catalogue: 913 stars of magnitude < 4.5 from the HYG database v4.0 (CC BY-SA 4.0, astronexus/HYG-Database), `stars.json`, placed by RA/Dec, rotated by live sidereal time, colour from B-V |
| Night shade | computed live from the subsolar point |
| Position | live GPS / browser geolocation (watched continuously); Santandrei only as fallback, labelled `default` (web) / `FALLBACK` (watch) |
| HOME distance / bearing | computed (great circle) from the live position |
| Weather | fetched from Open-Meteo (free, no key), refreshed every 12 min and when you move; shows data age in minutes if older than 20 min |
| Battery | live: Battery API in the browser (`PWR --` where unsupported), WKInterfaceDevice on the watch |
| Radar sweep, grain, scanlines | decorative only, carry no data |

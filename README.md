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

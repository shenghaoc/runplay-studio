# DEM Elevation Correction

GPS altitude is noisy: on a flat route it wanders up and down by metres, and
every wiggle counts as climb. A digital elevation model (DEM) gives the height
of the ground itself. RunPlay Studio can correct a run's elevation from DEM
tiles **you download yourself** and keep in a folder on your Mac. The app only
reads that folder; it never downloads tiles and never sends a route anywhere.

## Getting tiles

RunPlay Studio reads **Terrarium PNG** tiles in the slippy-map `z/x/y.png`
layout (y counted from the north, not TMS):

```text
<your folder>/
  13/
    4265/
      2903.png
      2904.png
    4266/
      ...
  14/
    ...
```

Each tile is an 8-bit RGB (or RGBA) PNG whose side is a power of two,
normally 256 pixels. Height in metres is
`(R × 256 + G + B / 256) − 32768`, as defined in the Tilezen
[formats documentation](https://github.com/tilezen/joerd/blob/master/docs/formats.md).
Buffered variants (260 or 516 pixels, with two pixels of overlap on each
edge), GeoTIFF, WebP, and 16-bit or grayscale PNGs are not read.

One free source is **Terrain Tiles** on the
[AWS Registry of Open Data](https://registry.opendata.aws/terrain-tiles/): the
public bucket `elevation-tiles-prod` (us-east-1; an EU copy is
`elevation-tiles-prod-eu`), readable without an AWS account. Its Terrarium
tiles are 256 pixels, zoom 0–15, at
`https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png`
([service notes](https://github.com/tilezen/joerd/blob/master/docs/use-service.md)).
Download the tiles covering the places you run with whatever tool you like,
keeping the `z/x/y.png` structure, for example one tile:

```bash
mkdir -p ~/DEM/terrarium/13/4265
curl -o ~/DEM/terrarium/13/4265/2903.png \
  https://s3.amazonaws.com/elevation-tiles-prod/terrarium/13/4265/2903.png
```

### Which zoom

| Zoom | Pixel size at the equator | Pixel size at 45° latitude | Tile width at 45° |
|---|---|---|---|
| 12 | ≈ 38 m | ≈ 27 m | ≈ 6.9 km |
| 13 | ≈ 19 m | ≈ 13.5 m | ≈ 3.5 km |
| 14 | ≈ 9.6 m | ≈ 6.8 m | ≈ 1.7 km |

Zoom 13 or 14 suits running. Much of the underlying data is about 30 m, so a
finer zoom mostly multiplies the tiles a route needs. When a folder holds
several zooms, the app reads the finest zoom up to 14 unless you pick another
one in Settings.

One correction may decode 64 MiB of heights (256 tiles of 256 pixels). A route
needing more tiles at the chosen zoom is left uncorrected and says so. Each
zoom step down quarters the tiles an area needs and roughly halves the tiles
along a route.

### Attribution

The Terrain Tiles are assembled from many national and global datasets, each
with its own licence. The Tilezen
[attribution list](https://github.com/tilezen/joerd/blob/master/docs/attribution.md)
names them and the credit each one asks for. If you share images, videos, or
exports whose elevation came from these tiles, follow those terms.

## Using the folder

1. **Settings → Elevation → Choose Folder…** and pick the folder that holds the
   zoom directories. The app scans it, remembers it as a bookmark, and shows
   the zooms it found and the tile size. A folder without Terrarium tiles is
   refused with the expected layout.
2. **Correct new imports** is on by default once a folder is chosen: every
   import (file, watch folder, Strava archive, multi-session FIT) is corrected
   before it is saved, and the import summary says how much of the route the
   tiles covered.
3. **Correct Elevation of N Runs** corrects the runs already in your library.
   It never starts by itself. It shows progress, can be cancelled (runs
   corrected so far stay corrected), and resumes where it stopped. Runs that
   were only partly covered are checked again in later passes in case you
   added tiles.

**Workout ▸ Use Recorded Elevation** keeps one run's recorded altitude and
removes its DEM elevation; library passes then leave it alone. Unchecking it
corrects the run again. **Workout ▸ Correct Elevation** re-reads the folder for
one run, for example after adding tiles.

## How a run is corrected

- Every route point is sampled bilinearly from the four nearest pixel centres
  at the chosen zoom. A point whose tile is missing or unreadable, or whose
  pixels are transparent or outside −500…9,000 m, keeps its recorded altitude.
  A missing tile never fails an import.
- **Barometric altitude is kept.** A FIT file that declares an onboard
  barometric altimeter (a `device_info` message with a local barometer) keeps
  its recorded altitude, and DEM elevation only fills points where it is
  missing. Any other recorded altitude — GPS, or a GPX, TCX, or JSON file that
  does not say — is replaced wherever a tile covers the route, and the
  elevation note says so plainly. If such a file came from a barometric watch,
  choose Use Recorded Elevation for it.
- **A source switch is never climb.** Where the route moves between DEM and
  recorded altitude (at the edge of your tiles, or around a barometric gap),
  the elevation analysis starts a new run, exactly as at a recording pause. The
  height difference between the two sources is never counted as ascent or
  descent and never forms a climb or descent highlight. The elevation chart
  breaks its line there and dashes the fallback source.
- Corrected elevation feeds everything elevation feeds: ascent and descent,
  split gain, biggest climb and descent, the elevation chart, the 3D map
  height, elevation colouring, and the replay readout. Training load does not
  use altitude and is unchanged. The raw source totals kept for comparison stay
  over the recorded altitude.

The chart note under the Elevation metric names the source (DEM tiles,
barometric altimeter, recorded altitude with its sensor unknown, or a mix) and
lists what the correction did, including tile coverage. The JSON export's
`elevationSource` object carries the same facts.

## Limitations

- A DEM is the **bare ground**. On a bridge, pier, overpass, or in a tunnel the
  tiles report the ground or water beneath, and an indoor or treadmill run has
  no meaningful ground height. Use Recorded Elevation for such runs.
- Near coastlines and open water a pixel can mix land with the water or sea
  floor, so a shoreline route may dip.
- Detail is limited by the source data, about 30 m in many places: a short,
  steep rise can be smoothed away.
- Only Terrarium PNG is read. GeoTIFF and buffered tiles are not supported.

## Privacy

The folder is remembered as an opaque bookmark in `dem-tiles.json` beside your
workout library. Tiles are read from disk only; nothing is downloaded or
uploaded, and exports never identify the folder. See
[privacy.md](privacy.md#dem-elevation-tiles).

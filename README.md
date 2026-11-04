# Blink

A tiny macOS file viewer that opens instantly. One window per file, zoom in / out / fit / actual size, nothing else.

| Opens | How |
|---|---|
| jpg, png, tiff, avif, heic, gif, webp | ImageIO. Animated GIF / AVIF / APNG / HEICS play with their own frame timing; multi-page TIFFs show every page. |
| pdf | PDFKit, continuous scroll |
| csv / tsv | Grid with a header row and row numbers; quoted fields, `,` `;` or tab detected |
| eml / emlx | Headers, HTML or text body, inline images, attachments (click to open). Remote images are blocked until you click "Load Remote Images"; page scripts never run. |
| xlsx and other Office files | Apple's Quick Look renderer |
| gpx | Track, waypoints, distance, climb and time on OpenStreetMap tiles, or OpenTopoMap (contours, hillshade). Files with no extension are recognised by content. |
| mp4, mov, m4a, mp3 | AVKit player |
| md | Two columns: source on the left, GitHub-flavoured rendering (cmark-gfm) on the right. They scroll together and refresh when the file changes. |
| txt and anything else | Plain text |

Keys: ⌘+ / ⌘= zoom in, ⌘− zoom out, ⌘0 fit, ⌘1 actual size, ⇧⌘R show in Finder.

## Why it's fast

* AppKit with no nib, no NSDocument, no state restoration.
* The executable links only AppKit and ImageIO. PDFKit, WebKit, MapKit, AVKit and Quick Look live in `libBlinkViewers.dylib`, loaded the first time one of those files opens.
* It stays running. With no windows open it leaves the Dock and waits as a menu-bar icon (Open…, Open at Login, Quit), so later files open in ~0.2 s instead of a cold launch.

Measured on an M4 MacBook Air, macOS 26 (time from `open` to the window on screen):

| | Blink | Preview |
|---|---|---|
| Cold launch, jpg | ~0.6 s | ~1.0 s |
| Cold launch, pdf | ~0.6 s | ~1.2 s |
| Already running, jpg | ~0.23 s | ~0.64 s |

(A do-nothing AppKit app takes ~0.5 s through the same path, so cold launch is close to the floor.) `BLINK_TIMING=1` prints launch milestones to stderr.

## Build

```bash
./build.sh                                   # build, sign, install to /Applications/AI Apps
NOTARIZE=1 ./build.sh                        # also notarize + staple
swift tools/set-defaults.swift "/Applications/AI Apps/Blink.app"   # make Blink the default viewer
```

Map tiles © OpenStreetMap contributors; topo style © OpenTopoMap (CC-BY-SA). Tiles are cached in `~/Library/Caches/Blink/Tiles`. Requests identify Blink in their User-Agent, per the OSM tile policy.

## License

GPL-3.0

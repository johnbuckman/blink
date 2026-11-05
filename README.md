# Blink

A tiny macOS file viewer that opens instantly. One window per file, zoom in / out / fit / actual size, and an "Edit in …" button that hands the file to the app you edit it in.

| Opens | How |
|---|---|
| jpg, png, tiff, avif, heic, gif, webp | ImageIO. Animated GIF / AVIF / APNG / HEICS play with their own frame timing; multi-page TIFFs show every page. |
| pdf | PDFKit, continuous scroll |
| csv / tsv | Grid with a header row and row numbers; quoted fields, `,` `;` or tab detected |
| eml / emlx | Headers, HTML or text body, inline images, attachments (click to open). Remote images are blocked until you click "Load Remote Images"; page scripts never run. |
| xlsx | Cell values in a grid with Excel's column letters and row numbers, one tab per sheet (read directly, no Excel needed) |
| rtf, doc, docx | AppKit's own importers: fonts, styles, tables and pictures on a white page |
| xls, pptx, numbers, pages, key | Apple's Quick Look renderer |
| gpx | Track, waypoints, distance, climb and time on OpenStreetMap tiles, or OpenTopoMap (contours, hillshade). Files with no extension are recognised by content. |
| mp4, mov, m4a, mp3 | AVKit player |
| md | Two columns: source on the left, GitHub-flavoured rendering (cmark-gfm) on the right. They scroll together and refresh when the file changes. |
| txt, tcl, adp, js and anything else | Plain text |

Keys: ⌘+ / ⌘= zoom in, ⌘− zoom out, ⌘0 fit, ⌘1 actual size, ⌘E edit, ⌘K crop, ⇧⌘A arrows, ⌘S save with arrows, ⌘Z undo, ⇧⌘R show in Finder, ⌘Q close all windows (Blink keeps running in the menu bar; quit it from the menu-bar icon).

## Crop and arrows (pictures)

* **Crop:** drag on a picture to draw a rectangle. Drag its handles to resize it, drag inside it to move it, and press Esc to clear it. **Crop** (⌘K) saves just that part as `name-crop-1.jpg` (then `-crop-2` …) next to the original, in the original's format, and opens it.
* **Arrows:** turn on **Arrow** (⇧⌘A), then drag to draw an arrow. It curves gently outwards and is slightly see-through. Its colour is picked to stand out from what's under it, and differs from the other arrows' colours. Type straight away to label it: the label is written along the arrow and follows its curve, in black or white with a halo in the arrow's colour. A long label gets smaller, down to a readable minimum, and then wraps onto more lines. Return finishes the label, and ⌘Z takes arrows and labels back off. **Save** (⌘S) writes `name-arrows-1.jpg`, and a crop includes any arrows.
* **After saving:** the new file's full path is copied to the clipboard, ready to paste into a chat or a terminal.
* **For AI readers:** every saved file says in plain words what was done, including the original's full path so the two can be compared. For example: "Made in Blink from the original picture /Users/me/Pictures/harbour-sunset.jpg (3000x2000 px): cropped to 1720x1265 px, taken from x 34, y 307 of the original. Arrow 1 (green) starts at (202, 126) and points at (783, 986), with the label "the boat" written along it." This text goes in the EXIF UserComment, TIFF ImageDescription, IPTC Caption and PNG Description fields.

## Edit in …

The titlebar's Edit button (⌘E) opens the file in its editing app. The button is hidden when that app isn't installed. To change an app, edit the table in `Sources/Blink/Editor.swift`.

| Files | Edit in |
|---|---|
| Pictures | Photoshop |
| mp4, mov, m4v | Final Cut Pro |
| m4a, mp3, wav, aiff, flac | Audition |
| xlsx, xls, csv, tsv | Excel |
| rtf, doc, docx | Word |
| pptx · numbers · pages · key | PowerPoint · Numbers · Pages · Keynote |
| pdf | Illustrator |
| gpx | MapOut |
| md | MacDown |
| eml, txt, tcl, adp, js and other text | Sublime Text |

## Why it's fast

* AppKit with no nib, no NSDocument, no state restoration.
* The executable links only AppKit and ImageIO (and reads xlsx itself). PDFKit, WebKit, MapKit, AVKit and Quick Look live in `libBlinkViewers.dylib`, loaded the first time one of those files opens.
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
./build.sh                                   # build, sign (first Developer ID in the keychain), install
NOTARIZE=1 BLINK_NOTARY_PROFILE=<profile> ./build.sh   # also notarize + staple
swift tools/set-defaults.swift /Applications/Blink.app   # make Blink the default viewer
```

Map tiles © OpenStreetMap contributors; topo style © OpenTopoMap (CC-BY-SA). Tiles are cached in `~/Library/Caches/Blink/Tiles`. Requests identify Blink in their User-Agent, per the OSM tile policy.

## License

GPL-3.0

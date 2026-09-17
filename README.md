# Daisy — File Converter for Mac

**The converter that comes to you.** Hold Shift, drag a file, drop it on a petal.
Daisy puts a wheel of every format that file can become right where you are, and
converts it on your Mac — nothing is uploaded, ever.

Named for what it looks like: white petals around a yellow centre. The file
sits in the middle, every format it can become fans out around it.

[**Download 0.3.1**](https://github.com/ishanmalu/daisy/releases/latest) ·
[Site](https://ishanmalu.github.io/daisy/) · macOS 14+ · Universal · Free for noncommercial use

A menu-bar wheel and a `daisy` CLI over one conversion engine, with nine
converters bundled inside the app so it runs on a machine with nothing
installed. Swift + AppKit, SwiftPM, no Xcode; checks ship in the binary as
`Daisy --selftest`.

## What it does

**Convert** — drop files, pick a format petal (only the ones every dropped file
can produce):

| Class | Routes | Engine |
|---|---|---|
| Images | jpg png webp heic avif tiff bmp gif ↔ each other; svg → raster; raster → svg (trace) | ImageIO / cwebp / resvg / potrace |
| Audio | mp3 m4a aac wav flac ogg opus aiff ↔ each other | ffmpeg |
| Video | mp4 mov mkv webm avi m4v ↔ each other; → gif; → audio | ffmpeg |
| Documents | md html rtf txt epub docx odt ↔ each other; office → pdf; pdf → txt/docx | pandoc / LibreOffice / PDFKit |
| PDF | images → pdf; pdf → png/jpg/tiff | PDFKit |
| Archives | folder ↔ zip / tar / tar.gz / 7z; extract zip/tar/7z/rar → folder | bsdtar / 7zz |

**Tools** (hold ⌥, or Tab) — same-format edits that write a new file:
Resize · Compress · Crop-to-aspect · Strip metadata · Trim (A/V) ·
**OCR → searchable PDF** (Vision) · **Remove background** (VisionKit) ·
Merge PDF · Split PDF.

**Recipes** (Tab again) — saved multi-step pipelines (`web-image`, `square-jpg`,
`reel-to-mp4`, `clip-to-gif`, `scan-to-ocr-pdf`), editable in `recipes.json`.

**Watch folders** — anything dropped into a watched folder is converted (by
format or by recipe) and the original moved to `_processed/`. Runs in-process;
add them in Settings or `daisy watch add`.

**RAR creation is not supported** — no licensable RAR encoder. Use ZIP or 7z.

## HUD

A radial wheel, like Tangerine — the file in the hub, targets fanning out as
petals. Monochrome, keyboard-driven:

```
← → move    ↵ run    ⌥ Tools    ⇥ cycle Convert / Tools / Recipes    esc
```

**⌥⇧V** pops the wheel wherever the pointer is — permission-free, via a Carbon
hotkey. If files are on the clipboard it loads them; otherwise drag one from
Finder straight onto the ring. A `DragMonitor` also tries to summon it mid
Shift-drag from Finder, where the OS allows a global mouse monitor
(`Daisy --drag-probe` tells you). It also opens from the menu bar or the
"Convert with Daisy…" Finder Service. Runs happen on a background queue with a
progress readout and auto-dismiss on success.

## Site

[ishanmalu.github.io/daisy](https://ishanmalu.github.io/daisy/) — served from
`docs/`. The hero wheel is live SVG built from the same geometry the app draws.

## Build from source

```sh
swift run Daisy --selftest             # 50 graph + logic checks
Scripts/build-app.sh 0.3.0             # -> dist/Daisy.app  (add --universal for arm64+x86_64)
Scripts/make-dmg.sh 0.3.0             # -> dist/Daisy-0.3.0.dmg
open dist/Daisy.app                    # menu-bar icon -> Open Wheel / Settings
```

## CLI

```sh
daisy convert photo.png --to webp --quality 80
daisy convert *.jpg --to pdf --out ~/Desktop
daisy convert in.png out.avif                     # target inferred from the name
daisy convert shot.png --preset web-jpg           # saved preset
daisy tool resize clip.mov --preset "½"
daisy tool ocr scan.png                           # -> scan-ocr.pdf, searchable
daisy tool removeBackground portrait.jpg          # -> portrait-nobg.png
daisy merge a.pdf b.pdf ; daisy split book.pdf
daisy recipe square-jpg *.png
daisy watch add ~/Dropbox/Incoming --to webp
daisy presets ; daisy recipes ; daisy formats ; daisy info movie.mkv
```

## Intel Macs

The app is a universal binary and every native route — images through ImageIO,
images ↔ PDF, PDF pages, OCR, background removal, resize/crop/compress, and
folder ↔ zip/tar via the system `bsdtar` — works on Intel with nothing else
installed.

The nine bundled engines are arm64 only: Homebrew no longer publishes x86_64
bottles for pandoc, qpdf or sevenzip, so a fully bundled universal build can't
be assembled. `EngineLocator` reads each Mach-O header and skips any slice it
can't run, so on Intel it falls straight through to `/usr/local/bin`. To light
up video, audio, WebP, SVG and documents there:

```sh
brew install ffmpeg webp resvg potrace unar qpdf sevenzip pandoc
```

## Using it

Hold **⇧** and drag a file out of Finder, or press **⌥⇧V** — the wheel appears
dead centre. Drop on a petal, or arrow to one and press ↵. With nothing loaded
the ring is a button: click it (⌘O, or the menu bar's **Convert File…**) and
Finder's picker opens.

Drop **several files** and pick a format that can hold all of them — PDF —
and Daisy asks which you meant: **one PDF** of N pages, or **N separate PDFs**.
Pages come out in filename order, because a multi-file drop arrives in whatever
order the source app hands over. A single file never asks, and a set that can
only be combined (a pile of PDFs) merges without asking.

Drop a **folder** and you get both readings of it — every convertible file
inside becomes a batch, and the folder's own archive targets stay on the wheel.
So a folder of 40 photos is one click to WebP, or one click to ZIP.

**⌥** swaps Convert for Tools, **⇥** cycles Convert / Tools / Recipes, **esc**
closes.

## Bundled engines

The app finds Homebrew copies on a dev machine. For a self-contained `.app`
(engine dir ~20 MB):

```sh
brew install webp qpdf sevenzip unar resvg
Scripts/bundle-engines.sh             # copies the binaries, then collect-dylibs.py
                                      #   vendors the dylibs into Resources/engine/libs/
                                      #   and rewrites install names to @loader_path
Scripts/build-app.sh 0.6.1
```

The bundled set is deliberately GPL-free, so the DMG carries no source-offer
obligation: cwebp (BSD-3), qpdf (Apache-2.0), resvg (MPL-2.0), 7zz and unar
(LGPL, shipped as replaceable dylibs). ffmpeg, pandoc and potrace are GPL and
libvips's bottle hard-links libfftw3 and libimagequant, so none of them are
bundled — install them with Homebrew and Daisy picks them up off `PATH`.

WebP is the one raster format macOS decodes but won't encode, so cwebp stands
in; everything else runs on ImageIO, PDFKit and Vision. `Scripts/collect-dylibs.py`
is a small deterministic stand-in for `dylibbundler` (walks `otool -L`, copies,
`install_name_tool`s, strips package-manager rpaths).

**LibreOffice** is bring-your-own: install it under `/Applications` (or drop a
copy in `~/Library/Application Support/Daisy/engine/`) and Office↔PDF fidelity
conversions light up. Never auto-downloaded.

Engine licenses live in `LICENSES/`.

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free to use, copy, modify and share
for anything that isn't commercial. Read the source, build it yourself, send a
patch. If you want it inside a business, ask me.

Bundled engines keep their own licenses; see `LICENSES/NOTICE.md`.

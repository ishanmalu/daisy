# Changelog

## 0.9.0

- **Several files into one PDF.** Drop three photos, pick PDF, and Daisy now
  asks what you meant: **one PDF** of three pages, or **three separate PDFs**.
  It always quietly assumed the second; combining existed only under ⌥ as Merge
  PDF, which is not where anyone looks for it. Any number of files — 40 photos
  into a 40-page PDF works the same way.
- Pages come out in **filename order** (`img2` before `img10`). A multi-file
  drop arrives in whatever order the source app hands over, which for Finder is
  selection order — invisible and not something you can control.
- It only asks when both readings are real. One file never asks. A set that can
  *only* be combined — a pile of PDFs, or images mixed with PDFs, where
  PDF→PDF is not a conversion — merges straight away. And PDF now appears on
  the wheel for those sets at all, which it previously could not, since it was
  never a conversion route for them.
- Merging goes through the same code the ⌥ Merge PDF tool uses, so both routes
  produce identical output and identical naming.

## 0.8.1

- **Fixed: the wheel kept re-presenting the file you just converted.** Summoning
  it loaded whatever file URL happened to be on the clipboard, and copying a
  file is how most people get one in — so every summon after a conversion put
  the same file straight back in the middle, and it looked like the wheel never
  let go. The wheel now always opens empty. Pasting is still one keystroke, it
  just has to be asked for, and the empty ring says so: **⌘V paste**.

## 0.8.0

- **Fixed: Quit did nothing.** Every menu item was pointed at the app delegate,
  including Quit, whose action was `NSApplication.terminate(_:)`. AppKit greys
  out any item whose target cannot perform its action, so Quit was silently
  disabled. `--selftest` now asserts that every menu item can actually fire its
  action, and that check fails against the old wiring.
- **Updates from Settings.** Settings shows the current version with a button
  that checks GitHub Releases and turns into Update when there is a newer one,
  plus an opt-in daily background check. Also in the menu bar as
  **Check for Updates…**.
- Nothing installs without two independent checks: the download must match the
  SHA-256 published with the release (a release without one is refused, not
  trusted), and the app inside must satisfy the running app's own code-signing
  requirement. Ad-hoc builds can never satisfy that — their requirement pins
  the exact code hash — so they verify the image and reveal it in Finder for
  you to install by hand. Automatic in-place updates start working the day
  Daisy is signed with a Developer ID.
- Only GitHub hosts are ever contacted or opened; URLs read out of the release
  JSON are checked against an allowlist rather than trusted.
- `make-dmg.sh` now writes `dist/SHA256SUMS.txt` alongside the image. It has to
  ship with the release or the updater refuses the download.
- New `--update-check` diagnostic prints what the updater sees.

## 0.7.1

- **Fixed the ring that cut around the wheel while it opened.** A window's drop
  shadow is derived from the shape of its content and is not recomputed while
  that shape is still moving, so growing or scaling the disc left a hard ring of
  stale shadow hanging outside it for the whole animation — and
  `invalidateShadow()` on every frame did not keep up either. The disc now keeps
  a fixed shape throughout; its arrival is carried entirely by what happens
  inside the glass. Scaling the blur with a layer transform had the same class
  of problem for a different reason: it resamples a blur that has already been
  captured, which leaves a visibly cut edge.
- **The opening is a bloom now, in phases.** The glass fades up first as a stage
  to arrive on, the centre pops out of it, then the petals sweep open on a 19ms
  stagger — each one growing outward *and* turning into place, all the same way,
  so the wheel unwinds rather than the petals simply getting longer. Labels are
  clipped to their own petal, so none can ghost outside one that is still
  growing.
- The rim light around the edge is smaller and much shorter — a catch of light
  as the flower opens rather than a halo thrown across the desktop.

## 0.7.0

- **Menu-bar icon is a five-petal daisy.** The eight-petal app mark closes into
  a cog at 18pt; five petals around a punched centre still read as a flower.
- **The wheel unfurls.** Petals grow outward from the hub on a 35ms stagger with
  a slight overshoot, labels fading up behind them, the hub popping first. The
  same unfurl replays on ⌥ and ⇥, so a mode change reads as the wheel turning
  over rather than blinking.
- **Close button** on the disc's top-right shoulder — in the margin rather than
  on the glass, where it would sit on a petal. Works mid-conversion: the job
  carries on, the wheel gets out of the way. `esc` still does the same thing.
- **Everything eases now.** Hover, focus and progress are spring-driven instead
  of switching instantly; a petal warms up and reaches outward under the cursor;
  a sweep runs the rim while a job converts and throws one ring off it when the
  job lands; the empty ring's dashes turn slowly so it looks like it is waiting.
  Closing fades and shrinks instead of cutting to nothing.
- **Drag feedback.** The targeted petal reaches further toward the cursor, three
  dots march from the hub out along it, and the cursor carries a ring that
  tightens and inverts once it locks on.
- All of it runs off one display link that stops the moment the springs settle,
  so an idle wheel costs nothing.
- Fix: `build-app.sh` used `-Xswiftc -target` for its two single-arch builds. The
  Swift Build backend keeps its own host target and appends that one, so the
  link step got two conflicting targets and died. It uses `--arch` now.

## 0.6.1

- **The wheel blooms open.** A ring of accent light flares past the rim and
  burns off in about half a second as the disc scales up. It's a ring rather
  than a filled glow because the disc is opaque — a bloom that peaks in the
  middle is hidden behind it, so the light peaks at the rim instead. The window
  grew from 300 to 360pt to give it somewhere to go, and the blur, which carries
  the circular mask, moved into an unmasked container: anything parented to a
  masked view gets clipped by that mask too.
- **Bloom on the site as well**, on scroll reveal — a brief brightness-and-blur
  on each block plus a radial wash behind it. Code blocks are excluded; blurred
  monospace is just mush.
- **Contrast pass.** Every text node on the site now clears WCAG AA. `--faint`
  was 3.31:1 against the page and used all over, and the download button's
  subtitle was 3.66:1 dark-on-yellow. Both fixed, along with the footer tagline
  and the coffee link.
- Fix: the formats section still claimed nine engines are bundled and that
  nothing needs installing. Neither has been true since 0.4.0.

## 0.6.0 — Daisy

Kuori is now **Daisy**. The name was a Finnish pun on *peel*, inherited from
being a Tangerine alternative; the wheel long ago stopped being citrus and
became a ring of petals around a centre, so the name now describes the thing
itself.

- **White petals, yellow centre.** The petals are near-opaque on purpose — a
  translucent white over a dark desktop turns grey, and grey petals aren't a
  daisy — so the glass shows in the gaps between them and around the rim. The
  centre is a vertical gradient rather than a flat fill, and the progress pill
  inverts to accent-on-dark because it sits on top of it.
- Icon and menu-bar glyph redrawn from the wheel's own geometry, so the mark and
  the UI can't drift apart.
- Everything renamed: `daisy` on the command line, `com.ishanmalu.daisy`,
  `~/Library/Application Support/Daisy`, the hotkey's four-char code. **An
  existing install keeps its config under the old Kuori folder** — this is a
  fresh directory, not a migration. Copy `presets.json`, `recipes.json` and
  `watch.json` across if you had any.
- `--demo` takes `tools` / `recipes` too, which is how the site screenshots are
  taken.

## 0.5.0

- **Click to choose.** The empty ring is a button now: click it (or press ↵, or
  ⌘O) and Finder's own picker opens. Dragging is still the fast path, but the
  wheel no longer requires knowing about Shift-drag to be usable. New menu-bar
  item, **Convert File…**, does both in one step.
- **Folder drops do the obvious thing.** Drop a folder of photos and the wheel
  offers image targets for everything inside it *and* the archive targets for
  the folder itself — convert 40 images, or zip the folder, from the same wheel.
  Shallow, name-ordered, hidden files and subfolders skipped.
- **Liquid glass.** The wheel is a real behind-window blur clipped to the disc,
  with a lit top rim and a shaded underside so the edge reads as thick. Petals
  are translucent with their own specular edge; the hub is denser so a thumbnail
  has something to sit on. It rises into place with a short spring rather than
  blinking on.
- The empty ring warms its dashed edge and takes a pointing-hand cursor when the
  mouse is over it.
- `InputSet` lifts folder-expansion policy out of the view, where it's testable;
  nine new checks cover it. 63 in total.
- New `--demo <files…> [light|dark]` holds the wheel open over the live desktop.
  `--shot-ui` caches the view offscreen, which a behind-window blur can't
  survive, so this is the only way to see the real thing.

## 0.4.0

- **Licence: PolyForm Noncommercial 1.0.0.** Daisy is free to use, read, modify
  and pass around for anything that isn't commercial. Commercial use is a
  conversation, not a download.
- **The bundle is GPL-free.** ffmpeg, pandoc and potrace are gone from the DMG
  (GPL-3 / GPL-2), and so is libvips — its bottle hard-links libfftw3 (GPL-2)
  and libimagequant (GPL-3), and removing either dylib stops vips loading at
  all. Daisy still finds every one of them on `PATH`; only redistribution
  changed. `Resources/engine` went 350 MB → 20 MB.
- **cwebp (BSD-3) replaces vips for WebP**, the one raster format macOS decodes
  but won't encode. Any input ImageIO can read is staged through a temp PNG
  first, so HEIC → WebP and friends still work, with quality, resize, EXIF
  preservation and `--strip` all behaving as before.
- `Scripts/collect-licenses.sh` walks the formulae behind the bundle and writes
  `LICENSES/NOTICE.md` — component, SPDX identifier, upstream — plus the licence
  texts themselves.
- Fix: `brew install` hints in engine-missing errors now name the formula rather
  than the binary (`webp`, not `cwebp`).

## 0.3.1

- Universal binary — the app now carries both arm64 and x86_64 slices.
- `EngineLocator` reads each engine's Mach-O header and skips slices it can't
  run, so the arm64 bundled engines are ignored on Intel and the search falls
  through to `/usr/local/bin` instead of trying to exec something that can't
  start. Applies to all three lookup tiers.
- Verified by running the x86_64 slice under Rosetta: 54/54 checks, bundled
  engines correctly skipped, native routes (ImageIO, PDFKit, Vision, bsdtar)
  all still converting.

## 0.3.0

- **Radial HUD**, à la Tangerine: the source file sits in the hub and the
  targets fan out as rounded citrus-segment petals. Click a petal, or arrow to
  it and press ↵. Icons on tool petals. ⌥ swaps Convert → Tools; ⇥ cycles
  Convert / Tools / Recipes; a tool with presets opens its presets as a
  sub-wheel (esc backs out). Still one ink / one paper, light + dark.
- **Bundled engines**: `Scripts/collect-dylibs.py` (a deterministic
  dylibbundler replacement) vendors ffmpeg, ffprobe, vips, qpdf, 7zz, unar,
  resvg, potrace and pandoc plus ~86 dylibs into `Resources/engine/`, rewriting
  every install name and stray rpath to `@loader_path`. `Daisy.app` now runs
  every route with nothing on `PATH` (verified: webp/avif/heic/svg-trace/gif,
  md→html/docx/rtf, OCR, resize). DMG ≈ 101 MB.
- HEIC/AVIF (both directions) route to macOS ImageIO — the vips bottle has no
  libheif module.
- Bundled binaries launch with `GIO_MODULE_DIR` etc. pointed away from any
  Homebrew glib, so vips never cross-loads a second libgio.
- Fix: `Converter.execute` is now a protocol requirement, so multi-step routes
  (e.g. `md → html`) dispatch to `DocConverter` instead of the no-op default.

- **Documents**: pandoc for md/html/rtf/txt/epub/docx/odt round-trips;
  LibreOffice (bring-your-own) for Office ↔ PDF fidelity; PDF → txt native.
  pptx/xlsx/odp/ods registered. Multi-step routes (Markdown → PDF) handled in
  `DocConverter.execute`.
- **Presets** (`Presets`, `presets.json`): named format + options, `daisy
  convert --preset`, `daisy presets`. Six built-ins.
- **Recipes** (`Recipe` / `RecipeRunner`, `recipes.json`): ordered convert/tool
  pipelines chained through temp files. `daisy recipe`, HUD Recipes mode. Five
  built-ins.
- **Watch folders** (`WatchFolders`, FSEvents, in-process): auto-convert new
  files by format or recipe, move originals to `_processed/`. `daisy watch
  add|list|remove|run`, Settings table.
- **Native tools**: OCR → searchable PDF (Vision text layer, invisible), Remove
  background (VisionKit foreground mask → transparent PNG).
- **Settings window**: login toggle (`SMAppService`), watch-folder editor,
  presets/recipes JSON shortcuts.
- **HUD**: Tab now cycles Convert → Tools → Recipes.
- **Distribution**: `build-app.sh --universal`, `make-dmg.sh`, `notarize.sh`,
  GitHub Actions CI on `macos-15`.
- 48 self-test checks.

## 0.2.0

- **Tools** (`⌥` in the HUD / `daisy tool …`): Resize, Compress, Crop-to-aspect,
  Strip metadata, Trim (A/V), Merge PDF, Split PDF — same-format edits that write
  a new file (`name-resized.jpg`). Presets (¼ / ½ / ≤1920 …, Light/Medium/Strong,
  1:1 / 4:5 / 16:9 / 9:16).
- **Raster → SVG** trace: potrace fed a PGM that `NativeOps` rasterizes
  in-process, so it works without libvips.
- **PDF**: merge (PDFs + images), split (page per file), compress (downsample +
  rebuild), strip metadata — all via PDFKit, no binaries.
- **HUD redesign**: frameless card, keyboard-driven (arrows move · ↵ run · ⌥
  Tools · Tab locks mode · esc close), category-grouped format tiles, a thin
  progress bar, auto-dismiss on success. Still one ink / one paper.
- `daisy tool|merge|split` on the CLI; `Daisy --shot-ui <png> [dark] [tools]`.

## 0.1.0

First working slice.

- Conversion engine with a declarative capability graph (`Sources/Daisy/Core/Engine.swift`).
- Converters: images (libvips + ImageIO fallback), audio/video (ffmpeg),
  video → GIF, images ↔ PDF (PDFKit), folder ↔ zip/tar/tar.gz/7z, archive extraction.
- `daisy` CLI: `convert`, `formats`, `info` — same path the GUI uses.
- Menu-bar app with a floating Drop Zone; multi-file drops offer the intersection
  of each file's routes. Finder Services entry ("Convert with Daisy…").
- `Daisy --selftest`: format resolution, graph integrity, argument builders,
  output naming/collision, engine availability report.
- `Scripts/build-app.sh` (arm64, ad-hoc signed), `Scripts/bundle-engines.sh`
  (dylib relocation), `Scripts/makeicon.swift` (icon drawn in code).
- RAR creation explicitly refused (no licensable encoder).

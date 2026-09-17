import AppKit
import UniformTypeIdentifiers

/// The radial wheel. The source file sits in the hub, targets fan out as petals.
/// Drop a file onto a petal, or move with the arrow keys and press return.
/// ⌥ swaps Convert for Tools; ⇥ cycles Convert / Tools / Recipes.
final class DropPanel: NSPanel {
    static let shared = DropPanel()

    private let hud = WheelHUD()

    /// The window is deliberately larger than the disc. The extra ring is where
    /// the opening bloom and the drop shadow live — at the old 300pt both were
    /// clipped flat against the window edge.
    static let side: CGFloat = 360

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        // The wheel is glass: a live blur of the desktop behind it, clipped to
        // the disc, with the HUD's own translucent fills painted on top. The
        // mask is what keeps the blur circular — a rounded-rect layer mask
        // would be ignored by the behind-window blur.
        let bounds = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.circleMask(side: Self.side, diameter: WheelHUD.discDiameter)

        // An unmasked container holds everything. The blur has to carry the
        // circular mask itself, and anything parented to it gets clipped by that
        // mask too — which is where the bloom went the first time.
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.addSubview(blur)
        hud.frame = bounds
        container.addSubview(hud)
        contentView = container
        hud.owner = self
    }

    /// A circle of `diameter` centred in a `side` square. Fixed size with no cap
    /// insets: the window never resizes, and stretching a circle that has to stay
    /// concentric with the drawing on top of it is asking for a seam.
    private static func circleMask(side: CGFloat, diameter d: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            let o = (side - d) / 2
            NSBezierPath(ovalIn: NSRect(x: o, y: o, width: d, height: d)).fill()
            return true
        }
    }

    override var canBecomeKey: Bool { true }

    func toggle() { isVisible ? orderOut(nil) : summon() }

    /// Hotkey / menu summon. Always an empty ring.
    ///
    /// It used to load whatever file URL happened to be on the clipboard. That
    /// reads as a bug rather than a shortcut: copying a file is how most people
    /// get one into the wheel, so every summon after a conversion silently
    /// re-presented the file just converted, and it looked like the wheel never
    /// let go of it. Pasting is still one keystroke, it just has to be asked
    /// for now.
    func summon() {
        centreOnScreen()
        present()
    }

    func showCentered() { centreOnScreen(); present() }

    /// The wheel always lands dead centre of the active screen — one place to
    /// look for it, and a drag always has the same distance to travel.
    private func centreOnScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: (vf.midX - frame.width / 2).rounded(),
                               y: (vf.midY - frame.height / 2).rounded()))
    }

    private func present() {
        let fresh = !isVisible
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(hud)
        if fresh { playEntrance() }
    }

    /// A short rise into place with a bloom: the flower's own yellow flares out
    /// past the rim and burns off while the disc scales up. The glow lives in a
    /// layer of its own so it can overflow the disc — which is the whole reason
    /// the window is bigger than the wheel.
    private func playEntrance() {
        hud.playEntrance()
        guard let content = contentView, let layer = content.layer else { return }

        // The disc never changes shape while it opens. A window shadow is
        // derived from the content's shape and does not track a shape that is
        // still moving, so a growing or scaling disc drags a hard ring of stale
        // shadow around outside itself for the whole animation. Fading the
        // window brings the shadow up with it; the arrival is carried by what
        // happens inside the glass.
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 1
        }

        playBloom(on: layer, in: content.bounds)
    }

    /// A quick catch of light around the rim as the flower opens. Small and
    /// brief on purpose: it hugs the edge rather than throwing a halo across
    /// the desktop, and it is gone before the petals finish landing.
    private func playBloom(on layer: CALayer, in bounds: CGRect) {
        let r = WheelHUD.discDiameter / 2 + 17
        let bloom = CALayer()
        bloom.frame = CGRect(x: bounds.midX - r, y: bounds.midY - r, width: r * 2, height: r * 2)
        bloom.contents = Self.bloomImage(diameter: r * 2)
        bloom.opacity = 0

        let life = 0.26
        let flare = CAKeyframeAnimation(keyPath: "opacity")
        flare.values = [0, 0.5, 0]
        flare.keyTimes = [0, 0.30, 1]
        flare.duration = life
        let spread = CABasicAnimation(keyPath: "transform.scale")
        spread.fromValue = 0.92
        spread.toValue = 1.05
        spread.duration = life
        spread.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bloom.add(flare, forKey: "flare")
        bloom.add(spread, forKey: "spread")
        layer.addSublayer(bloom)
        DispatchQueue.main.asyncAfter(deadline: .now() + life) { bloom.removeFromSuperlayer() }
    }

    /// The bloom is a ring, not a filled circle. The disc is opaque, so a glow
    /// that peaks in the middle is almost entirely hidden behind it — the light
    /// has to peak where the rim is and fall away outwards.
    ///
    /// `NSGradient`'s radial draw rather than a `CAGradientLayer` because the
    /// layer version bands visibly at this size.
    private static func bloomImage(diameter d: CGFloat) -> CGImage? {
        let rimStop = (WheelHUD.discDiameter / 2) / (d / 2)
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            NSGradient(colors: [Theme.accent.withAlphaComponent(0),
                                Theme.accent.withAlphaComponent(0.25),
                                Theme.accent.withAlphaComponent(0.85),
                                Theme.accent.withAlphaComponent(0)],
                       atLocations: [0, rimStop - 0.08, rimStop, 1],
                       colorSpace: .sRGB)?
                .draw(fromCenter: mid, radius: 0, toCenter: mid, radius: rect.width / 2,
                      options: [])
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// From the menu, Services, or a paste — an interactive open.
    func load(urls: [URL]) {
        showCentered()
        hud.accept(urls)
    }

    private var dragDismiss: DispatchWorkItem?

    /// From `DragMonitor`: a Shift-drag is in progress somewhere. Appear in the
    /// middle without taking focus, so the drag keeps running. The HUD reads the
    /// dragged files once the drag enters it; if none does, we vanish.
    func beginDrop() {
        centreOnScreen()
        hud.armForDrag()
        orderFront(nil)

        // Mouse-up is what really dismisses this; the timer is only a backstop
        // for a drag whose release we never see.
        dragDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissIfDragSummoned() }
        dragDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func cancelDragDismiss() { dragDismiss?.cancel(); dragDismiss = nil }

    func dismissIfDragSummoned() {
        if hud.dragSummoned { hud.dragSummoned = false; orderOut(nil) }
    }

    /// Fade and shrink out. `orderOut` on its own is a hard cut, which reads as
    /// a glitch next to an entrance that takes half a second.
    func dismiss() {
        guard isVisible, !dismissing else { return }
        dismissing = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            self.dismissing = false
        }
    }

    private var dismissing = false

    /// Menu-bar "Convert File…": the wheel plus Finder's picker in one step.
    func summonAndChoose() {
        showCentered()
        hud.chooseFiles()
    }

    /// `--shot-ui` only.
    func previewMode(_ name: String) { hud.forceMode(name) }
}

private struct WheelItem {
    let title: String
    let symbol: String?
    let run: () -> Void
}

private final class WheelHUD: NSView {
    weak var owner: DropPanel?
    var dragSummoned = false

    private enum Mode: CaseIterable { case convert, tools, recipes }
    private var stickyMode: Mode?
    private var optionHeld = false
    private var mode: Mode { optionHeld ? .tools : (stickyMode ?? .convert) }

    private var inputs: [URL] = []
    private var formats: [Format] = []
    private var thumb: NSImage?
    private var items: [WheelItem] = []
    private var focus = 0
    private var hover: Int?
    private var presetParent: Tool?
    /// Set while the wheel is asking whether to fold several inputs into one
    /// file of this format, or convert each separately.
    private var combineTarget: Format?
    /// Set when `inputs` came from expanding a dropped folder.
    private var folderInput: URL?
    /// Cursor is over the empty ring, which is one big button.
    private var hoveringEmpty = false
    private var running = false
    private var progress = 0.0
    private var errorText: String?
    private var errorClear: DispatchWorkItem?

    // MARK: motion
    //
    // Nothing in the wheel animates itself — it is one drawn view. A display
    // link advances every moving quantity once per frame and stops as soon as
    // they all settle, so an idle wheel costs nothing.

    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// Per-petal hover weight, 0…1. Indexed alongside `items`.
    private var petalHeat: [Spring] = []
    /// Eased stand-in for `progress`, so the arc sweeps instead of jumping.
    private var shownProgress = Spring()
    /// Warmth of the empty ring and of the close button under the cursor.
    private var emptyHeat = Spring()
    private var closeHeat = Spring()
    /// The wheel unfurling on summon, and the flash when a job lands.
    private var entrance = Clock(duration: 0.78)
    private var success = Clock(duration: 0.72)
    /// A drag is currently over the wheel: petals lean toward the cursor.
    private var dragActive = false
    private var dragPoint: CGPoint?
    private var closeHover = false

    static let discDiameter: CGFloat = 286

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private let discR: CGFloat = 143
    private let hubR: CGFloat = 44
    private let innerR: CGFloat = 50
    private let outerR: CGFloat = 134
    private var midR: CGFloat { (innerR + outerR) / 2 }
    private let petalGap: CGFloat = 0.10

    override init(frame f: NSRect) {
        super.init(frame: f)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    // MARK: ticker

    /// Wake the display link. Cheap to call repeatedly — it no-ops while running.
    private func animate() {
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let l = displayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        // A dropped frame must not be integrated in one step, or the springs
        // overshoot wildly on the frame after a stall.
        let dt = CGFloat(min(1.0 / 30, max(1.0 / 240, now - lastTick)))
        lastTick = now

        while petalHeat.count < items.count { petalHeat.append(Spring()) }
        if petalHeat.count > items.count { petalHeat.removeLast(petalHeat.count - items.count) }

        let lit = hover ?? focus
        for i in petalHeat.indices {
            petalHeat[i].target = (i == lit && !items.isEmpty) ? 1 : 0
            petalHeat[i].step(dt)
        }
        shownProgress.target = CGFloat(progress)
        shownProgress.step(dt)
        emptyHeat.target = hoveringEmpty ? 1 : 0
        emptyHeat.step(dt)
        closeHeat.target = closeHover ? 1 : 0
        closeHeat.step(dt)

        needsDisplay = true

        // The empty ring's dashes turn continuously, so it is the one state
        // that keeps the link alive on purpose. It is also the state you only
        // ever see for a few seconds, with the panel deliberately on screen.
        let idleBreathing = inputs.isEmpty && (window?.isVisible ?? false)
        let springsSettled = petalHeat.allSatisfy(\.settled)
            && shownProgress.settled && emptyHeat.settled && closeHeat.settled
        if springsSettled && !entrance.running && !success.running && !idleBreathing {
            link?.invalidate()
            link = nil
        }
    }

    /// Called by the panel as it comes on screen.
    func playEntrance() {
        entrance.start()
        petalHeat.indices.forEach { petalHeat[$0].snap(to: 0) }
        animate()
    }

    /// The opening is a bloom, and the order matters: the glass arrives first
    /// so there is something for the flower to sit on, the centre pops out of
    /// it, and the petals swing open last. The phases overlap heavily — played
    /// in sequence this reads as three animations rather than one.

    /// Normalised time into a phase starting at `at`, lasting `over`.
    private func phase(_ at: Double, _ over: Double) -> CGFloat? {
        guard let e = entrance.elapsed else { return nil }
        return CGFloat((e - at) / over)
    }

    /// The glass fading up. Quick — it is the stage, not the performance.
    private var discAppear: CGFloat {
        guard let t = phase(0, 0.20) else { return 1 }
        return Ease.out(t)
    }

    private var hubAppear: CGFloat {
        guard let t = phase(0.06, 0.34) else { return 1 }
        return Ease.outBack(t, 1.9)
    }

    /// 0…1 for petal `i`. A tight stagger: wide enough to read as a sweep
    /// around the wheel, close enough that they are all in the air at once.
    private func petalAppear(_ i: Int) -> CGFloat {
        guard let t = phase(0.11 + 0.019 * Double(i), 0.38) else { return 1 }
        return Ease.outBack(t, 1.25)
    }

    /// Each petal turns into place as it grows, all the same way, so the wheel
    /// unwinds instead of the petals merely getting longer.
    private func petalSwing(_ i: Int) -> CGFloat {
        guard let t = phase(0.11 + 0.019 * Double(i), 0.44) else { return 0 }
        return (1 - Ease.out(t)) * 0.20
    }

    // MARK: contents

    func accept(_ urls: [URL]) {
        let (resolved, folder) = InputSet.expand(urls)
        guard resolved != inputs || folder != folderInput else { return }
        folderInput = folder
        inputs = resolved
        formats = resolved.compactMap { Formats.byURL($0) }
        thumb = resolved.count == 1 ? Self.thumbnail(resolved[0], side: hubR * 2)
              : folder.flatMap { Self.thumbnail($0, side: hubR * 2) }
        presetParent = nil
        combineTarget = nil
        running = false
        progress = 0
        rebuild()
    }

    /// Shown by `DragMonitor` before we know what's being dragged.
    func armForDrag() {
        resetIdle()
        dragSummoned = true
    }

    /// A conversion failed — say so on the wheel rather than only beeping.
    /// The petals stay put so the same drop can be retried.
    private func showError(_ message: String) {
        errorText = message
        needsDisplay = true
        errorClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.errorText = nil; self?.needsDisplay = true }
        errorClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    /// Back to the empty ring — after a conversion, or before a new drag.
    private func resetIdle() {
        errorClear?.cancel()
        errorText = nil
        inputs = []
        formats = []
        thumb = nil
        items = []
        presetParent = nil
        combineTarget = nil
        folderInput = nil
        hover = nil
        focus = 0
        running = false
        progress = 0
        dragSummoned = false
        hoveringEmpty = false
        needsDisplay = true
    }

    fileprivate func forceMode(_ name: String) {
        stickyMode = ["tools": .tools, "recipes": .recipes][name]
        rebuild()
    }

    private func cycleMode() {
        let order = Mode.allCases
        stickyMode = order[(order.firstIndex(of: stickyMode ?? .convert)! + 1) % order.count]
        presetParent = nil
        combineTarget = nil
        rebuild()
    }

    private func rebuild() {
        guard !inputs.isEmpty else { needsDisplay = true; return }
        // A new set of petals unfurls the same way the first set did, which is
        // what makes ⌥ and ⇥ read as the wheel changing rather than blinking.
        entrance.start()
        animate()
        switch mode {
        case .convert: items = combineTarget.map(combineItems) ?? convertItems()
        case .tools:   items = presetParent.map(presetItems) ?? toolItems()
        case .recipes: items = recipeItems()
        }
        focus = min(focus, max(0, items.count - 1))
        needsDisplay = true
    }

    private func convertItems() -> [WheelItem] {
        let routes = inputs.map { url -> Set<String> in
            guard let f = Formats.byURL(url) else { return [] }
            return Set(Engine.targets(for: f).map(\.id))
        }
        var shared = routes.dropFirst().reduce(routes.first ?? []) { $0.intersection($1) }
        // An expanded folder can still be packed as a whole.
        if folderInput != nil, let folder = Formats.byID["folder"] {
            shared.formUnion(Engine.targets(for: folder).map(\.id))
        }
        // A format that can hold several inputs at once belongs on the wheel
        // even when it is not a conversion route for them: PDF is never a
        // target for a PDF, so without this a pile of PDFs could only be
        // merged from under ⌥, which is not where anyone looks for it.
        let convertible = shared
        for f in Formats.list where !shared.contains(f.id) {
            if Combine.offered(to: f, from: formats, count: inputs.count) { shared.insert(f.id) }
        }

        return shared.compactMap { Formats.byID[$0] }
            .filter { $0.id != "folder" || inputs.allSatisfy { Formats.byURL($0)?.category == .archive } }
            .sorted { ($0.category.rawValue, $0.label) < ($1.category.rawValue, $1.label) }
            .map { fmt in
                WheelItem(title: fmt.label, symbol: nil) { [weak self] in
                    guard let self else { return }
                    guard Combine.offered(to: fmt, from: self.formats, count: self.inputs.count) else {
                        self.runConvert(to: fmt)
                        return
                    }
                    if convertible.contains(fmt.id) {
                        // Both readings are real, so the wheel has to ask.
                        self.combineTarget = fmt
                        self.focus = 0
                        self.rebuild()
                    } else {
                        // Combining is the only thing this could mean.
                        self.runCombine(to: fmt)
                    }
                }
            }
    }

    /// The two answers, as a sub-wheel. Same shape as a tool's presets, and
    /// esc backs out of it the same way.
    private func combineItems(_ target: Format) -> [WheelItem] {
        [
            WheelItem(title: "ONE\n\(target.label)", symbol: "doc.on.doc") { [weak self] in
                self?.runCombine(to: target)
            },
            WheelItem(title: "SEPARATE", symbol: "square.grid.2x2") { [weak self] in
                self?.combineTarget = nil
                self?.runConvert(to: target)
            },
        ]
    }

    private func toolItems() -> [WheelItem] {
        Tool.allCases
            .filter { $0.applies(to: formats, count: inputs.count) }
            .map { t in WheelItem(title: t.wheelLabel, symbol: t.symbol) { [weak self] in self?.pickTool(t) } }
    }

    private func presetItems(_ t: Tool) -> [WheelItem] {
        t.presets.map { p in
            WheelItem(title: p.label.uppercased(), symbol: t.symbol) { [weak self] in self?.runTool(t, preset: p) }
        }
    }

    private func recipeItems() -> [WheelItem] {
        Recipes.all().map { r in
            let short = r.name.count > 12 ? String(r.name.prefix(11)) + "…" : r.name
            return WheelItem(title: short.uppercased(), symbol: "wand.and.stars") { [weak self] in self?.runRecipe(r) }
        }
    }

    private func pickTool(_ t: Tool) {
        if t.presets.isEmpty { runTool(t, preset: nil); return }
        presetParent = t
        focus = 0
        rebuild()
    }

    // MARK: run

    private func runConvert(to target: Format) {
        // Packing an expanded folder acts on the folder, not on each file in it.
        if let folder = folderInput, target.category == .archive {
            run(count: 1) { report in
                guard let out = Naming.output(for: folder, target: target, into: nil, collision: .suffix) else {
                    throw ConvertError.badInput("Couldn't name the archive.")
                }
                let written = try Engine.run(input: folder, to: target, output: out, opts: ConvertOptions())
                report(1)
                return (written, "\(folder.lastPathComponent) → \(target.label)")
            }
            return
        }

        let files = inputs
        run(count: files.count) { report in
            var first: URL?
            for (i, input) in files.enumerated() {
                guard let out = Naming.output(for: input, target: target, into: nil, collision: .suffix) else { continue }
                let written = try Engine.run(input: input, to: target, output: out, opts: ConvertOptions())
                if first == nil { first = written }
                report(i + 1)
            }
            return (first, "\(files.count) → \(target.label)")
        }
    }

    /// One file out of many. Deliberately the same call the ⌥ Merge PDF tool
    /// makes, so both routes produce identical output and identical naming.
    private func runCombine(to target: Format) {
        let files = Combine.ordered(inputs)
        combineTarget = nil
        run(count: 1) { report in
            let outs = try ToolRunner.run(.pdfMerge, inputs: files, params: ToolRunner.Params(preset: nil))
            report(1)
            return (outs.first, "\(files.count) → one \(target.label)")
        }
    }

    private func runTool(_ tool: Tool, preset: ToolPreset?) {
        let files = inputs
        let steps = (tool == .pdfMerge || tool == .pdfSplit) ? 1 : files.count
        run(count: steps) { report in
            if tool == .pdfMerge || tool == .pdfSplit {
                let outs = try ToolRunner.run(tool, inputs: files, params: ToolRunner.Params(preset: preset))
                report(1)
                return (outs.first, tool.label)
            }
            var first: URL?
            for (i, input) in files.enumerated() {
                let outs = try ToolRunner.run(tool, inputs: [input], params: ToolRunner.Params(preset: preset))
                if first == nil { first = outs.first }
                report(i + 1)
            }
            return (first, "\(tool.label) · \(files.count)")
        }
    }

    private func runRecipe(_ recipe: Recipe) {
        let files = inputs
        run(count: files.count) { report in
            var first: URL?
            for (i, input) in files.enumerated() {
                let out = try RecipeRunner.run(recipe, input: input, into: nil)
                if first == nil { first = out }
                report(i + 1)
            }
            return (first, "\(recipe.name) · \(files.count)")
        }
    }

    private func run(count: Int,
                     _ work: @escaping (_ report: @escaping (Int) -> Void) throws -> (URL?, String)) {
        guard !running else { return }
        running = true
        progress = 0
        needsDisplay = true

        DispatchQueue(label: "daisy.run", qos: .userInitiated).async { [weak self] in
            let report: (Int) -> Void = { done in
                DispatchQueue.main.async {
                    self?.progress = Double(done) / Double(max(1, count))
                    self?.needsDisplay = true
                }
            }
            do {
                let (reveal, _) = try work(report)
                DispatchQueue.main.async {
                    self?.progress = 1
                    self?.success.start()
                    self?.animate()
                    if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                        guard let self else { return }
                        // Came from a drag → get out of the way. Opened deliberately
                        // (hotkey, or clicked into) → stay, cleared, ready for the next file.
                        if self.window?.isKeyWindow != true { self.owner?.dismiss() }
                        self.resetIdle()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running = false
                    self.progress = 0
                    self.showError(error.localizedDescription)
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: geometry

    /// Bisector of petal `i`, measured from +x counter-clockwise, index 0 at 12 o'clock.
    private func angle(_ i: Int) -> CGFloat {
        .pi / 2 - CGFloat(i) * (2 * .pi / CGFloat(max(1, items.count)))
    }

    private var petalHalfAngle: CGFloat {
        max(0.14, .pi / CGFloat(max(1, items.count)) - petalGap / 2)
    }

    private func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }

    /// `rIn`/`rOut` default to the resting ring but are driven while animating —
    /// the entrance grows a petal outward from the hub, and hover pushes its
    /// tip a few points further out.
    private func petalPath(_ i: Int, rIn: CGFloat? = nil, rOut: CGFloat? = nil,
                           turn: CGFloat = 0) -> NSBezierPath {
        let a = angle(i) + turn, ha = petalHalfAngle
        let innerR = rIn ?? self.innerR
        let outerR = rOut ?? self.outerR
        let pts = [
            polar(innerR, a - ha), polar(innerR, a), polar(innerR, a + ha),
            polar(outerR, a + ha), polar(outerR, a), polar(outerR, a - ha),
        ]
        let path = NSBezierPath()
        func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
        path.move(to: mid(pts[pts.count - 1], pts[0]))
        for k in pts.indices {
            path.appendArc(from: pts[k], to: pts[(k + 1) % pts.count], radius: 9)
        }
        path.close()
        return path
    }

    /// The close button, sat in the margin off the disc's top-right shoulder.
    /// Outside the glass rather than on it: anywhere inside the rim it would
    /// land on a petal, and the margin already exists for the bloom and shadow.
    private var closeRect: NSRect {
        let r: CGFloat = 13
        let c = polar(discR + 14, .pi / 4)
        return NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    private func petalIndex(at p: CGPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = p.x - center.x, dy = p.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        guard r >= innerR - 6, r <= outerR + 6 else { return nil }
        let ang = atan2(dy, dx), ha = petalHalfAngle
        for i in items.indices {
            var d = ang - angle(i)
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            if abs(d) <= ha + petalGap * 0.4 { return i }
        }
        return nil
    }

    // MARK: paint

    private var discRect: NSRect {
        NSRect(x: center.x - discR, y: center.y - discR, width: discR * 2, height: discR * 2)
    }

    override func draw(_ dirty: NSRect) {
        let disc = NSBezierPath(ovalIn: discRect)

        guard !inputs.isEmpty else {
            let arrive = discAppear
            Theme.glassTint.withAlphaComponent(Theme.glassTint.alphaComponent * arrive).setFill()
            disc.fill()
            drawRim(arrive)
            let heat = Ease.clamp(emptyHeat.value)
            // The dash pattern rotates slowly, so an empty wheel looks like it
            // is waiting for something rather than sitting inert.
            let phase = CGFloat(CACurrentMediaTime().truncatingRemainder(dividingBy: 4) / 4) * 12
            let dashed = NSBezierPath(ovalIn: discRect.insetBy(dx: 9 - heat * 2, dy: 9 - heat * 2))
            dashed.lineWidth = 1.5 + heat * 0.6
            dashed.setLineDash([6, 6], count: 2, phase: phase)
            Theme.accent.withAlphaComponent(0.42 + 0.33 * heat).setStroke()
            dashed.stroke()
            text("Drop files", at: CGPoint(x: center.x, y: center.y + 16), 14, .semibold, Theme.ink)
            text("or click to choose", at: CGPoint(x: center.x, y: center.y - 3),
                 11, .regular, Theme.inkFaint)
            text("⌘V paste   ⌥ tools   ⇥ mode   esc", at: CGPoint(x: center.x, y: center.y - 30),
                 9, .regular, Theme.inkFaint, tracking: 0.3)
            drawCloseButton()
            return
        }

        // The glass fades up before anything sits on it, so the wheel has a
        // stage to arrive on instead of materialising all at once.
        let arrive = discAppear
        Theme.glassTint.withAlphaComponent(Theme.glassTint.alphaComponent * arrive).setFill()
        disc.fill()
        drawRim(arrive)

        if items.isEmpty {
            text("no route for", at: CGPoint(x: center.x, y: center.y + 8), 12, .medium, Theme.ink)
            text("this selection", at: CGPoint(x: center.x, y: center.y - 10), 12, .medium, Theme.ink)
        } else {
            for i in items.indices { drawPetal(i) }
        }
        drawDragFlow()
        drawDragCursor()
        drawProgressArc()
        drawSuccessPulse()
        if let errorText { drawToast(errorText) } else { drawHub() }
        drawCloseButton()
    }

    /// While a file is dragged onto a petal, three dots march from the hub out
    /// along that petal — the file visibly heading somewhere.
    ///
    /// Drawn over the petal in `onAccent`, not under it and not in the accent:
    /// under the petals the whole path is hidden behind them, and accent on a
    /// lit petal is accent on accent.
    private func drawDragFlow() {
        guard dragActive, let i = hover, items.indices.contains(i) else { return }
        let a = angle(i)
        let from = hubR + 10, to = outerR - 16
        guard to > from else { return }

        let cycle = CACurrentMediaTime().truncatingRemainder(dividingBy: 0.75) / 0.75
        for k in 0..<3 {
            var t = CGFloat(cycle) + CGFloat(k) / 3
            if t > 1 { t -= 1 }
            let p = polar(from + (to - from) * t, a)
            // Fade in off the hub and out at the tip so they arrive rather than
            // blink out of existence.
            let fade = min(1, t / 0.2) * min(1, (1 - t) / 0.25)
            let r = 2.8 - 0.8 * t
            Theme.onAccent.withAlphaComponent(0.55 * fade).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r,
                                        width: r * 2, height: r * 2)).fill()
        }
    }

    /// The target ring, drawn after the petals — over a lit petal it has to
    /// invert, because accent on accent is nothing at all.
    private func drawDragCursor() {
        guard dragActive, let p = dragPoint else { return }
        let locked = hover != nil
        let ink = locked ? Theme.onAccent : Theme.accent
        let r: CGFloat = locked ? 9 : 13
        let ring = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = locked ? 2 : 1.2
        ink.withAlphaComponent(locked ? 0.95 : 0.45).setStroke()
        ring.stroke()
        if locked {
            ink.withAlphaComponent(0.9).setFill()
            let dot: CGFloat = 2.6
            NSBezierPath(ovalIn: NSRect(x: p.x - dot, y: p.y - dot,
                                        width: dot * 2, height: dot * 2)).fill()
        }
    }

    /// A sweep around the rim while a job runs. Reads at a glance from across
    /// the screen in a way the percentage in the hub does not.
    private func drawProgressArc() {
        let p = Ease.clamp(shownProgress.value)
        guard running || p > 0.001 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: discR - 4.5,
                      startAngle: 90, endAngle: 90 - 360 * Double(p), clockwise: true)
        arc.lineWidth = 3
        arc.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = Theme.accent.withAlphaComponent(0.6)
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        glow.set()
        Theme.accent.setStroke()
        arc.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// One ring thrown off the rim when a job lands — the visual receipt.
    private func drawSuccessPulse() {
        guard let t = success.progress, success.running else { return }
        let e = Ease.out(t)
        let ring = NSBezierPath(ovalIn: discRect.insetBy(dx: -e * 26, dy: -e * 26))
        ring.lineWidth = 3 * (1 - e) + 0.5
        Theme.accent.withAlphaComponent(0.75 * (1 - e)).setStroke()
        ring.stroke()
    }

    /// Fades in with the wheel and warms under the cursor. Deliberately quiet:
    /// esc already closes, so this is for people who reach for the mouse.
    private func drawCloseButton() {
        let appear = hubAppear
        guard appear > 0.05 else { return }
        let heat = Ease.clamp(closeHeat.value)
        let box = closeRect.insetBy(dx: (1 - appear) * 5, dy: (1 - appear) * 5)
        let circle = NSBezierPath(ovalIn: box)

        Theme.glassTint.withAlphaComponent(0.55 + 0.35 * heat + 0.25 * appear).setFill()
        circle.fill()
        Theme.specular.withAlphaComponent(Theme.specular.alphaComponent * (0.5 + 0.5 * heat)).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let arm = box.width * (0.21 + 0.02 * heat)
        let c = CGPoint(x: box.midX, y: box.midY)
        let x = NSBezierPath()
        x.move(to: CGPoint(x: c.x - arm, y: c.y - arm)); x.line(to: CGPoint(x: c.x + arm, y: c.y + arm))
        x.move(to: CGPoint(x: c.x - arm, y: c.y + arm)); x.line(to: CGPoint(x: c.x + arm, y: c.y - arm))
        x.lineWidth = 1.6
        x.lineCapStyle = .round
        (heat > 0.5 ? Theme.accent : Theme.ink)
            .withAlphaComponent((0.55 + 0.45 * heat) * appear).setStroke()
        x.stroke()
    }

    /// What sells the glass: a bright arc along the top of the curve fading to a
    /// dark one underneath, so the edge reads as a lit bevel rather than a line.
    /// Drawn as two half-circle strokes rather than a gradient stroke, which
    /// AppKit can't do directly.
    private func drawRim(_ fade: CGFloat = 1) {
        guard fade > 0.01 else { return }
        let inset = discRect.insetBy(dx: 0.75, dy: 0.75)

        for (from, to, colour, width) in [
            (20.0, 160.0, Theme.specular.withAlphaComponent(Theme.specular.alphaComponent * fade), 1.6),
            (200.0, 340.0, Theme.glassEdge.withAlphaComponent(Theme.glassEdge.alphaComponent * fade), 1.3),
        ] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: CGPoint(x: inset.midX, y: inset.midY),
                          radius: inset.width / 2, startAngle: from, endAngle: to)
            arc.lineWidth = width
            arc.lineCapStyle = .round
            colour.setStroke()
            arc.stroke()
        }

        // A continuous hairline underneath keeps the circle closed where the two
        // arcs don't meet.
        let ring = NSBezierPath(ovalIn: inset)
        ring.lineWidth = 1
        Theme.hairline.withAlphaComponent(0.10 * fade).setStroke()
        ring.stroke()
    }

    private func drawToast(_ message: String) {
        let width: CGFloat = 210
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let str = NSAttributedString(string: message, attributes: [.font: font, .paragraphStyle: para])
        let size = str.boundingRect(with: NSSize(width: width - 20, height: 120),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let box = NSRect(x: center.x - width / 2, y: center.y - (size.height + 20) / 2,
                         width: width, height: size.height + 20)
        let card = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        Theme.paper.setFill()
        card.fill()
        NSColor.systemRed.withAlphaComponent(0.55).setStroke()
        card.lineWidth = 1
        card.stroke()
        text(message, at: CGPoint(x: box.midX, y: box.midY), 11, .medium, Theme.ink, maxWidth: width - 20)
    }



    private func drawPetal(_ i: Int) {
        let appear = petalAppear(i)
        guard appear > 0.001 else { return }

        let heat = petalHeat.indices.contains(i) ? Ease.clamp(petalHeat[i].value) : 0
        // Hover pushes the tip outward; a drag pushes it further, so the wheel
        // visibly reaches for the file.
        let reach = heat * (dragActive ? 9 : 5)
        let rIn = innerR - heat * 2
        // Clamped: the rim is at discR and a reaching tip must not break out of
        // the glass it is cut from.
        let rOut = min(discR - 9, innerR + (outerR - innerR) * appear + reach)
        let turn = petalSwing(i)
        let petal = petalPath(i, rIn: rIn, rOut: rOut, turn: turn)

        NSGraphicsContext.saveGraphicsState()
        if appear < 1 { petal.addClip() }   // keeps the label inside a growing petal

        if heat > 0.01 {
            // Rest colour underneath, accent faded in over it, so the transition
            // is a warm-up rather than a swap.
            Theme.petalRest.setFill()
            petal.fill()
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = Theme.accent.withAlphaComponent(0.55 * heat)
            glow.shadowBlurRadius = 10 + 10 * heat
            glow.shadowOffset = .zero
            glow.set()
            Theme.accent.withAlphaComponent(heat).setFill()
            petal.fill()
            NSGraphicsContext.restoreGraphicsState()
            if running { Theme.accent.withAlphaComponent(0.35 * heat).setFill(); petal.fill() }
        } else {
            Theme.petalRest.setFill()
            petal.fill()
        }
        // Each petal gets its own thin lit edge, so the whole wheel looks
        // cut from one sheet of glass rather than printed on the disc.
        Theme.specular.withAlphaComponent(Theme.specular.alphaComponent * 0.45).setStroke()
        petal.lineWidth = 1
        petal.stroke()

        // The clip is still on: a label must never ghost outside the petal it
        // belongs to while that petal is still growing.
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Label fades up late, once the petal is most of the way out.
        let textAlpha = Ease.clamp((appear - 0.55) / 0.35)
        guard textAlpha > 0.01 else { return }
        let fg = (heat > 0.5 ? Theme.onAccent : Theme.onPetal)
            .withAlphaComponent(textAlpha)

        let item = items[i]
        let p = polar((rIn + rOut) / 2 + 5, angle(i) + turn)
        var labelY = p.y
        if let name = item.symbol,
           let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) {
            icon.isTemplate = true
            fg.set()
            icon.draw(in: NSRect(x: p.x - 7, y: p.y + 4, width: 14, height: 14),
                      from: .zero, operation: .sourceOver, fraction: textAlpha,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            labelY = p.y - 10
        }
        text(item.title, at: CGPoint(x: p.x, y: labelY), 10.5, .semibold, fg, tracking: 0.2, maxWidth: 88)
    }

    private func drawHub() {
        let box = NSRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2)
        let hub = NSBezierPath(ovalIn: box)

        // The centre is the one saturated thing on the wheel. A vertical
        // gradient rather than a flat fill so it reads as a rounded disc.
        NSGradient(starting: Theme.accent, ending: Theme.accentDeep)?
            .draw(in: hub, angle: -90)

        if let thumb {
            NSGraphicsContext.saveGraphicsState()
            hub.addClip()
            thumb.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            text(sourceLabel(), at: CGPoint(x: center.x, y: center.y + 4), 12, .semibold, Theme.onAccent)
        }
        // Nothing else says which mode you're in, and the petals alone are
        // ambiguous. The combine question borrows the same slot to name the
        // format it is asking about — "SEPARATE" on its own says nothing.
        let banner = combineTarget.map { $0.label.uppercased() }
            ?? (mode == .convert ? nil : (mode == .tools ? "TOOLS" : "RECIPES"))
        if let banner {
            let colour = thumb == nil ? Theme.onAccent.withAlphaComponent(0.62)
                                      : Theme.paper.withAlphaComponent(0.85)
            text(banner, at: CGPoint(x: center.x, y: center.y + hubR - 13), 8.5, .semibold,
                 colour, tracking: 1)
        }
        // Same bevel as the disc, at hub scale.
        let hubArc = NSBezierPath()
        hubArc.appendArc(withCenter: center, radius: hubR - 0.5, startAngle: 25, endAngle: 155)
        hubArc.lineWidth = 1.2
        hubArc.lineCapStyle = .round
        Theme.specular.setStroke()
        hubArc.stroke()
        Theme.hairline.withAlphaComponent(0.14).setStroke()
        hub.lineWidth = 1
        hub.stroke()

        let pill = running ? "\(Int(Ease.clamp(shownProgress.value) * 100))%"
            : presetParent.map { $0.label.uppercased() } ?? (focusTitle() ?? "")
        guard !pill.isEmpty else { return }
        let width = (pill as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width + 18
        let r = NSRect(x: center.x - width / 2, y: center.y - hubR + 6, width: width, height: 20)
        let shape = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        glow.shadowBlurRadius = 10
        glow.shadowOffset = .zero
        glow.set()
        // The pill overlaps the yellow centre, so it can't also be yellow.
        Theme.onAccent.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        text(pill, at: CGPoint(x: r.midX, y: r.midY), 11, .semibold, Theme.accent)
    }

    private func sourceLabel() -> String {
        if folderInput != nil { return "\(inputs.count) IN FOLDER" }
        if inputs.count > 1 { return "\(inputs.count) FILES" }
        return formats.first?.label ?? inputs.first.map { $0.pathExtension.uppercased() } ?? ""
    }

    private func focusTitle() -> String? {
        let i = hover ?? focus
        return items.indices.contains(i) ? items[i].title.replacingOccurrences(of: "\n", with: " ") : nil
    }

    private func text(_ s: String, at p: CGPoint, _ size: CGFloat, _ weight: NSFont.Weight,
                      _ color: NSColor, tracking: CGFloat = 0, maxWidth: CGFloat = 400) {
        guard !s.isEmpty else { return }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        if tracking != 0 { attrs[.kern] = tracking }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        attrs[.paragraphStyle] = para
        let str = NSAttributedString(string: s, attributes: attrs)
        let box = str.boundingRect(with: NSSize(width: maxWidth, height: 60),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
        str.draw(with: NSRect(x: p.x - box.width / 2, y: p.y - box.height / 2, width: box.width, height: box.height),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private static func thumbnail(_ url: URL, side: CGFloat) -> NSImage? {
        guard let src = NSImage(contentsOf: url), src.size.width > 0, src.size.height > 0 else { return nil }
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        let scale = side / min(src.size.width, src.size.height)
        let w = src.size.width * scale, h = src.size.height * scale
        src.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        out.unlockFocus()
        return out
    }

    // MARK: input

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if inputs.isEmpty {
            // The whole empty ring is one target, so say so with the cursor and
            // by warming the dashed edge.
            let inside = hypot(p.x - center.x, p.y - center.y) <= discR
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            if inside != hoveringEmpty { hoveringEmpty = inside; animate() }
            return
        }
        if hoveringEmpty { hoveringEmpty = false; animate() }

        let overClose = closeRect.contains(p)
        if overClose != closeHover { closeHover = overClose; animate() }

        let i = petalIndex(at: p)
        if i != hover { hover = i; animate() }
        (overClose || i != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    override func mouseExited(with e: NSEvent) {
        NSCursor.arrow.set()
        if hover != nil || hoveringEmpty || closeHover {
            hover = nil; hoveringEmpty = false; closeHover = false
            animate()
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        // The close button works even mid-conversion — the job keeps running,
        // the wheel just gets out of the way.
        if closeRect.contains(p) { owner?.dismiss(); return }
        guard !running else { return }
        if inputs.isEmpty {
            if hypot(p.x - center.x, p.y - center.y) <= discR { chooseFiles() }
            return
        }
        guard let i = petalIndex(at: p) else { return }
        focus = i
        items[i].run()
    }

    /// The empty ring doubles as a button. Dragging is the fast path, but a
    /// click here opens Finder's own picker — the same wheel either way.
    func chooseFiles() {
        // A drag-summoned panel is on a dismiss timer and isn't key; the picker
        // needs both of those undone or it opens behind and then vanishes.
        owner?.cancelDragDismiss()
        dragSummoned = false
        owner?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true      // folders are an input too (→ zip)
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Choose"
        panel.message = "Pick a file to convert."
        // Free-standing rather than a sheet: the wheel is a borderless 300pt
        // panel and a sheet hanging off it would be wider than its own parent.
        // It also has to clear the wheel's floating level to be visible at all.
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.owner?.makeKeyAndOrderFront(nil)
            self.owner?.makeFirstResponder(self)
            guard response == .OK, !panel.urls.isEmpty else { return }
            self.accept(panel.urls)
        }
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53:                                 // esc
            if presetParent != nil || combineTarget != nil {
                presetParent = nil
                combineTarget = nil
                rebuild()
            } else { owner?.dismiss() }
        case 123, 126: step(-1)                   // ← ↑
        case 124, 125: step(+1)                   // → ↓
        case 36, 76, 49:                         // return, space
            if running { return }
            if inputs.isEmpty { chooseFiles() }
            else if items.indices.contains(focus) { items[focus].run() }
        case 48: cycleMode()                     // tab
        default:
            let key = e.charactersIgnoringModifiers
            if e.modifierFlags.contains(.command), key == "v" { paste() }
            else if e.modifierFlags.contains(.command), key == "o" { chooseFiles() }
            else { super.keyDown(with: e) }
        }
    }

    private func step(_ d: Int) {
        guard !items.isEmpty else { return }
        focus = (focus + d + items.count) % items.count
        hover = nil          // keyboard takes over from the mouse
        animate()
    }

    override func flagsChanged(with e: NSEvent) {
        let held = e.modifierFlags.contains(.option)
        if held != optionHeld {
            optionHeld = held
            presetParent = nil
            combineTarget = nil
            rebuild()
        }
        super.flagsChanged(with: e)
    }

    private func paste() {
        if let urls = Self.fileURLs(NSPasteboard.general), !urls.isEmpty { accept(urls) }
    }

    // MARK: drag

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        dragActive = true
        dragPoint = convert(s.draggingLocation, from: nil)
        loadFromDrag(s)
        animate()
        return .copy
    }

    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        if inputs.isEmpty { loadFromDrag(s) }
        let p = convert(s.draggingLocation, from: nil)
        dragPoint = p
        dragActive = true
        let i = petalIndex(at: p)
        if i != hover { hover = i }
        // The cursor moves every frame, so the tether has to redraw every frame.
        needsDisplay = true
        animate()
        return .copy
    }

    /// The drag pasteboard is readable now that the drag is over our window —
    /// which it wasn't from `DragMonitor`.
    private func loadFromDrag(_ s: NSDraggingInfo) {
        guard let urls = Self.fileURLs(s.draggingPasteboard), !urls.isEmpty else { return }
        owner?.cancelDragDismiss()
        accept(urls)
    }

    override func draggingExited(_ s: NSDraggingInfo?) {
        dragActive = false
        dragPoint = nil
        hover = nil
        animate()
    }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        dragActive = false
        dragPoint = nil
        guard let urls = Self.fileURLs(s.draggingPasteboard), !urls.isEmpty else { return false }
        owner?.cancelDragDismiss()
        dragSummoned = false
        accept(urls)
        if !running, let i = petalIndex(at: convert(s.draggingLocation, from: nil)) {
            focus = i
            items[i].run()
        } else {
            // Dropped on the disc, not a petal — leave it open and make it usable by keyboard.
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
        }
        return true
    }

    override func draggingEnded(_ s: NSDraggingInfo) {
        if dragSummoned {
            dragSummoned = false
            owner?.orderOut(nil)
        }
    }

    private static func fileURLs(_ pb: NSPasteboard) -> [URL]? {
        pb.readObjects(forClasses: [NSURL.self],
                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}

private extension Tool {
    var symbol: String {
        switch self {
        case .resize:           return "arrow.up.left.and.arrow.down.right"
        case .compress:         return "arrow.down.right.and.arrow.up.left"
        case .crop:             return "crop"
        case .stripMetadata:    return "tag.slash"
        case .trim:             return "scissors"
        case .ocr:              return "text.viewfinder"
        case .removeBackground: return "person.crop.rectangle.badge.xmark"
        case .pdfMerge:         return "doc.on.doc"
        case .pdfSplit:         return "square.split.1x2"
        }
    }

    /// Short label for a petal; `\n` breaks the wide ones onto two lines.
    var wheelLabel: String {
        switch self {
        case .resize:           return "RESIZE"
        case .compress:         return "COMPRESS"
        case .crop:             return "CROP"
        case .stripMetadata:    return "STRIP\nMETA"
        case .trim:             return "TRIM"
        case .ocr:              return "OCR"
        case .removeBackground: return "REMOVE\nBG"
        case .pdfMerge:         return "MERGE\nPDF"
        case .pdfSplit:         return "SPLIT\nPDF"
        }
    }
}

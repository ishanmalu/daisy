import AppKit

/// Watches for a Shift-held file drag anywhere on screen and pops the wheel
/// under the cursor, the way Tangerine does. Mouse-event monitors don't need
/// Accessibility (only keyboard ones do), so this works out of the box.
final class DragMonitor {
    static let shared = DragMonitor()

    private var handles: [Any] = []
    private var summoning = false
    /// Drag pasteboard generation at mouse-down. A real drag session writes
    /// to it; moving a window or selecting text doesn't.
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var dragEvents = 0
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = Set(
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

    func start() {
        guard handles.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            handles.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            handles.append(l)
        }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            baseline = NSPasteboard(name: .drag).changeCount
            dragEvents = 0

        case .leftMouseDragged:
            // Only a Shift-drag of files. Checked on every drag event because
            // the source writes the pasteboard a few events into the drag.
            // Reading the types, not the contents, needs no permission.
            guard !summoning, NSEvent.modifierFlags.contains(.shift) else { return }
            dragEvents += 1
            let pb = NSPasteboard(name: .drag)
            if pb.changeCount != baseline {
                // A drag session started: summon only if it carries files.
                guard !Self.fileTypes.isDisjoint(with: pb.types ?? []) else { return }
            } else {
                // No session visible (a window move, or the pasteboard isn't
                // readable from here). Fail open to the old behaviour, a few
                // events in so a session has had time to show up.
                guard dragEvents >= 6 else { return }
            }
            summoning = true
            DispatchQueue.main.async { DropPanel.shared.beginDrop() }

        case .leftMouseUp:
            guard summoning else { return }
            summoning = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                DropPanel.shared.dismissIfDragSummoned()
            }

        default:
            break
        }
    }
}

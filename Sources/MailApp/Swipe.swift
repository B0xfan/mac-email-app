import SwiftUI
import AppKit

// MARK: - Swipe actions: two-finger slide on an email row

enum SwipeAction: String, CaseIterable, Codable {
    case archive, pin, aside, toggleRead, trash, none
    var title: String {
        switch self { case .archive: return "Archive"; case .pin: return "Pin"; case .aside: return "Set Aside"; case .toggleRead: return "Mark read or unread"; case .trash: return "Move to Trash"; case .none: return "Do nothing" }
    }
    var symbol: String {
        switch self { case .archive: return "archivebox"; case .pin: return "pin"; case .aside: return "rectangle.stack"; case .toggleRead: return "envelope.open"; case .trash: return "trash"; case .none: return "nosign" }
    }
    /// What the revealed bar says for this email ("Mark read" or "Mark unread" depends on the email).
    func label(for m: Mail) -> String { self == .toggleRead ? (m.unread ? "Mark read" : "Mark unread") : title }
}

enum Swipe {
    static func commitDistance(width: CGFloat) -> CGFloat { min(190, width / 2) }   // further than the bar, or past the middle
    static func shouldCommit(_ dx: CGFloat, width: CGFloat) -> Bool { abs(dx) >= commitDistance(width: width) }
    static func clamp(_ dx: CGFloat, width: CGFloat) -> CGFloat { max(-width * 0.75, min(width * 0.75, dx)) }
    /// Slide right is positive. A trackpad with natural scrolling reports finger direction; without it the sign flips.
    static func signedDelta(_ scrollX: CGFloat, naturalScrolling: Bool) -> CGFloat { naturalScrolling ? scrollX : -scrollX }
    static func isHorizontal(dx: CGFloat, dy: CGFloat) -> Bool { dx != 0 && abs(dx) > abs(dy) * 1.2 }
}

/// One listener for every row: horizontal two-finger slides are handed to the row under the pointer, vertical ones pass through to the list.
@MainActor
final class SwipeHub {
    static let shared = SwipeHub()
    private var views = NSHashTable<SwipeCatcherView>.weakObjects()
    private var monitor: Any?
    private enum Mode { case idle, undecided, swipe, pass }
    private var mode = Mode.idle
    private weak var active: SwipeCatcherView?
    private var dx: CGFloat = 0

    func add(_ v: SwipeCatcherView) {
        views.add(v)
        guard monitor == nil, !Keychain.testMode else { return }   // headless test modes never listen to the real trackpad
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.handle(e) }
        }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard e.hasPreciseScrollingDeltas, e.phase != [] || e.momentumPhase != [] else { return e }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) { mode = .undecided; active = nil; dx = 0 }
        if mode == .undecided, e.phase.contains(.changed) || e.phase.contains(.began) {
            if Swipe.isHorizontal(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY),
               let v = views.allObjects.first(where: { $0.contains(e) }) { active = v; mode = .swipe } else { mode = .pass }
        }
        defer { if e.phase.contains(.ended) || e.phase.contains(.cancelled) { if mode == .swipe { active?.onFinish?() }; mode = .idle; active = nil; dx = 0 } }
        guard mode == .swipe, let v = active else { return e }
        if e.momentumPhase != [] { return nil }
        dx += Swipe.signedDelta(e.scrollingDeltaX, naturalScrolling: e.isDirectionInvertedFromDevice)
        v.onUpdate?(dx, v.bounds.width)
        return nil
    }
}

final class SwipeCatcherView: NSView {
    var onUpdate: ((CGFloat, CGFloat) -> Void)?
    var onFinish: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steals clicks
    func contains(_ e: NSEvent) -> Bool {
        guard window != nil, window === e.window, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.contains(convert(e.locationInWindow, from: nil))
    }
}

struct SwipeCatcher: NSViewRepresentable {
    let update: (CGFloat, CGFloat) -> Void
    let finish: () -> Void
    func makeNSView(context: Context) -> SwipeCatcherView {
        let v = SwipeCatcherView(); v.onUpdate = update; v.onFinish = finish
        MainActor.assumeIsolated { SwipeHub.shared.add(v) }
        return v
    }
    func updateNSView(_ v: SwipeCatcherView, context: Context) { v.onUpdate = update; v.onFinish = finish }
}

/// The coloured bar that shows under the row while it slides: right side teal, left side purple, as drawn.
struct SwipeBar: View {
    let action: SwipeAction, text: String, fromLeft: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: action.symbol).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 14, weight: .bold)).lineLimit(1)
        }
        .padding(.horizontal, 16).frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, alignment: fromLeft ? .leading : .trailing)
        .background(fromLeft ? Theme.acc : Theme.blk)
        .foregroundStyle(fromLeft ? Theme.accText : Theme.bg)
        .accessibilityHidden(true)
    }
}

// MARK: - Store: doing the chosen action

extension MailStore {
    /// Pin and Set Aside only make sense in the inbox; elsewhere that side does nothing.
    func swipeFor(_ a: SwipeAction) -> SwipeAction { (a == .aside || a == .pin) && mailbox != .inbox ? .none : a }

    /// Changes labels on every copy of the message held in memory: the row itself, and (conversations) its entry inside a conversation's list.
    func applyLabels(_ id: String, add: [String], remove: [String]) {
        func change(_ l: inout [String]) { l.removeAll { remove.contains($0) }; for a in add where !l.contains(a) { l.append(a) } }
        func f(_ x: inout Mail) {
            if x.id == id { change(&x.labels) }
            if let i = x.convo?.firstIndex(where: { $0.id == id }) { change(&x.convo![i].labels) }
        }
        for i in inbox.indices { f(&inbox[i]) }
        for i in other.indices { f(&other[i]) }
        for i in aside.indices { f(&aside[i]) }
        if openMail != nil { f(&openMail!) }
    }

    func toggleRead(_ given: Mail) async {
        let m = (inbox + other + aside).first { $0.id == given.id } ?? given
        let wasUnread = m.unread
        let ids = wasUnread ? unreadIDs(m) : [m.id]
        do {
            try await gmail.modify(ids: ids, add: wasUnread ? [] : ["UNREAD"], remove: wasUnread ? ["UNREAD"] : [])
            for id in ids { applyLabels(id, add: wasUnread ? [] : ["UNREAD"], remove: wasUnread ? ["UNREAD"] : []) }
            saveCache()
            undoArchive = ids; undoSibs = []; undoAside = false; undoUntrash = false
            undoFolder = (add: wasUnread ? ["UNREAD"] : [], remove: wasUnread ? [] : ["UNREAD"])
            showToast(wasUnread ? "Marked read." : "Marked unread.", action: "Undo")
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    func swipe(_ m: Mail, _ chosen: SwipeAction) async {
        switch swipeFor(chosen) {
        case .none: return
        case .archive: await archive(m)
        case .aside: await setAside(m)
        case .trash: await leaveInbox(m, add: [], text: "Moved to Trash.", aside: false, exactUndo: true, trashIt: true)
        case .toggleRead: await toggleRead(m)
        case .pin:
            let touched = await togglePin(m)
            guard let l = pinLabelID, let now = (inbox + other).first(where: { $0.id == m.id }) else { return }
            let pinned = isPinned(now)
            undoArchive = touched.isEmpty ? [m.id] : touched; undoSibs = []; undoAside = false; undoUntrash = false
            undoFolder = (add: pinned ? [] : [l], remove: pinned ? [l] : [])
            showToast(pinned ? "Pinned." : "Unpinned.", action: "Undo")
        }
    }
}

import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: appBundleID, category: "PathCompletion")

/// What the pane wiring (`TerminalPane.configure`) hands the completion
/// controller on each refresh. Nil means the preconditions fail — the setting
/// is off, the pane is remote, a program owns the line instead of a shell, or
/// a password prompt is up. Non-nil carries the directories bare tokens and
/// `~` resolve against.
struct PathCompletionContext {
    let homeDirectory: String
    let workingDirectory: String
}

/// One row the popup shows: the candidate plus its file icon, resolved once
/// at listing time on the main actor (`NSWorkspace` icon lookups are not for
/// background queues).
struct PathCompletionRow: Identifiable {
    let candidate: PathCompletionCandidate
    let icon: NSImage
    var id: String { candidate.name }
}

/// Observable state the popup's SwiftUI content renders. The controller owns
/// it; rows are replaced wholesale on every accepted refresh, so identity is
/// the entry name (unique within one directory listing).
@MainActor
@Observable
final class PathCompletionModel {
    var rows: [PathCompletionRow] = []
    var selectedIndex: Int = 0
    /// The directory the rows came from, shown as the popup's context line.
    var baseDirectory: String = ""
    /// How many rows the popup reserves height for (the last page may be
    /// short); the SwiftUI host derives its preferred content size from it.
    var visibleRowCount: Int = 1

    @ObservationIgnored var commit: (PathCompletionCandidate) -> Void = { _ in }
}

/// The cursor-anchored path-completion popup: an `NSPopover` in the shape of
/// `PasswordBubble` (`.applicationDefined`, never keeps key), showing the
/// directory entries the token being typed prefixes. The terminal view drives
/// it — `noteInputChanged` after every keystroke that could edit the line,
/// `handleKeyDown` ahead of libghostty while it is open — and every rule
/// about WHICH token triggers and WHAT a commit types lives in the pure
/// `PathCompletion` model.
///
/// While it is open the popup owns ↑/↓/Tab/Return/Escape on the terminal's
/// key path: arrows move the selection, Tab commits (directories append `/`
/// and the popup re-lists their children — the drill-down), Return commits
/// only when it would add characters and otherwise passes through so the
/// shell runs the line, Escape dismisses. Selection resets to nothing after a
/// commit, so the Enter that follows a drill-down runs the command instead of
/// descending forever.
@MainActor
final class PathCompletionController: NSObject, NSPopoverDelegate {
    /// Hardware key codes (Carbon `kVK_*`), the same grammar `sendKey` uses.
    private enum Key {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    private static let rowHeight: CGFloat = 24
    private static let maximumVisibleRows = 8
    private static let popupWidth: CGFloat = 280

    private weak var view: GhosttyTerminalNSView?
    /// Injected by `TerminalPane.configure` — the pane-side preconditions and
    /// directories. Re-read on every refresh so a pane that stopped being a
    /// shell at a prompt closes the popup instead of refreshing it.
    var context: (() -> PathCompletionContext?)?
    private let model = PathCompletionModel()
    private var popover: NSPopover?
    /// The query the shown rows answer; kept so a refresh for the same token
    /// re-anchors instead of re-listing.
    private var query: PathCompletionQuery?
    /// Guards against a stale background listing landing over a newer one.
    private var generation = 0
    private var refreshWork: DispatchWorkItem?
    /// Set across a commit's drill-down refresh: the popup re-opens showing
    /// the entered directory but selects nothing, so the next Return runs the
    /// command rather than committing a child.
    private var suppressAutoSelectOnce = false
    private var iconCache: [String: NSImage] = [:]

    var isShown: Bool { popover?.isShown == true }

    init(view: GhosttyTerminalNSView) {
        self.view = view
        super.init()
        model.commit = { [weak self] candidate in
            self?.commit(candidate)
        }
    }

    // MARK: - Driving

    /// A keystroke (or paste, or IME commit) may have edited the input line.
    /// Debounced: the terminal core processes input on its own thread, so the
    /// read must wait out the quiet period or it re-parses the previous token.
    func noteInputChanged() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    /// A frame was drawn while the popup is open — the catch-up trigger for
    /// text that landed after the debounced refresh read (a commit's own
    /// typed text included). Cheap: it only schedules the same debounced
    /// refresh.
    func noteRender() {
        guard isShown else { return }
        noteInputChanged()
    }

    /// A click landed in the terminal — the cursor is wherever the click put
    /// it, which the popup neither knows nor anchors to.
    func noteMouse() {
        close()
    }

    /// The terminal view lost first responder. Kept open when the popover's
    /// own window took key — that is a click on one of its rows arriving —
    /// closed when anything else did (another pane, tab, window, app).
    func viewDidLoseFocus() {
        guard let popover, popover.isShown else { return }
        if NSApp.keyWindow !== popover.contentViewController?.view.window {
            close()
        }
    }

    func close() {
        refreshWork?.cancel()
        refreshWork = nil
        generation += 1
        query = nil
        popover?.close()
        popover = nil
    }

    // MARK: - Key interception (while shown)

    /// Returns true when the event was consumed — it moved the selection,
    /// committed, or dismissed, and must not reach libghostty.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isShown, !model.rows.isEmpty else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isSubset(of: [.shift]) else { return false }
        switch event.keyCode {
        case Key.escape:
            close()
            return true
        case Key.up:
            moveSelection(-1)
            return true
        case Key.down:
            moveSelection(1)
            return true
        case Key.tab:
            if flags.contains(.shift) {
                moveSelection(-1)
            } else {
                commit(selectedOrFirst)
            }
            return true
        case Key.returnKey:
            return handleReturn()
        case Key.left,
             Key.right:
            // The cursor moved; the token it ends is no longer the parsed one.
            close()
            return false
        default:
            return false
        }
    }

    private var selectedOrFirst: PathCompletionCandidate {
        let index = model.selectedIndex >= 0 ? model.selectedIndex : 0
        return model.rows[index].candidate
    }

    private func moveSelection(_ delta: Int) {
        let count = model.rows.count
        guard count > 0 else { return }
        if model.selectedIndex < 0 {
            model.selectedIndex = delta > 0 ? 0 : count - 1
        } else {
            model.selectedIndex = (model.selectedIndex + delta + count) % count
        }
    }

    private func handleReturn() -> Bool {
        guard let query else { return false }
        let candidate = selectedOrFirst
        // Return never commits a file: the word the user typed may be exactly
        // what they mean to run, and a file suggestion that extends it would
        // rewrite the command. A directory commits only when it adds more
        // than its `/` — that is the drill-down; a fully typed directory
        // passes through so the line runs.
        guard candidate.isDirectory else {
            close()
            return false
        }
        let plan = PathCompletion.insertion(for: candidate, typedPrefix: query.typedPrefix)
        if plan.erase == 0, plan.text == "/" {
            close()
            return false
        }
        commit(candidate)
        return true
    }

    // MARK: - Refresh

    private func refresh() {
        guard let view, let context = context?() else {
            close()
            return
        }
        guard let anchor = view.cursorCellRect() else {
            close()
            return
        }
        guard let line = view.readCommandLineBeforeCursor() else {
            close()
            return
        }
        guard let parsed = PathCompletion.query(
            inLine: line,
            homeDirectory: context.homeDirectory,
            workingDirectory: context.workingDirectory
        )
        else {
            close()
            return
        }
        if isShown, parsed == query {
            // Same token — only the cursor may have moved.
            reanchor(anchor)
            return
        }
        query = parsed
        generation += 1
        let listedGeneration = generation
        let base = parsed.baseDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = PathCompletion.directoryEntries(at: base)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.apply(listing, query: parsed, generation: listedGeneration, anchor: anchor)
                }
            }
        }
    }

    private func apply(
        _ listing: [PathDirectoryEntry]?,
        query parsed: PathCompletionQuery,
        generation listedGeneration: Int,
        anchor: NSRect
    ) {
        guard listedGeneration == generation, parsed == query else { return }
        let entries = listing ?? []
        let candidates = PathCompletion.candidates(for: parsed, in: entries)
        guard !candidates.isEmpty else {
            close()
            return
        }
        model.rows = candidates.map { candidate in
            PathCompletionRow(candidate: candidate, icon: icon(for: parsed.baseDirectory, candidate: candidate))
        }
        model.baseDirectory = parsed.baseDirectory
        if suppressAutoSelectOnce {
            suppressAutoSelectOnce = false
            model.selectedIndex = -1
        } else {
            model.selectedIndex = 0
        }
        model.visibleRowCount = min(candidates.count, Self.maximumVisibleRows)
        present(at: anchor)
    }

    private func icon(for base: String, candidate: PathCompletionCandidate) -> NSImage {
        let key = base + "/" + candidate.name
        if let cached = iconCache[key] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: key)
        image.size = NSSize(width: 15, height: 15)
        if iconCache.count > 512 {
            iconCache.removeAll()
        }
        iconCache[key] = image
        return image
    }

    // MARK: - Commit

    private func commit(_ candidate: PathCompletionCandidate) {
        guard let view, let query else { return }
        let plan = PathCompletion.insertion(for: candidate, typedPrefix: query.typedPrefix)
        view.commitPathCompletion(eraseCount: plan.erase, text: plan.text)
        if candidate.isDirectory {
            // Drill down: re-list the entered directory once its `/` lands.
            suppressAutoSelectOnce = true
            noteInputChanged()
        } else {
            close()
        }
    }

    // MARK: - Popover

    private func present(at anchor: NSRect) {
        if let popover, popover.isShown {
            if popover.positioningRect != anchor {
                popover.positioningRect = anchor
            }
            return
        }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        // No per-keystroke animation: the content updates on every character.
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: PathCompletionPopupView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        guard let view else { return }
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        self.popover = popover
    }

    private func reanchor(_ anchor: NSRect) {
        guard let popover, popover.isShown else { return }
        if popover.positioningRect != anchor {
            popover.positioningRect = anchor
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
    }
}

/// The popup content: a context line with the directory, then the candidate
/// rows — icon, name, and for directories the chevron that says committing
/// drills in. The selected row is accent-tinted; clicking a row commits it
/// exactly as Tab would.
private struct PathCompletionPopupView: View {
    let model: PathCompletionModel

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: model.baseDirectory)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            PathCompletionRowView(row: row, isSelected: index == model.selectedIndex) {
                                model.commit(row.candidate)
                            }
                            .id(row.id)
                        }
                    }
                }
                .onChange(of: model.selectedIndex) { _, newValue in
                    guard model.rows.indices.contains(newValue) else { return }
                    proxy.scrollTo(model.rows[newValue].id, anchor: nil)
                }
            }
        }
        .frame(width: 280, height: popupHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var popupHeight: CGFloat {
        let rows = CGFloat(model.visibleRowCount) * 24
        let header: CGFloat = 20
        return rows + header + 4
    }
}

private struct PathCompletionRowView: View {
    let row: PathCompletionRow
    let isSelected: Bool
    let commit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 15, height: 15)
            Text(verbatim: row.candidate.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(MactermTheme.fg)
            Spacer(minLength: 8)
            if row.candidate.isDirectory {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .fill(MactermTheme.accentSoft)
            }
        }
        .onTapGesture(perform: commit)
    }
}

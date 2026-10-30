import AppKit
import Combine
import SwiftTerm
import SwiftUI

// A raw terminal onto one agent: SwiftTerm runs `herdr agent attach <pane>` in
// a PTY, so this is the agent's own TUI — colors, keys, mouse and resizing go
// straight through. Themed with any Ghostty theme (Tokyo Night by default).
//
// herdr gives a terminal to one attached client at a time. When another has
// it — another window, or the same agent open on the Mac it runs on — this one
// shares it instead: `herdr terminal session observe` draws it live (any
// number of clients can), and what you type goes in through herdr's
// pane.send_text, so both windows see and type at once. The attached one sets
// the size; Take Over makes it this one. Taken from, it goes back to sharing
// rather than going blank.

@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let pane: String
    let view: AgentTerminalView
    @Published var attached = false
    @Published var ended = false
    /// Ended because another window (or terminal) has this agent: herdr
    /// gives a terminal to one attached client at a time.
    @Published var elsewhere = false
    /// Sharing: a live mirror while another client has the terminal; keys
    /// go in through herdr's API (see type(_:)).
    @Published var watching = false
    /// Keys typed while sharing, not yet sent, and whether a send is out:
    /// sent in order, a burst as one.
    private var outbox: [UInt8] = []
    private var sending = false
    /// The process ending now was ended on purpose, to start `next`.
    private var next: (() -> Void)?
    /// Where the attach script says why it stopped.
    private let why = FileManager.default.temporaryDirectory.appendingPathComponent("reflex-attach-\(UUID().uuidString)")
    /// The link under the pointer, for the ⌘-click hint, and where the
    /// pointer found it (top-left origin, in the window's content).
    @Published var link: (url: String, at: CGPoint)?
    private var bag = Set<AnyCancellable>()

    init(pane: String) {
        self.pane = pane
        view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
        super.init()
        view.processDelegate = self
        view.optionAsMetaKey = true
        view.machine = Machines.machine(of: pane)
        view.pane = pane
        view.onInput = { [weak self] data in
            guard let self else { return false }
            // herdr-core: keys go down the stream (nowhere while it opens).
            if self.core {
                self.stream?.write(Data(data))
                return true
            }
            guard self.watching else { return false }
            self.type(data)
            return true
        }
        view.onResize = { [weak self] cols, rows in
            guard let self, let stream = self.stream else { return }
            stream.facts(self.display())
            stream.resize(cols: cols, rows: rows)
        }
        view.onFocus = { [weak self] on in self?.stream?.focus(on) }
        view.onLink = { [weak self] url, at in self?.link = url.map { ($0, at) } }
        TerminalScroll.install()
        TerminalScroll.views[ObjectIdentifier(view)] = view
        TerminalSelect.install()
        TerminalKeys.install()
        TerminalLinks.install()
        apply(Themes.shared.current, font: Themes.font(Themes.shared.fontFamily, size: Themes.shared.fontSize))
        Themes.shared.$current.combineLatest(Themes.shared.$fontSize, Themes.shared.$fontFamily)
            .sink { [weak self] t, s, f in self?.apply(t, font: Themes.font(f, size: s)) }
            .store(in: &bag)
    }

    func apply(_ t: TermTheme, font: NSFont) {
        view.installColors(t.palette.map { hex in
            let c = NSColor(hex: hex).usingColorSpace(.sRGB) ?? .black
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                   blue: UInt16(c.blueComponent * 65535))
        })
        view.nativeBackgroundColor = NSColor(hex: t.background)
        view.nativeForegroundColor = NSColor(hex: t.foreground)
        view.caretColor = NSColor(hex: t.cursor)
        view.selectedTextBackgroundColor = NSColor(hex: t.selection)
        view.font = font
        view.needsDisplay = true
    }

    // MARK: herdr-core

    /// An agent in herdr-core: its stream comes straight into this view, no
    /// process in between. Any number of viewers can have it at once, so
    /// there is no taking over and no sharing to fall back to: the one you
    /// last typed in, resized or focused sets its size.
    var core: Bool { HerdrCore.isCore(pane) }
    private var stream: CoreStream?
    private var reattaching = 0

    /// What this view looks like (the core answers programs' display
    /// queries with it): its colors, and its cell size in device pixels.
    func display() -> [String: Any] {
        var d: [String: Any] = ["fg": Themes.shared.current.foreground, "bg": Themes.shared.current.background,
                                "cursor": Themes.shared.current.cursor]
        let t = view.getTerminal()
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if t.cols > 0, t.rows > 0, view.bounds.width > 0 {
            d["cell"] = [Int((view.bounds.width / CGFloat(t.cols) * scale).rounded()),
                         Int((view.bounds.height / CGFloat(t.rows) * scale).rounded())]
        }
        return d
    }

    private func attachCore(reason: String) {
        NSLog("Reflex: attach %@ through herdr-core (%@)", pane, reason)
        stream?.close()
        stream = nil
        ended = false
        elsewhere = false
        watching = false
        attached = true
        // A fresh screen: the core paints it whole (screen, history, modes).
        view.feed(text: "\u{1b}c")
        view.resetKeys()
        let t = view.getTerminal()
        let cols = max(t.cols, 20), rows = max(t.rows, 5)
        let display = display()
        let pane = pane
        Task { @MainActor [weak self] in
            do {
                let s = try await CoreLink.shared.attach(pane, cols: cols, rows: rows, history: 2000, display: display)
                guard let self else { return s.close() }
                guard self.attached, self.stream == nil else { return s.close() }
                self.stream = s
                s.start(data: { [weak self] d in self?.view.feed(byteArray: ArraySlice([UInt8](d))) },
                        closed: { [weak self] why in self?.coreEnded(why) })
                if self.view.window?.isKeyWindow == true { s.focus(true) }
                // Its size now, if the window changed while this opened.
                let now = self.view.getTerminal()
                if now.cols != cols || now.rows != rows { s.resize(cols: now.cols, rows: now.rows) }
                self.reattaching = 0
            } catch {
                NSLog("Reflex: attach %@ through herdr-core failed: %@", pane, error.localizedDescription)
                self?.coreEnded((error as? HerdrCore.Failure)?.kind ?? "lost")
            }
        }
    }

    /// Its stream ended. Lost — the program (a kept terminal gets a new
    /// shell) or the line to the core (an update restarts it) — comes back:
    /// try again for a while. An exit or a kill is the end.
    private func coreEnded(_ why: String) {
        stream = nil
        guard attached else { return }
        let back = ["lost", "unavailable", "timeout", "signaled", "server_stop", "stopped_by_restart", "holder_lost"]
        if back.contains(why), reattaching < 30 {
            reattaching += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.attached, self.stream == nil else { return }
                self.attachCore(reason: "back after \(why)")
            }
            return
        }
        NSLog("Reflex: %@ ended in herdr-core (%@)", pane, why)
        attached = false
        withAnimation(Motion.enter) { ended = true }
    }

    /// Attach, retrying quietly: Herdr refuses an attach while a read is in
    /// flight. A terminal takes one attached client. One left behind by a
    /// Reflex that was killed or crashed is ended first (see endOrphans); one
    /// that is live — another window — keeps it, and this window says so and
    /// offers to take it (`takeover`), rather than the two taking it in turns.
    func attach(takeover: Bool = false, reason: String) {
        if core { return attachCore(reason: reason) }
        if switchFromRunning({ [weak self] in self?.attach(takeover: takeover, reason: reason) }) { return }
        NSLog("Reflex: attach %@ (%@%@)", pane, reason, takeover ? ", taking over" : "")
        ended = false
        elsewhere = false
        watching = false
        view.resetKeys()
        TerminalSession.endOrphans(pane: pane)
        try? FileManager.default.removeItem(at: why)
        let script = """
        \(Self.waitForTunnel)
        err=$(mktemp -t reflex-attach)
        for i in 1 2 3 4 5 6 7 8 9 10; do
          herdr agent attach "$4" $3 2>"$err"; status=$?
          # Taken by another window, or held by one (a client just ended may
          # still hold it for a moment: ask again a few times first).
          if grep -q "taken over" "$err"; then echo elsewhere > "$2"; rm -f "$err"; exit 1; fi
          [ $status = 0 ] && { rm -f "$err"; exit 0; }
          if grep -q "already has an attached client" "$err"; then
            [ $i -lt 2 ] && { sleep 0.2; continue; }
            echo elsewhere > "$2"; rm -f "$err"; exit 1
          fi
          # A window not laid out yet (opened at launch) is a 0×0 terminal, and
          # another Mac's tunnel may be reconnecting: both pass in a moment.
          grep -q -e retry -e "zero-sized" -e server_not_running "$err" || { cat "$err"; { printf 'error '; cat "$err"; } > "$2"; rm -f "$err"; exit 1; }
          printf '\\033[2J\\033[H'; sleep 0.3
        done
        rm -f "$err"; exit 1
        """
        view.startProcess(executable: "/bin/sh", args: ["-c", script, "reflex-attach", pane, why.path, takeover ? "--takeover" : "", herdrPane],
                          environment: herdrEnv())
        attached = true
        watchExit()
    }

    /// Watch without taking the terminal: herdr streams the screen as ANSI
    /// frames (JSON lines, base64), drawn here as they come; the size follows
    /// this window's (the stream restarts on a resize). Keys go nowhere.
    func watch(reason: String) {
        if core { return attachCore(reason: reason) }
        if switchFromRunning({ [weak self] in self?.watch(reason: reason) }) { return }
        NSLog("Reflex: watch %@ (%@)", pane, reason)
        ended = false
        elsewhere = false
        view.resetKeys()
        let script = """
        stty -echo -icanon 2>/dev/null
        printf '\\033[?25l'
        while :; do
          resized=
          trap 'resized=1; kill $obs 2>/dev/null' WINCH
          herdr terminal session observe "$1" --cols "$(tput cols)" --rows "$(tput lines)" 2>/dev/null |
            /usr/bin/perl -MJSON::PP -MMIME::Base64 -ne '$|=1; my $d = eval { decode_json($_) } or next;
              exit 0 if $d->{type} eq "terminal.closed";
              print decode_base64($d->{bytes}) if $d->{type} eq "terminal.frame"' &
          obs=$!
          wait $obs
          [ -n "$resized" ] || exit 0
          pkill -P $$ -f "terminal session observe" 2>/dev/null
        done
        """
        view.startProcess(executable: "/bin/sh", args: ["-c", script, "reflex-watch", herdrPane, pane],
                          environment: herdrEnv())
        attached = true
        watching = true
        watchExit()
    }

    private func type(_ data: ArraySlice<UInt8>) {
        outbox.append(contentsOf: data)
        guard !sending else { return }
        sending = true
        Task { @MainActor in
            while !outbox.isEmpty {
                let chunk = outbox
                outbox = []
                await Client.local.type(pane, String(decoding: chunk, as: UTF8.self))
            }
            sending = false
        }
    }

    /// The process started last, until its end is handled.
    private var live: pid_t = 0

    /// SwiftTerm misses a process that ends at once: it watches for the exit
    /// only after the fork, and its end-of-output path doesn't report it. A
    /// quick failure (a tunnel not up yet) left the window blank. So look too:
    /// gone without a word, it is reaped here and handled as an end.
    private func watchExit() {
        guard let pid = view.process?.shellPid, pid > 0 else { return }
        live = pid
        check(pid)
    }

    private func check(_ pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.live == pid else { return }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid || self.view.process?.running == false {
                NSLog("Reflex: %@ ended unreported; handling it", self.pane)
                self.handleEnd()
            } else {
                self.check(pid)
            }
        }
    }

    /// SwiftTerm says a process ended before it lets go of it, and ignores a
    /// start until it has: wait for that (briefly) before starting the next.
    private func whenStopped(_ then: @escaping () -> Void, tries: Int = 40) {
        guard view.process?.running == true, tries > 0 else { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.whenStopped(then, tries: tries - 1)
        }
    }

    /// Ends what runs now and starts `then` once it has: true if it had to.
    private func switchFromRunning(_ then: @escaping () -> Void) -> Bool {
        guard attached, let pid = view.process?.shellPid, pid > 0 else { return false }
        next = then
        kill(-pid, SIGKILL)
        return true
    }

    /// Another Mac's terminal opened while its tunnel is (re)connecting, at
    /// launch say: wait until its herdr answers through it (a socket file can
    /// be left from before; `status server` succeeds either way, so read it),
    /// a little, before trying.
    private static let waitForTunnel = """
    if [ -n "$HERDR_SOCKET_PATH" ]; then
      i=0; until herdr status server --json 2>/dev/null | grep -q '"running":true'; do
        [ $i = 0 ] && printf 'Connecting…\\r'; i=$((i+1)); [ $i -ge 40 ] && break; sleep 0.5
      done
    fi
    """

    /// The pane's id in its own herdr (another Mac's, through the tunnel).
    private var herdrPane: String { Machines.route(pane)?.pane ?? pane }

    private func herdrEnv() -> [String] {
        var env = Daemon.shared.childEnvironment()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // On another machine: its herdr, through the tunnel (see Machines).
        if let remote = Machines.route(pane) {
            env["HERDR_SOCKET_PATH"] = remote.sock
            env["HERDR_SESSION"] = nil
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    func detach() {
        if core {
            attached = false
            stream?.close()
            stream = nil
        }
        // The attach runs in its own session (setsid): end the whole group.
        // herdr's client ignores SIGTERM and could outlive the window,
        // keeping the pane from the next one.
        if attached, let pid = view.process?.shellPid, pid > 0 { kill(-pid, SIGKILL) }
        if attached { view.terminate() }
        attached = false
        watching = false
        next = nil
        // What was killed here ends unheard: nothing comes next.
        live = 0
        try? FileManager.default.removeItem(at: why)
        TerminalScroll.views[ObjectIdentifier(view)] = nil
        TerminalSelect.toAgent[ObjectIdentifier(view)] = nil
    }

    /// Attach scripts for this pane whose Reflex is gone (killed, crashed):
    /// their parent is launchd. Their clients would hold the terminal.
    static func endOrphans(pane: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, f[1] == "1", let pid = Int32(f[0]),
                  f[2].hasPrefix("/bin/sh -c "),
                  f[2].contains(" reflex-attach \(pane) ") || f[2].hasSuffix(" reflex-attach \(pane)") || f[2].hasSuffix(" \(pane)") && f[2].contains(" reflex-watch ")
            else { continue }
            NSLog("Reflex: ending an orphaned attach to %@ (%d)", pane, pid)
            kill(-pid, SIGKILL)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.handleEnd() }
    }

    /// The process ended (SwiftTerm said so, or watchExit saw it): start what
    /// comes next — the one asked for, sharing when another has the terminal,
    /// or the ended state.
    private func handleEnd() {
        guard live != 0 else { return }
        live = 0
        attached = false
        if let next {
            self.next = nil
            whenStopped(next)
            return
        }
        if watching {
            NSLog("Reflex: watching %@ ended", pane)
            watching = false
            withAnimation(Motion.enter) { ended = true }
            return
        }
        let said = (try? String(contentsOf: why, encoding: .utf8)) ?? ""
        let elsewhere = said.hasPrefix("elsewhere")
        NSLog("Reflex: attach to %@ ended%@", pane, elsewhere ? " (open elsewhere)" : said.isEmpty ? "" : ": " + said.trimmingCharacters(in: .whitespacesAndNewlines))
        // Another window or Mac has it: share it.
        if elsewhere {
            whenStopped { [weak self] in self?.watch(reason: "open elsewhere") }
            return
        }
        withAnimation(Motion.enter) { ended = true }
    }
}

/// Hosts the terminal at exactly the size it shows. SwiftTerm reserves a
/// scroller's width — even an overlay scroller's, which draws nothing — until
/// it is hidden, and hiding it hands that width back: the grid is then never
/// wider than the window, so a line's last column can't fall off the edge.
final class TerminalContainer: NSView {
    let term: LocalProcessTerminalView

    init(term: LocalProcessTerminalView) {
        self.term = term
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(term)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Hidden first, then sized: the columns follow the width left over.
        for case let scroller as NSScroller in term.subviews { scroller.isHidden = true }
        // setFrameSize recomputes them even when the size is unchanged, as it
        // is when the first layout finds a size set with the scroller shown.
        term.frame.origin = .zero
        term.setFrameSize(bounds.size)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer(term: session.view) }
    func updateNSView(_ v: TerminalContainer, context: Context) {}
}

/// Scrolling in an agent terminal. herdr's attach client (like most TUIs) runs
/// in the alternate screen with mouse reporting on, where there is no local
/// scrollback: the wheel must reach the program as mouse wheel events (SGR),
/// or as arrow keys in an alternate screen without mouse reporting. Only a
/// plain shell falls back to SwiftTerm's own scrollback.
@MainActor
enum TerminalScroll {
    private static var monitor: Any?
    private static var carry: CGFloat = 0
    static var views: [ObjectIdentifier: LocalProcessTerminalView] = [:]

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard let view = views.values.first(where: { $0.window === e.window && $0.window != nil }) else { return e }
            let p = view.convert(e.locationInWindow, from: nil)
            guard view.bounds.contains(p) else { return e }
            // The text moves out from under a link's hint; the next move finds what's there.
            (view as? AgentTerminalView)?.hover(at: nil, command: false)
            return handle(e, view: view, at: p) ? nil : e
        }
    }

    private static func handle(_ e: NSEvent, view: LocalProcessTerminalView, at p: NSPoint) -> Bool {
        let t = view.getTerminal()
        let mouse = t.mouseMode != .off
        guard mouse || t.isCurrentBufferAlternate else { return false }
        // Trackpads report many small precise deltas; turn them into whole lines.
        let unit: CGFloat = e.hasPreciseScrollingDeltas ? 18 : 1
        carry += e.scrollingDeltaY / unit
        let lines = Int(carry.rounded(.towardZero))
        guard lines != 0 else { return true }
        carry -= CGFloat(lines)
        let up = lines > 0
        let cols = max(t.cols, 1), rows = max(t.rows, 1)
        let width = view.bounds.width
        let col = min(cols - 1, max(0, Int(p.x / max(width, 1) * CGFloat(cols))))
        let row = min(rows - 1, max(0, Int((view.bounds.height - p.y) / max(view.bounds.height, 1) * CGFloat(rows))))
        for _ in 0..<min(abs(lines), 12) {
            if mouse {
                let flags = t.encodeButton(button: up ? 4 : 5, release: false,
                                           shift: e.modifierFlags.contains(.shift),
                                           meta: e.modifierFlags.contains(.option),
                                           control: e.modifierFlags.contains(.control))
                t.sendEvent(buttonFlags: flags, x: col, y: row)
            } else {
                view.send(txt: t.applicationCursor ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B"))
            }
        }
        return true
    }
}

/// Selecting text in an agent terminal. herdr's attach turns mouse reporting
/// on, so a drag goes to the program: right inside an agent that selects for
/// itself, useless in the plain shell left after it exits. So with no agent in
/// the pane the mouse stays here (drag selects, ⌘C copies), and Shift-drag
/// selects anywhere, as in Ghostty.
@MainActor
enum TerminalSelect {
    private static var monitor: Any?
    /// Per terminal: whether its pane has an agent to give the mouse to.
    static var toAgent: [ObjectIdentifier: Bool] = [:]
    /// The terminal a Shift-drag is selecting in, until the button comes up.
    private static var holding: LocalProcessTerminalView?

    static func set(_ view: LocalProcessTerminalView, agent: Bool) {
        toAgent[ObjectIdentifier(view)] = agent
        if holding !== view { view.allowMouseReporting = agent }
    }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            if e.type == .leftMouseUp {
                // Back to the agent once the terminal has seen the release.
                if holding != nil { DispatchQueue.main.async { release() } }
                return e
            }
            guard e.modifierFlags.contains(.shift),
                  let view = TerminalScroll.views.values.first(where: { $0.window === e.window && $0.window != nil }),
                  view.bounds.contains(view.convert(e.locationInWindow, from: nil)) else { return e }
            holding = view
            view.allowMouseReporting = false
            return e
        }
    }

    private static func release() {
        guard let v = holding else { return }
        holding = nil
        v.allowMouseReporting = toAgent[ObjectIdentifier(v)] ?? true
    }
}

/// An agent's terminal: links under the pointer, and keys that can go through
/// herdr instead of the process. SwiftTerm speaks the kitty keyboard protocol
/// an agent asks for through herdr (Claude Code's Shift-Return newline,
/// pi's Option-Up), and with it off sends modified keys as Ghostty does.
final class AgentTerminalView: LocalProcessTerminalView {
    /// A new process starts with legacy keys: whatever a killed client pushed
    /// (`CSI > flags u`) was never popped, so pop it all.
    func resetKeys() { feed(text: "\u{1b}[<99u") }

    // MARK: Links

    /// ⌘-click opens a link, as in Ghostty: an OSC 8 hyperlink, or a URL just
    /// written out (pi and Claude Code print them plain, which SwiftTerm
    /// ignores). Over one, ⌘ turns the pointer into a hand, and `onLink`
    /// reports it, with where the pointer met it, for the hint under the
    /// pointer. The clicks are TerminalLinks'.
    var onLink: ((String?, CGPoint) -> Void)?
    /// Keys and pastes on their way to the process: true takes them (a shared
    /// terminal types through herdr instead).
    var onInput: ((ArraySlice<UInt8>) -> Bool)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let onInput, onInput(data) { return }
        super.send(source: source, data: data)
    }

    // MARK: Size and focus

    /// The grid's size whenever it changes, and whether this view has the
    /// keyboard: a herdr-core stream has no process to tell (SwiftTerm only
    /// reports a size to one), so the view says it.
    var onResize: ((Int, Int) -> Void)?
    var onFocus: ((Bool) -> Void)?
    private var grid = (cols: 0, rows: 0)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let t = getTerminal()
        guard t.cols != grid.cols || t.rows != grid.rows else { return }
        grid = (t.cols, t.rows)
        onResize?(t.cols, t.rows)
    }

    /// Focus follows its window: one terminal per window, which has the
    /// keyboard while the window is key.
    private var keyWatch: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyWatch.forEach(NotificationCenter.default.removeObserver)
        keyWatch = []
        guard let w = window else { return }
        for (name, on) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            keyWatch.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocus?(on) }
            })
        }
    }

    // MARK: Images

    /// The Mac its agent runs on ("" for this one; see Machines), and its pane.
    var machine = ""
    var pane = ""

    /// ⌘V with an image (a screenshot, a file copied in Finder) pastes its
    /// path, as a drop into Ghostty does, and the agent reads it: Claude Code
    /// makes it an [Image]. One on another Mac gets a copy there first.
    /// Text pastes as always.
    override func paste(_ sender: Any) {
        let images = Attachments.read(.general)
        guard !images.isEmpty else { return super.paste(sender) }
        let machine = machine
        Task { @MainActor in
            var paths = images.map(\.url.path)
            if !machine.isEmpty {
                do {
                    // herdr-core puts a file beside the terminal, on its machine.
                    paths = HerdrCore.isCore(pane) ? try await Attachments.put(images.map(\.url), beside: pane)
                        : try await Attachments.copy(images.map(\.url), to: machine)
                } catch {
                    NSLog("Reflex: pasting an image to %@: %@", machine, (error as? Attachments.NotCopied)?.why ?? "\(error)")
                    NSSound.beep()
                    return
                }
            }
            let text = paths.map(Self.escaped).joined(separator: " ")
            if terminal.bracketedPasteMode { send(txt: "\u{1b}[200~") }
            send(txt: text)
            if terminal.bracketedPasteMode { send(txt: "\u{1b}[201~") }
        }
    }

    /// A path as a shell (and a terminal drop) writes it: backslashes before
    /// anything but plain characters.
    private static func escaped(_ path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,@"))
        return path.unicodeScalars.map { plain.contains($0) ? String($0) : "\\" + String($0) }.joined()
    }
    private(set) var hovered: String?
    private var hoverArea: NSTrackingArea?
    /// Owns the tracking area: SwiftTerm's own mouseMoved would also send
    /// each move to a program that asked for motion, so it can't be the owner.
    private lazy var hoverOwner = HoverOwner(self)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                  owner: hoverOwner, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    func hover(at p: NSPoint?, command: Bool) {
        let url = p.flatMap { link(at: $0) }
        if url != hovered {
            hovered = url
            // Window content coordinates, top-left origin, as SwiftUI lays out.
            let w = p.map { convert($0, to: nil) } ?? .zero
            onLink?(url, CGPoint(x: w.x, y: (window?.contentView?.bounds.height ?? 0) - w.y))
        }
        if p != nil { (url != nil && command ? NSCursor.pointingHand : NSCursor.iBeam).set() }
    }

    private final class HoverOwner: NSResponder {
        weak var view: AgentTerminalView?
        init(_ view: AgentTerminalView) { self.view = view; super.init() }
        required init?(coder: NSCoder) { fatalError() }
        override func mouseMoved(with e: NSEvent) {
            guard let v = view else { return }
            v.hover(at: v.convert(e.locationInWindow, from: nil), command: e.modifierFlags.contains(.command))
        }
        override func mouseExited(with e: NSEvent) { view?.hover(at: nil, command: false) }
    }

    /// The link under a point in the view, if any.
    func link(at p: NSPoint) -> String? {
        let t = getTerminal()
        let glyph = font.glyph(withName: "W")
        let cell = CGSize(width: font.advancement(forGlyph: glyph).width,
                          height: ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
        guard cell.width > 0, cell.height > 0, p.x >= 0, p.y >= 0 else { return nil }
        let col = Int(p.x / cell.width), row = Int((bounds.height - p.y) / cell.height)
        guard col < t.cols, row < t.rows, let line = t.getLine(row: row) else { return nil }
        if let payload = line[col].getPayload() as? String, let semi = payload.firstIndex(of: ";") {
            let url = String(payload[payload.index(after: semi)...])
            if AgentTerminalView.opens(url) { return url }
        }
        // One character per column, so a match's offset is its column.
        let text = String((0..<t.cols).map { c -> Character in
            let ch = line[c].getCharacter()
            return ch == "\u{0}" || ch.unicodeScalars.count != 1 ? " " : ch
        })
        let ns = text as NSString
        for m in AgentTerminalView.urls.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var url = ns.substring(with: m.range)
            // Sentence punctuation after a link isn't part of it; a closing
            // bracket is only when the link opened one.
            while let last = url.last, ".,;:!?'\"".contains(last)
                    || (last == ")" && url.filter { $0 == "(" }.count < url.filter { $0 == ")" }.count)
                    || (last == "]" && !url.contains("[")) {
                url.removeLast()
            }
            if col >= m.range.location && col < m.range.location + url.utf16.count && AgentTerminalView.opens(url) { return url }
        }
        return nil
    }

    private static let urls = try! NSRegularExpression(pattern: #"(?:https?|file)://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#)

    /// Web and file links only: an OSC 8 link can name any scheme.
    static func opens(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "mailto"].contains(scheme)
    }
}

/// The Mac's line keys, as Ghostty sends them: ⌘⌫ clears the line (^U),
/// ⌘← and ⌘→ go to its start and end (^A, ^E). SwiftTerm drops ⌘⌫ and moves
/// by a word for the other two.
@MainActor
enum TerminalKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  let view = TerminalScroll.views.values.first(where: { $0.window === e.window && $0.window != nil }),
                  let first = e.window?.firstResponder as? NSView, first.isDescendant(of: view) else { return e }
            switch e.keyCode {
            case 51: view.send(txt: "\u{15}")
            case 123: view.send(txt: "\u{01}")
            case 124: view.send(txt: "\u{05}")
            default: return e
            }
            return nil
        }
    }
}

/// ⌘-click on a link in an agent terminal opens it, and the click goes no
/// further: not to SwiftTerm's selection, nor to the agent. ⌘ pressed or let
/// go over a link swaps the pointer.
@MainActor
enum TerminalLinks {
    private static var monitor: Any?
    /// The link a ⌘-click went down on: opened if it comes up on it too.
    private static var pressed: (view: AgentTerminalView, url: String)?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]) { e in
            guard let view = TerminalScroll.views.values.first(where: { $0.window === e.window && $0.window != nil }) as? AgentTerminalView
            else { return e }
            let p = view.convert(e.locationInWindow, from: nil)
            switch e.type {
            case .flagsChanged:
                // A key event: where the pointer is has to be asked.
                guard let w = view.window, w.isKeyWindow else { return e }
                let at = view.convert(w.mouseLocationOutsideOfEventStream, from: nil)
                view.hover(at: view.bounds.contains(at) ? at : nil, command: e.modifierFlags.contains(.command))
                return e
            case .leftMouseDown:
                guard e.modifierFlags.contains(.command), view.bounds.contains(p), let url = view.link(at: p) else { return e }
                pressed = (view, url)
                return nil
            case .leftMouseDragged:
                return pressed == nil ? e : nil
            default:
                guard let (v, url) = pressed else { return e }
                pressed = nil
                if v === view, view.link(at: p) == url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
                return nil
            }
        }
    }
}

struct AgentPopout: View {
    @ObservedObject var session: TerminalSession
    /// The window's title-bar height: the header shares that row with the traffic lights.
    var titlebar: CGFloat = 28
    @ObservedObject var store = Store.shared
    @ObservedObject var themes = Themes.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hintSize = CGSize.zero

    private var agent: AgentInfo? { store.state.agents.first { $0.pane == session.pane } }
    private var theme: TermTheme { themes.current }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                TerminalHost(session: session)
                    .padding(.top, 4)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.bottom, 6)
                if session.watching {
                    // Top right, small: the input box is at the bottom, and you type here too.
                    VStack {
                        HStack(spacing: 8) {
                            Spacer()
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.on.rectangle").font(.system(size: 11, weight: .semibold))
                                Text("Shared").font(.system(size: 12, weight: .semibold))
                                Button("Take Over") { session.attach(takeover: true, reason: "take over") }
                                    .buttonStyle(.glassProminent).controlSize(.small)
                            }
                            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
                            .raySurface(Capsule())
                            .help("Another window or Mac has \(agent?.kind ?? "the agent") open too: both see it and type here. That one sets the size; Take Over makes it this one, with the mouse.")
                        }
                        .padding(10)
                        Spacer()
                    }
                    .transition(.surface(reduce: reduce))
                }
                if session.ended {
                    VStack(spacing: 10) {
                        if session.elsewhere {
                            Text("Open in another window").font(Type.title)
                            Text("herdr shows \(agent?.kind ?? "an agent") in one window at a time.")
                                .font(.system(size: 12)).foregroundStyle(Ink.dim)
                            Button("Take It Back") { session.attach(takeover: true, reason: "take back") }.buttonStyle(.glassProminent)
                        } else {
                            Text("Detached from \(agent?.kind ?? "the agent")").font(Type.title)
                            Button("Reattach") { session.attach(reason: "reattach") }.buttonStyle(.glassProminent)
                        }
                    }
                    .padding(18)
                    .raySurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transition(.surface(reduce: reduce))
                }
            }
        }
        .background(Color(hex: theme.background))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { session.attach(reason: "window opened") }
        // An agent takes the mouse; the shell it leaves behind gives it back.
        .onChange(of: agent == nil, initial: true) { _, gone in TerminalSelect.set(session.view, agent: !gone) }
        .onDisappear { session.detach() }
        .overlay(alignment: .topLeading) {
            if let link = session.link, !session.ended {
                GeometryReader { g in
                    linkHint
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { hintSize = $0 }
                        .offset(hintOffset(at: link.at, in: g.frame(in: .global)))
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .id(link.url)
            }
        }
        .animation(Motion.micro, value: session.link?.url)
    }

    /// Just under the pointer, as a tooltip sits; above it at the window's
    /// foot, and never past either side. The pointer is in window content
    /// coordinates; the frame (below the title bar) is too.
    private func hintOffset(at p: CGPoint, in frame: CGRect) -> CGSize {
        let x = min(max(8, p.x - frame.minX - 6), frame.width - hintSize.width - 8)
        let y = p.y - frame.minY
        let below = y + 14
        return CGSize(width: x, height: below + hintSize.height > frame.height - 8 ? y - hintSize.height - 10 : below)
    }

    /// What a link under the pointer does; the link itself is right there.
    private var linkHint: some View {
        Text("⌘-click to open")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(hex: theme.foreground))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color(hex: theme.background).opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(hex: theme.foreground).opacity(0.15)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// One line, exactly as tall as the title bar, so it sits level with the
    /// traffic lights.
    private var header: some View {
        HStack(spacing: 8) {
            AgentGlyph(status: agent?.status ?? "unknown", size: 10, pulse: store.pulses[session.pane] ?? 0, machine: Machines.machine(of: session.pane))
            Text(agent.map { "\($0.kind) · \($0.folder)" } ?? session.pane)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            // Another Mac's agent wears its name here, as in the rail.
            MachineChip(machine: Machines.machine(of: session.pane))
            Text(agent.map { [$0.status, $0.title].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "no agent")
                .font(.system(size: 12))
                .opacity(0.55)
                .lineLimit(1)
                .contentTransition(.interpolate)
            Spacer(minLength: 8)
            if session.attached && !session.watching && !session.core {
                Button { session.watch(reason: "let go") } label: {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color(hex: theme.foreground).opacity(0.6))
                .help("Share: let another window or Mac have the size and mouse; this one still sees and types")
            }
            OpenInButton(agent: agent, pane: session.pane, tint: Color(hex: theme.foreground).opacity(0.6))
            CloseSessionButton(pane: session.pane, tint: Color(hex: theme.foreground).opacity(0.6))
        }
        .foregroundStyle(Color(hex: theme.foreground))
        .padding(.leading, 78)
        .padding(.trailing, 10)
        .frame(height: titlebar)
    }
}

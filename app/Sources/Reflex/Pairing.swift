import SwiftUI

// "Take Reflex with you": a QR the phone's camera opens. It holds a one-time
// code, never the phone token: reflexd trades the code for the token once
// (see /api/pair) and the code is wiped after ten minutes either way.

@MainActor
final class Pairing: ObservableObject {
    static let shared = Pairing()

    enum Phase: Equatable { case preparing, ready(url: String), paired, expired, failed(String) }
    @Published private(set) var phase: Phase = .preparing
    @Published var shown = false

    static let lifetime: TimeInterval = 600
    private var file: URL { Settings.supportDir.appendingPathComponent("pair.txt") }
    private var code = ""
    private var watch: Timer?
    private var expires = Date.distantPast

    /// A fresh code; the phone remote comes on if it was off (scanning is
    /// the ask).
    func start() {
        stop()
        phase = .preparing
        let s = Settings.shared
        if !s.remote {
            s.remote = true
            Daemon.shared.restart()
        }
        code = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? code.write(to: file, atomically: true, encoding: .utf8)
        expires = Date().addingTimeInterval(Pairing.lifetime)
        let code = self.code
        Task {
            // Wait for reflexd (it restarts when the remote just came on) and
            // for the tailnet's name, so the code points somewhere real.
            for _ in 0..<40 {
                if await Client.local.healthy() { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let tailnet = await Task.detached { Tailnet.detect() }.value
            guard self.code == code else { return }
            if tailnet == nil && !s.remoteLAN {
                phase = .failed("Your phone can't reach this Mac yet. Install Tailscale on both — private, and it works anywhere — or allow this Wi-Fi in Settings → Phone.")
                return
            }
            let host = tailnet?.host ?? Remote.addresses.first ?? "127.0.0.1"
            phase = .ready(url: "http://\(host):\(s.port)/?p=\(code)")
        }
        watch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func check() {
        guard !code.isEmpty else { return }
        if Date() > expires { stop(); phase = .expired; return }
        // reflexd wiped the file: the phone has it.
        if case .ready = phase, (try? String(contentsOf: file, encoding: .utf8))?.isEmpty == true {
            code = ""
            watch?.invalidate()
            phase = .paired
        }
    }

    /// Forget the code (Done, expiry, or a new one).
    func stop() {
        watch?.invalidate()
        watch = nil
        code = ""
        try? FileManager.default.removeItem(at: file)
    }

    var remaining: Int { max(0, Int(expires.timeIntervalSinceNow / 60.0.rounded(.up))) }
}

/// The card beside the rail, after getone's: title, a line, the code, the
/// promise (once, ten minutes), Done.
struct PairingCard: View {
    @ObservedObject var pairing = Pairing.shared
    @ObservedObject var tailnet = TailnetState.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    var done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Take Reflex with you")
                    .font(.system(size: 18, weight: .semibold))
                Text("Scan with your phone’s camera. It signs you in, and your agents come along.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                switch pairing.phase {
                case .preparing:
                    ProgressView().controlSize(.regular)
                case .ready(let url):
                    if let img = Remote.qr(url) {
                        Image(nsImage: img).interpolation(.none).resizable()
                            .frame(width: 196, height: 196)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .transition(.opacity.combined(with: .scale(scale: reduce ? 1 : 0.97)))
                    }
                case .paired:
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(Tone.done)
                            .symbolEffect(.bounce, value: pairing.phase == .paired)
                        Text("Your phone is in").font(.system(size: 14, weight: .semibold))
                    }
                    .transition(.opacity)
                case .expired:
                    VStack(spacing: 10) {
                        Text("This code expired").font(.system(size: 14, weight: .semibold))
                        Button("New Code") { pairing.start() }.buttonStyle(.plain)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .rayPill(Capsule())
                    }
                case .failed(let why):
                    Text(why).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            .frame(width: 252, height: 252)
            .animation(Motion.enter, value: pairing.phase)

            Text(footnote)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: done) {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .rayPill(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 300)
        .raySurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { tailnet.refresh() }
    }

    private var footnote: String {
        switch pairing.phase {
        case .paired: return "Add the page to your Home Screen to keep it one tap away."
        default:
            return tailnet.current == nil
                ? "The link works once and expires in 10 minutes. Your phone must be on the same Wi-Fi."
                : "The link works once and expires in 10 minutes. Over Tailscale, it works anywhere."
        }
    }
}

/// The card in its window, with the same entrance and exit as the inbox.
struct PairingHost: View {
    @ObservedObject var pairing = Pairing.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    var done: () -> Void

    var body: some View {
        PairingCard(done: done)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(pairing.shown ? 1 : 0)
            .scaleEffect(pairing.shown || reduce ? 1 : 0.97, anchor: .trailing)
            .offset(x: pairing.shown || reduce ? 0 : 14)
            .blur(radius: pairing.shown || reduce ? 0 : 3)
            .animation(pairing.shown ? Motion.enter : Motion.exit, value: pairing.shown)
            // It stays while you pick up your phone (no click-away); once the
            // phone is in, it goes on its own.
            .onChange(of: pairing.phase) { _, phase in
                guard phase == .paired else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if pairing.phase == .paired && pairing.shown { done() }
                }
            }
    }
}

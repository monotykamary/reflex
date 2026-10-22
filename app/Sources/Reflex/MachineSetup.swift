import AppKit
import SwiftUI

// Adding another Mac (Settings → Machines, and onboarding): type how ssh
// reaches it, Test says what stands in the way in words you can act on
// (Remote Login off, or limited to some users; no key; a host key never
// seen; asleep or off the tailnet; herdr missing), and Add saves it with
// `herdr machine add`, the same saved machines herdr's own sidebar uses.

@MainActor
final class MachineSetup: ObservableObject {
    static let shared = MachineSetup()

    enum Verdict: Equatable {
        case ready(herdr: Bool)
        case loginOff, refused, noKey, hostKey, unreachable
        case other(String)
    }

    enum Phase: Equatable {
        case idle, testing, adding
        case tested(Verdict)
        case added
        case addFailed(String)
    }

    @Published var host = ""
    @Published var phase = Phase.idle

    private var target: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canTest: Bool { !target.isEmpty && phase != .testing && phase != .adding }

    func test() {
        let target = target
        guard !target.isEmpty else { return }
        phase = .testing
        let env = Daemon.shared.childEnvironment()
        Task.detached {
            // -v: whether it got as far as signing in tells "Remote Login
            // allows only some users" from "nothing answers SSH there".
            let r = Self.run(env, "/usr/bin/ssh", ["-v", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", target,
                                              "PATH=\"$HOME/.local/bin:$PATH\"; command -v herdr >/dev/null && echo herdr-yes || echo herdr-no"])
            let verdict = Self.verdict(r)
            await MainActor.run { if self.target == target { self.phase = .tested(verdict) } }
        }
    }

    func add() {
        let target = target
        guard !target.isEmpty else { return }
        phase = .adding
        let env = Daemon.shared.childEnvironment()
        Task.detached {
            let r = Self.run(env, "/bin/sh", ["-c", "herdr machine add \"$1\"", "herdr-add", target])
            await MainActor.run {
                if r.status == 0 {
                    self.phase = .added
                    self.host = ""
                    Machines.shared.refresh()
                } else {
                    let why = (r.err + "\n" + r.out).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }.suffix(2).joined(separator: " ")
                    self.phase = .addFailed(why.isEmpty ? "herdr couldn't add it." : why)
                }
            }
        }
    }

    /// The command for Terminal, when a step needs you (a password, an approval).
    var command: String? {
        let t = target.isEmpty ? "<host>" : target
        switch phase {
        case .tested(.noKey): return "ssh-copy-id \(t)"
        case .tested(.hostKey): return "ssh \(t)"
        case .tested(.ready(herdr: false)), .addFailed: return "herdr machine add \(t)"
        default: return nil
        }
    }

    /// What Test found, and what to do about it.
    var advice: (ok: Bool, text: String)? {
        switch phase {
        case .idle, .testing, .adding: return nil
        case .added: return (true, "Added. Its agents show up here as soon as the tunnel is up.")
        case .addFailed(let why): return (false, "herdr didn't add it: \(why) Run the command in Terminal: herdr asks there before it installs or restarts anything.")
        case .tested(let v):
            switch v {
            case .ready(herdr: true): return (true, "Signed in, and herdr is there. Add it.")
            case .ready(herdr: false): return (false, "Signed in, but herdr isn't installed on it. Run the command in Terminal: herdr offers to install itself there.")
            case .loginOff: return (false, "Nothing answers SSH on it: Remote Login is off (or a port is wrong). On that Mac: System Settings → General → Sharing → Remote Login.")
            case .refused: return (false, "That Mac let you sign in, then closed the connection: Remote Login allows only some users. On it: Sharing → Remote Login → ⓘ → Allow access for, add your user. A managed work Mac may need IT for this.")
            case .noKey: return (false, "That Mac doesn't know this one's SSH key yet. Run the command in Terminal once, with that Mac's password, then Test again.")
            case .hostKey: return (false, "This Mac hasn't met that one yet (or its key changed). Run the command in Terminal once and accept its key, then Test again.")
            case .unreachable: return (false, "Can't reach it: is it awake, and on your network or tailnet? With Tailscale in userspace mode, give it `ProxyCommand tailscale nc %h %p` in ~/.ssh/config.")
            case .other(let e): return (false, e)
            }
        }
    }

    nonisolated private static func verdict(_ r: (status: Int32, out: String, err: String)) -> Verdict {
        if r.status == 0 { return .ready(herdr: r.out.contains("herdr-yes")) }
        let e = r.err.lowercased()
        if e.contains("host key verification failed") || e.contains("remote host identification has changed") { return .hostKey }
        if e.contains("permission denied") { return .noKey }
        // Signed in, then shown the door: macOS's Remote Login access list.
        if e.contains("authenticated to") { return .refused }
        // Nothing answers SSH (through `tailscale nc` too: the dial is refused
        // and the handshake never starts).
        if e.contains("connection refused") || e.contains("connection was refused") || e.contains("kex_exchange_identification") {
            return .loginOff
        }
        if e.contains("could not resolve") || e.contains("timed out") || e.contains("timeout") || e.contains("no route")
            || e.contains("unreachable") || e.contains("is down") || e.contains("dial failure") { return .unreachable }
        let last = r.err.split(separator: "\n").last { !$0.hasPrefix("debug") }.map(String.init) ?? "ssh failed (\(r.status))."
        return .other(last)
    }

    nonisolated private static func run(_ env: [String: String], _ exe: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "", "couldn't run \(exe)") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

/// Host field, Test and Add, and what Test found. Fits a Settings form and an
/// onboarding page alike.
struct AddMachineView: View {
    @ObservedObject var setup = MachineSetup.shared

    private var ready: Bool { setup.phase == .tested(.ready(herdr: true)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $setup.host, prompt: Text("ssh host — e.g. work-laptop or you@100.64.0.2"))
                    .textFieldStyle(.roundedBorder)
                    // A Form right-aligns a field's text; this one reads as an input line.
                    .multilineTextAlignment(.leading)
                    .labelsHidden()
                    .onSubmit { ready ? setup.add() : setup.test() }
                    .onChange(of: setup.host) { if setup.phase != .testing && setup.phase != .adding { setup.phase = .idle } }
                Button(setup.phase == .testing ? "Testing…" : "Test") { setup.test() }
                    .buttonStyle(.glass)
                    .disabled(!setup.canTest)
                Button(setup.phase == .adding ? "Adding…" : "Add") { setup.add() }
                    .buttonStyle(.glassProminent)
                    .tint(Tone.remote)
                    .disabled(!ready)
            }
            if let a = setup.advice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: a.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(a.ok ? Tone.done : Tone.blocked)
                    Text(a.text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .transition(.opacity)
            }
            if let c = setup.command {
                HStack(spacing: 8) {
                    Text(c).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c, forType: .string)
                    }
                    .buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .animation(Motion.enter, value: setup.phase)
    }
}

/// The three things another Mac needs, as a short list.
struct MachineSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            step(1, "On the other Mac, turn on Remote Login", "System Settings → General → Sharing → Remote Login, and under ⓘ allow your user.")
            step(2, "Let this Mac sign in with a key", "`ssh-copy-id <host>` once; Test tells you if it's missing. Tailscale works.")
            step(3, "Add it", "Reflex runs `herdr machine add`, and keeps a tunnel to it from then on.")
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(Tone.remote)
                .frame(width: 18, height: 18)
                .background(Tone.remote.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

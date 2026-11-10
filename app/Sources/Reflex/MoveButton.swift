import SwiftUI

/// The terminal window's move button: this session to a new boat machine, or
/// to another machine herdr-core reaches. Pressing it is the OK; a session
/// mid-turn moves once the turn ends.
struct MoveButton: View {
    var agent: AgentInfo?
    var tint: Color
    @ObservedObject private var move = HerdrMove.shared
    @ObservedObject private var template = BoatTemplate.shared
    @State private var machines: [CoreMachines.Machine] = CoreMachines.known

    var body: some View {
        Menu {
            if let a = agent { items(a) }
        } label: {
            Image(systemName: "sailboat")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(tint)
        .foregroundStyle(tint)
        .disabled(agent == nil || move.moving.contains(agent?.pane ?? ""))
        .help("Move this session to another machine")
        .task {
            await BoatTemplate.shared.refresh()
            machines = await CoreMachines.list()
        }
    }

    @ViewBuilder private func items(_ a: AgentInfo) -> some View {
        switch move.readiness(a, to: Boat.key) {
        case .kind:
            Text("Reflex resumes claude, pi and codex, not \(a.kind)")
        case .noSession:
            Text("Reflex doesn't know this session's id yet")
        case .notHere:
            Text("Only this Mac's sessions move to another machine")
        default:
            if Boat.hasBoat {
                Section("boat.dev") {
                    Button(template.exists ? "New Boat Machine" : "New Boat Machine (builds your template first)") { move.toBoat(a) }
                    if case .stale(_, let changed) = template.state {
                        Button("Rebuild Template, Then Move") { move.toBoat(a, rebuild: true) }
                        Text("Changed since the template: " + changed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    } else if template.exists {
                        Button("Rebuild Template, Then Move") { move.toBoat(a, rebuild: true) }
                    }
                }
            }
            let others = machines.filter { $0.state == "connected" && $0.name != a.machine }
            if !others.isEmpty {
                Section("Machines") {
                    ForEach(others, id: \.name) { m in
                        Button("Move to \(m.name)") { move.prepare(a, to: m.name) }
                    }
                }
            }
            if !Boat.hasBoat && others.isEmpty {
                Text("No other machine: install the boat CLI, or add one in Settings → Machines")
            }
            if move.readiness(a, to: Boat.key) == .busy {
                Text("It moves once this turn ends")
            }
            Text("\(a.kind) copies what its work needs, then moves")
        }
    }
}

/// Across the top of the terminal window: an agent asking to move (yours to
/// approve), or what a move is doing.
struct MoveBanner: View {
    var pane: String
    var tint: Color
    @ObservedObject private var requests = MoveRequests.shared
    @ObservedObject private var move = HerdrMove.shared

    var body: some View {
        if let r = requests.request(for: pane) {
            HStack(spacing: 8) {
                Image(systemName: "sailboat").font(.system(size: 11, weight: .semibold))
                Text("Move to \(r.to)?").font(.system(size: 12, weight: .semibold))
                Button("Not Now") { requests.decline(r) }.controlSize(.small)
                Button("Move") { requests.approve(r) }.buttonStyle(.glassProminent).controlSize(.small)
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
            .raySurface(Capsule())
            .help("The agent asked to move this session to \(r.to). It moves once its turn ends. Settings → Machines can approve these for you.")
        } else if let note = move.notes[pane] {
            HStack(spacing: 8) {
                if move.moving.contains(pane) || note.hasSuffix("…") { ProgressView().controlSize(.mini) }
                Text(note).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Button { move.dismissNote(pane) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .raySurface(Capsule())
            .frame(maxWidth: 520)
        }
    }
}

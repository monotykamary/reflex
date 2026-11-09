import Foundation

@main struct MachineRemovalTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    static func write(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: Settings.supportDir.appendingPathComponent(name))
    }
    static func read(_ name: String) throws -> [[String: Any]] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Settings.supportDir.appendingPathComponent(name))) as! [[String: Any]]
    }
    static func args(_ name: String) throws -> [String] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Settings.supportDir.appendingPathComponent(name + ".args"))) as! [String]
    }
    static func flushUI() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }
    static func expectFailure(_ action: () async throws -> Void) async {
        do {
            try await action()
            fatalError("Removal should have failed")
        } catch {
            check(error.localizedDescription.contains("test removal refused"), "Show the backend's error, not silent failure")
        }
    }

    @MainActor static func main() async throws {
        // A hung callback or a blocked main actor must not leave CI running.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { fatalError("Removal harness timed out") }
        let fm = FileManager.default
        try fm.createDirectory(at: Machines.dir, withIntermediateDirectories: true)
        let localSocket = Machines.dir.appendingPathComponent("local.sock")
        try Data("local untouched".utf8).write(to: localSocket)
        let id = "profile with spaces & 'quotes'"
        let profiles: [[String: Any]] = [
            ["id": id, "label": "Work", "target": "first", "session": "default", "enabled": true],
            ["id": "other", "label": "Work", "target": "second", "session": "default", "enabled": true],
            ["id": "disabled", "label": "Off", "target": "third", "session": "default", "enabled": false]
        ]
        try write("herdr.json", profiles)
        let machines = Machines()
        try machines.fixture(JSONSerialization.data(withJSONObject: profiles))
        await flushUI()
        check(MachinesModel.shared.rows.count == 3, "Fixture publishes every saved profile")
        let removed = MachinesModel.shared.rows.first { $0.id == id }!
        let other = MachinesModel.shared.rows.first { $0.id == "other" }!
        check(removed.key != other.key, "Duplicate labels have distinct tunnel keys")
        let refreshes = RemoteIndex.shared.refreshes

        // Failure must leave both the saved profile and local connections intact.
        try Data().write(to: Settings.supportDir.appendingPathComponent("fail"))
        await expectFailure { try await machines.remove(id) }
        await flushUI()
        check(machines.fixtureKeys.count == 2, "Failed removal preserves tunnels")
        check(MachinesModel.shared.rows.count == 3, "Failed removal preserves rows")
        check(RemoteIndex.shared.refreshes == refreshes, "No refresh for a failed removal")
        try fm.removeItem(at: Settings.supportDir.appendingPathComponent("fail"))

        try await machines.remove(id)
        await flushUI()
        let herdrArgs = try args("herdr")
        check(herdrArgs == ["machine", "remove", id], "Remove by exact profile ID as one argument, not label/key or shell source")
        check(machines.fixtureKeys == [other.key], "Only the matching tunnel is removed")
        check(MachinesModel.shared.rows.map(\.id).sorted() == ["disabled", "other"], "Published rows drop the removed profile")
        let savedHerdr = try read("herdr.json")
        check(savedHerdr.count == 2, "Removal persists in herdr, not just UI state")
        for suffix in [".sock", "-client.sock"] {
            check(!fm.fileExists(atPath: Machines.dir.appendingPathComponent(removed.key + suffix).path), "Drop stale socket even when the tunnel process is already gone")
            check(fm.fileExists(atPath: Machines.dir.appendingPathComponent(other.key + suffix).path), "Do not drop another tunnel's socket")
        }
        let listed = try String(contentsOf: Machines.dir.appendingPathComponent("list"), encoding: .utf8)
        check(listed == other.key + "\n", "Removed tunnel bypasses the reconnect grace period")
        try await machines.remove("disabled")
        await flushUI()
        check(MachinesModel.shared.rows.map(\.id) == ["other"], "Disabled profiles can be removed too")
        print("PASS herdr: exact ID, persistence, failed removal, disabled profile, socket/list cleanup")

        let core: [[String: Any]] = [
            ["name": "office", "target": "host1", "state": "connected"],
            ["name": "offline", "target": "host2", "state": "needs_login"],
            ["name": "transient", "target": "host3", "temporary": true]
        ]
        try write("hc.json", core)
        _ = await CoreMachines.list(fresh: 0)
        check(CoreMachines.known.count == 2, "Only saved external core machines are shown")
        // A temporary one Reflex made (a boat machine) is shown.
        let made = Settings.supportDir.appendingPathComponent("boat/machines", isDirectory: true)
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        try Data("bx_test\n".utf8).write(to: made.appendingPathComponent("transient"))
        _ = await CoreMachines.list(fresh: 0)
        check(CoreMachines.known.map(\.name) == ["office", "offline", "transient"] && CoreMachines.known[2].temporary,
              "A temporary machine Reflex made is shown, marked temporary")
        try fm.removeItem(at: made.appendingPathComponent("transient"))
        _ = await CoreMachines.list(fresh: 0)
        try Data().write(to: Settings.supportDir.appendingPathComponent("fail"))
        await expectFailure { try await CoreMachines.remove("office") }
        check(CoreMachines.known.count == 2, "Failed core removal preserves cached machines")
        try fm.removeItem(at: Settings.supportDir.appendingPathComponent("fail"))

        // A periodic list already in flight must not resurrect a removed machine.
        HerdrCore.holdNextList()
        let pending = Task { await CoreMachines.list(fresh: 0) }
        while !HerdrCore.listWaiting { try await Task.sleep(nanoseconds: 1_000_000) }
        try await CoreMachines.remove("office")
        check(CoreMachines.known.map(\.name) == ["offline"], "Success immediately evicts the core cache entry")
        HerdrCore.releaseList()
        let stale = await pending.value
        check(stale.map(\.name) == ["offline"], "An old list response cannot undo removal")
        let coreArgs = try args("hc")
        check(coreArgs == ["machine", "rm", "office", "--json"], "Use the core's saved machine name")
        let reloaded = await CoreMachines.list(fresh: 0)
        check(reloaded.map(\.name) == ["offline"], "Core removal persists after reloading")
        try await CoreMachines.remove("offline")
        check(CoreMachines.known.isEmpty, "Offline core machines can be removed")
        check(RemoteIndex.shared.refreshes == refreshes + 4, "Refresh remote sessions after each successful removal")
        let localData = try Data(contentsOf: localSocket)
        check(localData == Data("local untouched".utf8), "Local connection is never touched")
        print("PASS core: persistence, failure recovery, offline removal, stale-list race, index refresh")
        print("PASS local machine and unrelated external machines remain untouched")
    }
}

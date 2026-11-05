// The real PhoneViewer with a controlled asynchronous core. A wall-clock
// watchdog runs OFF the main actor: its old busy loop starves main timers.
import AppKit
import Foundation

func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    fflush(stdout)
    if !ok { exit(1) }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
    fputs("FAIL phone opens starved the main actor or never completed\n", stderr)
    exit(1)
}

@MainActor
func wave(_ viewer: PhoneViewer, fail: Bool = false) async -> [Bool] {
    HerdrCore.hold = true
    HerdrCore.fail = fail
    let tasks = (0..<8).map { _ in
        Task { @MainActor in
            do { try await viewer.open(); return true } catch { return false }
        }
    }
    while HerdrCore.waiting == nil { await Task.yield() }
    // Let the other calls reach the already-in-flight opening.
    for _ in 0..<20 { await Task.yield() }
    HerdrCore.release()
    var results: [Bool] = []
    for task in tasks { results.append(await task.value) }
    return results
}

@MainActor
func verify() async throws {
    let viewer = PhoneViewer(pane: "probe")
    let ok = await wave(viewer)
    check(ok.allSatisfy { $0 }, "concurrent opens all complete")
    check(HerdrCore.gets == 1 && CoreLink.shared.attaches == 1, "concurrent opens share one attachment")
    try await viewer.open(active: true)
    check(CoreLink.shared.modes == [true, false], "active request upgrades the shared observer")
    try await viewer.open()
    check(CoreLink.shared.attaches == 2, "an observer can reuse an active stream")
    viewer.close()
    let retried = await wave(viewer, fail: true)
    check(retried.contains(false) && retried.contains(true), "failed opening wakes callers; a waiter retries")
    check(HerdrCore.gets == 4 && CoreLink.shared.attaches == 3, "failed opening is cleared before retry")
    viewer.close()
    try await viewer.open()
    check(CoreLink.shared.attaches == 4, "viewer reopens after close")
    print("PhoneViewer opening: all checks passed")
    exit(0)
}
Task { @MainActor in
    do { try await verify() } catch { check(false, "unexpected error: \(error)") }
}
RunLoop.main.run(until: Date() + 15)
exit(1)

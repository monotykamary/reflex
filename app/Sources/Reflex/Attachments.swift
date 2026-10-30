import AppKit
import UniformTypeIdentifiers

// Images pasted or dropped into the Ask bar. Jev never sees them — routing
// is by your words — but the agent does: each image is a PNG file whose
// path rides along with the prompt, and every agent can read an image by
// its path (Claude Code: "Read 1 file", then it describes it).

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let thumb: NSImage

    static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id }
}

enum Attachments {
    /// Per-user temporary folder (private to you; macOS clears it in time).
    static var folder: URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("Reflex", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// Images on the pasteboard: image files (copied in Finder) as they are,
    /// image data (a screenshot, an image copied from a page) saved as PNG.
    /// Plain text on the pasteboard wins: that paste is for the field.
    static func read(_ pb: NSPasteboard) -> [Attachment] {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL]) ?? []
        if !files.isEmpty { return files.compactMap(file) }
        guard pb.string(forType: .string) == nil,
              pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
              let image = NSImage(pasteboard: pb) else { return [] }
        return save(image).map { [$0] } ?? []
    }

    static func file(_ url: URL) -> Attachment? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Attachment(url: url, thumb: image)
    }

    /// As PNG, at most 2048 px on the long side (plenty to read, kinder on
    /// the agent's context).
    static func save(_ image: NSImage) -> Attachment? {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return nil }
        var bitmap = rep
        let long = max(rep.pixelsWide, rep.pixelsHigh)
        if long > 2048 {
            let k = 2048 / CGFloat(long)
            let w = Int(CGFloat(rep.pixelsWide) * k), h = Int(CGFloat(rep.pixelsHigh) * k)
            if let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
                rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                bitmap = scaled
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = folder.appendingPathComponent("image-\(stamp)-\(UUID().uuidString.prefix(4)).png")
        do { try png.write(to: url) } catch { return nil }
        return Attachment(url: url, thumb: image)
    }

    /// The prompt as the agent gets it: your words, then each image's path.
    static func prompt(_ text: String, _ images: [Attachment]) -> String {
        prompt(text, paths: images.map(\.url.path))
    }

    static func prompt(_ text: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        return text + " " + paths.map { "[image: \($0)]" }.joined(separator: " ")
    }

    // MARK: Other Macs

    struct NotCopied: Error { let why: String }

    /// An agent on another Mac can't read this Mac's files, so its images go
    /// there first: over your ssh (as RemoteIndex reads that Mac), into its
    /// own temporary folder. Their paths there, in order.
    static func copy(_ files: [URL], to machine: String) async throws -> [String] {
        // A machine herdr-core added: through the core, no ssh of ours.
        if await CoreMachines.has(machine) {
            var paths: [String] = []
            for f in files { paths.append(try await coreUpload(f, on: machine)) }
            return paths
        }
        return try await Task.detached {
            let (up, env) = Machines.shared.reachable()
            guard let m = up.first(where: { $0.key == machine }) else {
                throw NotCopied(why: "\(machine) isn't connected, so the image can't get there.")
            }
            return try files.map { try upload($0, to: m.target, env: env) }
        }.value
    }

    /// Images pasted into a herdr-core terminal on another Mac: the core puts
    /// each beside the terminal, on its machine (removed with the terminal).
    static func put(_ files: [URL], beside pane: String) async throws -> [String] {
        var paths: [String] = []
        for f in files {
            guard let data = try? Data(contentsOf: f) else { throw NotCopied(why: "Couldn't read \(f.lastPathComponent).") }
            do {
                let r = try await HerdrCore.call("terminal.put", ["terminal": pane, "name": f.lastPathComponent,
                                                                  "data": data.base64EncodedString()], timeout: 60)
                guard let path = r["path"] as? String else { throw NotCopied(why: "herdr-core didn't say where it put the image.") }
                paths.append(path)
            } catch let e as HerdrCore.Failure {
                throw NotCopied(why: "Couldn't put the image there: \(e.message)")
            }
        }
        return paths
    }

    /// The same temporary folder as over ssh, written there by the core.
    private static func coreUpload(_ file: URL, on machine: String) async throws -> String {
        guard let data = try? Data(contentsOf: file) else { throw NotCopied(why: "Couldn't read \(file.lastPathComponent).") }
        let name = uploadName(file)
        do {
            let r = try await HerdrCore.call("machine.exec", ["on": machine, "line": uploadCommand(name),
                                                               "input": data.base64EncodedString(), "timeout": 60], timeout: 70)
            let out = (r["stdout"] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (r["code"] as? Int) == 0, path.hasPrefix("/") else { throw NotCopied(why: "Couldn't copy the image to \(machine).") }
            return path
        } catch let e as HerdrCore.Failure {
            throw NotCopied(why: "Couldn't copy the image to \(machine): \(e.message)")
        }
    }

    private static func uploadName(_ file: URL) -> String {
        let ext = file.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return "image-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "png" : ext)"
    }

    /// Its per-user temporary folder: an ssh session may not set TMPDIR.
    private static func uploadCommand(_ name: String) -> String {
        #"d="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}"; d="${d:-/tmp/}"; d="${d%/}/Reflex"; "#
            + #"mkdir -p "$d" && cat > "$d/\#(name)" && printf '%s' "$d/\#(name)""#
    }

    private static func upload(_ file: URL, to target: String, env: [String: String]) throws -> String {
        guard let input = FileHandle(forReadingAtPath: file.path) else {
            throw NotCopied(why: "Couldn't read \(file.lastPathComponent).")
        }
        defer { try? input.close() }
        let cmd = uploadCommand(uploadName(file))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", target, cmd]
        p.environment = env
        let out = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { throw NotCopied(why: "ssh didn't start.") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, path.hasPrefix("/") else {
            NSLog("Reflex: copying an image to %@ failed (%d)", target, p.terminationStatus)
            throw NotCopied(why: "Couldn't copy the image there over ssh.")
        }
        return path
    }
}

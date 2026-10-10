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
        guard !images.isEmpty else { return text }
        return text + " " + images.map { "[image: \($0.url.path)]" }.joined(separator: " ")
    }
}

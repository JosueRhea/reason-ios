import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// A file on disk waiting to be sent (picked, pasted, dropped or shared).
struct LocalFile: Hashable {
    let id: String
    let url: URL
    let name: String
    let contentType: String
    let size: Int64

    var isImage: Bool { contentType.hasPrefix("image/") }
    var isVideo: Bool { contentType.hasPrefix("video/") }

    static let maxFileBytes: Int64 = 64 << 20
    static let maxTotalBytes: Int64 = 80 << 20
    static let maxCount = 10

    /// Copies `source` into our temp area so it outlives security-scoped / provider URLs.
    static func importing(_ source: URL, suggestedName: String? = nil, type: UTType? = nil) throws -> LocalFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let name = sanitize(suggestedName ?? source.lastPathComponent)
        let dest = dir.appendingPathComponent(id + "-" + name)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        return make(id: id, url: dest, name: name, type: type)
    }

    /// Writes raw data (pasted image, camera photo) to a temp file.
    static func writing(_ data: Data, name: String, type: UTType) throws -> LocalFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let dest = dir.appendingPathComponent(id + "-" + sanitize(name))
        try data.write(to: dest)
        return make(id: id, url: dest, name: sanitize(name), type: type)
    }

    private static func make(id: String, url: URL, name: String, type: UTType?) -> LocalFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let t = type ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let mime = t.preferredMIMEType ?? "application/octet-stream"
        return LocalFile(id: id, url: url, name: name, contentType: mime, size: size)
    }

    private static func sanitize(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "file" : cleaned
    }

    static func validate(_ files: [LocalFile]) -> String? {
        if files.count > maxCount { return "You can send up to \(maxCount) files at a time." }
        if let big = files.first(where: { $0.size > maxFileBytes }) { return "\(big.name) is over 64 MB." }
        if files.reduce(0, { $0 + $1.size }) > maxTotalBytes { return "Files add up to more than 80 MB." }
        return nil
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Small preview: the image itself, a video frame, or nil for other files.
    func thumbnail(maxPixel: CGFloat = 240) async -> UIImage? {
        let url = self.url
        if isImage {
            return await Task.detached {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
        }
        if isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            if let (cg, _) = try? await gen.image(at: .zero) { return UIImage(cgImage: cg) }
        }
        return nil
    }

    static func symbol(for contentType: String, name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if contentType.hasPrefix("image/") { return "photo" }
        if contentType.hasPrefix("video/") { return "play.rectangle.fill" }
        if contentType.hasPrefix("audio/") { return "waveform" }
        if contentType == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if ["zip", "gz", "tar", "tgz", "7z", "rar"].contains(ext) { return "doc.zipper" }
        if ["swift", "ts", "tsx", "js", "py", "rs", "go", "json", "yml", "yaml", "toml", "sh", "c", "h", "m", "java", "kt", "rb", "sql", "html", "css", "md"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if ["csv", "xlsx", "xls", "numbers"].contains(ext) { return "tablecells" }
        if contentType.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

/// Streams a sendMessage JSON body with base64 `data_url` attachments to a temp file,
/// so large files never sit in memory as one string (important in the share extension).
enum MessageBodyWriter {
    static func write(fields: [String: Any], files: [LocalFile]) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("body-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }

        // Everything except attachments, as a JSON object missing its closing brace.
        var head = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        head.removeLast()   // "}"
        try h.write(contentsOf: head)
        try h.write(contentsOf: Data((fields.isEmpty ? "" : ",") .utf8))
        try h.write(contentsOf: Data("\"attachments\":[".utf8))

        for (i, f) in files.enumerated() {
            if i > 0 { try h.write(contentsOf: Data(",".utf8)) }
            let meta = try JSONSerialization.data(withJSONObject: ["id": f.id, "name": f.name, "content_type": f.contentType])
            var metaOpen = meta
            metaOpen.removeLast()
            try h.write(contentsOf: metaOpen)
            try h.write(contentsOf: Data(",\"data_url\":\"data:\(f.contentType);base64,".utf8))
            let input = try FileHandle(forReadingFrom: f.url)
            defer { try? input.close() }
            let chunk = 3 * 256 * 1024   // multiple of 3 keeps base64 chunks concatenable
            while let data = try input.read(upToCount: chunk), !data.isEmpty {
                try h.write(contentsOf: data.base64EncodedData())
            }
            try h.write(contentsOf: Data("\"}".utf8))
        }
        try h.write(contentsOf: Data("]}".utf8))
        return out
    }
}

/// Turns item providers (Photos picker, drag & drop, share sheet) into local files and text.
enum ItemImporter {
    struct Result {
        var files: [LocalFile] = []
        var texts: [String] = []
    }

    static func load(_ providers: [NSItemProvider]) async -> Result {
        var out = Result()
        for p in providers {
            let types = p.registeredContentTypes
            // Web links and plain text become message text, not files.
            if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }),
               !types.contains(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text) }) {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                    out.texts.append(url.absoluteString); continue
                }
            }
            if types.allSatisfy({ $0.conforms(to: .text) }), !types.isEmpty {
                if let t = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { out.texts.append(t); continue }
            }
            // Prefer a concrete file type (heic/jpeg/mov/pdf…) over generic ones.
            let fileType = types.first { $0.conforms(to: .data) || $0.conforms(to: .package) || $0.conforms(to: .archive) }
                ?? types.first
            guard let type = fileType else { continue }
            if let f = await loadFile(p, type: type) { out.files.append(f) }
        }
        return out
    }

    private static func loadFile(_ p: NSItemProvider, type: UTType) async -> LocalFile? {
        let suggested = p.suggestedName
        return await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                // The URL is only valid inside this handler: copy it out now.
                guard let url else { cont.resume(returning: nil); return }
                var name = suggested ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty, (name as NSString).pathExtension.isEmpty { name += "." + ext }
                cont.resume(returning: try? LocalFile.importing(url, suggestedName: name, type: type))
            }
        }
    }
}

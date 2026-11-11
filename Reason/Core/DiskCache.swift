import Foundation

/// Tiny JSON cache in Caches/ so launch can show the last-known state instantly.
enum DiskCache {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("reason-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let queue = DispatchQueue(label: "reason.diskcache", qos: .utility)

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()

    private static func url(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    static func load<T: Decodable>(_ key: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? encoder.encode(value) else { return }
        let u = url(key)
        queue.async { try? data.write(to: u, options: .atomic) }
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }
}

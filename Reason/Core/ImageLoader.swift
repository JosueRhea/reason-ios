import ImageIO
import UIKit

/// Fetches and downsamples remote images off the main thread; memory-cached by URL + pixel size.
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    init() { cache.totalCostLimit = 96 << 20 }

    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let k = key(url, maxPixel)
        if let hit = cache.object(forKey: k) { return hit }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { Self.downsample(data, maxPixel: maxPixel) }.value
        if let image { cache.setObject(image, forKey: k, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
        return image
    }

    private func key(_ url: URL, _ px: CGFloat) -> NSString { "\(url.absoluteString)@\(Int(px))" as NSString }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }
        return UIImage(cgImage: cg)
    }
}

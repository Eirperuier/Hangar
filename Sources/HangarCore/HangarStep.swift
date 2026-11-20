import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A change made of pixels rather than values: a picture something else made from the one before it (an object
/// erased, the background taken out, more of the scene drawn round it, the whole of it made larger), kept by its id in
/// the app's store (`HangarAssets`). It's laid over the picture before it, where its frame says, as much as its mask
/// says; the geometry, adjustments and filter are drawn on what the steps make, so they stay values and can be changed
/// after it (as Photos keeps Clean Up's pixels under its adjustments).
public struct HangarStep: Hashable, Sendable, Codable {
    /// What made it (a mode's or an action's id), to tell steps apart and to make one again.
    public var tool: String
    /// The pictures it made, by their ids in the store: more than one when it was asked for several takes.
    public var takes: [String]
    /// The take it uses.
    public var take: Int
    /// Where it goes over the picture before it, that picture being 0 to 1 each way from its top left: the whole of
    /// it by default, larger for more of the scene round it.
    public var frame: CGRect
    /// Where it's laid over the picture before it (white) and where that's left (black), by its id in the store, the
    /// size of its frame; nil for all of it.
    public var mask: String?
    /// What it was asked, as its maker reads it: to make it again, or to open its mode as it was.
    public var parameters: HangarValue?

    public init(tool: String, takes: [String], take: Int = 0, frame: CGRect = Self.whole, mask: String? = nil,
                parameters: HangarValue? = nil) {
        self.tool = tool
        self.takes = takes
        self.take = take
        self.frame = frame
        self.mask = mask
        self.parameters = parameters
    }

    /// The picture it uses.
    public var asset: String? {
        takes.indices.contains(take) ? takes[take] : takes.first
    }

    /// The picture before it, whole.
    public static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The picture it makes, the one before it being 0 to 1 each way: its frame and that one together.
    public var reach: CGRect {
        frame.union(Self.whole)
    }
}

/// Where an app keeps the pictures steps make (`HangarStep`), each by an id: an edit keeps only their ids. Its own
/// storage, a server's, or a folder (`HangarAssetFolder`). Any thread.
public protocol HangarAssets: Sendable {
    /// The picture kept as `id`, nil if it's gone. It may read a file: never asked on the main thread.
    func picture(_ id: String) -> CGImage?
    /// Keeps a picture, giving its id.
    func keep(_ picture: CGImage) throws -> String
}

/// Pictures kept as files in a folder, by their ids (PNG, so a picture without a background keeps it so).
public final class HangarAssetFolder: HangarAssets, @unchecked Sendable {
    public let url: URL
    private let cache = NSCache<NSString, CGImage>()

    public init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cache.countLimit = 8
    }

    /// A folder in the app's caches: for steps that needn't outlive the app's caches.
    public static let caches = HangarAssetFolder(url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hangar", isDirectory: true))

    public func picture(_ id: String) -> CGImage? {
        if let kept = cache.object(forKey: id as NSString) { return kept }
        guard let source = CGImageSourceCreateWithURL(file(id) as CFURL, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        cache.setObject(picture, forKey: id as NSString)
        return picture
    }

    public func keep(_ picture: CGImage) throws -> String {
        let id = UUID().uuidString
        guard let destination = CGImageDestinationCreateWithURL(file(id) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        cache.setObject(picture, forKey: id as NSString)
        return id
    }

    private func file(_ id: String) -> URL {
        url.appendingPathComponent(id).appendingPathExtension("png")
    }
}

/// Pictures kept in memory only: for tests, and an edit that won't be kept.
public final class HangarMemoryAssets: HangarAssets, @unchecked Sendable {
    private let lock = NSLock()
    private var pictures: [String: CGImage] = [:]

    public init() {}

    public func picture(_ id: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return pictures[id]
    }

    public func keep(_ picture: CGImage) throws -> String {
        let id = UUID().uuidString
        lock.lock()
        pictures[id] = picture
        lock.unlock()
        return id
    }
}

// Sources/SwiftStack/Lex/BinaryAssetPool.swift
import Foundation

/// Reference to a slice of a binary asset loaded into memory (#embed C23).
@frozen
public struct AssetSlice: Sendable, BitwiseCopyable, Equatable {
    public let assetId: UInt32
    public let offset: UInt32
    public let count: UInt32

    @inlinable
    public init(assetId: UInt32, offset: UInt32, count: UInt32) {
        self.assetId = assetId
        self.offset = offset
        self.count = count
    }
}

/// Global pool interning binary resources for the C23 #embed directive (01-frontend.md §4.5).
/// Keyed by file path and content so identical assets are stored once.
public final class BinaryAssetPool: @unchecked Sendable {
    public static let shared = BinaryAssetPool()

    private var assets: [Data] = []
    private var pathToAssetId: [String: UInt32] = [:]
    private var slices: [AssetSlice] = []
    private let lock = Mutex()

    public init() {
        // Asset 0 is empty asset
        assets.append(Data())
        slices.append(AssetSlice(assetId: 0, offset: 0, count: 0))
    }

    /// Interns binary data for a given path, returning the asset ID.
    public func intern(path: String, data: Data) -> UInt32 {
        lock.withLock {
            if let existing = pathToAssetId[path] {
                return existing
            }
            let id = UInt32(assets.count)
            assets.append(data)
            pathToAssetId[path] = id
            return id
        }
    }

    /// Interns or registers an AssetSlice, returning a slice index.
    public func registerSlice(assetId: UInt32, offset: UInt32, count: UInt32) -> UInt32 {
        lock.withLock {
            let slice = AssetSlice(assetId: assetId, offset: offset, count: count)
            let idx = UInt32(slices.count)
            slices.append(slice)
            return idx
        }
    }

    /// Accesses the data for a given asset ID.
    public func data(for assetId: UInt32) -> Data? {
        lock.withLock {
            guard Int(assetId) < assets.count else { return nil }
            return assets[Int(assetId)]
        }
    }

    /// Accesses an AssetSlice by index.
    public func slice(at index: UInt32) -> AssetSlice {
        lock.withLock {
            let idx = Int(index)
            guard idx >= 0 && idx < slices.count else {
                return slices[0]
            }
            return slices[idx]
        }
    }

    /// Resets the pool (for testing and whole-module builds).
    public func reset() {
        lock.withLock {
            assets.removeAll(keepingCapacity: true)
            assets.append(Data())
            pathToAssetId.removeAll(keepingCapacity: true)
            slices.removeAll(keepingCapacity: true)
            slices.append(AssetSlice(assetId: 0, offset: 0, count: 0))
        }
    }
}

import AppKit
import Foundation
import MapKit
import RunPlayCore

/// MapKit-backed snapshotter that composites app route overlays manually.
public struct MapKitWorkoutMapSnapshotter: WorkoutMapSnapshotting, Sendable {
    public init() {}

    public func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        try Task.checkCancellation()

        guard request.routes.contains(where: { !$0.coordinates.isEmpty })
            || !request.markers.isEmpty else {
            throw WorkoutMapSnapshotError.emptyRoute
        }

        let size = request.size
        guard size.width > 0, size.height > 0 else {
            throw WorkoutMapSnapshotError.invalidRegion
        }

        guard let mapRect = MapSnapshotRegionPlanner.planMapRect(
            routes: request.routes,
            markers: request.markers,
            imageSize: size
        ) else {
            throw WorkoutMapSnapshotError.invalidRegion
        }

        let options = MKMapSnapshotter.Options()
        options.mapRect = mapRect
        options.size = NSSize(width: size.width, height: size.height)
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        options.appearance = NSAppearance(
            named: request.appearance == .dark ? .darkAqua : .aqua
        )

        // Explicit top-down camera — never export pitched 3D.
        let center = MKMapPoint(x: mapRect.midX, y: mapRect.midY).coordinate
        let metersPerMapPoint = max(MKMetersPerMapPointAtLatitude(center.latitude), 0.000_001)
        let spanMeters = max(mapRect.size.width, mapRect.size.height) * metersPerMapPoint
        let camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: max(spanMeters * 1.35, 500),
            pitch: 0,
            heading: 0
        )
        options.camera = camera

        let holder = SnapshotterHolder(options: options)
        do {
            return try await withTaskCancellationHandler {
                try await holder.start(request: request)
            } onCancel: {
                holder.cancel()
            }
        } catch is CancellationError {
            throw WorkoutMapSnapshotError.cancelled
        }
    }
}

/// Unchecked holder so MapKit snapshotter can participate in cancellation handlers.
private final class SnapshotterHolder: @unchecked Sendable {
    private let snapshotter: MKMapSnapshotter
    private let lock = NSLock()
    private var didCancel = false

    init(options: MKMapSnapshotter.Options) {
        self.snapshotter = MKMapSnapshotter(options: options)
    }

    func cancel() {
        lock.lock()
        didCancel = true
        lock.unlock()
        snapshotter.cancel()
    }

    func start(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        try await withCheckedThrowingContinuation { continuation in
            snapshotter.start(with: DispatchQueue.global(qos: .userInitiated)) { [lock] snap, error in
                lock.lock()
                let cancelled = self.didCancel
                lock.unlock()

                if cancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(
                            throwing: WorkoutMapSnapshotError.snapshotFailed(error.localizedDescription)
                        )
                    }
                    return
                }

                guard let snap else {
                    continuation.resume(
                        throwing: WorkoutMapSnapshotError.snapshotFailed("Snapshot returned no image")
                    )
                    return
                }

                do {
                    let basemap = try Self.basemapImage(from: snap.image)
                    let converter = ImmediateCoordinateConverter(snapshot: snap)
                    let result = try MapSnapshotOverlayComposer.compose(
                        basemap: basemap,
                        routes: request.routes,
                        markers: request.markers,
                        converter: converter,
                        lineWidth: request.lineWidth,
                        isCancelled: { Task.isCancelled }
                    )
                    continuation.resume(returning: result)
                } catch is CancellationError {
                    continuation.resume(throwing: CancellationError())
                } catch let snapshotError as WorkoutMapSnapshotError {
                    continuation.resume(throwing: snapshotError)
                } catch {
                    continuation.resume(
                        throwing: WorkoutMapSnapshotError.compositionFailed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private static func basemapImage(from image: NSImage) throws -> CGImage {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }
        throw WorkoutMapSnapshotError.compositionFailed("Could not obtain basemap CGImage")
    }
}

/// Converts coordinates using a live snapshot; used only on the snapshot queue.
private struct ImmediateCoordinateConverter: MapCoordinateConverting, @unchecked Sendable {
    let snapshot: MKMapSnapshotter.Snapshot

    func point(for coordinate: RouteMapCoordinate) -> CGPoint {
        let nsPoint = snapshot.point(for: coordinate.mapKitCoordinate)
        return CGPoint(x: nsPoint.x, y: nsPoint.y)
    }
}

/// In-memory snapshot cache keyed by full request identity.
public actor WorkoutMapSnapshotCache {
    private var storage: [WorkoutMapSnapshotCacheKey: WorkoutMapSnapshotResult] = [:]
    private let maxEntries: Int

    public init(maxEntries: Int = 8) {
        self.maxEntries = maxEntries
    }

    public func value(for key: WorkoutMapSnapshotCacheKey) -> WorkoutMapSnapshotResult? {
        storage[key]
    }

    public func store(_ result: WorkoutMapSnapshotResult, for key: WorkoutMapSnapshotCacheKey) {
        storage[key] = result
        while storage.count > maxEntries, let first = storage.keys.first {
            storage.removeValue(forKey: first)
        }
    }

    public func removeAll() {
        storage.removeAll()
    }
}

/// Snapshotter decorator that caches successful composites in memory only.
public struct CachingWorkoutMapSnapshotter: WorkoutMapSnapshotting, Sendable {
    private let base: any WorkoutMapSnapshotting
    private let cache: WorkoutMapSnapshotCache

    public init(
        base: any WorkoutMapSnapshotting = MapKitWorkoutMapSnapshotter(),
        cache: WorkoutMapSnapshotCache = WorkoutMapSnapshotCache()
    ) {
        self.base = base
        self.cache = cache
    }

    public func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        if let key = request.cacheKey, let cached = await cache.value(for: key) {
            return cached
        }
        let result = try await base.makeSnapshot(request: request)
        if let key = request.cacheKey {
            await cache.store(result, for: key)
        }
        return result
    }
}

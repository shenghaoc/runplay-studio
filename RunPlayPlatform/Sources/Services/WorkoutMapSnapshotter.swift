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
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            throw WorkoutMapSnapshotError.invalidRegion
        }

        guard let mapRect = MapSnapshotRegionPlanner.planMapRect(
            routes: request.routes,
            markers: request.markers,
            imageSize: size
        ) else {
            throw WorkoutMapSnapshotError.invalidRegion
        }

        let options = Self.makeSnapshotOptions(request: request, mapRect: mapRect)

        let holder = MapKitSnapshotterSession<WorkoutMapSnapshotResult>(
            options: options
        ) { snapshot, isCancelled in
            let basemap = try WorkoutMapSnapshotImageNormalizer.normalizedCGImage(
                from: snapshot.image,
                targetSize: request.size
            )
            let converter = ImmediateCoordinateConverter(snapshot: snapshot)
            return try MapSnapshotOverlayComposer.compose(
                basemap: basemap,
                routes: request.routes,
                markers: request.markers,
                converter: converter,
                lineWidth: request.lineWidth,
                isCancelled: isCancelled
            )
        }
        do {
            return try await withTaskCancellationHandler {
                try await holder.start()
            } onCancel: {
                holder.cancel()
            }
        } catch is CancellationError {
            throw WorkoutMapSnapshotError.cancelled
        }
    }

    static func makeSnapshotOptions(
        request: WorkoutMapSnapshotRequest,
        mapRect: MKMapRect
    ) -> MKMapSnapshotter.Options {
        let options = MKMapSnapshotter.Options()
        // Unlike the iOS API, macOS exposes no snapshot scale option. Request
        // the fixed canvas here, then normalize the returned NSImage to these
        // exact pixel dimensions before compositing overlays.
        options.size = NSSize(width: request.size.width, height: request.size.height)
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

        // Setting the camera recalculates the visible region. Apply the
        // planner's padded/aspect-correct rect last so it remains authoritative.
        options.mapRect = mapRect
        return options
    }
}

/// Shared one-shot MapKit snapshot session. It centralizes cancellation and
/// error normalization while allowing each consumer to synchronously capture
/// snapshot-coordinate data before MapKit releases its live snapshot object.
final class MapKitSnapshotterSession<Output: Sendable>: @unchecked Sendable {
    typealias Transform = @Sendable (
        MKMapSnapshotter.Snapshot,
        @escaping @Sendable () -> Bool
    ) throws -> Output

    private let snapshotter: MKMapSnapshotter
    private let transform: Transform
    private let lock = NSLock()
    private var didCancel = false

    init(options: MKMapSnapshotter.Options, transform: @escaping Transform) {
        self.snapshotter = MKMapSnapshotter(options: options)
        self.transform = transform
    }

    func cancel() {
        lock.lock()
        didCancel = true
        lock.unlock()
        snapshotter.cancel()
    }

    private func cancellationRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }

    func start() async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            snapshotter.start(with: DispatchQueue.global(qos: .userInitiated)) { snap, error in
                if self.cancellationRequested() {
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
                    let result = try self.transform(
                        snap,
                        { self.cancellationRequested() }
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
}

/// Converts AppKit's potentially Retina-backed snapshot image into the exact
/// one-pixel-per-point canvas used by snapshot coordinate conversion.
enum WorkoutMapSnapshotImageNormalizer {
    static func normalizedCGImage(from image: NSImage, targetSize: CGSize) throws -> CGImage {
        guard targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width > 0, targetSize.height > 0,
              targetSize.width <= CGFloat(Int.max), targetSize.height <= CGFloat(Int.max) else {
            throw WorkoutMapSnapshotError.compositionFailed("Basemap target size is invalid")
        }

        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        guard width > 0, height > 0 else {
            throw WorkoutMapSnapshotError.compositionFailed("Basemap target size is invalid")
        }

        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw WorkoutMapSnapshotError.compositionFailed("Could not obtain basemap CGImage")
        }

        if source.width == width, source.height == height {
            return source
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WorkoutMapSnapshotError.compositionFailed("Could not normalize basemap pixels")
        }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else {
            throw WorkoutMapSnapshotError.compositionFailed("Could not finalize normalized basemap")
        }
        return normalized
    }
}

/// Converts coordinates using a live snapshot; used only on the snapshot queue.
struct ImmediateCoordinateConverter: MapCoordinateConverting, @unchecked Sendable {
    let snapshot: MKMapSnapshotter.Snapshot

    func point(for coordinate: RouteMapCoordinate) -> CGPoint {
        let nsPoint = snapshot.point(for: coordinate.mapKitCoordinate)
        return CGPoint(x: nsPoint.x, y: nsPoint.y)
    }
}

/// In-memory snapshot cache keyed by full request identity.
///
/// Eviction is FIFO by insertion order (not dictionary key order).
public actor WorkoutMapSnapshotCache {
    private var storage: [WorkoutMapSnapshotCacheKey: WorkoutMapSnapshotResult] = [:]
    private var insertionOrder: [WorkoutMapSnapshotCacheKey] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 8) {
        self.maxEntries = maxEntries
    }

    public func value(for key: WorkoutMapSnapshotCacheKey) -> WorkoutMapSnapshotResult? {
        storage[key]
    }

    public func store(_ result: WorkoutMapSnapshotResult, for key: WorkoutMapSnapshotCacheKey) {
        if storage[key] != nil {
            // Refresh value in place; keep original insertion order.
            storage[key] = result
            return
        }
        storage[key] = result
        insertionOrder.append(key)
        while storage.count > maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    public func removeAll() {
        storage.removeAll()
        insertionOrder.removeAll()
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

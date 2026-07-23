import XCTest
@testable import RunPlayCore

final class WorkoutTagQueryAndManifestTests: XCTestCase {

    // MARK: - Manifest migration

    func testVersion1DecodesEmptyOrganization() throws {
        let id = UUID()
        let json = """
        {
          "version": 1,
          "workoutIDs": ["\(id.uuidString)"],
          "selectedWorkoutID": "\(id.uuidString)"
        }
        """
        let decoded = try JSONDecoder().decode(WorkoutLibraryManifest.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.tags.isEmpty)
        XCTAssertTrue(decoded.tagAssignments.isEmpty)
        XCTAssertTrue(decoded.smartCollections.isEmpty)
        XCTAssertTrue(decoded.favoriteWorkoutIDs.isEmpty)
    }

    func testVersion2DecodesEmptyOrganizationPreservingFavorites() throws {
        let a = UUID()
        let b = UUID()
        let original = WorkoutLibraryManifest(
            version: 2,
            workoutIDs: [a, b],
            selectedWorkoutID: b,
            favoriteWorkoutIDs: [a]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutLibraryManifest.self, from: data)
        XCTAssertEqual(decoded.favoriteWorkoutIDs, [a])
        XCTAssertTrue(decoded.tags.isEmpty)
        XCTAssertTrue(decoded.smartCollections.isEmpty)
    }

    func testVersion3RoundTrip() throws {
        let workoutID = UUID()
        let tag = WorkoutTag(name: "Race", color: .red)
        let collection = WorkoutSmartCollection(
            name: "Races",
            query: WorkoutLibrarySavedQuery(
                searchText: "race",
                filter: WorkoutLibraryFilter(
                    tags: .selected(tagIDs: [tag.id], match: .any)
                ),
                sort: .dateNewest
            )
        )
        let original = WorkoutLibraryManifest(
            version: 3,
            workoutIDs: [workoutID],
            selectedWorkoutID: workoutID,
            favoriteWorkoutIDs: [workoutID],
            tags: [tag],
            tagAssignments: [WorkoutTagAssignment(workoutID: workoutID, tagIDs: [tag.id])],
            smartCollections: [collection]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutLibraryManifest.self, from: data)
        XCTAssertEqual(decoded.tags, [tag])
        XCTAssertEqual(decoded.tagAssignments.first?.tagIDs, [tag.id])
        XCTAssertEqual(decoded.smartCollections.first?.name, "Races")
        XCTAssertEqual(decoded.favoriteWorkoutIDs, [workoutID])
    }

    func testManifestDecodeCapsOrganizationArrays() throws {
        let workoutID = UUID()
        let tags = (0...WorkoutLibraryManifest.ResourceLimits.maxTags).map { index in
            WorkoutTag(name: "Tag " + String(index))
        }
        let tagIDs = (0..<(WorkoutTagPolicy.default.maxTagsPerWorkout + 5)).map { _ in UUID() }
        let assignment = WorkoutTagAssignment(workoutID: workoutID, tagIDs: tagIDs)
        let collections = (0...WorkoutLibraryManifest.ResourceLimits.maxSmartCollections).map { index in
            WorkoutSmartCollection(name: "Collection " + String(index), query: WorkoutLibrarySavedQuery())
        }
        let original = WorkoutLibraryManifest(
            workoutIDs: [workoutID],
            tags: tags,
            tagAssignments: [assignment],
            smartCollections: collections
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutLibraryManifest.self, from: data)

        XCTAssertEqual(decoded.tags.count, WorkoutLibraryManifest.ResourceLimits.maxTags)
        XCTAssertEqual(
            decoded.tagAssignments.first?.tagIDs.count,
            WorkoutLibraryManifest.ResourceLimits.maxTagIDsPerAssignment
        )
        XCTAssertEqual(
            decoded.smartCollections.count,
            WorkoutLibraryManifest.ResourceLimits.maxSmartCollections
        )
    }

    func testMigratePromotesToVersion3() {
        var manifest = WorkoutLibraryManifest(version: 1, workoutIDs: [UUID()])
        manifest.migrateToCurrentVersionIfNeeded()
        XCTAssertEqual(manifest.version, 3)
    }

    func testRepairRemovesMissingWorkoutAssignments() {
        let workoutID = UUID()
        let tag = WorkoutTag(name: "Easy", color: .green)
        var manifest = WorkoutLibraryManifest(
            workoutIDs: [workoutID],
            tags: [tag],
            tagAssignments: [
                WorkoutTagAssignment(workoutID: workoutID, tagIDs: [tag.id]),
                WorkoutTagAssignment(workoutID: UUID(), tagIDs: [tag.id]),
            ]
        )
        _ = manifest.repairOrganization()
        XCTAssertEqual(manifest.tagAssignments.count, 1)
        XCTAssertEqual(manifest.tagAssignments.first?.workoutID, workoutID)
    }

    func testRepairRemovesMissingTagReferencesAndEmptiesCollectionTagFilter() {
        let missingTag = UUID()
        let collection = WorkoutSmartCollection(
            name: "Tagged",
            query: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(
                    tags: .selected(tagIDs: [missingTag], match: .all)
                )
            )
        )
        var manifest = WorkoutLibraryManifest(
            workoutIDs: [UUID()],
            tags: [],
            smartCollections: [collection]
        )
        let report = manifest.repairOrganization()
        XCTAssertFalse(report.isEmpty)
        if case .anyTags = manifest.smartCollections[0].query.filter.tags {
            // ok
        } else {
            XCTFail("Expected anyTags after repair")
        }
    }

    func testDeleteTagStripsAssignmentsAndCollectionFilters() {
        let workoutID = UUID()
        let tag = WorkoutTag(name: "Intervals", color: .orange)
        let other = WorkoutTag(name: "Easy", color: .green)
        let collection = WorkoutSmartCollection(
            name: "Hard",
            query: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(
                    tags: .selected(tagIDs: [tag.id, other.id], match: .any)
                )
            )
        )
        var manifest = WorkoutLibraryManifest(
            workoutIDs: [workoutID],
            tags: [tag, other],
            tagAssignments: [WorkoutTagAssignment(workoutID: workoutID, tagIDs: [tag.id, other.id])],
            smartCollections: [collection]
        )
        manifest.deleteTag(id: tag.id)
        XCTAssertEqual(manifest.tags.map(\.id), [other.id])
        XCTAssertEqual(manifest.tagAssignments.first?.tagIDSet, [other.id])
        if case .selected(let ids, _) = manifest.smartCollections[0].query.filter.tags {
            XCTAssertEqual(ids, [other.id])
        } else {
            XCTFail("Expected remaining selected tag")
        }
    }

    func testFileStoreLoadsV1AndSavesV3() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifestTagV1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = FileWorkoutLibraryStore(rootURL: temp)
        try store.ensureDirectoriesExist()
        let id = UUID()
        let raw = """
        {"version":1,"workoutIDs":["\(id.uuidString)"],"selectedWorkoutID":"\(id.uuidString)"}
        """
        try Data(raw.utf8).write(to: temp.appendingPathComponent("manifest.json"))
        let loaded = try store.loadManifest()
        XCTAssertEqual(loaded.version, WorkoutLibraryManifest.currentVersion)
        try store.saveManifest(loaded)
        let reloaded = try store.loadManifest()
        XCTAssertEqual(reloaded.version, 3)
        XCTAssertTrue(reloaded.tags.isEmpty)
    }

    // MARK: - Query tag filters

    private func makeEntry(
        id: UUID = UUID(),
        favorite: Bool = false,
        tagIDs: Set<UUID> = [],
        tagNames: [String] = [],
        name: String = "Run",
        notes: String? = nil,
        source: WorkoutSource = .fit,
        hasHR: Bool = false
    ) -> WorkoutLibraryEntry {
        WorkoutLibraryEntry(
            id: id,
            manifestIndex: 0,
            isFavorite: favorite,
            displayName: name,
            metadataName: name,
            notes: notes,
            activityType: "running",
            deviceName: nil,
            source: source,
            importProvider: nil,
            originalFilename: nil,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            totalDistanceMeters: 5000,
            activePaceSecondsPerKilometer: 300,
            totalElapsedSeconds: 1500,
            hasHeartRate: hasHR,
            hasCorrectedElevation: false,
            hasRecordedLaps: false,
            nameNotesRevision: "\(name)|\(notes ?? "")",
            tagIDs: tagIDs,
            tagNames: tagNames
        )
    }

    func testTagNameSearch() async throws {
        let race = UUID()
        let entry = makeEntry(tagIDs: [race], tagNames: ["Race"], name: "Morning")
        let docs = [entry.id: WorkoutLibrarySearchDocument.make(from: entry)]
        let service = WorkoutLibraryQueryService()
        let result = try await service.execute(
            entries: [entry],
            documents: docs,
            query: WorkoutLibraryQuery(searchText: "race")
        )
        XCTAssertEqual(result.matchingIDs, [entry.id])
    }

    func testSelectedAnyAndAllAndUntagged() async throws {
        let t1 = UUID()
        let t2 = UUID()
        let a = makeEntry(id: UUID(), tagIDs: [t1], tagNames: ["Race"])
        let b = makeEntry(id: UUID(), tagIDs: [t1, t2], tagNames: ["Race", "Easy"])
        let c = makeEntry(id: UUID(), tagIDs: [], tagNames: [])
        let entries = [a, b, c]
        let docs = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, WorkoutLibrarySearchDocument.make(from: $0))
        })
        let service = WorkoutLibraryQueryService()

        let any = try await service.execute(
            entries: entries,
            documents: docs,
            query: WorkoutLibraryQuery(
                filter: WorkoutLibraryFilter(tags: .selected(tagIDs: [t1], match: .any))
            )
        )
        XCTAssertEqual(Set(any.matchingIDs), [a.id, b.id])

        let all = try await service.execute(
            entries: entries,
            documents: docs,
            query: WorkoutLibraryQuery(
                filter: WorkoutLibraryFilter(tags: .selected(tagIDs: [t1, t2], match: .all))
            )
        )
        XCTAssertEqual(all.matchingIDs, [b.id])

        let untagged = try await service.execute(
            entries: entries,
            documents: docs,
            query: WorkoutLibraryQuery(
                filter: WorkoutLibraryFilter(tags: .untaggedOnly)
            )
        )
        XCTAssertEqual(untagged.matchingIDs, [c.id])

        let emptySelected = try await service.execute(
            entries: entries,
            documents: docs,
            query: WorkoutLibraryQuery(
                filter: WorkoutLibraryFilter(tags: .selected(tagIDs: [], match: .any))
            )
        )
        XCTAssertEqual(emptySelected.filteredCount, 3)
    }

    func testTagFilterCombinesWithFavouriteAndSource() async throws {
        let tag = UUID()
        let a = makeEntry(favorite: true, tagIDs: [tag], tagNames: ["Race"], source: .fit)
        let b = makeEntry(favorite: false, tagIDs: [tag], tagNames: ["Race"], source: .gpx)
        let service = WorkoutLibraryQueryService()
        let docs = [
            a.id: WorkoutLibrarySearchDocument.make(from: a),
            b.id: WorkoutLibrarySearchDocument.make(from: b),
        ]
        let result = try await service.execute(
            entries: [a, b],
            documents: docs,
            query: WorkoutLibraryQuery(
                filter: WorkoutLibraryFilter(
                    favorite: .favoritesOnly,
                    source: .fit,
                    tags: .selected(tagIDs: [tag], match: .any)
                )
            )
        )
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testLargeLibraryTagFilterLinear() async throws {
        let tag = UUID()
        var entries: [WorkoutLibraryEntry] = []
        entries.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let id = UUID()
            let tagged = i % 10 == 0
            entries.append(makeEntry(
                id: id,
                tagIDs: tagged ? [tag] : [],
                tagNames: tagged ? ["Race"] : [],
                name: "Run \(i)"
            ))
        }
        let docs = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, WorkoutLibrarySearchDocument.make(from: $0))
        })
        let service = WorkoutLibraryQueryService()
        let result = try await service.execute(
            entries: entries,
            documents: docs,
            query: WorkoutLibraryQuery(
                filter: WorkoutLibraryFilter(tags: .selected(tagIDs: [tag], match: .any))
            )
        )
        XCTAssertEqual(result.filteredCount, 1_000)
    }
}

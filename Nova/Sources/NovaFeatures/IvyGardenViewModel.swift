import Foundation
import NovaCore
import NovaDomain
import Observation

@MainActor
@Observable
public final class IvyGardenViewModel {
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case gallery
        case identify
        case planning

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .gallery: return "Gallery"
            case .identify: return "Identify"
            case .planning: return "Planning"
            }
        }
    }

    public var section: Section = .gallery
    public private(set) var plants: [PlantSighting] = []
    public private(set) var lastIdentify: PlantIdentifyResult?
    public private(set) var lastWalk: GardenWalkResult?
    public private(set) var lastCatalog: GardenCatalogResult?
    public private(set) var planItems: [GardenPlanItem] = []
    public private(set) var savedWalks: [GardenWalkResult] = []
    public private(set) var suggestedTips: [GardenSuggestedTip] = []
    public private(set) var plantRecommendations: [GardenPlantRecommendation] = []
    public private(set) var climate: GardenClimateSnapshot?
    /// Active USDA zone (1…13) driving Annual/Perennial gallery tags.
    public private(set) var activeHardinessZone: Int?
    public var climateCityDraft: String = ""
    public var hardinessZoneDraft: Int = 7
    public private(set) var statusMessage: String = ""
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false
    public private(set) var isWalking = false
    public private(set) var isCataloging = false
    public private(set) var directoryURL: URL?
    public private(set) var librarySaveMessage: String?
    /// Catalog detections that match gallery plants — awaiting Keep New / Replace / Discard.
    public private(set) var pendingDuplicateReviews: [GardenCatalogDuplicateItem] = []
    /// Index into `pendingDuplicateReviews` while the review sheet is open.
    public private(set) var duplicateReviewIndex: Int = 0
    /// Drives the duplicate-review sheet.
    public var isPresentingDuplicateReview = false

    /// Current item in the duplicate-review queue, if any.
    public var currentDuplicateReview: GardenCatalogDuplicateItem? {
        guard duplicateReviewIndex >= 0,
              duplicateReviewIndex < pendingDuplicateReviews.count
        else { return nil }
        return pendingDuplicateReviews[duplicateReviewIndex]
    }

    public var pendingDuplicateCount: Int { pendingDuplicateReviews.count }

    private let store: any PlantLibraryStoring
    private let analyzeImage: (CapturedFrame, String) async throws -> String
    private let captureStill: (() async throws -> CapturedFrame)?
    private let startLiveLook: ((Int) async throws -> AsyncStream<CapturedFrame>)?
    private let stopLiveLook: (() async -> Void)?
    private let releaseCamera: (() async -> Void)?
    private let isVisionReady: () async -> Bool
    private let recognizeText: ((Data) async -> String)?
    private let speakAboutFrame: ((CapturedFrame, String) async throws -> String)?
    private let speakBriefing: ((String) async throws -> Void)?
    private let fetchClimate: ((String) async throws -> GardenClimateSnapshot)?
    private let holdVideoForAudio: ((Bool) async -> Void)?
    private let saveLibraryNote: ((String) async -> Void)?
    private let selector = FrameSelector()
    /// Bumped by `stopGardenWalk()` so in-flight capture/analysis exits cleanly.
    private var walkGeneration = 0
    private var walkTask: Task<Void, Never>?
    /// Speak Garden Overview after duplicate review finishes (if catalog asked to speak).
    private var pendingCatalogSpeak = false
    /// Keyframes retained so overview can be rebuilt after reviews.
    private var pendingCatalogOverviewFrames: [Data] = []
    /// Profiles saved this catalog session (new + review resolutions).
    private var catalogSessionProfiles: [CatalogPlantDraft] = []
    private var catalogSessionStats = GardenCatalogRunStats()

    public init(
        store: any PlantLibraryStoring,
        analyzeImage: @escaping (CapturedFrame, String) async throws -> String,
        captureStill: (() async throws -> CapturedFrame)? = nil,
        startLiveLook: ((Int) async throws -> AsyncStream<CapturedFrame>)? = nil,
        stopLiveLook: (() async -> Void)? = nil,
        releaseCamera: (() async -> Void)? = nil,
        isVisionReady: @escaping () async -> Bool = { false },
        recognizeText: ((Data) async -> String)? = nil,
        speakAboutFrame: ((CapturedFrame, String) async throws -> String)? = nil,
        speakBriefing: ((String) async throws -> Void)? = nil,
        fetchClimate: ((String) async throws -> GardenClimateSnapshot)? = nil,
        holdVideoForAudio: ((Bool) async -> Void)? = nil,
        saveLibraryNote: ((String) async -> Void)? = nil
    ) {
        self.store = store
        self.analyzeImage = analyzeImage
        self.captureStill = captureStill
        self.startLiveLook = startLiveLook
        self.stopLiveLook = stopLiveLook
        self.releaseCamera = releaseCamera
        self.isVisionReady = isVisionReady
        self.recognizeText = recognizeText
        self.speakAboutFrame = speakAboutFrame
        self.speakBriefing = speakBriefing
        self.fetchClimate = fetchClimate
        self.holdVideoForAudio = holdVideoForAudio
        self.saveLibraryNote = saveLibraryNote
    }

    public var plantCount: Int { plants.count }

    public var lastWalkShareText: String {
        lastWalk?.shareText ?? ""
    }

    public func saveLastWalkToLibrary() async {
        if let catalog = lastCatalog {
            guard let saveLibraryNote else {
                librarySaveMessage = "Library notes unavailable."
                return
            }
            await saveLibraryNote(catalog.shareText)
            librarySaveMessage = "Saved Garden Overview to Library notes"
            statusMessage = librarySaveMessage ?? statusMessage
            return
        }
        guard let walk = lastWalk else {
            librarySaveMessage = "No Garden Overview to save yet."
            return
        }
        guard let saveLibraryNote else {
            librarySaveMessage = "Library notes unavailable."
            return
        }
        await saveLibraryNote(walk.shareText)
        librarySaveMessage = "Saved Garden Walk to Library notes"
        statusMessage = librarySaveMessage ?? statusMessage
    }

    public func notePhotoLoadFailed() {
        errorMessage = "Could not read that media — try JPEG/HEIC photos or an MP4/MOV video from Photos."
    }

    public func planItems(for season: GardenSeason) -> [GardenPlanItem] {
        GardenPlanningDiff.items(for: season, in: planItems)
    }

    public func load() async {
        plants = await store.all()
        directoryURL = await store.directory()
        climateCityDraft = await store.climateCity() ?? climateCityDraft
        if let zone = await store.hardinessZone() {
            activeHardinessZone = zone
            hardinessZoneDraft = zone
        } else if let climateZone = climate?.hardinessZone {
            activeHardinessZone = climateZone
            hardinessZoneDraft = climateZone
        }
        savedWalks = await store.gardenWalks()
        await retagPlantsForActiveZone(persist: activeHardinessZone != nil || climate?.hardinessZone != nil)
        rebuildPlan()
    }

    /// Persist zone, retag every gallery plant as Annual/Perennial for that zone.
    public func saveHardinessZone() async {
        let zone = GardenLifeCycleDiff.clampZone(hardinessZoneDraft) ?? hardinessZoneDraft
        hardinessZoneDraft = zone
        activeHardinessZone = zone
        await store.setHardinessZone(zone)
        await retagPlantsForActiveZone(persist: true)
        rebuildPlan()
        statusMessage = "Zone \(zone) saved — gallery tagged Annual/Perennial"
    }

    public func imageURL(for plant: PlantSighting) -> URL? {
        guard !plant.fileName.isEmpty else { return nil }
        return directoryURL?.appendingPathComponent(plant.fileName)
    }

    public func imageURL(forPlantId id: UUID?) -> URL? {
        guard let id, let plant = plants.first(where: { $0.id == id }) else { return nil }
        return imageURL(for: plant)
    }

    public func delete(_ plant: PlantSighting) async {
        await store.delete(id: plant.id)
        await load()
        statusMessage = "Removed \(plant.name)"
    }

    /// Import photos / video keyframes into the gallery via catalog (merge + confidence filters).
    public func importPhotosToGallery(_ imageDatas: [Data]) async {
        section = .gallery
        await catalogFrames(imageDatas, speak: false)
    }

    /// Full plant catalog from a local movie (Media → Send to Ivy or Garden upload).
    /// Identifies every distinct plant, saves/merges profiles, and builds a Garden Overview.
    public func catalogVideo(at url: URL, speak: Bool = true) async {
        statusMessage = "Sampling video for plant catalog…"
        errorMessage = nil
        let frames = await VideoKeyframeSampler.jpegKeyFramesAdaptive(from: url, catalog: true)
        guard !frames.isEmpty else {
            errorMessage = "Could not read that video — try an MP4/MOV from Photos or Media."
            return
        }
        await catalogFrames(frames, speak: speak)
    }

    /// Catalog every distinct plant across stills / video keyframes into the Gallery.
    public func catalogFrames(_ imageDatas: [Data], speak: Bool = true) async {
        let datas = Array(imageDatas.filter { !$0.isEmpty }.prefix(12))
        guard !datas.isEmpty else {
            errorMessage = "Add a photo or video to catalog plants."
            return
        }
        isCataloging = true
        isBusy = true
        errorMessage = nil
        defer {
            isCataloging = false
            isBusy = false
        }

        var library = await store.all()
        let framePrompt = GardenVideoCatalogDiff.framePrompt(library: library, climate: climate)
        var frameDrafts: [CatalogPlantDraft] = []
        var stats = GardenCatalogRunStats(framesTotal: datas.count)
        for (index, data) in datas.enumerated() {
            statusMessage = "Cataloging frame \(index + 1) of \(datas.count)…"
            let frame = CapturedFrame(imageData: data, width: 0, height: 0)
            do {
                let answer = try await analyzeImage(frame, framePrompt)
                let parsed = GardenVideoCatalogDiff.parseFrameJSON(
                    answer,
                    library: library,
                    imageData: data
                )
                let isolated = Self.isolatePlantDrafts(parsed, sourceImage: data)
                let prepared = GardenVideoCatalogDiff.dedupeLibraryMatchesForMultiPlant(isolated)
                stats.detections += prepared.count
                stats.cropped += prepared.filter {
                    GardenVideoCatalogDiff.isIsolatedSpecimenCrop($0)
                        && ($0.imageData?.isEmpty == false)
                }.count
                frameDrafts.append(contentsOf: prepared)
            } catch {
                stats.framesFailed += 1
                continue
            }
        }

        var merged = GardenVideoCatalogDiff.mergeDrafts(frameDrafts)
        merged = GardenVideoCatalogDiff.dedupeLibraryMatchesForMultiPlant(merged)
        guard !merged.isEmpty else {
            let failNote = stats.framesFailed > 0
                ? " (\(stats.framesFailed) frame\(stats.framesFailed == 1 ? "" : "s") failed analysis)"
                : ""
            errorMessage = "No confident plant IDs in that media — try a closer photo of leaves/flowers.\(failNote)"
            statusMessage = "Catalog empty · \(stats.summaryLine)"
            return
        }

        statusMessage = "Saving \(merged.count) plant profile\(merged.count == 1 ? "" : "s")…"
        var persisted: [CatalogPlantDraft] = []
        var reviews: [GardenCatalogDuplicateItem] = []
        for draft in merged {
            switch await classifyCatalogDraft(draft, library: &library) {
            case .created(let saved):
                stats.created += 1
                persisted.append(saved)
            case .needsReview(let item):
                reviews.append(item)
            case .skippedWeak:
                stats.skippedWeak += 1
            }
        }
        stats.duplicatesPending = reviews.count
        pendingDuplicateReviews = reviews
        duplicateReviewIndex = 0
        isPresentingDuplicateReview = false
        catalogSessionProfiles = persisted
        catalogSessionStats = stats
        pendingCatalogSpeak = speak
        pendingCatalogOverviewFrames = datas

        guard !persisted.isEmpty || !reviews.isEmpty else {
            errorMessage = "Plants looked uncertain — nothing new was saved. Try closer shots of distinct plants."
            statusMessage = "Catalog skipped weak IDs · \(stats.summaryLine)"
            return
        }

        await load()

        if !reviews.isEmpty {
            let n = reviews.count
            statusMessage = "\(n) duplicate plant\(n == 1 ? "" : "s") found"
            if !persisted.isEmpty {
                await publishCatalogResult(
                    profiles: persisted,
                    stats: stats,
                    overviewFrames: datas,
                    speak: false
                )
                statusMessage = "\(n) duplicate plant\(n == 1 ? "" : "s") found · \(persisted.count) new saved — tap Review"
            } else {
                errorMessage = nil
                lastCatalog = GardenCatalogResult(
                    overview: GardenWalkResult(
                        overview: "\(n) possible duplicate\(n == 1 ? "" : "s") need review before the gallery is updated."
                    ),
                    profiles: [],
                    stats: stats
                )
            }
            return
        }

        await publishCatalogResult(
            profiles: persisted,
            stats: stats,
            overviewFrames: datas,
            speak: speak
        )
        pendingCatalogSpeak = false
        pendingCatalogOverviewFrames = []
        catalogSessionProfiles = []
    }

    /// Opens the side-by-side duplicate review sheet at the first pending item.
    public func beginDuplicateReview() {
        guard !pendingDuplicateReviews.isEmpty else { return }
        duplicateReviewIndex = min(duplicateReviewIndex, pendingDuplicateReviews.count - 1)
        isPresentingDuplicateReview = true
        section = .gallery
    }

    /// Apply Keep New / Replace / Discard to the current duplicate, then advance.
    public func resolveDuplicateReview(_ action: GardenCatalogDuplicateAction) async {
        guard let item = currentDuplicateReview else {
            isPresentingDuplicateReview = false
            return
        }
        isBusy = true
        defer { isBusy = false }

        var library = await store.all()
        switch action {
        case .keepNew:
            if let saved = await createPlantFromDraft(item.draft, library: &library) {
                catalogSessionStats.created += 1
                catalogSessionStats.duplicatesPending = max(0, catalogSessionStats.duplicatesPending - 1)
                catalogSessionProfiles.append(saved)
            }
        case .replace:
            if let saved = await replaceExistingPlant(item, library: &library) {
                catalogSessionStats.updated += 1
                catalogSessionStats.duplicatesPending = max(0, catalogSessionStats.duplicatesPending - 1)
                catalogSessionProfiles.append(saved)
            }
        case .discard:
            catalogSessionStats.skippedWeak += 1
            catalogSessionStats.duplicatesPending = max(0, catalogSessionStats.duplicatesPending - 1)
        }

        pendingDuplicateReviews.remove(at: duplicateReviewIndex)
        if pendingDuplicateReviews.isEmpty {
            duplicateReviewIndex = 0
            isPresentingDuplicateReview = false
            await load()
            let speak = pendingCatalogSpeak
            let frames = pendingCatalogOverviewFrames
            pendingCatalogSpeak = false
            pendingCatalogOverviewFrames = []
            let profiles = catalogSessionProfiles
            let stats = catalogSessionStats
            catalogSessionProfiles = []
            if profiles.isEmpty {
                statusMessage = "Duplicates reviewed — nothing saved"
                if var catalog = lastCatalog {
                    catalog.stats = stats
                    lastCatalog = catalog
                }
                return
            }
            await publishCatalogResult(
                profiles: profiles,
                stats: stats,
                overviewFrames: frames,
                speak: speak
            )
        } else {
            if duplicateReviewIndex >= pendingDuplicateReviews.count {
                duplicateReviewIndex = pendingDuplicateReviews.count - 1
            }
            await load()
            let remaining = pendingDuplicateReviews.count
            statusMessage = "\(remaining) duplicate\(remaining == 1 ? "" : "s") left to review"
            if var catalog = lastCatalog {
                catalog.stats = catalogSessionStats
                lastCatalog = catalog
            }
        }
    }

    public func dismissDuplicateReviewSheet() {
        // Leave the queue intact so the Review button still works.
        isPresentingDuplicateReview = false
        let n = pendingDuplicateReviews.count
        if n > 0 {
            statusMessage = "\(n) duplicate plant\(n == 1 ? "" : "s") found — tap Review to continue"
        }
    }

    private func publishCatalogResult(
        profiles: [CatalogPlantDraft],
        stats: GardenCatalogRunStats,
        overviewFrames: [Data],
        speak: Bool
    ) async {
        await load()
        let library = plants
        statusMessage = "Writing Garden Overview…"
        var overview = GardenVideoCatalogDiff.fallbackOverview(from: profiles)
        let overviewPrompt = GardenVideoCatalogDiff.overviewPrompt(profiles: profiles, climate: climate)
        if let firstData = profiles.compactMap(\.imageData).first ?? overviewFrames.first {
            let frame = CapturedFrame(imageData: firstData, width: 0, height: 0)
            if let answer = try? await analyzeImage(frame, overviewPrompt) {
                let parsed = GardenVideoCatalogDiff.parseOverviewJSON(answer, library: library)
                let sanitized = GardenVideoCatalogDiff.sanitizeOverview(parsed, catalog: profiles)
                if !sanitized.overview.isEmpty {
                    overview = sanitized
                }
            }
        }

        let slimProfiles = profiles.map { draft -> CatalogPlantDraft in
            var next = draft
            next.imageData = nil
            return next
        }
        var finalStats = stats
        finalStats.duplicatesPending = pendingDuplicateReviews.count
        let result = GardenCatalogResult(overview: overview, profiles: slimProfiles, stats: finalStats)
        lastCatalog = result
        lastWalk = overview
        _ = await store.appendGardenWalk(overview)
        savedWalks = await store.gardenWalks()
        rebuildPlan()
        statusMessage = "Cataloged · \(finalStats.summaryLine)"
        errorMessage = finalStats.framesFailed > 0
            ? "\(finalStats.framesFailed) frame\(finalStats.framesFailed == 1 ? "" : "s") failed analysis; other frames were cataloged."
            : nil

        guard speak else { return }
        let briefing = GardenVideoCatalogDiff.speakPrompt(result: result, climate: climate)
        await holdVideoForAudio?(true)
        do {
            statusMessage = "Ivy speaking Garden Overview…"
            if let speakBriefing {
                try await speakBriefing(briefing)
                statusMessage = "Catalog briefing finished · \(finalStats.summaryLine)"
                errorMessage = nil
            }
            await holdVideoForAudio?(false)
        } catch {
            await holdVideoForAudio?(false)
            statusMessage = "Cataloged · \(finalStats.summaryLine) (text only)"
            errorMessage = "Audio briefing skipped: \(error.localizedDescription)"
        }
    }

    /// Garden Walk from a local movie — prefers full catalog + overview for videos.
    public func startGardenWalkFromVideo(at url: URL, speak: Bool = true) async {
        await catalogVideo(at: url, speak: speak)
    }

    private enum CatalogClassifyOutcome {
        case created(CatalogPlantDraft)
        case needsReview(GardenCatalogDuplicateItem)
        case skippedWeak
    }

    /// Auto-save only clear new plants; queue any library match for user review.
    private func classifyCatalogDraft(
        _ draft: CatalogPlantDraft,
        library: inout [PlantSighting]
    ) async -> CatalogClassifyOutcome {
        if let existing = Self.resolveExistingPlant(for: draft, library: library) {
            var queued = draft
            queued.matchedPlantId = existing.id
            queued.matchedLibraryName = existing.name
            return .needsReview(
                GardenCatalogDuplicateItem(
                    draft: queued,
                    existingPlantId: existing.id,
                    existingPlantName: existing.name
                )
            )
        }

        guard GardenVideoCatalogDiff.shouldCreateNewPlant(draft) else {
            return .skippedWeak
        }

        if let saved = await createPlantFromDraft(draft, library: &library) {
            return .created(saved)
        }
        return .skippedWeak
    }

    /// Library hit by id, then exact/fuzzy name or unique species.
    private static func resolveExistingPlant(
        for draft: CatalogPlantDraft,
        library: [PlantSighting]
    ) -> PlantSighting? {
        if let matchId = draft.matchedPlantId,
           let existing = library.first(where: { $0.id == matchId }) {
            return existing
        }
        return library.first(where: { plant in
            if let species = draft.species, let ps = plant.species,
               !species.isEmpty,
               ps.localizedCaseInsensitiveCompare(species) == .orderedSame {
                let sameSpecies = library.filter {
                    ($0.species ?? "").localizedCaseInsensitiveCompare(species) == .orderedSame
                }
                return sameSpecies.count == 1
                    || GardenVideoCatalogDiff.namesLikelySame(plant.name, draft.name)
            }
            return plant.name.localizedCaseInsensitiveCompare(draft.name) == .orderedSame
                || GardenVideoCatalogDiff.namesLikelySame(plant.name, draft.name)
        })
    }

    private func createPlantFromDraft(
        _ draft: CatalogPlantDraft,
        library: inout [PlantSighting]
    ) async -> CatalogPlantDraft? {
        var next = draft
        let imageData = draft.imageData.flatMap { $0.isEmpty ? nil : $0 } ?? Data()
        let ocr = await recognizeText?(imageData) ?? ""
        var saved = await store.save(
            imageData: imageData,
            name: draft.name,
            species: draft.species,
            location: nil,
            careNotes: draft.careTips,
            text: ocr,
            caption: draft.health ?? "Cataloged from video"
        )
        saved.suggestedActions = draft.suggestedActions
        saved.seasonalNotes = draft.seasonalNotes
        saved.healthStatus = draft.health
        saved.isOutdoor = draft.isOutdoor
        saved.frostSensitive = draft.frostSensitive
        saved = await store.upsert(saved)
        library.append(saved)
        next.savedPlantId = saved.id
        next.matchedPlantId = saved.id
        next.matchedLibraryName = saved.name
        return next
    }

    private func replaceExistingPlant(
        _ item: GardenCatalogDuplicateItem,
        library: inout [PlantSighting]
    ) async -> CatalogPlantDraft? {
        guard var existing = library.first(where: { $0.id == item.existingPlantId }) else {
            return await createPlantFromDraft(item.draft, library: &library)
        }
        let draft = item.draft
        if GardenVideoCatalogDiff.namesLikelySame(existing.name, draft.name),
           (draft.confidence ?? 0) >= 0.9 {
            existing.name = draft.name
        }
        if let species = draft.species, !species.isEmpty {
            if existing.species == nil || existing.species?.isEmpty == true
                || (draft.confidence ?? 0) >= 0.8 {
                existing.species = species
            }
        }
        if !draft.careTips.isEmpty { existing.careNotes = draft.careTips }
        if !draft.suggestedActions.isEmpty { existing.suggestedActions = draft.suggestedActions }
        if !draft.seasonalNotes.isEmpty { existing.seasonalNotes = draft.seasonalNotes }
        if let health = draft.health, !health.isEmpty {
            existing.healthStatus = health
            existing.caption = health
        }
        if let outdoor = draft.isOutdoor { existing.isOutdoor = outdoor }
        if let frost = draft.frostSensitive { existing.frostSensitive = frost }
        if let crop = draft.imageData, !crop.isEmpty {
            existing = await writePlantImage(existing, imageData: crop)
        }
        let saved = await store.upsert(existing)
        if let idx = library.firstIndex(where: { $0.id == saved.id }) {
            library[idx] = saved
        }
        var next = draft
        next.savedPlantId = saved.id
        next.matchedPlantId = saved.id
        next.matchedLibraryName = saved.name
        next.name = saved.name
        return next
    }

    /// Write (or replace) the on-disk JPEG for a library plant and return an
    /// updated sighting with the correct `fileName`.
    private func writePlantImage(_ plant: PlantSighting, imageData: Data) async -> PlantSighting {
        guard !imageData.isEmpty else { return plant }
        let dir = await store.directory()
        let fileName = plant.fileName.isEmpty
            ? "nova-plant-\(plant.id.uuidString).jpg"
            : plant.fileName
        try? imageData.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        return PlantSighting(
            id: plant.id,
            fileName: fileName,
            name: plant.name,
            species: plant.species,
            location: plant.location,
            careNotes: plant.careNotes,
            text: plant.text,
            caption: plant.caption,
            lastWateredAt: plant.lastWateredAt,
            isOutdoor: plant.isOutdoor,
            frostSensitive: plant.frostSensitive,
            lifeCycle: plant.lifeCycle,
            suggestedActions: plant.suggestedActions,
            seasonalNotes: plant.seasonalNotes,
            healthStatus: plant.healthStatus,
            createdAt: plant.createdAt,
            updatedAt: plant.updatedAt
        )
    }

    public func clearLibrary() async {
        await store.clear()
        await load()
    }

    public func logWatering(_ plant: PlantSighting) async {
        var next = plant
        next.lastWateredAt = Date()
        _ = await store.upsert(next)
        await load()
        statusMessage = "Logged watering for \(plant.name)"
    }

    public func updateNotes(
        _ plant: PlantSighting,
        name: String,
        species: String,
        location: String,
        careNotes: String,
        isOutdoor: Bool,
        frostSensitive: Bool,
        suggestedActions: [String] = [],
        seasonalNotes: String = "",
        healthStatus: String? = nil
    ) async {
        var next = plant
        next.name = name
        next.species = species.isEmpty ? nil : species
        next.location = location.isEmpty ? nil : location
        next.careNotes = careNotes
        next.isOutdoor = isOutdoor
        next.frostSensitive = frostSensitive
        next.suggestedActions = suggestedActions
        next.seasonalNotes = seasonalNotes
        next.healthStatus = healthStatus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            ? nil
            : healthStatus
        next.lifeCycle = GardenLifeCycleDiff.classify(next, zone: activeHardinessZone)
        _ = await store.upsert(next)
        await load()
    }

    public func saveClimateCity() async {
        let city = climateCityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.setClimateCity(city.isEmpty ? nil : city)
        await refreshClimate()
    }

    public func refreshClimate() async {
        let city = (await store.climateCity()) ?? climateCityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else {
            climate = nil
            rebuildPlan()
            return
        }
        guard let fetchClimate else {
            climate = GardenClimateSnapshot(city: city, summary: "Set a climate city to estimate frost dates.")
            rebuildPlan()
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            climate = try await fetchClimate(city)
            if let zone = climate?.hardinessZone {
                activeHardinessZone = zone
                hardinessZoneDraft = zone
                await store.setHardinessZone(zone)
                await retagPlantsForActiveZone(persist: true)
            }
            statusMessage = climate?.summary ?? "Climate updated"
            errorMessage = nil
        } catch {
            // Soft failure — keep seasonal defaults; don't paint Garden Walk red.
            statusMessage = "Climate: \(error.localizedDescription)"
            climate = GardenClimateSnapshot(
                city: city,
                summary: "Could not refresh frost dates — using seasonal defaults. Try “Philadelphia” or “Philadelphia, Pennsylvania”."
            )
        }
        rebuildPlan()
    }

    public func identifyWithGlasses(save: Bool = true) async {
        guard await isVisionReady(), let captureStill else {
            errorMessage = "Glasses camera not ready — register Meta glasses or upload a plant photo/video."
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let frame = try await captureStill()
            await releaseCamera?()
            await runIdentify(frame: frame, save: save, location: nil)
        } catch {
            errorMessage = String(describing: error)
            await releaseCamera?()
        }
    }

    public func identify(imageData: Data, save: Bool = true, location: String? = nil) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let frame = CapturedFrame(imageData: imageData, width: 0, height: 0)
        await runIdentify(frame: frame, save: save, location: location)
    }

    /// Live Garden Walk from Meta glasses (~10s look), then spoken coaching overview.
    public func startGardenWalkWithGlasses(speak: Bool = true) async {
        guard await isVisionReady(), startLiveLook != nil else {
            errorMessage = "Glasses camera not ready — register Meta glasses or upload a garden video/photo."
            return
        }
        guard !isWalking else { return }
        walkTask?.cancel()
        walkGeneration += 1
        let generation = walkGeneration
        walkTask = Task { @MainActor [weak self] in
            await self?.performGardenWalkWithGlasses(speak: speak, generation: generation)
        }
        await walkTask?.value
    }

    /// Stop an in-progress glasses or photo Garden Walk (capture, analysis, or briefing).
    public func stopGardenWalk() async {
        walkGeneration += 1
        walkTask?.cancel()
        walkTask = nil
        await stopLiveLook?()
        await releaseCamera?()
        await holdVideoForAudio?(false)
        if isWalking || isBusy {
            isWalking = false
            isBusy = false
            statusMessage = "Garden Walk stopped"
            errorMessage = nil
        }
    }

    private func performGardenWalkWithGlasses(speak: Bool, generation: Int) async {
        isWalking = true
        isBusy = true
        errorMessage = nil
        statusMessage = "Garden Walk — looking with glasses…"
        defer {
            if generation == walkGeneration {
                isWalking = false
                isBusy = false
                if walkTask != nil { walkTask = nil }
            }
        }
        guard let startLiveLook else { return }
        do {
            // Do NOT hold video-for-audio while collecting walk frames — that
            // drops every live frame (preferAudio default). Hold only after
            // release, right before spoken briefing.
            let stream = try await startLiveLook(2)
            var collected: [CapturedFrame] = []
            let deadline = Date().addingTimeInterval(10)
            for await frame in stream {
                guard generation == walkGeneration, !Task.isCancelled else {
                    await stopLiveLook?()
                    await releaseCamera?()
                    return
                }
                collected.append(frame)
                if collected.count >= 8 || Date() >= deadline { break }
            }
            guard generation == walkGeneration, !Task.isCancelled else {
                await stopLiveLook?()
                await releaseCamera?()
                return
            }
            await stopLiveLook?()
            await releaseCamera?()

            var burst = selector.selectBurst(collected)
            // Fallback: stills if live look opened the camera but yielded no frames
            // (e.g. prior sessionAlreadyExists race).
            if burst.isEmpty, let captureStill {
                statusMessage = "Garden Walk — capturing stills…"
                var stills: [CapturedFrame] = []
                for _ in 0..<3 {
                    guard generation == walkGeneration, !Task.isCancelled else {
                        await releaseCamera?()
                        return
                    }
                    if let frame = try? await captureStill() {
                        stills.append(frame)
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                }
                await releaseCamera?()
                burst = selector.selectBurst(stills)
            }

            guard generation == walkGeneration, !Task.isCancelled else { return }
            guard !burst.isEmpty else {
                errorMessage = "No frames captured during Garden Walk."
                return
            }

            await holdVideoForAudio?(true)
            await runGardenWalk(frames: burst, speak: speak, generation: generation)
            await holdVideoForAudio?(false)
        } catch is CancellationError {
            await stopLiveLook?()
            await releaseCamera?()
            await holdVideoForAudio?(false)
        } catch {
            guard generation == walkGeneration else { return }
            errorMessage = String(describing: error)
            await stopLiveLook?()
            await releaseCamera?()
            await holdVideoForAudio?(false)
        }
    }

    /// Garden Walk from one or more uploaded stills / video keyframes.
    public func startGardenWalk(imageDatas: [Data], speak: Bool = true) async {
        let frames = imageDatas
            .filter { !$0.isEmpty }
            .prefix(12)
            .map { CapturedFrame(imageData: $0, width: 0, height: 0) }
        guard !frames.isEmpty else {
            errorMessage = "Add a photo or video for Garden Walk."
            return
        }
        guard !isWalking else { return }
        walkTask?.cancel()
        walkGeneration += 1
        let generation = walkGeneration
        walkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isWalking = true
            self.isBusy = true
            self.errorMessage = nil
            defer {
                if generation == self.walkGeneration {
                    self.isWalking = false
                    self.isBusy = false
                    self.walkTask = nil
                }
            }
            await self.runGardenWalk(frames: Array(frames), speak: speak, generation: generation)
        }
        await walkTask?.value
    }

    private func runGardenWalk(frames: [CapturedFrame], speak: Bool, generation: Int) async {
        let library = await store.all()
        let prompt = GardenWalkDiff.analysisPrompt(library: library, climate: climate)
        statusMessage = "Analyzing \(frames.count) walk photo\(frames.count == 1 ? "" : "s")…"
        var partial: [GardenWalkResult] = []
        for (index, frame) in frames.enumerated() {
            guard generation == walkGeneration, !Task.isCancelled else { return }
            statusMessage = "Analyzing walk photo \(index + 1) of \(frames.count)…"
            do {
                let answer = try await analyzeImage(frame, prompt)
                guard generation == walkGeneration, !Task.isCancelled else { return }
                partial.append(GardenWalkDiff.parseModelJSON(answer, library: library))
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
        guard generation == walkGeneration, !Task.isCancelled else { return }
        guard !partial.isEmpty else {
            errorMessage = "Garden Walk analysis failed."
            return
        }
        let merged = GardenWalkDiff.merge(partial)
        lastWalk = merged
        _ = await store.appendGardenWalk(merged)
        savedWalks = await store.gardenWalks()
        statusMessage = merged.healthScore.map { "Walk complete · \($0)" } ?? "Walk complete"
        rebuildPlan()

        guard speak else { return }
        guard generation == walkGeneration, !Task.isCancelled else { return }
        let briefing = GardenWalkDiff.speakPrompt(result: merged, library: library, climate: climate)
        do {
            statusMessage = "Ivy speaking walk overview…"
            if let speakBriefing {
                try await speakBriefing(briefing)
            } else if let speakAboutFrame {
                // Legacy path: only if the frame is still fresh enough.
                let best = selector.pickBest(frames) ?? frames.last
                guard let best, best.age <= StreamBandwidthPolicy.default.maxFrameAgeSeconds else {
                    throw NovaError.vision("Walk analysis is ready, but audio needs a fresh capture — open Listen or retry Walk.")
                }
                _ = try await speakAboutFrame(best, briefing)
            } else {
                return
            }
            guard generation == walkGeneration, !Task.isCancelled else { return }
            statusMessage = "Walk briefing finished"
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == walkGeneration else { return }
            // Silent analysis still useful if TTS fails.
            statusMessage = "Walk analyzed (text only)"
            errorMessage = "Audio briefing skipped: \(error.localizedDescription)"
        }
    }

    private func runIdentify(
        frame: CapturedFrame,
        save: Bool,
        location: String?,
        switchToGallery: Bool = true
    ) async {
        var library = await store.all()
        let prompt = PlantIdentifyDiff.analysisPrompt(library: library)
        do {
            let answer = try await analyzeImage(frame, prompt)
            var result = PlantIdentifyDiff.parseModelJSON(answer, library: library)
            result.plants = PlantIdentifyDiff.dedupeLibraryMatchesForMultiPlant(result.plants)

            if save {
                var savedNames: [String] = []
                var skippedNames: [String] = []
                for hit in result.plants where PlantIdentifyDiff.shouldPersist(hit) {
                    let plantImage: Data
                    if let box = hit.boundingBox,
                       let cropped = PlantImageIsolator.cropJPEG(frame.imageData, box: box) {
                        plantImage = cropped
                    } else {
                        plantImage = frame.imageData
                    }
                    let ocrText = await recognizeText?(plantImage) ?? ""

                    if let matchId = hit.matchedPlantId,
                       var existing = library.first(where: { $0.id == matchId }) {
                        if let species = hit.species, !species.isEmpty {
                            if existing.species == nil || existing.species?.isEmpty == true
                                || (hit.confidence ?? 0) >= 0.8 {
                                existing.species = species
                            }
                        }
                        if !hit.careTips.isEmpty { existing.careNotes = hit.careTips }
                        if let health = hit.health, !health.isEmpty {
                            existing.healthStatus = health
                            existing.caption = health
                        }
                        if let location, !location.isEmpty { existing.location = location }
                        existing = await writePlantImage(existing, imageData: plantImage)
                        let plant = await store.upsert(existing)
                        if let idx = library.firstIndex(where: { $0.id == plant.id }) {
                            library[idx] = plant
                        }
                        if let idx = result.plants.firstIndex(where: { $0.id == hit.id }) {
                            result.plants[idx].matchedPlantId = plant.id
                            result.plants[idx].matchedLibraryName = plant.name
                        }
                        savedNames.append(plant.name)
                    } else if PlantIdentifyDiff.shouldSaveAsNew(hit) {
                        let plant = await store.save(
                            imageData: plantImage,
                            name: hit.name,
                            species: hit.species,
                            location: location,
                            careNotes: hit.careTips,
                            text: ocrText,
                            caption: hit.health ?? ""
                        )
                        library.append(plant)
                        if let idx = result.plants.firstIndex(where: { $0.id == hit.id }) {
                            result.plants[idx].matchedPlantId = plant.id
                            result.plants[idx].matchedLibraryName = plant.name
                        }
                        savedNames.append(plant.name)
                    } else {
                        skippedNames.append(hit.name)
                    }
                }

                if !savedNames.isEmpty {
                    var unique: [String] = []
                    var seen = Set<String>()
                    for name in savedNames where seen.insert(name).inserted {
                        unique.append(name)
                    }
                    statusMessage = unique.count == 1
                        ? "Saved \(unique[0]) to garden library"
                        : "Saved \(unique.count) plant profiles (\(unique.joined(separator: ", ")))"
                } else if let top = result.plants.first {
                    statusMessage = "Skipped weak ID (\(top.name)) — try a closer photo"
                } else {
                    statusMessage = "No confident plant ID — photo not saved"
                }
                if !skippedNames.isEmpty, !savedNames.isEmpty {
                    statusMessage += " · skipped \(skippedNames.count) weak"
                }
            } else if let top = result.plants.first {
                statusMessage = result.plants.count == 1
                    ? "Identified \(top.name)"
                    : "Identified \(result.plants.count) plants"
            } else {
                statusMessage = "No plant identified"
            }
            lastIdentify = result
            if switchToGallery { section = .gallery }
            await load()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Crop each detected plant out of the shared frame so profiles get isolated photos.
    private static func isolatePlantDrafts(
        _ drafts: [CatalogPlantDraft],
        sourceImage: Data
    ) -> [CatalogPlantDraft] {
        let multi = drafts.count > 1
        return drafts.map { draft in
            var next = draft
            guard let box = draft.boundingBox else { return next }
            // Single plant with a huge box → leave full frame.
            if !multi, box.area >= 0.85 { return next }
            if let cropped = PlantImageIsolator.cropJPEG(sourceImage, box: box) {
                next.imageData = cropped
            }
            return next
        }
    }

    private func rebuildPlan() {
        planItems = GardenPlanningDiff.buildPlan(library: plants, climate: climate)
        suggestedTips = GardenLifeCycleDiff.suggestedTips(from: savedWalks)
        let zone = activeHardinessZone ?? climate?.hardinessZone
        plantRecommendations = GardenPlantingRecommendationsDiff.recommendations(
            zone: zone,
            climate: climate,
            library: plants
        )
    }

    /// Recompute Annual/Perennial for every plant from the active zone.
    private func retagPlantsForActiveZone(persist: Bool) async {
        let zone = activeHardinessZone ?? climate?.hardinessZone
        let tagged = GardenLifeCycleDiff.retag(plants, zone: zone)
        plants = tagged.sorted { $0.updatedAt > $1.updatedAt }
        guard persist else { return }
        for plant in tagged where plant.lifeCycle != nil {
            _ = await store.upsert(plant)
        }
        plants = await store.all()
    }
}

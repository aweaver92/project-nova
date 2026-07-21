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
    public private(set) var planItems: [GardenPlanItem] = []
    public private(set) var climate: GardenClimateSnapshot?
    public var climateCityDraft: String = ""
    public private(set) var statusMessage: String = ""
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false
    public private(set) var isWalking = false
    public private(set) var directoryURL: URL?
    public private(set) var librarySaveMessage: String?

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
        guard let walk = lastWalk else {
            librarySaveMessage = "No Garden Walk to save yet."
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
        errorMessage = "Could not read one or more photos — try JPEG/HEIC stills from Photos."
    }

    public func planItems(for season: GardenSeason) -> [GardenPlanItem] {
        GardenPlanningDiff.items(for: season, in: planItems)
    }

    public func load() async {
        plants = await store.all()
        directoryURL = await store.directory()
        climateCityDraft = await store.climateCity() ?? climateCityDraft
        rebuildPlan()
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

    /// Import one or more photos into the gallery (identify + save each).
    public func importPhotosToGallery(_ imageDatas: [Data]) async {
        let datas = Array(imageDatas.filter { !$0.isEmpty }.prefix(12))
        guard !datas.isEmpty else {
            errorMessage = "Could not read those photos — try again."
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var saved = 0
        for (index, data) in datas.enumerated() {
            statusMessage = "Adding photo \(index + 1) of \(datas.count)…"
            let frame = CapturedFrame(imageData: data, width: 0, height: 0)
            let countBefore = await store.all().count
            await runIdentify(frame: frame, save: true, location: nil, switchToGallery: false)
            var countAfter = await store.all().count
            if countAfter <= countBefore {
                // Vision failed — still keep the photo in the gallery.
                _ = await store.save(
                    imageData: data,
                    name: "Plant",
                    species: nil,
                    location: nil,
                    careNotes: "",
                    text: await recognizeText?(data) ?? "",
                    caption: "Added from Photos — rename in Gallery"
                )
                countAfter = await store.all().count
                errorMessage = nil
            }
            if countAfter > countBefore { saved += 1 }
        }
        section = .gallery
        await load()
        if saved > 0 { errorMessage = nil }
        statusMessage = saved == 0
            ? "No plants saved from those photos"
            : "Added \(saved) photo\(saved == 1 ? "" : "s") to gallery (\(plants.count) total)"
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
        frostSensitive: Bool
    ) async {
        var next = plant
        next.name = name
        next.species = species.isEmpty ? nil : species
        next.location = location.isEmpty ? nil : location
        next.careNotes = careNotes
        next.isOutdoor = isOutdoor
        next.frostSensitive = frostSensitive
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
            errorMessage = "Glasses camera not ready — register Meta glasses or upload a photo."
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
        guard await isVisionReady(), let startLiveLook else {
            errorMessage = "Glasses camera not ready — register Meta glasses or upload a garden video/photo."
            return
        }
        isWalking = true
        isBusy = true
        errorMessage = nil
        statusMessage = "Garden Walk — looking with glasses…"
        defer {
            isWalking = false
            isBusy = false
        }
        do {
            // Do NOT hold video-for-audio while collecting walk frames — that
            // drops every live frame (preferAudio default). Hold only after
            // release, right before spoken briefing.
            let stream = try await startLiveLook(2)
            var collected: [CapturedFrame] = []
            let deadline = Date().addingTimeInterval(10)
            for await frame in stream {
                collected.append(frame)
                if collected.count >= 8 || Date() >= deadline { break }
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
                    if let frame = try? await captureStill() {
                        stills.append(frame)
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                }
                await releaseCamera?()
                burst = selector.selectBurst(stills)
            }

            guard !burst.isEmpty else {
                errorMessage = "No frames captured during Garden Walk."
                return
            }

            await holdVideoForAudio?(true)
            await runGardenWalk(frames: burst, speak: speak)
            await holdVideoForAudio?(false)
        } catch {
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
        isWalking = true
        isBusy = true
        errorMessage = nil
        defer {
            isWalking = false
            isBusy = false
        }
        await runGardenWalk(frames: Array(frames), speak: speak)
    }

    private func runGardenWalk(frames: [CapturedFrame], speak: Bool) async {
        let library = await store.all()
        let prompt = GardenWalkDiff.analysisPrompt(library: library)
        statusMessage = "Analyzing \(frames.count) walk photo\(frames.count == 1 ? "" : "s")…"
        var partial: [GardenWalkResult] = []
        for (index, frame) in frames.enumerated() {
            statusMessage = "Analyzing walk photo \(index + 1) of \(frames.count)…"
            do {
                let answer = try await analyzeImage(frame, prompt)
                partial.append(GardenWalkDiff.parseModelJSON(answer, library: library))
            } catch {
                continue
            }
        }
        guard !partial.isEmpty else {
            errorMessage = "Garden Walk analysis failed."
            return
        }
        let merged = GardenWalkDiff.merge(partial)
        lastWalk = merged
        statusMessage = merged.healthScore.map { "Walk complete · \($0)" } ?? "Walk complete"
        rebuildPlan()

        guard speak else { return }
        let briefing = GardenWalkDiff.speakPrompt(result: merged, library: library)
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
            statusMessage = "Walk briefing finished"
            errorMessage = nil
        } catch {
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
        let library = await store.all()
        let prompt = PlantIdentifyDiff.analysisPrompt(library: library)
        do {
            let answer = try await analyzeImage(frame, prompt)
            var result = PlantIdentifyDiff.parseModelJSON(answer, library: library)
            if save, let top = result.plants.first {
                let ocrText = await recognizeText?(frame.imageData) ?? ""
                let plant = await store.save(
                    imageData: frame.imageData,
                    name: top.name,
                    species: top.species,
                    location: location,
                    careNotes: top.careTips,
                    text: ocrText,
                    caption: top.health ?? ""
                )
                if let idx = result.plants.firstIndex(where: { $0.id == top.id }) {
                    result.plants[idx].matchedPlantId = plant.id
                    result.plants[idx].matchedLibraryName = plant.name
                }
                statusMessage = "Saved \(plant.name) to garden library"
            } else if let top = result.plants.first {
                statusMessage = "Identified \(top.name)"
            } else if save {
                // Still keep the photo in the gallery even when ID is uncertain.
                let plant = await store.save(
                    imageData: frame.imageData,
                    name: "Plant",
                    species: nil,
                    location: location,
                    careNotes: "",
                    text: await recognizeText?(frame.imageData) ?? "",
                    caption: "Unidentified — rename in Gallery"
                )
                statusMessage = "Saved photo as \(plant.name) — tap to rename"
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

    private func rebuildPlan() {
        planItems = GardenPlanningDiff.buildPlan(library: plants, climate: climate)
    }
}

import Foundation
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

    private let store: any PlantLibraryStoring
    private let analyzeImage: (CapturedFrame, String) async throws -> String
    private let captureStill: (() async throws -> CapturedFrame)?
    private let startLiveLook: ((Int) async throws -> AsyncStream<CapturedFrame>)?
    private let stopLiveLook: (() async -> Void)?
    private let releaseCamera: (() async -> Void)?
    private let isVisionReady: () async -> Bool
    private let recognizeText: ((Data) async -> String)?
    private let speakAboutFrame: ((CapturedFrame, String) async throws -> String)?
    private let fetchClimate: ((String) async throws -> GardenClimateSnapshot)?
    private let holdVideoForAudio: ((Bool) async -> Void)?
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
        fetchClimate: ((String) async throws -> GardenClimateSnapshot)? = nil,
        holdVideoForAudio: ((Bool) async -> Void)? = nil
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
        self.fetchClimate = fetchClimate
        self.holdVideoForAudio = holdVideoForAudio
    }

    public var plantCount: Int { plants.count }

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
            errorMessage = String(describing: error)
            climate = GardenClimateSnapshot(city: city, summary: "Could not refresh frost dates — using seasonal defaults.")
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
            await holdVideoForAudio?(true)
            let stream = try await startLiveLook(2)
            var collected: [CapturedFrame] = []
            let deadline = Date().addingTimeInterval(10)
            for await frame in stream {
                collected.append(frame)
                if collected.count >= 8 || Date() >= deadline { break }
            }
            await stopLiveLook?()
            await releaseCamera?()
            await holdVideoForAudio?(false)
            let burst = selector.selectBurst(collected)
            guard !burst.isEmpty else {
                errorMessage = "No frames captured during Garden Walk."
                return
            }
            await runGardenWalk(frames: burst, speak: speak)
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
            .prefix(6)
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
        statusMessage = "Analyzing garden walk…"
        var partial: [GardenWalkResult] = []
        for frame in frames {
            do {
                let answer = try await analyzeImage(frame, prompt)
                partial.append(GardenWalkDiff.parseModelJSON(answer, library: library))
            } catch {
                // Keep other frames if one fails.
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

        guard speak, let speakAboutFrame, let best = selector.pickBest(frames) ?? frames.last else {
            return
        }
        do {
            statusMessage = "Ivy speaking walk overview…"
            _ = try await speakAboutFrame(best, GardenWalkDiff.speakPrompt(result: merged, library: library))
            statusMessage = "Walk briefing finished"
        } catch {
            // Silent analysis still useful if TTS fails.
            errorMessage = "Walk analyzed, but audio briefing failed: \(error)"
        }
    }

    private func runIdentify(frame: CapturedFrame, save: Bool, location: String?) async {
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
            } else {
                statusMessage = "No plant identified"
            }
            lastIdentify = result
            section = .gallery
            await load()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func rebuildPlan() {
        planItems = GardenPlanningDiff.buildPlan(library: plants, climate: climate)
    }
}

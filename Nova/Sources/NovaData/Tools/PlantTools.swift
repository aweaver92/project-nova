import Foundation
import NovaDomain

// MARK: - List / mutate

public struct ListPlantsTool: Tool {
    public let name = "list_plants"
    public let description = "List plants in Ivy's garden image library with locations and care notes."
    public let requiresConfirmation = false
    public let parametersJSON = #"{"type":"object","properties":{"limit":{"type":"integer"}},"additionalProperties":false}"#

    private let store: any PlantLibraryStoring

    public init(store: any PlantLibraryStoring) {
        self.store = store
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let limit: Int? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(limit: nil)
        let limit = max(1, min(args.limit ?? 24, 60))
        return await store.summary(limit: limit)
    }
}

public struct SavePlantTool: Tool {
    public let name = "save_plant"
    public let description = "Add or describe a plant in the garden library without a new photo (name, species, location, care notes)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"name":{"type":"string"},"species":{"type":"string"},"location":{"type":"string"},"care_notes":{"type":"string"},"caption":{"type":"string"}},"required":["name"],"additionalProperties":false}
    """

    private let store: any PlantLibraryStoring

    public init(store: any PlantLibraryStoring) {
        self.store = store
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let name: String
            let species: String?
            let location: String?
            let care_notes: String?
            let caption: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let plant = await store.save(
            imageData: Data(),
            name: args.name,
            species: args.species,
            location: args.location,
            careNotes: args.care_notes ?? "",
            text: "",
            caption: args.caption ?? ""
        )
        return #"{"ok":true,"id":"\#(plant.id.uuidString)","name":"\#(plant.name)"}"#
    }
}

public struct UpdatePlantTool: Tool {
    public let name = "update_plant"
    public let description = "Update an existing garden-library plant by id (name, species, location, care notes, outdoor/frost flags)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"species":{"type":"string"},"location":{"type":"string"},"care_notes":{"type":"string"},"is_outdoor":{"type":"boolean"},"frost_sensitive":{"type":"boolean"}},"required":["id"],"additionalProperties":false}
    """

    private let store: any PlantLibraryStoring

    public init(store: any PlantLibraryStoring) {
        self.store = store
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let id: String
            let name: String?
            let species: String?
            let location: String?
            let care_notes: String?
            let is_outdoor: Bool?
            let frost_sensitive: Bool?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let uuid = UUID(uuidString: args.id),
              var plant = await store.all().first(where: { $0.id == uuid }) else {
            return #"{"ok":false,"error":"plant_not_found"}"#
        }
        if let name = args.name, !name.isEmpty { plant.name = name }
        if let species = args.species { plant.species = species }
        if let location = args.location { plant.location = location }
        if let care = args.care_notes { plant.careNotes = care }
        if let outdoor = args.is_outdoor { plant.isOutdoor = outdoor }
        if let frost = args.frost_sensitive { plant.frostSensitive = frost }
        _ = await store.upsert(plant)
        return #"{"ok":true,"id":"\#(plant.id.uuidString)","name":"\#(plant.name)"}"#
    }
}

public struct RemovePlantTool: Tool {
    public let name = "remove_plant"
    public let description = "Delete a plant from Ivy's garden library by id."
    public let requiresConfirmation = true
    public let parametersJSON = #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#

    private let store: any PlantLibraryStoring

    public init(store: any PlantLibraryStoring) {
        self.store = store
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let uuid = UUID(uuidString: args.id) else {
            return #"{"ok":false,"error":"invalid_id"}"#
        }
        await store.delete(id: uuid)
        return #"{"ok":true}"#
    }
}

public struct LogPlantWateringTool: Tool {
    public let name = "log_plant_watering"
    public let description = "Mark a garden-library plant as watered now (by id or exact name)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"additionalProperties":false}
    """

    private let store: any PlantLibraryStoring

    public init(store: any PlantLibraryStoring) {
        self.store = store
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String?; let name: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let all = await store.all()
        var plant: PlantSighting?
        if let id = args.id, let uuid = UUID(uuidString: id) {
            plant = all.first { $0.id == uuid }
        } else if let name = args.name {
            plant = all.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        guard var found = plant else {
            return #"{"ok":false,"error":"plant_not_found"}"#
        }
        found.lastWateredAt = Date()
        _ = await store.upsert(found)
        return #"{"ok":true,"id":"\#(found.id.uuidString)","name":"\#(found.name)","watered_at":"now"}"#
    }
}

// MARK: - Identify

public struct IdentifyPlantTool: Tool {
    public let name = "identify_plant"
    public let description = "Capture a still from the glasses camera, identify plant(s) with vision grounded in the garden library, and optionally save the primary match into the library."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"save":{"type":"boolean","description":"If true, save the top identified plant into the library."},"location":{"type":"string"}},"additionalProperties":false}
    """

    private let frameCapture: any FrameCapture
    private let ai: any ConversationalAIProvider
    private let store: any PlantLibraryStoring
    private let isVisionReady: @Sendable () async -> Bool

    public init(
        frameCapture: any FrameCapture,
        ai: any ConversationalAIProvider,
        store: any PlantLibraryStoring,
        isVisionReady: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.frameCapture = frameCapture
        self.ai = ai
        self.store = store
        self.isVisionReady = isVisionReady
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let save: Bool?; let location: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(save: nil, location: nil)

        guard await isVisionReady() else {
            return #"{"ok":false,"error":"vision_not_ready","hint":"Open Garden on the phone to upload a plant photo, or register glasses first."}"#
        }

        let frame = try await frameCapture.captureStill()
        await frameCapture.releaseCamera()

        let library = await store.all()
        let prompt = PlantIdentifyDiff.analysisPrompt(library: library)
        let answer = try await ai.analyze(image: frame, prompt: prompt)
        var result = PlantIdentifyDiff.parseModelJSON(answer, library: library)

        var savedId: String?
        if args.save == true, let top = result.plants.first, PlantIdentifyDiff.shouldPersist(top) {
            if let matchId = top.matchedPlantId,
               var existing = library.first(where: { $0.id == matchId }) {
                if let species = top.species, !species.isEmpty {
                    if existing.species == nil || existing.species?.isEmpty == true
                        || (top.confidence ?? 0) >= 0.8 {
                        existing.species = species
                    }
                }
                if !top.careTips.isEmpty { existing.careNotes = top.careTips }
                if let health = top.health, !health.isEmpty {
                    existing.healthStatus = health
                    existing.caption = health
                }
                if let location = args.location, !location.isEmpty {
                    existing.location = location
                }
                let plant = await store.upsert(existing)
                savedId = plant.id.uuidString
                if let idx = result.plants.firstIndex(where: { $0.id == top.id }) {
                    result.plants[idx].matchedPlantId = plant.id
                    result.plants[idx].matchedLibraryName = plant.name
                }
            } else if PlantIdentifyDiff.shouldSaveAsNew(top) {
                let plant = await store.save(
                    imageData: frame.imageData,
                    name: top.name,
                    species: top.species,
                    location: args.location,
                    careNotes: top.careTips,
                    text: "",
                    caption: top.health ?? ""
                )
                savedId = plant.id.uuidString
                if let idx = result.plants.firstIndex(where: { $0.id == top.id }) {
                    result.plants[idx].matchedPlantId = plant.id
                    result.plants[idx].matchedLibraryName = plant.name
                }
            }
        }

        return try Self.encode(result, savedId: savedId)
    }

    static func encode(_ result: PlantIdentifyResult, savedId: String?) throws -> String {
        let plants: [[String: Any]] = result.plants.map { hit in
            var d: [String: Any] = [
                "name": hit.name,
                "care_tips": hit.careTips
            ]
            if let species = hit.species { d["species"] = species }
            if let matched = hit.matchedLibraryName { d["matched_library"] = matched }
            if let id = hit.matchedPlantId { d["plant_id"] = id.uuidString }
            if let confidence = hit.confidence { d["confidence"] = confidence }
            if let health = hit.health { d["health"] = health }
            return d
        }
        var payload: [String: Any] = [
            "ok": true,
            "plants": plants
        ]
        if let notes = result.notes { payload["notes"] = notes }
        if let savedId { payload["saved_id"] = savedId }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
    }
}

// MARK: - Garden Walk / Planning

public struct GardenWalkTool: Tool {
    public let name = "garden_walk"
    public let description = "Capture a short glasses live look of the garden, analyze health/maintenance/mistakes grounded in the plant library and current season/climate, and return a coaching overview. Prefer this when the user wants a Garden Walk or proactive garden check. For a phone video, tell them to open Garden (upload) or Media → Send to Ivy."
    public let requiresConfirmation = false
    public let parametersJSON = #"{"type":"object","properties":{"duration_seconds":{"type":"number"}},"additionalProperties":false}"#

    private let frameCapture: any FrameCapture
    private let ai: any ConversationalAIProvider
    private let store: any PlantLibraryStoring
    private let climateClient: GardenClimateClient
    private let isVisionReady: @Sendable () async -> Bool
    private let selector = FrameSelector()

    public init(
        frameCapture: any FrameCapture,
        ai: any ConversationalAIProvider,
        store: any PlantLibraryStoring,
        climateClient: GardenClimateClient = GardenClimateClient(),
        isVisionReady: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.frameCapture = frameCapture
        self.ai = ai
        self.store = store
        self.climateClient = climateClient
        self.isVisionReady = isVisionReady
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let duration_seconds: Double? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(duration_seconds: nil)
        let duration = min(max(args.duration_seconds ?? 10, 4), 20)

        guard await isVisionReady() else {
            return #"{"ok":false,"error":"vision_not_ready","hint":"Open Garden and tap Garden Walk, upload a garden video/photo, or send a Media video to Ivy. Register glasses for a live walk."}"#
        }

        let stream = try await frameCapture.startLiveLook(fps: 2)
        var collected: [CapturedFrame] = []
        let deadline = Date().addingTimeInterval(duration)
        for await frame in stream {
            collected.append(frame)
            if collected.count >= 8 || Date() >= deadline { break }
        }
        await frameCapture.stopLiveLook()
        await frameCapture.releaseCamera()

        let burst = selector.selectBurst(collected)
        guard !burst.isEmpty else {
            return #"{"ok":false,"error":"no_frames"}"#
        }

        let library = await store.all()
        var climate: GardenClimateSnapshot?
        if let city = await store.climateCity() {
            climate = try? await climateClient.snapshot(city: city)
        }
        let prompt = GardenWalkDiff.analysisPrompt(library: library, climate: climate)
        var partial: [GardenWalkResult] = []
        for frame in burst {
            let answer = try await ai.analyze(image: frame, prompt: prompt)
            partial.append(GardenWalkDiff.parseModelJSON(answer, library: library))
        }
        let merged = GardenWalkDiff.merge(partial)
        return try Self.encode(merged)
    }

    static func encode(_ result: GardenWalkResult) throws -> String {
        let findings: [[String: Any]] = result.findings.map { f in
            var d: [String: Any] = [
                "severity": f.severity,
                "title": f.title,
                "detail": f.detail
            ]
            if let name = f.matchedPlantName { d["matched_library"] = name }
            if let id = f.matchedPlantId { d["plant_id"] = id.uuidString }
            return d
        }
        var payload: [String: Any] = [
            "ok": true,
            "overview": result.overview,
            "findings": findings,
            "maintenance": result.maintenance,
            "mistakes": result.mistakes,
            "spoken_summary": result.spokenSummary
        ]
        if let health = result.healthScore { payload["health_score"] = health }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
    }
}

public struct ListGardenPlanTool: Tool {
    public let name = "list_garden_plan"
    public let description = "Seasonal garden plan for the user's climate: current-season planting, watering/heat care, and (when timely) bring-inside-before-frost guidance."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"season":{"type":"string","description":"spring|summer|fall|winter — omit to focus on the current season"},"city":{"type":"string","description":"Optional climate city override"}},"additionalProperties":false}
    """

    private let store: any PlantLibraryStoring
    private let climateClient: GardenClimateClient

    public init(store: any PlantLibraryStoring, climateClient: GardenClimateClient = GardenClimateClient()) {
        self.store = store
        self.climateClient = climateClient
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let season: String?; let city: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(season: nil, city: nil)

        if let city = args.city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            await store.setClimateCity(city)
        }

        let library = await store.all()
        var climate: GardenClimateSnapshot?
        if let city = await store.climateCity() {
            climate = try? await climateClient.snapshot(city: city)
        }
        var plan = GardenPlanningDiff.buildPlan(library: library, climate: climate)
        if let seasonRaw = args.season,
           let season = GardenSeason(rawValue: seasonRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            plan = GardenPlanningDiff.items(for: season, in: plan)
        } else {
            // Default to current season so chat doesn't lead with off-season frost rows.
            plan = GardenPlanningDiff.items(for: GardenSeason.current(), in: plan)
        }
        let summary = GardenPlanningDiff.summary(plan: plan, climate: climate)
        let rows: [[String: Any]] = plan.prefix(40).map { item in
            var d: [String: Any] = [
                "season": item.season.rawValue,
                "kind": item.kind.rawValue,
                "title": item.title,
                "detail": item.detail,
                "window": item.windowLabel
            ]
            if let id = item.plantId { d["plant_id"] = id.uuidString }
            if let name = item.plantName { d["plant_name"] = name }
            return d
        }
        var payload: [String: Any] = [
            "ok": true,
            "summary": summary,
            "items": rows
        ]
        if let climate {
            payload["climate_city"] = climate.city
            payload["climate_summary"] = climate.summary
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
    }
}

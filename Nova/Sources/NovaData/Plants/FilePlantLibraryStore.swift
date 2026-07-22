import Foundation
import NovaCore
import NovaDomain

/// File-backed garden library for Ivy. Images live under `Documents/PlantLibrary`
/// with a JSON index so the gallery persists on-device.
public actor FilePlantLibraryStore: PlantLibraryStoring {
    private struct Meta: Codable {
        var climateCity: String?
    }

    private let dir: URL
    private let indexURL: URL
    private let metaURL: URL
    private var plants: [PlantSighting]
    private var meta: Meta
    private let maxItems: Int

    public init(directory: URL? = nil, maxItems: Int = 1_000) {
        let resolved = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        self.dir = resolved
        self.indexURL = resolved.appendingPathComponent("index.json")
        self.metaURL = resolved.appendingPathComponent("meta.json")
        self.plants = Self.load(from: indexURL)
        self.meta = Self.loadMeta(from: metaURL)
        self.maxItems = maxItems
    }

    public func directory() -> URL { dir }

    public func all() -> [PlantSighting] {
        plants.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func climateCity() -> String? {
        let trimmed = meta.climateCity?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public func setClimateCity(_ city: String?) {
        let trimmed = city?.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.climateCity = (trimmed?.isEmpty == false) ? trimmed : nil
        persistMeta()
    }

    @discardableResult
    public func upsert(_ plant: PlantSighting) -> PlantSighting {
        var next = plant
        next.updatedAt = Date()
        if let idx = plants.firstIndex(where: { $0.id == next.id }) {
            // Keep existing file if the replacement has an empty fileName.
            if next.fileName.isEmpty {
                next = PlantSighting(
                    id: next.id,
                    fileName: plants[idx].fileName,
                    name: next.name,
                    species: next.species,
                    location: next.location,
                    careNotes: next.careNotes,
                    text: next.text,
                    caption: next.caption,
                    lastWateredAt: next.lastWateredAt,
                    isOutdoor: next.isOutdoor ?? plants[idx].isOutdoor,
                    frostSensitive: next.frostSensitive ?? plants[idx].frostSensitive,
                    suggestedActions: next.suggestedActions.isEmpty
                        ? plants[idx].suggestedActions
                        : next.suggestedActions,
                    seasonalNotes: next.seasonalNotes.isEmpty
                        ? plants[idx].seasonalNotes
                        : next.seasonalNotes,
                    healthStatus: next.healthStatus ?? plants[idx].healthStatus,
                    createdAt: plants[idx].createdAt,
                    updatedAt: next.updatedAt
                )
            }
            plants[idx] = next
        } else {
            plants.append(next)
            pruneIfNeeded()
        }
        persist()
        return next
    }

    @discardableResult
    public func save(
        imageData: Data,
        name: String,
        species: String?,
        location: String?,
        careNotes: String,
        text: String,
        caption: String
    ) -> PlantSighting {
        let id = UUID()
        let fileName: String
        if imageData.isEmpty {
            fileName = ""
        } else {
            fileName = "nova-plant-\(id.uuidString).jpg"
            try? imageData.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        }
        let plant = PlantSighting(
            id: id,
            fileName: fileName,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Plant" : name,
            species: species,
            location: location,
            careNotes: careNotes,
            text: text,
            caption: caption
        )
        plants.append(plant)
        pruneIfNeeded()
        persist()
        return plant
    }

    public func delete(id: UUID) {
        guard let idx = plants.firstIndex(where: { $0.id == id }) else { return }
        let removed = plants.remove(at: idx)
        if !removed.fileName.isEmpty {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(removed.fileName))
        }
        persist()
    }

    public func clear() {
        for plant in plants where !plant.fileName.isEmpty {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(plant.fileName))
        }
        plants.removeAll()
        persist()
    }

    public func summary(limit: Int = 24) -> String {
        let slice = all().prefix(max(1, limit))
        guard !slice.isEmpty else {
            return "Plant library is empty — identify or save plants to build Ivy's garden context."
        }
        var header = "Plant library (\(plants.count)) · \(GardenSeason.current().title)"
        if let city = climateCity() {
            header += " · climate \(city)"
        }
        let frostRelevant = GardenPlanningDiff.isFrostAdviceRelevant(climate: nil)
        let lines = slice.map { plant -> String in
            var line = "• \(plant.name)"
            if let species = plant.species, !species.isEmpty { line += " (\(species))" }
            if let location = plant.location, !location.isEmpty { line += " @ \(location)" }
            if plant.isOutdoor == true { line += " [outdoor]" }
            if plant.frostSensitive == true, frostRelevant { line += " [frost-sensitive]" }
            if let watered = plant.lastWateredAt {
                let days = Calendar.current.dateComponents([.day], from: watered, to: Date()).day ?? 0
                line += days == 0 ? " · watered today" : " · watered \(days)d ago"
            }
            if !plant.careNotes.isEmpty {
                line += " — \(plant.careNotes.prefix(80))"
            }
            return line
        }
        return header + ":\n" + lines.joined(separator: "\n")
    }

    private func pruneIfNeeded() {
        guard plants.count > maxItems else { return }
        let overflow = plants.count - maxItems
        let oldest = plants.sorted { $0.createdAt < $1.createdAt }.prefix(overflow)
        for plant in oldest {
            if !plant.fileName.isEmpty {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(plant.fileName))
            }
            plants.removeAll { $0.id == plant.id }
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(plants)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NovaLog.session.error("Plant library persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func persistMeta() {
        do {
            let data = try JSONEncoder().encode(meta)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            NovaLog.session.error("Plant library meta persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [PlantSighting] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PlantSighting].self, from: data)) ?? []
    }

    private static func loadMeta(from url: URL) -> Meta {
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            return Meta(climateCity: nil)
        }
        return meta
    }

    private static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("PlantLibrary", isDirectory: true)
    }
}

import SwiftUI
import NovaDomain
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Ivy's garden workspace: gallery, identify, Garden Walk, and seasonal planning.
public struct IvyGardenView: View {
    @Bindable var garden: IvyGardenViewModel
    var embedded: Bool = false
    @State private var identifyPickerItem: PhotosPickerItem?
    @State private var walkPickerItems: [PhotosPickerItem] = []
    @State private var confirmClear = false
    @State private var editing: PlantSighting?

    public init(garden: IvyGardenViewModel, embedded: Bool = false) {
        self.garden = garden
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .task {
            await garden.load()
            if garden.climate == nil, !garden.climateCityDraft.isEmpty {
                await garden.refreshClimate()
            }
        }
    }

    private var content: some View {
        List {
            gardenWalkSection

            Picker("Section", selection: $garden.section) {
                ForEach(IvyGardenViewModel.Section.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if !garden.statusMessage.isEmpty {
                Text(garden.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = garden.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            switch garden.section {
            case .gallery:
                gallerySection
            case .identify:
                identifySection
            case .planning:
                planningSection
            }
        }
        .navigationTitle("Garden")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if garden.section == .gallery, !garden.plants.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear plant library?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all plants", role: .destructive) {
                Task { await garden.clearLibrary() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editing) { plant in
            PlantEditorSheet(plant: plant) { name, species, location, notes, outdoor, frost in
                Task {
                    await garden.updateNotes(
                        plant,
                        name: name,
                        species: species,
                        location: location,
                        careNotes: notes,
                        isOutdoor: outdoor,
                        frostSensitive: frost
                    )
                    editing = nil
                }
            } onCancel: {
                editing = nil
            }
        }
        .onChange(of: identifyPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await garden.identify(imageData: data, save: true)
                }
                identifyPickerItem = nil
            }
        }
        .onChange(of: walkPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var frames: [Data] = []
                for item in items.prefix(6) {
                    if let framesFromVideo = await loadWalkFrames(from: item) {
                        frames.append(contentsOf: framesFromVideo)
                    }
                }
                await garden.startGardenWalk(imageDatas: frames, speak: true)
                walkPickerItems = []
            }
        }
    }

    @ViewBuilder
    private var gardenWalkSection: some View {
        Section {
            Button {
                Task { await garden.startGardenWalkWithGlasses(speak: true) }
            } label: {
                Label(
                    garden.isWalking ? "Walking…" : "Garden Walk",
                    systemImage: "figure.walk"
                )
            }
            .disabled(garden.isBusy || garden.isWalking)

            PhotosPicker(
                selection: $walkPickerItems,
                maxSelectionCount: 6,
                matching: .any(of: [.images, .videos])
            ) {
                Label("Upload walk photos/video", systemImage: "video.badge.plus")
            }
            .disabled(garden.isBusy || garden.isWalking)

            if let walk = garden.lastWalk {
                VStack(alignment: .leading, spacing: 6) {
                    if let score = walk.healthScore {
                        Text("Health · \(score)")
                            .font(.caption.weight(.semibold))
                    }
                    if !walk.overview.isEmpty {
                        Text(walk.overview)
                            .font(.caption)
                    }
                    if !walk.mistakes.isEmpty {
                        Text("Mistakes")
                            .font(.caption2.weight(.semibold))
                            .padding(.top, 2)
                        ForEach(walk.mistakes, id: \.self) { item in
                            Text("• \(item)").font(.caption2)
                        }
                    }
                    if !walk.maintenance.isEmpty {
                        Text("Maintenance")
                            .font(.caption2.weight(.semibold))
                            .padding(.top, 2)
                        ForEach(walk.maintenance, id: \.self) { item in
                            Text("• \(item)").font(.caption2)
                        }
                    }
                    ForEach(walk.findings) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(finding.severity): \(finding.title)")
                                .font(.caption.weight(.semibold))
                            if !finding.detail.isEmpty {
                                Text(finding.detail).font(.caption2)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        } header: {
            Text("Garden Walk")
        } footer: {
            Text("Ivy watches a live glasses feed or your upload, then speaks an overview — including mistakes you did not ask about.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var gallerySection: some View {
        Section {
            if garden.plants.isEmpty {
                Text("No plants yet. Identify from a photo or glasses to build Ivy’s library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(garden.plants) { plant in
                        Button {
                            editing = plant
                        } label: {
                            PlantThumbnail(url: garden.imageURL(for: plant), title: plant.name)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit") { editing = plant }
                            Button("Log watering") {
                                Task { await garden.logWatering(plant) }
                            }
                            Button("Delete", role: .destructive) {
                                Task { await garden.delete(plant) }
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
        } header: {
            Text("Library · \(garden.plantCount)")
        } footer: {
            Text("Long-press a plant to water, edit, or delete. Mark outdoor / frost-sensitive for Planning.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var identifySection: some View {
        Section {
            PhotosPicker(selection: $identifyPickerItem, matching: .images) {
                Label(
                    garden.isBusy ? "Identifying…" : "Upload plant photo",
                    systemImage: "photo.on.rectangle"
                )
            }
            .disabled(garden.isBusy)

            Button {
                Task { await garden.identifyWithGlasses(save: true) }
            } label: {
                Label(
                    garden.isBusy ? "Capturing…" : "Identify with glasses",
                    systemImage: "eyeglasses"
                )
            }
            .disabled(garden.isBusy)

            if let result = garden.lastIdentify, !result.plants.isEmpty {
                ForEach(result.plants) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.name).font(.subheadline.weight(.semibold))
                        if let species = hit.species, !species.isEmpty {
                            Text(species).font(.caption).foregroundStyle(.secondary)
                        }
                        if !hit.careTips.isEmpty {
                            Text(hit.careTips).font(.caption)
                        }
                        if let health = hit.health {
                            Text("Health: \(health)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Identify")
        } footer: {
            Text("Photos and glasses stills are matched against your garden library when possible.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var planningSection: some View {
        Section {
            TextField("Climate city", text: $garden.climateCityDraft, prompt: Text("e.g. Austin, TX"))
                .textInputAutocapitalization(.words)
            Button {
                Task { await garden.saveClimateCity() }
            } label: {
                Label(garden.isBusy ? "Refreshing…" : "Save city & refresh frost dates", systemImage: "cloud.sun")
            }
            .disabled(garden.isBusy || garden.climateCityDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let climate = garden.climate {
                Text(climate.summary.isEmpty ? climate.city : "\(climate.city) — \(climate.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Climate")
        } footer: {
            Text("Frost windows use a prior-year Open-Meteo sample for your city.")
                .font(.caption2)
        }

        ForEach(GardenSeason.allCases) { season in
            let rows = garden.planItems(for: season)
            Section {
                if rows.isEmpty {
                    Text("No suggestions for \(season.title.lowercased()) yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { item in
                        HStack(alignment: .top, spacing: 10) {
                            if item.plantId != nil {
                                PlantThumbnail(
                                    url: garden.imageURL(forPlantId: item.plantId),
                                    title: "",
                                    compact: true
                                )
                                .frame(width: 52)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.windowLabel)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tint)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(kindLabel(item.kind))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(season.title)
            }
        }
    }

    private func kindLabel(_ kind: GardenPlanKind) -> String {
        switch kind {
        case .plantNew: return "Plant new"
        case .bringInside: return "Bring inside"
        case .maintenance: return "Maintenance"
        }
    }

    private func loadWalkFrames(from item: PhotosPickerItem) async -> [Data]? {
        if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
            // Heuristic: smallish payloads are stills; large may still be images.
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) == false {
                return [data]
            }
        }
        #if canImport(AVFoundation) && canImport(UIKit)
        if let movie = try? await item.loadTransferable(type: WalkMovieTransfer.self) {
            return await extractKeyFrames(from: movie.url, count: 3)
        }
        #endif
        if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
            return [data]
        }
        return nil
    }

    #if canImport(AVFoundation) && canImport(UIKit)
    private func extractKeyFrames(from url: URL, count: Int) async -> [Data] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let duration: Double
        do {
            let cm = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cm)
        } catch {
            return []
        }
        guard duration.isFinite, duration > 0 else { return [] }
        var frames: [Data] = []
        let steps = max(count, 1)
        for i in 0..<steps {
            let t = duration * (Double(i) + 0.5) / Double(steps)
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                let image = UIImage(cgImage: cg)
                if let data = image.jpegData(compressionQuality: 0.7) {
                    frames.append(data)
                }
            }
        }
        return frames
    }
    #endif
}

#if canImport(AVFoundation)
private struct WalkMovieTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nova-garden-walk-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: received.file, to: temp)
            return WalkMovieTransfer(url: temp)
        }
    }
}
#endif

private struct PlantThumbnail: View {
    let url: URL?
    let title: String
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                #if canImport(UIKit)
                if let url, let data = try? Data(contentsOf: url), let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            minHeight: compact ? 52 : 88,
                            maxHeight: compact ? 52 : 88
                        )
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
                } else {
                    Image(systemName: "camera.macro")
                        .foregroundStyle(.secondary)
                }
                #else
                Image(systemName: "camera.macro")
                    .foregroundStyle(.secondary)
                #endif
            }
            .frame(height: compact ? 52 : 88)
            if !title.isEmpty {
                Text(title)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct PlantEditorSheet: View {
    let plant: PlantSighting
    let onSave: (String, String, String, String, Bool, Bool) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var species: String
    @State private var location: String
    @State private var careNotes: String
    @State private var isOutdoor: Bool
    @State private var frostSensitive: Bool

    init(
        plant: PlantSighting,
        onSave: @escaping (String, String, String, String, Bool, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.plant = plant
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: plant.name)
        _species = State(initialValue: plant.species ?? "")
        _location = State(initialValue: plant.location ?? "")
        _careNotes = State(initialValue: plant.careNotes)
        _isOutdoor = State(initialValue: plant.isOutdoor ?? GardenPlanningDiff.isLikelyOutdoor(plant))
        _frostSensitive = State(initialValue: plant.frostSensitive ?? GardenPlanningDiff.isFrostSensitive(plant))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Species", text: $species)
                TextField("Location", text: $location)
                TextField("Care notes", text: $careNotes, axis: .vertical)
                    .lineLimit(3...8)
                Toggle("Outdoor plant", isOn: $isOutdoor)
                Toggle("Bring inside before frost", isOn: $frostSensitive)
            }
            .navigationTitle("Edit plant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, species, location, careNotes, isOutdoor, frostSensitive)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

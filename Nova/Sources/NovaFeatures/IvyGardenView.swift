import SwiftUI
import NovaDomain
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Ivy's garden workspace: gallery, identify, Garden Walk, and seasonal planning.
public struct IvyGardenView: View {
    @Bindable var garden: IvyGardenViewModel
    @Bindable var conversation: ConversationViewModel
    var embedded: Bool = false
    @State private var identifyPickerItem: PhotosPickerItem?
    @State private var galleryPickerItems: [PhotosPickerItem] = []
    @State private var walkPickerItems: [PhotosPickerItem] = []
    @State private var confirmClear = false
    @State private var editing: PlantSighting?
    @State private var isGalleryEditing = false

    public init(garden: IvyGardenViewModel, conversation: ConversationViewModel, embedded: Bool = false) {
        self.garden = garden
        self.conversation = conversation
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
            Section {
                NovaUI.AgentVoiceChatBar(conversation: conversation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }

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
            if garden.section == .gallery {
                ToolbarItem(placement: .topBarTrailing) {
                    if !garden.plants.isEmpty {
                        Button(isGalleryEditing ? "Done" : "Edit") {
                            isGalleryEditing.toggle()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !garden.plants.isEmpty {
                        Button("Clear", role: .destructive) { confirmClear = true }
                    }
                }
            }
        }
        .onChange(of: garden.section) { _, section in
            if section != .gallery { isGalleryEditing = false }
        }
        .confirmationDialog("Clear plant library?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all plants", role: .destructive) {
                Task { await garden.clearLibrary() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editing) { plant in
            PlantEditorSheet(plant: plant) { name, species, location, notes, outdoor, frost, actions, seasonal, health in
                Task {
                    await garden.updateNotes(
                        plant,
                        name: name,
                        species: species,
                        location: location,
                        careNotes: notes,
                        isOutdoor: outdoor,
                        frostSensitive: frost,
                        suggestedActions: actions,
                        seasonalNotes: seasonal,
                        healthStatus: health
                    )
                    editing = nil
                }
            } onDelete: {
                Task {
                    await garden.delete(plant)
                    editing = nil
                }
            } onCancel: {
                editing = nil
            }
        }
        .onChange(of: identifyPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let frames = await loadMediaFrames(from: item), !frames.isEmpty {
                    if frames.count > 1 {
                        // Multi-frame (video): catalog + consensus instead of one middle still.
                        await garden.catalogFrames(frames, speak: false)
                    } else {
                        await garden.identify(imageData: frames[0], save: true)
                    }
                } else {
                    garden.notePhotoLoadFailed()
                }
                identifyPickerItem = nil
            }
        }
        .onChange(of: galleryPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var datas: [Data] = []
                for item in items.prefix(12) {
                    if datas.count >= 12 { break }
                    if let framesFromItem = await loadMediaFrames(from: item) {
                        let remaining = 12 - datas.count
                        datas.append(contentsOf: framesFromItem.prefix(remaining))
                    }
                }
                if datas.isEmpty {
                    garden.notePhotoLoadFailed()
                } else {
                    // Catalog merges frames and filters weak IDs — avoids one bed becoming
                    // Zinnia / Coleus / Celosia / Rose Mallow as separate gallery rows.
                    await garden.catalogFrames(datas, speak: false)
                }
                galleryPickerItems = []
            }
        }
        .onChange(of: walkPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var frames: [Data] = []
                for item in items.prefix(12) {
                    if frames.count >= 12 { break }
                    if let framesFromItem = await loadMediaFrames(from: item) {
                        let remaining = 12 - frames.count
                        frames.append(contentsOf: framesFromItem.prefix(remaining))
                    }
                }
                if frames.isEmpty {
                    garden.notePhotoLoadFailed()
                } else {
                    await garden.catalogFrames(frames, speak: true)
                }
                walkPickerItems = []
            }
        }
    }

    @ViewBuilder
    private var gardenWalkSection: some View {
        Section {
            if garden.isWalking {
                Button(role: .destructive) {
                    Task { await garden.stopGardenWalk() }
                } label: {
                    Label("Stop Garden Walk", systemImage: "stop.circle.fill")
                }
            } else {
                Button {
                    Task { await garden.startGardenWalkWithGlasses(speak: true) }
                } label: {
                    Label("Garden Walk (glasses)", systemImage: "figure.walk")
                }
                .disabled(garden.isBusy || garden.isCataloging)
            }

            PhotosPicker(
                selection: $walkPickerItems,
                maxSelectionCount: 12,
                matching: .any(of: [.images, .videos])
            ) {
                Label(
                    garden.isCataloging
                        ? "Cataloging plants…"
                        : "Catalog plants from photos or video",
                    systemImage: "photo.on.rectangle.angled"
                )
            }
            .disabled(garden.isBusy || garden.isWalking || garden.isCataloging)

            if let catalog = garden.lastCatalog {
                catalogOverviewBlock(catalog)
            } else if let walk = garden.lastWalk {
                walkOverviewBlock(walk, shareText: walk.shareText)
            }
        } header: {
            Text("Garden Overview")
        } footer: {
            Text("Upload a garden video (or photos) to identify and catalog every plant with care actions and seasonal tips. Glasses Walk is a quicker coaching look — tap Stop Garden Walk to cancel mid-capture or analysis. Press and hold the overview to share or save it to Library.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func catalogOverviewBlock(_ catalog: GardenCatalogResult) -> some View {
        let walk = catalog.overview
        VStack(alignment: .leading, spacing: 8) {
            walkOverviewContent(walk)
            if !catalog.profiles.isEmpty {
                Text("Cataloged plants · \(catalog.profiles.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                ForEach(catalog.profiles) { profile in
                    Button {
                        if let id = profile.savedPlantId ?? profile.matchedPlantId,
                           let plant = garden.plants.first(where: { $0.id == id }) {
                            editing = plant
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(profile.name)
                                    .font(.caption.weight(.semibold))
                                if let health = profile.health, !health.isEmpty {
                                    Text(health)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let species = profile.species, !species.isEmpty {
                                Text(species)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let action = profile.suggestedActions.first {
                                Text("→ \(action)")
                                    .font(.caption2)
                            }
                            if !profile.seasonalNotes.isEmpty {
                                Text(profile.seasonalNotes)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .textSelection(.enabled)
        .contextMenu {
            ShareLink(item: catalog.shareText) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button {
                Task { await garden.saveLastWalkToLibrary() }
            } label: {
                Label("Save to Library", systemImage: "books.vertical")
            }
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = catalog.shareText
                #endif
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private func walkOverviewBlock(_ walk: GardenWalkResult, shareText: String) -> some View {
        walkOverviewContent(walk)
            .textSelection(.enabled)
            .contextMenu {
                ShareLink(item: shareText) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task { await garden.saveLastWalkToLibrary() }
                } label: {
                    Label("Save to Library", systemImage: "books.vertical")
                }
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = shareText
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
    }

    @ViewBuilder
    private func walkOverviewContent(_ walk: GardenWalkResult) -> some View {
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
                Text("Watch-outs")
                    .font(.caption2.weight(.semibold))
                    .padding(.top, 2)
                ForEach(walk.mistakes, id: \.self) { item in
                    Text("• \(item)").font(.caption2)
                }
            }
            if !walk.maintenance.isEmpty {
                Text("Priority actions")
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

    @ViewBuilder
    private var gallerySection: some View {
        Section {
            PhotosPicker(
                selection: $galleryPickerItems,
                maxSelectionCount: 12,
                matching: .any(of: [.images, .videos])
            ) {
                Label(
                    garden.isBusy ? "Adding…" : "Add photos or video to gallery",
                    systemImage: "plus.circle"
                )
            }
            .disabled(garden.isBusy)

            if garden.plants.isEmpty {
                Text("No plants yet. Add photos or a video here, or catalog from Garden Overview / Media → Send to Ivy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(garden.plants) { plant in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                if isGalleryEditing {
                                    Task { await garden.delete(plant) }
                                } else {
                                    editing = plant
                                }
                            } label: {
                                PlantThumbnail(
                                    url: garden.imageURL(for: plant),
                                    title: plant.name,
                                    lifeCycle: plant.lifeCycle
                                )
                            }
                            .buttonStyle(.plain)

                            if isGalleryEditing {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .red)
                                    .padding(4)
                                    .accessibilityLabel("Remove \(plant.name)")
                            }
                        }
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
            Text(galleryHeader)
        } footer: {
            Text(isGalleryEditing
                 ? "Tap a plant to remove it. Tap Done when finished."
                 : "Add photos or a video to build Ivy’s library. Plants are tagged Annual or Perennial for your active hardiness zone. Tap a plant to edit; long-press to water or delete.")
                .font(.caption2)
        }
    }

    private var galleryHeader: String {
        var title = "Gallery · \(garden.plantCount)"
        if let zone = garden.activeHardinessZone {
            title += " · Zone \(zone)"
        }
        return title
    }

    @ViewBuilder
    private var identifySection: some View {
        Section {
            PhotosPicker(
                selection: $identifyPickerItem,
                matching: .any(of: [.images, .videos])
            ) {
                Label(
                    garden.isBusy ? "Identifying…" : "Upload plant photo or video",
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
            Text("Photos, videos (sampled as keyframes), and glasses stills are matched against your garden library when possible.")
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

            Stepper(
                "USDA zone \(garden.hardinessZoneDraft)",
                value: $garden.hardinessZoneDraft,
                in: 1...13
            )
            Button {
                Task { await garden.saveHardinessZone() }
            } label: {
                Label("Save zone & retag gallery", systemImage: "leaf")
            }
            .disabled(garden.isBusy)
        } header: {
            Text("Climate & zone")
        } footer: {
            Text("Frost windows use a prior-year Open-Meteo sample. Saving a city also estimates USDA zone; Annual/Perennial tags follow the active zone.")
                .font(.caption2)
        }

        Section {
            if garden.plantRecommendations.isEmpty {
                Text("No planting picks for this season yet. Save a climate city or USDA zone and pull to refresh Planning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(garden.plantRecommendations) { rec in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(rec.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(rec.method.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        HStack(spacing: 8) {
                            Text(rec.lifeCycle.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(rec.windowLabel)
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        Text(rec.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if rec.alreadyInLibrary {
                            Text("Already in your gallery — consider succession or a second variety.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text(recommendationHeader)
        } footer: {
            Text("Picks matched to \(GardenSeason.current().title.lowercased()) planting windows and your active zone. Prefer seed, transplant, bulb, or indoor starts as labeled.")
                .font(.caption2)
        }

        Section {
            if garden.suggestedTips.isEmpty {
                Text("No tips yet — finish a Garden Walk or catalog and Ivy will compile top action items here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(garden.suggestedTips) { tip in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tip.priority.title.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(tipPriorityColor(tip.priority))
                            Spacer()
                            Text(tipDateLabel(tip.date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(tip.title)
                            .font(.subheadline.weight(.semibold))
                        if let plant = tip.plantName, !plant.isEmpty {
                            Text(plant)
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        if !tip.detail.isEmpty {
                            Text(tip.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Suggested Tips")
        } footer: {
            Text("Condensed from garden walks — urgent first, then by date.")
                .font(.caption2)
        }

        Section {
            if garden.savedWalks.isEmpty {
                Text("Garden walk summaries will appear here after Walk or Catalog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(garden.savedWalks) { walk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tipDateLabel(walk.walkedAt))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                            if let health = walk.healthScore, !health.isEmpty {
                                Text("· \(health)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(walk.planningPreview)
                            .font(.caption)
                            .foregroundStyle(.primary)
                        if !walk.maintenance.isEmpty {
                            Text(walk.maintenance.prefix(3).map { "• \($0)" }.joined(separator: "\n"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Garden walk summaries")
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

    private var recommendationHeader: String {
        var title = "New plant recommendations"
        if let zone = garden.activeHardinessZone {
            title += " · Zone \(zone)"
        }
        title += " · \(GardenSeason.current().title)"
        return title
    }

    private func tipPriorityColor(_ priority: GardenTipPriority) -> Color {
        switch priority {
        case .urgent: return .red
        case .high: return .orange
        case .normal: return .secondary
        }
    }

    private func tipDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func kindLabel(_ kind: GardenPlanKind) -> String {
        switch kind {
        case .plantNew: return "Plant new"
        case .bringInside: return "Bring inside"
        case .maintenance: return "Maintenance"
        }
    }

    /// Load a still as JPEG. `Data` transferable often fails for HEIC in Photos.
    private func loadPhotoJPEG(from item: PhotosPickerItem) async -> Data? {
        #if canImport(UIKit)
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data),
           let jpeg = image.jpegData(compressionQuality: 0.82)
        {
            return jpeg
        }
        if let data = try? await item.loadTransferable(type: GardenImageTransfer.self) {
            return data.jpeg
        }
        #else
        if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
            return data
        }
        #endif
        return nil
    }

    /// Load a still as one JPEG, or sample keyframes from a movie.
    private func loadMediaFrames(from item: PhotosPickerItem) async -> [Data]? {
        let isMovie = item.supportedContentTypes.contains(where: {
            $0.conforms(to: .movie) || $0.conforms(to: .video) || $0.conforms(to: .mpeg4Movie) || $0.conforms(to: .quickTimeMovie)
        })
        if !isMovie, let jpeg = await loadPhotoJPEG(from: item) {
            return [jpeg]
        }
        if let movie = try? await item.loadTransferable(type: GardenMovieTransfer.self) {
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let frames = await VideoKeyframeSampler.jpegKeyFramesAdaptive(from: movie.url, catalog: true)
            return frames.isEmpty ? nil : frames
        }
        if let jpeg = await loadPhotoJPEG(from: item) {
            return [jpeg]
        }
        return nil
    }
}

#if canImport(UIKit)
private struct GardenImageTransfer: Transferable {
    let jpeg: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.82)
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return GardenImageTransfer(jpeg: jpeg)
        }
    }
}
#endif

private struct GardenMovieTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try Self.importMovie(from: received.file)
        }
        FileRepresentation(contentType: .mpeg4Movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try Self.importMovie(from: received.file)
        }
        FileRepresentation(contentType: .quickTimeMovie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try Self.importMovie(from: received.file)
        }
    }

    private static func importMovie(from file: URL) throws -> GardenMovieTransfer {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-garden-media-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.copyItem(at: file, to: temp)
        return GardenMovieTransfer(url: temp)
    }
}

private struct PlantThumbnail: View {
    let url: URL?
    let title: String
    var compact: Bool = false
    var lifeCycle: PlantLifeCycle? = nil

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomLeading) {
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
                if !compact, let lifeCycle {
                    Text(lifeCycle.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
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
    let onSave: (String, String, String, String, Bool, Bool, [String], String, String?) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var species: String
    @State private var location: String
    @State private var careNotes: String
    @State private var isOutdoor: Bool
    @State private var frostSensitive: Bool
    @State private var suggestedActionsText: String
    @State private var seasonalNotes: String
    @State private var healthStatus: String
    @State private var confirmDelete = false

    init(
        plant: PlantSighting,
        onSave: @escaping (String, String, String, String, Bool, Bool, [String], String, String?) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.plant = plant
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: plant.name)
        _species = State(initialValue: plant.species ?? "")
        _location = State(initialValue: plant.location ?? "")
        _careNotes = State(initialValue: plant.careNotes)
        _isOutdoor = State(initialValue: plant.isOutdoor ?? GardenPlanningDiff.isLikelyOutdoor(plant))
        _frostSensitive = State(initialValue: plant.frostSensitive ?? GardenPlanningDiff.isFrostSensitive(plant))
        _suggestedActionsText = State(initialValue: plant.suggestedActions.joined(separator: "\n"))
        _seasonalNotes = State(initialValue: plant.seasonalNotes)
        _healthStatus = State(initialValue: plant.healthStatus ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Species", text: $species)
                TextField("Location", text: $location)
                TextField("Health", text: $healthStatus, prompt: Text("ok / needs_water / stressed"))
                TextField("Care notes", text: $careNotes, axis: .vertical)
                    .lineLimit(3...8)
                TextField("Suggested actions (one per line)", text: $suggestedActionsText, axis: .vertical)
                    .lineLimit(3...8)
                TextField("Seasonal notes", text: $seasonalNotes, axis: .vertical)
                    .lineLimit(3...8)
                Toggle("Outdoor plant", isOn: $isOutdoor)
                Toggle("Bring inside before frost", isOn: $frostSensitive)
                if let life = plant.lifeCycle {
                    LabeledContent("For active zone", value: life.title)
                }

                Section {
                    Button("Delete from gallery", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
            .navigationTitle("Edit plant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let actions = suggestedActionsText
                            .split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        let health = healthStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(
                            name,
                            species,
                            location,
                            careNotes,
                            isOutdoor,
                            frostSensitive,
                            actions,
                            seasonalNotes,
                            health.isEmpty ? nil : health
                        )
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Remove this plant from the gallery?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

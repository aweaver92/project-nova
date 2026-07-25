import SwiftUI
import NovaDomain
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

/// Sage-exclusive task manager. Soft sage-green wash with pickup tasks
/// grouped by agent so the user can resume unfinished work through the day.
public struct SageTasksView: View {
    @Bindable var tasks: SageTasksViewModel
    @Bindable var conversation: ConversationViewModel
    var realtimeMintBlocked: Bool = false
    var onOpenSettings: (() -> Void)? = nil
    var embedded: Bool = false

    #if canImport(UIKit)
    @State private var draftPhotoItems: [PhotosPickerItem] = []
    @State private var attachTarget: AgentTask?
    @State private var attachPhotoItems: [PhotosPickerItem] = []
    #endif

    private static let sage = Color(red: 0.35, green: 0.55, blue: 0.45)
    private static let sageSoft = Color(red: 0.35, green: 0.55, blue: 0.45).opacity(0.12)

    public init(
        tasks: SageTasksViewModel,
        conversation: ConversationViewModel,
        realtimeMintBlocked: Bool = false,
        onOpenSettings: (() -> Void)? = nil,
        embedded: Bool = false
    ) {
        self.tasks = tasks
        self.conversation = conversation
        self.realtimeMintBlocked = realtimeMintBlocked
        self.onOpenSettings = onOpenSettings
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 20) {
                NovaUI.AgentVoiceChatBar(
                    conversation: conversation,
                    realtimeMintBlocked: realtimeMintBlocked,
                    onOpenSettings: onOpenSettings
                )
                header
                addTaskCard
                if tasks.openTasks.isEmpty {
                    emptyState
                } else {
                    ForEach(tasks.groupedOpen, id: \.agent) { group in
                        agentSection(name: group.agent, items: group.tasks)
                    }
                }
                if !tasks.recentDone.isEmpty {
                    doneSection
                }
                if !tasks.statusMessage.isEmpty {
                    Text(tasks.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(Self.sage)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Self.sageSoft.ignoresSafeArea())
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Self.sage)
        .task { await tasks.load() }
        .onAppear { tasks.setScreenVisible(true) }
        .onDisappear { tasks.setScreenVisible(false) }
        #if canImport(UIKit)
        .onChange(of: draftPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await ingestDraftPhotos(items) }
        }
        .sheet(item: $attachTarget) { task in
            NavigationStack {
                VStack(spacing: 16) {
                    Text("Attach photos to “\(task.title)”")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.top)
                    PhotosPicker(
                        selection: $attachPhotoItems,
                        maxSelectionCount: max(1, SageTasksViewModel.maxImagesPerTask - task.imageFileNames.count),
                        matching: .images
                    ) {
                        Label("Choose photos", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    Spacer()
                }
                .navigationTitle("Attach")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            attachTarget = nil
                            attachPhotoItems = []
                        }
                    }
                }
                .onChange(of: attachPhotoItems) { _, items in
                    guard !items.isEmpty else { return }
                    Task {
                        await ingestAttachPhotos(items, to: task)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        #endif
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(greeting)
                .font(.system(.title2, design: .serif).weight(.medium))
            Text(tasks.resumeSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Morning pickup."
        case 12..<17: return "Afternoon check-in."
        case 17..<22: return "Evening wrap-up."
        default: return "Where did we leave off?"
        }
    }

    private var addTaskCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick add")
                .font(.system(.headline, design: .serif))
            TextField("What needs finishing?", text: $tasks.draftTitle)
                .padding(10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
            TextField("Optional detail", text: $tasks.draftDetail, axis: .vertical)
                .lineLimit(2...3)
                .padding(10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
            Picker("Agent", selection: $tasks.draftAgent) {
                ForEach(tasks.agentChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)

            #if canImport(UIKit)
            PhotosPicker(
                selection: $draftPhotoItems,
                maxSelectionCount: max(1, SageTasksViewModel.maxImagesPerTask - tasks.draftImageData.count),
                matching: .images
            ) {
                Label(
                    tasks.draftImageData.isEmpty
                        ? "Add photos"
                        : "Add more photos (\(tasks.draftImageData.count)/\(SageTasksViewModel.maxImagesPerTask))",
                    systemImage: "photo.on.rectangle.angled"
                )
            }
            .disabled(tasks.draftImageData.count >= SageTasksViewModel.maxImagesPerTask)

            if !tasks.draftImageData.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(tasks.draftImageData.enumerated()), id: \.offset) { index, data in
                            ZStack(alignment: .topTrailing) {
                                if let ui = UIImage(data: data) {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                Button {
                                    tasks.removeDraftImage(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
            }
            #endif

            Button {
                Task { await tasks.addDraftTask() }
            } label: {
                Text("Add task")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tasks.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing open")
                .font(.system(.headline, design: .serif))
            Text("Ask Sage to review recent agent activity, or add a pickup above. Attach photos when a task needs a visual reminder.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func agentSection(name: String, items: [AgentTask]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: Self.icon(for: name))
                    .foregroundStyle(Self.sage)
                Text(name)
                    .font(.system(.headline, design: .serif))
                Spacer()
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { task in
                taskRow(task)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func taskRow(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    Task { await tasks.cycleStatus(task) }
                } label: {
                    statusBadge(task.status)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                    if let detail = task.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let summary = task.activitySummary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(Self.dateLabel(task.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                #if canImport(UIKit)
                if task.imageFileNames.count < SageTasksViewModel.maxImagesPerTask {
                    Button {
                        attachTarget = task
                        attachPhotoItems = []
                    } label: {
                        Image(systemName: "photo.badge.plus")
                            .font(.title3)
                            .foregroundStyle(Self.sage.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach photos")
                }
                #endif
                Button {
                    Task { await tasks.markDone(task) }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                        .foregroundStyle(Self.sage)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark done")
            }

            if !task.imageFileNames.isEmpty {
                TaskImageStrip(fileNames: task.imageFileNames, tasks: tasks) { fileName in
                    Task { await tasks.removeImage(from: task, fileName: fileName) }
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Mark in progress") {
                Task { await tasks.setStatus(task, status: .inProgress) }
            }
            Button("Mark incomplete") {
                Task { await tasks.setStatus(task, status: .incomplete) }
            }
            Button("Mark done") {
                Task { await tasks.markDone(task) }
            }
            #if canImport(UIKit)
            Button {
                attachTarget = task
                attachPhotoItems = []
            } label: {
                Label("Attach photos…", systemImage: "photo.badge.plus")
            }
            #endif
            Button("Delete", role: .destructive) {
                Task { await tasks.delete(task) }
            }
        }
    }

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently done")
                .font(.system(.headline, design: .serif))
            ForEach(tasks.recentDone) { task in
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Self.sage.opacity(0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.subheadline)
                        Text("\(task.agentName) · \(Self.dateLabel(task.updatedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func statusBadge(_ status: AgentTaskStatus) -> some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Self.sage.opacity(0.15), in: Capsule())
            .foregroundStyle(Self.sage)
    }

    #if canImport(UIKit)
    private func ingestDraftPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = SageTasksViewModel.jpegAttachment(from: data)
            else { continue }
            tasks.addDraftImage(jpeg)
        }
        draftPhotoItems = []
    }

    private func ingestAttachPhotos(_ items: [PhotosPickerItem], to task: AgentTask) async {
        var jpegs: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = SageTasksViewModel.jpegAttachment(from: data)
            else { continue }
            jpegs.append(jpeg)
        }
        await tasks.attachImages(to: task, jpegData: jpegs)
        attachPhotoItems = []
        attachTarget = nil
    }
    #endif

    private static func icon(for agent: String) -> String {
        switch agent.lowercased() {
        case "claude": return "chevron.left.forwardslash.chevron.right"
        case "max": return "figure.strengthtraining.traditional"
        case "remy": return "fork.knife"
        case "scholar": return "book"
        case "ivy": return "leaf"
        case "sage": return "checklist"
        default: return "sparkles"
        }
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Horizontal thumbnails for persisted task images.
private struct TaskImageStrip: View {
    let fileNames: [String]
    let tasks: SageTasksViewModel
    let onRemove: (String) -> Void
    @State private var urls: [String: URL] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(fileNames, id: \.self) { name in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            #if canImport(UIKit)
                            if let url = urls[name],
                               let data = try? Data(contentsOf: url),
                               let ui = UIImage(data: data)
                            {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.15))
                                    .overlay { ProgressView().scaleEffect(0.7) }
                            }
                            #else
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.15))
                            #endif
                        }
                        .frame(width: 56, height: 56)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            onRemove(name)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
        }
        .task(id: fileNames.joined(separator: ",")) {
            var next: [String: URL] = [:]
            for name in fileNames {
                if let url = await tasks.imageURL(for: name) {
                    next[name] = url
                }
            }
            urls = next
        }
    }
}

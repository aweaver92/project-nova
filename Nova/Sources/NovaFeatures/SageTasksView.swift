import SwiftUI
import NovaDomain

/// Sage-exclusive task manager. Soft sage-green wash with pickup tasks
/// grouped by agent so the user can resume unfinished work through the day.
public struct SageTasksView: View {
    @Bindable var tasks: SageTasksViewModel
    var embedded: Bool = false

    private static let sage = Color(red: 0.35, green: 0.55, blue: 0.45)
    private static let sageSoft = Color(red: 0.35, green: 0.55, blue: 0.45).opacity(0.12)

    public init(tasks: SageTasksViewModel, embedded: Bool = false) {
        self.tasks = tasks
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
        .padding(.top, 8)
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
            Text("Ask Sage to review recent agent activity, or add a pickup above. Suggested tasks appear here when work looks unfinished.")
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
                    Text(task.agentName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.sage)
                        .frame(width: 64, alignment: .leading)
                    Text(task.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            .foregroundStyle(Self.sage)
            .background(Self.sage.opacity(0.15), in: Capsule())
    }

    private static func icon(for agent: String) -> String {
        switch agent.lowercased() {
        case "claude": return "chevron.left.forwardslash.chevron.right"
        case "max": return "figure.strengthtraining.traditional"
        case "remy": return "fork.knife"
        case "scholar": return "text.book.closed"
        case "sage": return "checklist"
        default: return "sparkles"
        }
    }

    private static func dateLabel(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }
}

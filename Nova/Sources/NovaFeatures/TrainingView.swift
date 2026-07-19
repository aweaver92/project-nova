import SwiftUI
import NovaDomain

/// Max-exclusive training hub + live workout HUD. High-energy "gym HUD" look:
/// dark gradient hero, big numerals, rest ring — intentionally bolder than the
/// calmer specialist screens.
public struct TrainingView: View {
    @Bindable var training: TrainingViewModel
    var embedded: Bool = false
    @State private var editingPlan: WorkoutPlan?
    @State private var showNewPlan = false
    @State private var planPendingDelete: WorkoutPlan?

    private static let heat = LinearGradient(
        colors: [Color(red: 0.85, green: 0.15, blue: 0.10), Color(red: 0.95, green: 0.45, blue: 0.10)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public init(training: TrainingViewModel, embedded: Bool = false) {
        self.training = training
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
            VStack(spacing: 14) {
                if training.hasActiveSession {
                    liveHero
                    restCard
                    logCard
                    loggedSetsCard
                    endButton
                } else {
                    hubHero
                    plansCarousel
                    prStrip
                    historyCard
                }
                if !training.statusMessage.isEmpty {
                    Text(training.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(training.hasActiveSession ? "Live workout" : "Training")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.orange)
        .toolbar {
            if !training.hasActiveSession {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewPlan = true
                    } label: {
                        Label("New routine", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $editingPlan) { plan in
            WorkoutPlanEditorSheet(plan: plan) { saved in
                Task { await training.savePlan(saved) }
            }
        }
        .sheet(isPresented: $showNewPlan) {
            WorkoutPlanEditorSheet(plan: WorkoutPlan(name: "", exercises: [PlannedExercise(name: "")])) { saved in
                Task { await training.savePlan(saved) }
            }
        }
        .alert(
            "Delete routine?",
            isPresented: Binding(
                get: { planPendingDelete != nil },
                set: { if !$0 { planPendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let plan = planPendingDelete {
                    Task { await training.deletePlan(plan) }
                }
                planPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                planPendingDelete = nil
            }
        } message: {
            Text(planPendingDelete.map { "Remove \"\($0.name)\" from your saved routines." }
                 ?? "Remove this routine.")
        }
        .task {
            await training.load()
        }
    }

    // MARK: - Live HUD

    private var liveHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(training.activeSession?.title ?? "Workout", systemImage: "flame.fill")
                    .font(.subheadline.weight(.bold))
                    .textCase(.uppercase)
                Spacer()
                Text(training.elapsedLabel)
                    .font(.title3.monospacedDigit().weight(.bold))
            }
            .foregroundStyle(.white.opacity(0.9))

            if let current = training.progress.current {
                Text(current.name)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                setDots(
                    completed: training.progress.completedSetsForCurrent,
                    target: training.progress.targetSetsForCurrent ?? 1
                )
                Text(targetLine(for: current))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            } else if let last = training.activeSession?.sets.last {
                Text(last.exercise)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("Freeform · \(training.activeSession?.sets.count ?? 0) sets logged")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text("Ready for\nfirst set")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }

            if let next = training.progress.next {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Next: \(next.name)")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Self.heat, in: RoundedRectangle(cornerRadius: 20))
    }

    private func setDots(completed: Int, target: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<max(1, target), id: \.self) { idx in
                Circle()
                    .fill(idx < completed ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 10, height: 10)
            }
            Text("SET \(min(completed + 1, target))/\(target)")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.leading, 4)
        }
    }

    private var restCard: some View {
        VStack(spacing: 10) {
            if training.restRemainingSeconds > 0 {
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: restFraction)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: training.restRemainingSeconds)
                    VStack(spacing: 0) {
                        Text("\(training.restRemainingSeconds)")
                            .font(.system(size: 44, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("REST")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, height: 140)
                HStack(spacing: 12) {
                    Button {
                        Task { await training.skipRest() }
                    } label: {
                        Text("Skip")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task { await training.addRest() }
                    } label: {
                        Text("+30s")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    Task { await training.startRest() }
                } label: {
                    Label(
                        "Start rest · \(training.progress.current?.restSeconds ?? 90)s",
                        systemImage: "timer"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var restFraction: CGFloat {
        let total = max(1, training.primaryRestTimer?.seconds ?? 90)
        return CGFloat(training.restRemainingSeconds) / CGFloat(total)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOG SET")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            TextField("Exercise", text: $training.logExercise)
                .font(.headline)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                counterBox(label: "REPS", value: "\(training.logReps)") { delta in
                    training.logReps = min(50, max(1, training.logReps + delta))
                }
                counterBox(label: "LB", value: "\(Int(training.logWeight))") { delta in
                    training.logWeight = min(1000, max(0, training.logWeight + Double(delta * 5)))
                }
            }
            Button {
                Task { await training.logSet() }
            } label: {
                Label("Log set", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(training.logExercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func counterBox(label: String, value: String, adjust: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 10) {
                Button { adjust(-1) } label: {
                    Image(systemName: "minus.circle.fill").font(.title2)
                }
                Button { adjust(1) } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var loggedSetsCard: some View {
        let logged = training.setsForCurrentExercise()
        if !logged.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("THIS EXERCISE")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                ForEach(Array(logged.enumerated()), id: \.element.id) { idx, set in
                    HStack {
                        Text("\(idx + 1)")
                            .font(.caption.weight(.heavy))
                            .frame(width: 22, height: 22)
                            .background(Color.orange.opacity(0.15), in: Circle())
                            .foregroundStyle(.orange)
                        Text(setLine(set))
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var endButton: some View {
        Button(role: .destructive) {
            Task { await training.endSession() }
        } label: {
            Label("End workout", systemImage: "flag.checkered")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Hub

    private var hubHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("MAX", systemImage: "figure.strengthtraining.traditional")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white.opacity(0.8))
            Text("Time to train.")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(training.history.isEmpty
                 ? "First session — pick a plan or go freeform."
                 : "\(training.history.filter { !$0.isActive }.count) workouts logged. Keep the streak.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Button {
                Task { await training.startEmptySession() }
            } label: {
                Label("Start freeform workout", systemImage: "bolt.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(Color(red: 0.85, green: 0.2, blue: 0.1))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Self.heat, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var plansCarousel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ROUTINES")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showNewPlan = true
                } label: {
                    Label("New", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
            if training.plans.isEmpty {
                Text("No saved routines yet — tap New to build one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(training.plans) { plan in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(plan.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("\(plan.exercises.count) exercises")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                HStack(spacing: 8) {
                                    Button("Start") {
                                        Task { await training.startFromPlan(plan) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    Button("Edit") {
                                        editingPlan = plan
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(12)
                            .frame(width: 168, height: 132, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            .contextMenu {
                                Button {
                                    editingPlan = plan
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    planPendingDelete = plan
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var prStrip: some View {
        if !training.personalRecords.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("PERSONAL RECORDS")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(training.personalRecords) { pr in
                            HStack(spacing: 6) {
                                Image(systemName: "trophy.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(pr.exercise)
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(1)
                                    Text("\(Int(pr.weight)) lb")
                                        .font(.subheadline.weight(.heavy).monospacedDigit())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HISTORY")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            if training.history.filter({ !$0.isActive }).isEmpty {
                Text("No workouts logged yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(training.history.filter { !$0.isActive }) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(session.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(Self.dateLabel(session.startedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(historySummary(session))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if session.id != training.history.filter({ !$0.isActive }).last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Helpers

    private func targetLine(for exercise: PlannedExercise) -> String {
        var parts: [String] = []
        if let reps = exercise.reps { parts.append("\(reps) reps") }
        if let weight = exercise.weight { parts.append("@ \(Int(weight)) lb") }
        if let rest = exercise.restSeconds { parts.append("\(rest)s rest") }
        return parts.isEmpty ? "Coach's call" : parts.joined(separator: " · ")
    }

    private func setLine(_ set: WorkoutSet) -> String {
        var parts: [String] = []
        if let reps = set.reps { parts.append("\(reps) reps") }
        if let weight = set.weight { parts.append("@ \(Int(weight)) lb") }
        return parts.isEmpty ? set.exercise : parts.joined(separator: " ")
    }

    private func historySummary(_ session: WorkoutSession) -> String {
        if session.sets.isEmpty { return "No sets" }
        let names = session.sets.map(\.exercise)
        var seen: [String] = []
        for name in names where !seen.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            seen.append(name)
        }
        return "\(session.sets.count) sets · \(seen.prefix(4).joined(separator: ", "))"
    }

    private static func dateLabel(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
    }
}

// MARK: - Routine editor

private struct WorkoutPlanEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var plan: WorkoutPlan
    var onSave: (WorkoutPlan) -> Void

    init(plan: WorkoutPlan, onSave: @escaping (WorkoutPlan) -> Void) {
        _plan = State(initialValue: plan)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine") {
                    TextField("Name", text: $plan.name)
                    TextField("Notes", text: Binding(
                        get: { plan.notes ?? "" },
                        set: { plan.notes = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(2...4)
                }
                Section("Exercises") {
                    ForEach($plan.exercises) { $exercise in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Exercise", text: $exercise.name)
                            HStack {
                                labeledIntField("Sets", value: $exercise.sets)
                                labeledIntField("Reps", value: $exercise.reps)
                            }
                            HStack {
                                labeledDoubleField("Weight lb", value: $exercise.weight)
                                labeledIntField("Rest sec", value: $exercise.restSeconds)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        plan.exercises.remove(atOffsets: offsets)
                    }
                    Button {
                        plan.exercises.append(PlannedExercise(name: ""))
                    } label: {
                        Label("Add exercise", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle(plan.name.isEmpty ? "New routine" : "Edit routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleaned = plan.exercises.filter {
                            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        var saved = plan
                        saved.name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.exercises = cleaned
                        guard !saved.name.isEmpty, !saved.exercises.isEmpty else { return }
                        onSave(saved)
                        dismiss()
                    }
                }
            }
        }
    }

    private func labeledIntField(_ label: String, value: Binding<Int?>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, text: Binding(
                get: { value.wrappedValue.map(String.init) ?? "" },
                set: { value.wrappedValue = Int($0) }
            ))
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }

    private func labeledDoubleField(_ label: String, value: Binding<Double?>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, text: Binding(
                get: {
                    guard let v = value.wrappedValue else { return "" }
                    return v.truncatingRemainder(dividingBy: 1) == 0
                        ? String(Int(v))
                        : String(v)
                },
                set: { value.wrappedValue = Double($0) }
            ))
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }
}

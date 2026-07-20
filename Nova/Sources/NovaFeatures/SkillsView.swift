import SwiftUI
import NovaDomain

/// Skills list: reusable voice macros with trigger phrases and steps.
/// When `embedded` is true, omits its own `NavigationStack`.
public struct SkillsView: View {
    @Bindable var skills: SkillsViewModel
    var embedded: Bool
    @State private var showImport = false

    public init(skills: SkillsViewModel, embedded: Bool = false) {
        self.skills = skills
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Skills")
                }
            }
        }
    }

    private var content: some View {
        Group {
            if skills.skills.isEmpty {
                ContentUnavailableView {
                    Label("No Skills", systemImage: "wand.and.stars")
                } description: {
                    Text("Create a skill to teach Nova a reusable command, e.g. “start my workday”.")
                }
            } else {
                List {
                    ForEach(skills.skills) { skill in
                        NavigationLink {
                            SkillEditorView(skill: skill, skills: skills)
                        } label: {
                            SkillRow(skill: skill)
                        }
                    }
                    .onDelete { offsets in
                        Task { await skills.delete(at: offsets) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showImport = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Import skill")
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SkillEditorView(skill: nil, skills: skills)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New skill")
            }
        }
        .sheet(isPresented: $showImport) {
            ImportSkillSheet(skills: skills)
        }
        .task { await skills.load() }
    }
}

private struct ImportSkillSheet: View {
    @Bindable var skills: SkillsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Paste skill JSON")
                } footer: {
                    Text("Paste JSON shared from another device. The imported skill gets a new copy so it won't overwrite anything.")
                }
            }
            .navigationTitle("Import Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task {
                            let ok = await skills.importJSON(text)
                            if ok { dismiss() } else { showError = true }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Couldn’t import", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("That doesn’t look like valid skill JSON.")
            }
        }
    }
}

private struct SkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(skill.name).font(.body)
            Text("\(skill.steps.count) step\(skill.steps.count == 1 ? "" : "s") · \(skill.triggerPhrases.count) trigger\(skill.triggerPhrases.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SkillEditorView: View {
    let skill: Skill?
    @Bindable var skills: SkillsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var triggerPhrases: [String] = []
    @State private var steps: [SkillStep] = []
    @State private var newTrigger: String = ""
    @State private var scheduleEnabled = false
    @State private var scheduleTime = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var scheduleWeekdays: Set<Int> = []

    private static let weekdaySymbols: [(day: Int, label: String)] = [
        (1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat")
    ]

    var body: some View {
        Form {
            Section("Name") {
                TextField("Skill name", text: $name)
            }

            Section {
                ForEach(Array(triggerPhrases.enumerated()), id: \.offset) { idx, _ in
                    TextField("Phrase", text: Binding(
                        get: { idx < triggerPhrases.count ? triggerPhrases[idx] : "" },
                        set: { if idx < triggerPhrases.count { triggerPhrases[idx] = $0 } }
                    ))
                }
                .onDelete { triggerPhrases.remove(atOffsets: $0) }
                HStack {
                    TextField("Add a trigger phrase", text: $newTrigger)
                    Button {
                        let t = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        triggerPhrases.append(t)
                        newTrigger = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Trigger phrases")
            } footer: {
                Text("Say any of these (after “Nova”) to run the skill hands-free.")
            }

            Section("Steps") {
                ForEach($steps) { $step in
                    SkillStepEditor(step: $step)
                }
                .onDelete { steps.remove(atOffsets: $0) }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }

                Menu {
                    ForEach(SkillStep.Kind.allCases, id: \.self) { kind in
                        Button(Self.label(for: kind)) {
                            steps.append(SkillStep(kind: kind))
                        }
                    }
                } label: {
                    Label("Add step", systemImage: "plus.circle")
                }
            }

            Section {
                Toggle("Run on a schedule", isOn: $scheduleEnabled)
                if scheduleEnabled {
                    DatePicker("Time", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                    HStack {
                        ForEach(Self.weekdaySymbols, id: \.day) { item in
                            Button {
                                if scheduleWeekdays.contains(item.day) {
                                    scheduleWeekdays.remove(item.day)
                                } else {
                                    scheduleWeekdays.insert(item.day)
                                }
                            } label: {
                                Text(item.label)
                                    .font(.caption2)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(scheduleWeekdays.contains(item.day) ? Color.accentColor : Color.secondary.opacity(0.15))
                                    .foregroundStyle(scheduleWeekdays.contains(item.day) ? Color.white : Color.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Nova sends a reminder at this time; tap it to run the skill. Leave all days off for every day.")
            }

            if let skill {
                Section {
                    ShareLink(item: skills.exportJSON(skill)) {
                        Label("Share skill", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle(skill == nil ? "New Skill" : "Skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    Task {
                        await commit()
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .onAppear {
            name = skill?.name ?? ""
            triggerPhrases = skill?.triggerPhrases ?? []
            steps = skill?.steps ?? []
            if let sched = skill?.schedule {
                scheduleEnabled = true
                scheduleTime = Calendar.current.date(from: DateComponents(hour: sched.hour, minute: sched.minute)) ?? Date()
                scheduleWeekdays = Set(sched.weekdays ?? [])
            }
        }
    }

    private func currentSchedule() -> SkillSchedule? {
        guard scheduleEnabled else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: scheduleTime)
        let days = scheduleWeekdays.isEmpty ? nil : Array(scheduleWeekdays).sorted()
        return SkillSchedule(hour: comps.hour ?? 0, minute: comps.minute ?? 0, weekdays: days)
    }

    private func commit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let phrases = triggerPhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let schedule = currentSchedule()
        if var skill {
            skill.name = trimmedName
            skill.triggerPhrases = phrases
            skill.steps = steps
            skill.schedule = schedule
            await skills.save(skill)
        } else {
            await skills.save(Skill(name: trimmedName, triggerPhrases: phrases, steps: steps, schedule: schedule))
        }
    }

    static func label(for kind: SkillStep.Kind) -> String {
        switch kind {
        case .reminder: return "Reminder"
        case .calendarEvent: return "Calendar event"
        case .note: return "Save note"
        case .openURL: return "Open link/app"
        case .timer: return "Timer"
        case .webhook: return "Call webhook (HTTP)"
        case .delay: return "Wait / delay"
        case .say: return "Speak text"
        case .freeform: return "Ask the AI (freeform)"
        case .capture: return "Capture + read (camera)"
        }
    }
}

/// Per-step editor showing only the fields relevant to the step's kind.
private struct SkillStepEditor: View {
    @Binding var step: SkillStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SkillEditorView.label(for: step.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
            switch step.kind {
            case .reminder:
                TextField("Reminder text", text: $step.text)
                TextField("Due (ISO8601, optional)", text: bind(\.dateISO))
            case .calendarEvent:
                TextField("Event title", text: $step.text)
                TextField("Start (ISO8601)", text: bind(\.dateISO))
                TextField("Duration minutes", value: bindInt(\.durationMinutes), format: .number)
                    .keyboardType(.numberPad)
            case .note:
                TextField("Note text", text: $step.text, axis: .vertical)
            case .openURL:
                TextField("URL or deep link", text: bind(\.url))
                    .textInputAutocapitalization(.never)
            case .timer:
                TextField("Label", text: $step.text)
                TextField("Seconds", value: bindInt(\.seconds), format: .number)
                    .keyboardType(.numberPad)
            case .webhook:
                TextField("URL (https://…)", text: bind(\.url))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Method", selection: bind(\.httpMethod, default: "GET")) {
                    ForEach(["GET", "POST", "PUT"], id: \.self) { Text($0).tag($0) }
                }
                TextField("Body (POST/PUT, optional)", text: $step.text, axis: .vertical)
            case .delay:
                TextField("Seconds to wait", value: bindInt(\.seconds), format: .number)
                    .keyboardType(.numberPad)
            case .say:
                TextField("What Nova should say", text: $step.text, axis: .vertical)
            case .freeform:
                TextField("Instruction for the AI", text: $step.text, axis: .vertical)
            case .capture:
                TextField("Label (optional, e.g. 'receipt')", text: $step.text)
            }
            TextField("Output variable (optional)", text: bind(\.outputVariable))
                .textInputAutocapitalization(.never)
            TextField("Only if variable", text: conditionVariableBinding)
                .textInputAutocapitalization(.never)
            TextField("Equals", text: conditionEqualsBinding)
            Stepper(
                "Retries: \(step.retryPolicy?.maxAttempts ?? 1)",
                value: retryAttemptsBinding,
                in: 1...5
            )
            Toggle("Require confirmation", isOn: confirmationBinding)
        }
        .padding(.vertical, 2)
    }

    private var conditionVariableBinding: Binding<String> {
        Binding(
            get: { step.condition?.variable ?? "" },
            set: { newValue in
                let equals = step.condition?.equals ?? ""
                step.condition = newValue.isEmpty ? nil : SkillCondition(variable: newValue, equals: equals)
            }
        )
    }

    private var conditionEqualsBinding: Binding<String> {
        Binding(
            get: { step.condition?.equals ?? "" },
            set: { newValue in
                let variable = step.condition?.variable ?? ""
                if variable.isEmpty, newValue.isEmpty {
                    step.condition = nil
                } else {
                    step.condition = SkillCondition(variable: variable, equals: newValue)
                }
            }
        )
    }

    private var retryAttemptsBinding: Binding<Int> {
        Binding(
            get: { step.retryPolicy?.maxAttempts ?? 1 },
            set: { newValue in
                if newValue <= 1 {
                    step.retryPolicy = nil
                } else {
                    step.retryPolicy = SkillRetryPolicy(maxAttempts: newValue, delaySeconds: step.retryPolicy?.delaySeconds ?? 1)
                }
            }
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { step.requiresConfirmation == true },
            set: { step.requiresConfirmation = $0 ? true : nil }
        )
    }

    /// Bridges an optional String field to a non-optional TextField binding.
    private func bind(_ keyPath: WritableKeyPath<SkillStep, String?>) -> Binding<String> {
        Binding(
            get: { step[keyPath: keyPath] ?? "" },
            set: { step[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Optional String binding with a fallback default (e.g. a Picker selection).
    private func bind(_ keyPath: WritableKeyPath<SkillStep, String?>, default fallback: String) -> Binding<String> {
        Binding(
            get: { step[keyPath: keyPath] ?? fallback },
            set: { step[keyPath: keyPath] = $0 }
        )
    }

    /// Bridges an optional Int field to a non-optional numeric TextField binding.
    private func bindInt(_ keyPath: WritableKeyPath<SkillStep, Int?>) -> Binding<Int> {
        Binding(
            get: { step[keyPath: keyPath] ?? 0 },
            set: { step[keyPath: keyPath] = $0 <= 0 ? nil : $0 }
        )
    }
}

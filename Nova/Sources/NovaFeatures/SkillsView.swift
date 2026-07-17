import SwiftUI
import NovaDomain

/// Skills tab: teach Nova reusable voice macros. Each skill has trigger phrases
/// (spoken to run it hands-free) and an ordered list of steps.
public struct SkillsView: View {
    @Bindable var skills: SkillsViewModel

    public init(skills: SkillsViewModel) {
        self.skills = skills
    }

    public var body: some View {
        NavigationStack {
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
            .navigationTitle("Skills")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SkillEditorView(skill: nil, skills: skills)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New skill")
                }
            }
            .task { await skills.load() }
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
        }
    }

    private func commit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let phrases = triggerPhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if var skill {
            skill.name = trimmedName
            skill.triggerPhrases = phrases
            skill.steps = steps
            await skills.save(skill)
        } else {
            await skills.save(Skill(name: trimmedName, triggerPhrases: phrases, steps: steps))
        }
    }

    static func label(for kind: SkillStep.Kind) -> String {
        switch kind {
        case .reminder: return "Reminder"
        case .calendarEvent: return "Calendar event"
        case .note: return "Save note"
        case .openURL: return "Open link/app"
        case .timer: return "Timer"
        case .say: return "Speak text"
        case .freeform: return "Ask the AI (freeform)"
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
            case .say:
                TextField("What Nova should say", text: $step.text, axis: .vertical)
            case .freeform:
                TextField("Instruction for the AI", text: $step.text, axis: .vertical)
            }
        }
        .padding(.vertical, 2)
    }

    /// Bridges an optional String field to a non-optional TextField binding.
    private func bind(_ keyPath: WritableKeyPath<SkillStep, String?>) -> Binding<String> {
        Binding(
            get: { step[keyPath: keyPath] ?? "" },
            set: { step[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
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

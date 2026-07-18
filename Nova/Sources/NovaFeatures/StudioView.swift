import SwiftUI

/// Authoring tab: Workspaces and Skills behind a segmented control.
public struct StudioView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case workspaces = "Workspaces"
        case skills = "Skills"
        var id: String { rawValue }
    }

    @Bindable var workspaces: WorkspacesViewModel
    @Bindable var skills: SkillsViewModel
    @State private var segment: Segment = .workspaces

    public init(workspaces: WorkspacesViewModel, skills: SkillsViewModel) {
        self.workspaces = workspaces
        self.skills = skills
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch segment {
                case .workspaces:
                    WorkspacesView(workspaces: workspaces, embedded: true)
                case .skills:
                    SkillsView(skills: skills, embedded: true)
                }
            }
            .navigationTitle("Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Studio", selection: $segment) {
                        ForEach(Segment.allCases) { seg in
                            Text(seg.rawValue).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
            }
        }
    }
}

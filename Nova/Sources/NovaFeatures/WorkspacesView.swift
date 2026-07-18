import SwiftUI
import NovaDomain

/// Workspaces list: create/edit projects and set the active one.
/// When `embedded` is true, omits its own `NavigationStack` (used inside Studio).
public struct WorkspacesView: View {
    @Bindable var workspaces: WorkspacesViewModel
    var embedded: Bool

    public init(workspaces: WorkspacesViewModel, embedded: Bool = false) {
        self.workspaces = workspaces
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Workspaces")
                }
            }
        }
    }

    private var content: some View {
        List {
            Section {
                ForEach(workspaces.workspaces) { ws in
                    NavigationLink {
                        WorkspaceEditorView(workspace: ws, workspaces: workspaces)
                    } label: {
                        WorkspaceRow(
                            workspace: ws,
                            isActive: ws.id == workspaces.active?.id
                        )
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await workspaces.setActive(ws) }
                        } label: {
                            Label("Activate", systemImage: "checkmark.circle")
                        }
                        .tint(.green)
                    }
                }
                .onDelete { offsets in
                    Task { await workspaces.delete(at: offsets) }
                }
            } footer: {
                Text("Active workspace context is injected each session. Say “Nova, switch to my … workspace” hands-free.")
                    .font(.caption2)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    WorkspaceEditorView(workspace: nil, workspaces: workspaces)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New workspace")
            }
        }
        .task { await workspaces.load() }
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.body)
                if !workspace.contextNotes.isEmpty {
                    Text(workspace.contextNotes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            }
        }
    }
}

struct WorkspaceEditorView: View {
    let workspace: Workspace?
    @Bindable var workspaces: WorkspacesViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var contextNotes: String = ""

    var body: some View {
        Form {
            Section("Name") {
                TextField("Workspace name", text: $name)
            }
            Section {
                TextEditor(text: $contextNotes)
                    .frame(minHeight: 140)
            } header: {
                Text("Context Nova should remember")
            } footer: {
                Text("e.g. “Building a SwiftUI app called Nova; prefer concise, technical answers.”")
            }
            if let workspace, workspace.id != workspaces.active?.id {
                Section {
                    Button {
                        Task {
                            await workspaces.setActive(workspace)
                            dismiss()
                        }
                    } label: {
                        Label("Make active", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .navigationTitle(workspace == nil ? "New Workspace" : "Workspace")
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
        }
        .onAppear {
            name = workspace?.name ?? ""
            contextNotes = workspace?.contextNotes ?? ""
        }
    }

    private func commit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        if var workspace {
            workspace.name = trimmedName
            workspace.contextNotes = contextNotes
            await workspaces.update(workspace)
        } else {
            await workspaces.create(name: trimmedName, contextNotes: contextNotes)
        }
    }
}

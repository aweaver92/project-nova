import SwiftUI
import NovaDomain
#if canImport(UIKit)
import UIKit
#endif

public struct CodingView: View {
    @Bindable var coding: CodingViewModel
    var embedded: Bool
    @State private var showSessions = false
    @State private var showRepos = false
    @State private var showClone = false
    @State private var showCreateProject = false
    @State private var showPublish = false

    public init(coding: CodingViewModel, embedded: Bool = false) {
        self.coding = coding
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
        VStack(spacing: 0) {
            repoStatusCard
            Divider()
            if coding.isRunning || !coding.activitySteps.isEmpty {
                agentProcessPanel
                Divider()
            }
            transcript
            Divider()
            composer
        }
        .navigationTitle("Coding")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSessions = true
                } label: {
                    Label("Sessions", systemImage: "list.bullet")
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(coding.shortSessionId)
                        .font(.caption.monospaced().weight(.semibold))
                    HStack(spacing: 6) {
                        Text(coding.runStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        if coding.isRunning { ProgressView().controlSize(.mini) }
                    }
                    Text(coding.selectedRepoName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Repositories…") { showRepos = true }
                    Button("New web project…") { showCreateProject = true }
                    Button("Clone GitHub repo…") { showClone = true }
                    Button("New session") {
                        Task { await coding.startNewSession() }
                    }
                    Button("Refresh") {
                        Task {
                            await coding.refreshSessions()
                            await coding.refreshRepositories()
                            await coding.refreshRepoStatusAndDiff()
                        }
                    }
                    if let full = coding.pinnedSessionId {
                        Button("Copy session id") {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = full
                            #endif
                        }
                    }
                    if coding.isRunning {
                        Button("Cancel run", role: .destructive) {
                            Task { await coding.cancel() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSessions) { sessionPicker }
        .sheet(isPresented: $showRepos) { repoPicker }
        .sheet(isPresented: $showClone) { cloneSheet }
        .sheet(isPresented: $showCreateProject) { createProjectSheet }
        .sheet(isPresented: $showPublish) { publishSheet }
        .task {
            await coding.load()
            await coding.refreshPreviews()
        }
    }

    @ViewBuilder
    private var repoStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    showRepos = true
                } label: {
                    Label(coding.selectedRepoName, systemImage: "folder")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    Task { await coding.refreshRepoStatusAndDiff() }
                } label: {
                    if coding.isRefreshingRepo {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(coding.selectedRepoId == nil || coding.isRefreshingRepo)
            }

            if let status = coding.repoStatus {
                HStack(spacing: 8) {
                    Text(status.branch)
                        .font(.caption.monospaced())
                    if let upstream = status.upstream {
                        Text("↑\(status.ahead) ↓\(status.behind) · \(upstream)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(status.clean ? "Clean" : "\(status.changedFiles.count) changed")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status.clean ? Color.secondary : Color.orange)
                }
                if !status.changedFiles.isEmpty {
                    Text(status.changedFiles.prefix(6).map(\.path).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Button(coding.showDiff ? "Hide diff" : "Review diff") {
                        coding.toggleShowDiff()
                    }
                    .font(.caption)
                    .disabled(coding.repoDiff?.diff.isEmpty != false && status.clean)
                    Spacer()
                    Button("Create pull request") {
                        coding.preparePublishDraft()
                        showPublish = true
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(status.clean || coding.isPublishing)
                }
            } else if coding.selectedRepoId == nil {
                Text("Pick or clone a GitHub repository to code against.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            previewRow

            if coding.showDiff, let diff = coding.repoDiff {
                ScrollView {
                    Text(diff.diff.isEmpty ? "(no textual diff — untracked files only)" : diff.diff)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if diff.truncated {
                    Text("Diff truncated for review.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if let pr = coding.lastPublishResult {
                if let url = URL(string: pr.prUrl) {
                    Link("Opened \(pr.prUrl)", destination: url)
                        .font(.caption)
                } else {
                    Text(pr.prUrl)
                        .font(.caption)
                }
            }

            if !coding.statusMessage.isEmpty {
                Text(coding.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
    }

    /// Live preview: serve the repo from the bridge PC and open it in Safari.
    @ViewBuilder
    private var previewRow: some View {
        if let preview = coding.activePreview {
            HStack(spacing: 8) {
                Image(systemName: preview.isReady ? "globe" : "hourglass")
                    .font(.caption)
                    .foregroundStyle(preview.isReady ? Color.accentColor : .secondary)
                if preview.isReady, let url = URL(string: preview.url) {
                    Link(destination: url) {
                        Text(preview.url)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preview.state == "installing" ? "Installing dependencies…" : preview.state == "error" ? "Preview failed" : "Starting \(preview.kind) server…")
                            .font(.caption)
                            .foregroundStyle(preview.state == "error" ? Color.red : .secondary)
                        if preview.state == "error", let detail = preview.error ?? preview.lastOutput {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if preview.isPending {
                        ProgressView().controlSize(.mini)
                    }
                }
                Spacer()
                Button("Stop") {
                    Task { await coding.stopPreview() }
                }
                .font(.caption)
            }
        } else if coding.selectedRepoId != nil {
            Button {
                Task { await coding.startPreview() }
            } label: {
                Label(
                    coding.isStartingPreview ? "Starting preview…" : "Preview in browser",
                    systemImage: "safari"
                )
                .font(.caption.weight(.semibold))
            }
            .disabled(coding.isStartingPreview)
        }
    }

    /// Cursor Agents-window style live process feed.
    private var agentProcessPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Agent process")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(coding.runStatus.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if coding.isRunning {
                    ProgressView().controlSize(.mini)
                    Button("Stop") {
                        Task { await coding.cancel() }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(coding.activeRunId == nil)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(coding.activitySteps.suffix(24)) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: step.symbolName)
                                .font(.caption)
                                .foregroundStyle(step.isDone ? Color.secondary : Color.accentColor)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.text)
                                    .font(.caption)
                                    .foregroundStyle(step.isDone ? .secondary : .primary)
                                    .lineLimit(2)
                                if let detail = step.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            if !step.isDone && coding.isRunning {
                                ProgressView().controlSize(.mini)
                            } else if step.isDone {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: coding.isRunning ? 140 : 88)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !coding.statusMessage.isEmpty && coding.items.isEmpty && coding.repoStatus == nil {
                        Text(coding.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    ForEach(coding.items) { item in
                        transcriptRow(item)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: coding.items.count) { _, _ in
                if let last = coding.items.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ item: CodingTranscriptItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
        case .assistant:
            Text(item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        case .thinking:
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        case .tool:
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    coding.toggleExpand(item)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption)
                        Text(item.text)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if item.diff != nil {
                            Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                }
                .buttonStyle(.plain)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if item.isExpanded, let diff = item.diff, !diff.isEmpty {
                    ScrollView(.horizontal) {
                        Text(diff)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(6)
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
        case .status:
            Text(item.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        case .error:
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Prompt Cursor…", text: $coding.draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(coding.isRunning)
            Button {
                Task { await coding.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(coding.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coding.isRunning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var repoPicker: some View {
        NavigationStack {
            List {
                Section {
                    Button("New public web project…") {
                        showRepos = false
                        showCreateProject = true
                    }
                    Button("Clone GitHub repo…") {
                        showRepos = false
                        showClone = true
                    }
                }
                Section("Allowlisted repositories") {
                    if coding.repositories.isEmpty {
                        Text("No local repos under bridge roots yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coding.repositories) { repo in
                            Button {
                                Task {
                                    await coding.selectRepository(repo.id)
                                    showRepos = false
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(repo.name)
                                            .foregroundStyle(.primary)
                                        Text("\(repo.rootLabel)/\(repo.relativePath)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if repo.id == coding.selectedRepoId {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Repositories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showRepos = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await coding.refreshRepositories() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await coding.refreshRepositories() }
        }
    }

    private var cloneSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/owner/repo", text: $coding.cloneURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("Uses the bridge PC’s existing GitHub CLI authentication. Only https://github.com/owner/repo URLs are accepted.")
                }
            }
            .navigationTitle("Clone repo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showClone = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") {
                        Task {
                            await coding.cloneRepository()
                            if coding.selectedRepoId != nil {
                                showClone = false
                            }
                        }
                    }
                    .disabled(coding.cloneURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coding.isRefreshingRepo)
                }
            }
        }
    }

    private var createProjectSheet: some View {
        NavigationStack {
            Form {
                Section("Public GitHub repository") {
                    TextField("project-name", text: $coding.newProjectName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(
                        "Short description (optional)",
                        text: $coding.newProjectDescription,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                }

                Section("Web template") {
                    Picker("Template", selection: $coding.newProjectTemplate) {
                        ForEach(WebProjectTemplate.allCases) { template in
                            Text(template.title).tag(template)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Text(coding.newProjectTemplate.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Label("Repository visibility: Public", systemImage: "globe")
                    Text("Nova creates the repository under the bridge PC’s authenticated GitHub account, scaffolds the selected starter, commits it to main, pushes it, selects it in Coding, and starts a fresh Cursor session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let created = coding.lastCreatedProject,
                   let url = URL(string: created.repoUrl)
                {
                    Section("Created") {
                        Link(created.repoUrl, destination: url)
                    }
                }
            }
            .navigationTitle("New web project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreateProject = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(coding.isCreatingProject ? "Creating…" : "Create") {
                        Task {
                            await coding.createPublicWebProject()
                            if coding.lastCreatedProject != nil {
                                showCreateProject = false
                            }
                        }
                    }
                    .disabled(
                        coding.newProjectName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty || coding.isCreatingProject
                    )
                }
            }
        }
    }

    private var publishSheet: some View {
        NavigationStack {
            Form {
                Section("Review") {
                    if let status = coding.repoStatus {
                        LabeledContent("Branch now", value: status.branch)
                        ForEach(status.changedFiles) { file in
                            Text("\(file.status) \(file.path)")
                                .font(.caption.monospaced())
                        }
                    }
                }
                Section("Pull request") {
                    TextField("nova/branch-name", text: $coding.publishBranchName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Commit message", text: $coding.publishCommitMessage, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("PR title", text: $coding.publishPRTitle, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("PR body", text: $coding.publishPRBody, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let pr = coding.lastPublishResult, let url = URL(string: pr.prUrl) {
                    Section("Result") {
                        Link(pr.prUrl, destination: url)
                    }
                }
            }
            .navigationTitle("Create PR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPublish = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(coding.isPublishing ? "Publishing…" : "Confirm") {
                        Task {
                            await coding.publishPullRequest()
                            if coding.lastPublishResult != nil {
                                // Keep sheet open so the PR link is tappable.
                            }
                        }
                    }
                    .disabled(coding.isPublishing || coding.repoStatus?.clean == true)
                }
            }
            .onAppear { coding.preparePublishDraft() }
        }
    }

    private var sessionPicker: some View {
        NavigationStack {
            List {
                Section {
                    Button("New session") {
                        Task {
                            await coding.startNewSession()
                            showSessions = false
                        }
                    }
                }
                Section("Local Cursor agents") {
                    if coding.isLoading {
                        ProgressView()
                    } else if coding.sessions.isEmpty {
                        Text("No sessions. Send a prompt to create one.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coding.sessions) { session in
                            Button {
                                Task {
                                    await coding.attach(sessionId: session.id)
                                    showSessions = false
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(session.title)
                                            .foregroundStyle(.primary)
                                        if session.id == coding.pinnedSessionId {
                                            Image(systemName: "pin.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(session.id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let status = session.status {
                                        Text(status)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showSessions = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await coding.refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await coding.refreshSessions() }
        }
    }
}

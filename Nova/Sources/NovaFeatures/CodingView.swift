import SwiftUI
import NovaDomain
#if canImport(UIKit)
import UIKit
import PhotosUI
#endif

public struct CodingView: View {
    @Bindable var coding: CodingViewModel
    var embedded: Bool
    @State private var showSessions = false
    @State private var showRepos = false
    @State private var showClone = false
    @State private var showCreateProject = false
    @State private var showPublish = false
    @State private var showCommitAndBuildConfirm = false
    @State private var showRepoFiles = false
    @State private var showPromptHistory = false
    @State private var showTemplates = false
    @State private var showKeepAllConfirm = false
    @State private var showRevertAllConfirm = false
    @State private var showEndSessionConfirm = false
    /// Agent Keep/Revert file list: one summary row when collapsed.
    @State private var agentReviewFilesExpanded = false
    @State private var saveTemplateTitle = ""
    @State private var showSaveTemplate = false
    /// Expanded process feed; stays open after a run so summaries remain readable.
    @State private var agentProcessExpanded = true
    /// Repository browser action: preview a path, or pin it into prompts.
    @State private var browseMode: RepoBrowseMode = .preview
    #if canImport(UIKit)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    private enum RepoBrowseMode: String, CaseIterable {
        case preview
        case pin
    }

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
            if coding.showsCommitAndBuildProgress {
                commitAndBuildBanner
                Divider()
            } else if let failure = coding.lastCommitAndBuildFailure {
                commitAndBuildFailureBanner(failure)
                Divider()
            }
            if coding.isRunning && coding.stallPhase != .looksStuck {
                continuityBanner
                Divider()
            }
            if coding.stallPhase == .looksStuck {
                stallBanner
                Divider()
            }
            if coding.isRunning || !coding.activitySteps.isEmpty {
                agentProcessPanel
                Divider()
            }
            if let plan = coding.pendingPlan {
                pendingPlanPanel(plan)
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
                .disabled(!coding.isCodeViewSessionActive)
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(coding.showsCommitAndBuildProgress ? "Commit & Build" : coding.shortSessionId)
                        .font(.caption.monospaced().weight(.semibold))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(coding.showsCommitAndBuildProgress ? Color.orange : statusColor)
                            .frame(width: 6, height: 6)
                        Text(coding.showsCommitAndBuildProgress
                             ? (coding.commitAndBuildPhaseLabel.isEmpty ? "building" : coding.commitAndBuildPhaseLabel)
                             : coding.runStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if coding.showsCommitAndBuildProgress, let started = coding.commitAndBuildStartedAt {
                            ElapsedTimeText(since: started)
                        } else if coding.isRunning, let started = coding.runStartedAt {
                            ElapsedTimeText(since: started)
                        }
                        if coding.isRunning, let last = coding.lastSSEActivityAt {
                            LastEventAgeText(since: last)
                        }
                    }
                    Text(coding.selectedRepoName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("End session", role: .destructive) {
                    showEndSessionConfirm = true
                }
                .disabled(!coding.isCodeViewSessionActive)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Repositories…") { showRepos = true }
                    Button("New web project…") { showCreateProject = true }
                    Button("Clone GitHub repo…") { showClone = true }
                    Button("Commit and Build…") {
                        showCommitAndBuildConfirm = true
                    }
                    .disabled(coding.isCommitAndBuilding || coding.isPublishing)
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
        .sheet(isPresented: $showRepoFiles) { repositoryFileBrowser }
        .sheet(isPresented: $showPromptHistory) { promptHistorySheet }
        .sheet(isPresented: $showTemplates) { templatesSheet }
        .alert("Keep all agent changes?", isPresented: $showKeepAllConfirm) {
            Button("Keep all") {
                Task { await coding.keepAllReviewChanges() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leaves files on disk unchanged and marks them kept for publishing.")
        }
        .alert("Revert all agent changes?", isPresented: $showRevertAllConfirm) {
            Button("Revert all", role: .destructive) {
                Task { await coding.revertAllReviewChanges() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores pre-run content for agent-touched files only. Your earlier uncommitted work stays untouched.")
        }
        .alert("Save template", isPresented: $showSaveTemplate) {
            TextField("Title", text: $saveTemplateTitle)
            Button("Save") {
                Task {
                    await coding.saveCurrentDraftAsTemplate(title: saveTemplateTitle)
                    saveTemplateTitle = ""
                }
            }
            Button("Cancel", role: .cancel) { saveTemplateTitle = "" }
        } message: {
            Text("Saves the current draft as a reusable prompt for this repository.")
        }
        .alert("End coding session?", isPresented: $showEndSessionConfirm) {
            Button("End session", role: .destructive) {
                Task { await coding.endSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ends this chat. Reopen Code view when you want to start another session.")
        }
        .alert("Commit and build IPA?", isPresented: $showCommitAndBuildConfirm) {
            Button("Commit & Build", role: .destructive) {
                Task { await coding.commitAndBuildIpa(userAlreadyConfirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(commitAndBuildDisclaimer)
        }
        .task {
            await coding.load()
            await coding.beginCodeViewSession()
            await coding.refreshPreviews()
        }
    }

    private var commitAndBuildDisclaimer: String {
        let branch = coding.repoStatus?.branch ?? "this branch"
        let changed = coding.repoStatus?.changedFiles.count ?? 0
        return """
        Are you sure?

        This commits ALL local changes on \(branch) (\(changed) file(s)), pushes to origin, runs the GitHub Actions IPA job (often 10–25 minutes), and overwrites Nova/App/NovaApp.ipa for SideStore.

        Cancel if you are not ready to publish these changes.
        """
    }

    @ViewBuilder
    private var commitAndBuildBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(coding.commitAndBuildPhaseLabel.isEmpty
                     ? "Commit and Build in progress"
                     : coding.commitAndBuildPhaseLabel)
                    .font(.caption.weight(.semibold))
                if let started = coding.commitAndBuildStartedAt {
                    HStack(spacing: 4) {
                        Text("Elapsed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ElapsedTimeText(since: started)
                    }
                }
                Text(coding.statusMessage.isEmpty
                     ? "Commit, push, then GitHub Actions IPA build. Safe to lock or switch apps."
                     : coding.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private func commitAndBuildFailureBanner(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Commit and Build failed")
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button("Dismiss") {
                coding.clearCommitAndBuildFailure()
            }
            .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }

    @ViewBuilder
    private var continuityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: coding.runStatus == "reconnecting"
                  ? "arrow.triangle.2.circlepath"
                  : "desktopcomputer")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if coding.runStatus == "reconnecting" {
                    Text("Reconnecting to PC…")
                        .font(.caption.weight(.semibold))
                    Text(coding.statusMessage.isEmpty
                         ? "Checking the coding run that kept going on your PC."
                         : coding.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if coding.stallPhase == .stillWorking {
                    Text("Working on PC · quiet for a bit")
                        .font(.caption.weight(.semibold))
                    if let last = coding.lastSSEActivityAt {
                        LastEventAgeText(since: last, prefix: "Last event ")
                    } else {
                        Text("The agent keeps working even if you lock the phone.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Working on PC")
                        .font(.caption.weight(.semibold))
                    if let last = coding.lastSSEActivityAt {
                        LastEventAgeText(since: last, prefix: "Last event ")
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    @ViewBuilder
    private var stallBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Looks stuck")
                    .font(.caption.weight(.semibold))
                Text("No agent activity for a while. You can restart the session and retry.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let last = coding.lastSSEActivityAt {
                    LastEventAgeText(since: last, prefix: "Last event ")
                }
            }
            Spacer()
            Button("Restart session") {
                Task { await coding.restartSession() }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
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
                if coding.selectedRepoId != nil {
                    Button {
                        showRepoFiles = true
                    } label: {
                        Label("Files", systemImage: "folder.badge.gearshape")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
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
                if let review = coding.agentReview, !review.files.isEmpty {
                    Text("\(review.pendingCount) agent change\(review.pendingCount == 1 ? "" : "s") · \(review.keptCount) kept")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !status.changedFiles.isEmpty {
                    Text(status.changedFiles.prefix(6).map(\.path).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    if coding.agentReview != nil {
                        Button(coding.showDiff ? "Hide review" : "Review changes") {
                            coding.toggleShowDiff()
                            agentReviewFilesExpanded = coding.showDiff
                        }
                        .font(.caption)
                    } else {
                        Button(coding.showDiff ? "Hide diff" : "Review diff") {
                            coding.toggleShowDiff()
                        }
                        .font(.caption)
                        .disabled(coding.repoDiff?.diff.isEmpty != false && status.clean)
                    }
                    Spacer()
                    Button("Commit and Build") {
                        showCommitAndBuildConfirm = true
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(coding.isCommitAndBuilding || coding.isPublishing)
                    Button("Create pull request") {
                        coding.preparePublishDraft()
                        showPublish = true
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(
                        coding.isPublishing
                            || coding.isCommitAndBuilding
                            || (coding.agentReview.map { $0.files.isEmpty } ?? status.clean)
                    )
                }
            } else if coding.selectedRepoId == nil {
                Text("Pick or clone a GitHub repository to code against.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            previewRow

            if coding.showDiff {
                if let review = coding.agentReview {
                    agentReviewPanel(review)
                } else if let diff = coding.repoDiff {
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

            if let failure = coding.lastCommitAndBuildFailure, !coding.showsCommitAndBuildProgress {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let built = coding.lastCommitAndBuildResult, !coding.showsCommitAndBuildProgress {
                Text(built.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if coding.showsCommitAndBuildProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coding.commitAndBuildPhaseLabel.isEmpty
                             ? "Commit and Build running…"
                             : coding.commitAndBuildPhaseLabel)
                            .font(.caption.weight(.semibold))
                        if let started = coding.commitAndBuildStartedAt {
                            HStack(spacing: 4) {
                                Text("Elapsed")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                ElapsedTimeText(since: started)
                            }
                        }
                    }
                    Spacer(minLength: 0)
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

    @ViewBuilder
    private func agentReviewPanel(_ review: BridgeAgentReview) -> some View {
        let pending = review.files.filter { !$0.kept }
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    agentReviewFilesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(agentReviewFilesExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.isEmpty
                             ? (review.keptCount > 0 ? "All agent changes kept" : "No pending agent changes")
                             : "\(pending.count) agent change\(pending.count == 1 ? "" : "s") to keep")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !pending.isEmpty {
                            Text(pending.prefix(3).map(\.path).joined(separator: " · "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if review.keptCount > 0 {
                            Text("\(review.keptCount) kept")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if !pending.isEmpty {
                        Text("Review")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                pending.isEmpty
                    ? "Agent changes"
                    : "\(pending.count) agent changes to keep"
            )
            .accessibilityHint(agentReviewFilesExpanded ? "Collapse" : "Expand to review and keep or revert")

            if !pending.isEmpty {
                HStack(spacing: 12) {
                    Button("Keep all") { showKeepAllConfirm = true }
                        .font(.caption.weight(.semibold))
                    Button("Revert all", role: .destructive) { showRevertAllConfirm = true }
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
            }

            if agentReviewFilesExpanded {
                if pending.isEmpty {
                    Text(review.keptCount > 0 ? "All agent changes kept." : "No pending agent changes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(pending) { file in
                                agentReviewFileRow(file)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: review.pendingCount) { _, count in
            if count == 0 {
                agentReviewFilesExpanded = false
            }
        }
    }

    @ViewBuilder
    private func agentReviewFileRow(_ file: BridgeAgentReviewFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                coding.toggleReviewExpanded(file.path)
            } label: {
                HStack(spacing: 8) {
                    Text(file.change.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.orange)
                    Text(file.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: coding.expandedReviewPath == file.path ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if coding.expandedReviewPath == file.path {
                if file.binary {
                    Text("Binary file — preview unavailable.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(file.diff.isEmpty ? "(no textual diff)" : file.diff)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                if file.truncated {
                    Text("Diff truncated.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Keep") {
                        Task { await coding.keepReviewPaths([file.path]) }
                    }
                    .font(.caption.weight(.semibold))
                    Button("Revert", role: .destructive) {
                        Task { await coding.revertReviewPaths([file.path]) }
                    }
                    .font(.caption.weight(.semibold))
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func pendingPlanPanel(_ plan: CodingPendingPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Plan ready", systemImage: "list.bullet.clipboard.fill")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    coding.togglePendingPlanExpanded()
                } label: {
                    Image(systemName: plan.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                Button {
                    coding.dismissPendingPlan()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Text(plan.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let overview = plan.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !plan.isExpanded {
                Text(plan.summaryPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if plan.isExpanded {
                ScrollView {
                    Text(plan.markdown)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let path = plan.path, !path.isEmpty {
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await coding.approvePendingPlanAndBuild() }
                } label: {
                    Label("Approve & build", systemImage: "hammer.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coding.isRunning)

                Button {
                    coding.modifyPendingPlan()
                } label: {
                    Label("Modify plan", systemImage: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(coding.isRunning)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Live preview: serve the repo from the bridge PC and open it in Safari.
    @ViewBuilder
    private var previewRow: some View {
        if let preview = coding.activePreview {
            VStack(alignment: .leading, spacing: 6) {
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
                    if preview.isReady {
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = preview.url
                            #endif
                            coding.noteStatus("Preview URL copied")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .font(.caption)
                        .accessibilityLabel("Copy preview URL")
                    }
                    Button("Change") {
                        showRepoFiles = true
                    }
                    .font(.caption)
                    Button("Stop") {
                        Task { await coding.stopPreview() }
                    }
                    .font(.caption)
                }
                if preview.isReady {
                    previewAccessBanner(preview)
                }
                Label(
                    preview.path?.isEmpty == false ? (preview.path ?? "") : "Repository root",
                    systemImage: "scope"
                )
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        } else if coding.selectedRepoId != nil {
            HStack {
                Button {
                    showRepoFiles = true
                } label: {
                    Label(
                        coding.isStartingPreview ? "Starting preview…" : "Choose preview file or folder",
                        systemImage: "safari"
                    )
                    .font(.caption.weight(.semibold))
                }
                .disabled(coding.isStartingPreview)
                if let target = coding.previewTargetPath {
                    Text(target)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var repositoryFileBrowser: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mode", selection: $browseMode) {
                        Text("Preview").tag(RepoBrowseMode.preview)
                        Text("Pin context").tag(RepoBrowseMode.pin)
                    }
                    .pickerStyle(.segmented)
                }
                if coding.isLoadingRepoFiles && coding.repoFileEntries.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading files…")
                        Spacer()
                    }
                } else if coding.repoFileEntries.isEmpty {
                    ContentUnavailableView(
                        "No files",
                        systemImage: "folder",
                        description: Text("This folder is empty.")
                    )
                } else {
                    ForEach(coding.repoFileEntries) { entry in
                        Button {
                            if entry.isDirectory {
                                Task { await coding.browseRepository(path: entry.path) }
                            } else if browseMode == .preview {
                                coding.choosePreviewTarget(entry.path)
                                showRepoFiles = false
                                Task { await coding.startPreview(path: entry.path) }
                            } else {
                                Task {
                                    await coding.pinPath(entry.path, isDirectory: false)
                                    showRepoFiles = false
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : fileSymbol(entry.name))
                                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !entry.isDirectory, let size = entry.size {
                                        Text(
                                            ByteCountFormatter.string(
                                                fromByteCount: Int64(size),
                                                countStyle: .file
                                            )
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if browseMode == .pin, !entry.isDirectory {
                                    Image(systemName: "pin.fill")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Image(systemName: entry.isDirectory ? "chevron.right" : "safari")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if browseMode == .pin {
                                Button("Pin") {
                                    Task {
                                        await coding.pinPath(entry.path, isDirectory: entry.isDirectory)
                                    }
                                }
                                .tint(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle(
                coding.repoBrowsePath.isEmpty
                    ? coding.selectedRepoName
                    : coding.repoBrowsePath
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showRepoFiles = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await coding.browseRepository(path: coding.repoBrowsePath) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(coding.isLoadingRepoFiles)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        Task { await coding.browseParentDirectory() }
                    } label: {
                        Label("Up", systemImage: "arrow.up")
                    }
                    .disabled(coding.repoBrowsePath.isEmpty || coding.isLoadingRepoFiles)
                    Spacer()
                    if browseMode == .preview {
                        Button {
                            let path = coding.repoBrowsePath
                            coding.choosePreviewTarget(path.isEmpty ? nil : path)
                            showRepoFiles = false
                            Task {
                                await coding.startPreview(path: path.isEmpty ? nil : path)
                            }
                        } label: {
                            Label(
                                coding.repoBrowsePath.isEmpty
                                    ? "Preview repo root"
                                    : "Preview this folder",
                                systemImage: "safari"
                            )
                        }
                        .disabled(coding.isLoadingRepoFiles)
                    } else {
                        Button {
                            let path = coding.repoBrowsePath
                            Task {
                                await coding.pinPath(
                                    path.isEmpty ? "." : path,
                                    isDirectory: true
                                )
                                showRepoFiles = false
                            }
                        } label: {
                            Label(
                                coding.repoBrowsePath.isEmpty
                                    ? "Pin repo root"
                                    : "Pin this folder",
                                systemImage: "pin"
                            )
                        }
                        .disabled(coding.isLoadingRepoFiles || coding.pinnedPaths.count >= 3)
                    }
                }
            }
            .task {
                await coding.browseRepository(path: coding.repoBrowsePath)
            }
        }
    }

    private func fileSymbol(_ name: String) -> String {
        switch name.split(separator: ".").last?.lowercased() {
        case "html", "htm": return "doc.richtext"
        case "swift": return "swift"
        case "js", "ts", "tsx", "jsx": return "curlybraces"
        case "json": return "list.bullet.rectangle"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "md": return "doc.text"
        default: return "doc"
        }
    }

    /// Cursor Agents-window style live process feed.
    private var agentProcessPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        agentProcessExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: agentProcessExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text("Agent process")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(coding.runStatus.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if coding.isRunning {
                    ProgressView().controlSize(.mini)
                    Button("Stop") {
                        Task { await coding.cancel() }
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if agentProcessExpanded {
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
                .frame(maxHeight: 160)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .onChange(of: coding.isRunning) { _, running in
            // Only force-open when a new run starts; do not auto-hide when it ends.
            if running {
                agentProcessExpanded = true
            }
        }
        .onAppear {
            if coding.isRunning {
                agentProcessExpanded = true
            }
        }
    }

    private var statusColor: Color {
        switch coding.runStatus.lowercased() {
        case "running", "creating", "connecting", "reconnecting": return .green
        case "finished", "idle": return .secondary.opacity(0.6)
        case "error", "expired": return .red
        case "cancelled": return .orange
        default: return .secondary.opacity(0.6)
        }
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
                    if coding.items.isEmpty && !coding.isRunning {
                        emptyTranscriptState
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
            .onChange(of: coding.items.last?.text.count ?? 0) { _, _ in
                // Follow streaming text growth, not just new rows.
                guard coding.isRunning, let last = coding.items.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// Friendly first-run state with tappable starter prompts.
    private var emptyTranscriptState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start coding")
                    .font(.headline)
                Text(
                    coding.selectedRepoId == nil
                        ? "Pick a repository above, then describe what you want built or fixed — type here or ask Claude by voice. Prefix with /ask for a question with no coding updates."
                        : "Type a prompt here, or speak to Claude. Start with /ask to get an answer without coding updates."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            ForEach(coding.builtInTemplates, id: \.title) { template in
                Button {
                    coding.applyTemplate(template.body)
                    Task { await coding.send() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                        Text(template.title)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            if !coding.savedTemplates.isEmpty {
                ForEach(coding.savedTemplates) { template in
                    Button {
                        coding.applyTemplate(template.body)
                        Task { await coding.send() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                            Text(template.title)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 24)
    }

    /// Inline markdown (bold, code, links) without treating text as a format string.
    private static func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(verbatim: text)
    }

    @ViewBuilder
    private func transcriptRow(_ item: CodingTranscriptItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        if item.agentMode != .agent {
                            Label(item.agentMode.title, systemImage: item.agentMode.systemImage)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else if item.isAskOnly {
                            Label("Ask", systemImage: "questionmark.bubble.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if item.isFromVoice {
                            Label("Spoken", systemImage: "mic.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.text)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal)
        case .assistant:
            Self.markdownText(item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = item.text
                        #endif
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
        case .thinking:
            Button {
                coding.toggleExpand(item)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.caption2)
                        Text("Thinking")
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                        Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                    Text(item.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .italic()
                        .lineLimit(item.isExpanded ? nil : 3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        case .tool:
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    coding.toggleExpand(item)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.toolSymbolName)
                            .font(.caption)
                            .foregroundStyle(item.isDone ? Color.secondary : Color.accentColor)
                        Text(item.text)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if !item.isDone && coding.isRunning {
                            ProgressView().controlSize(.mini)
                        }
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(item.text)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if coding.canRetry {
                    Button {
                        Task { await coding.retryLast() }
                    } label: {
                        Label("Retry last prompt", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !coding.isCodeViewSessionActive {
                Label("Session ended. Reopen Code view to start another chat.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if coding.queuedPromptCount > 0 {
                Label(
                    "\(coding.queuedPromptCount) prompt\(coding.queuedPromptCount == 1 ? "" : "s") queued",
                    systemImage: "list.number"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !coding.pinnedPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(coding.pinnedPaths) { pin in
                            HStack(spacing: 4) {
                                Image(systemName: pin.isDirectory ? "folder" : "doc")
                                    .font(.caption2)
                                Text(pin.path)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                Button {
                                    Task { await coding.unpinPath(pin.path) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .accessibilityLabel("Unpin \(pin.path)")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    browseMode = .pin
                    showRepoFiles = true
                } label: {
                    Label("Pin", systemImage: "pin")
                        .font(.caption.weight(.semibold))
                }
                .disabled(coding.selectedRepoId == nil || coding.pinnedPaths.count >= 3)
                Button { showTemplates = true } label: {
                    Label("Templates", systemImage: "doc.text")
                        .font(.caption.weight(.semibold))
                }
                .disabled(coding.selectedRepoId == nil)
                Button { showPromptHistory = true } label: {
                    Label("Recent", systemImage: "clock")
                        .font(.caption.weight(.semibold))
                }
                .disabled(coding.selectedRepoId == nil || coding.promptHistory.isEmpty)
                Spacer()
                Button {
                    saveTemplateTitle = String(coding.draft.prefix(40))
                    showSaveTemplate = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.caption)
                }
                .disabled(coding.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            #if canImport(UIKit)
            if !coding.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(coding.pendingImages) { attachment in
                            ZStack(alignment: .topTrailing) {
                                if let image = UIImage(data: attachment.data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button {
                                    coding.removeImage(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.75))
                                }
                                .offset(x: 5, y: -5)
                                .accessibilityLabel("Remove image")
                            }
                            .padding(.top, 5)
                        }
                    }
                }
            }
            #endif

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    ForEach(CodingAgentMode.allCases) { mode in
                        Button {
                            coding.selectedAgentMode = mode
                        } label: {
                            if mode == coding.selectedAgentMode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Label(mode.title, systemImage: mode.systemImage)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: coding.selectedAgentMode.systemImage)
                        Text(coding.selectedAgentMode.title)
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel("Coding mode, \(coding.selectedAgentMode.title). \(coding.selectedAgentMode.subtitle)")
                .accessibilityValue(coding.selectedAgentMode.title)

                #if canImport(UIKit)
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: max(1, 4 - coding.pendingImages.count),
                    matching: .images
                ) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                }
                .disabled(coding.pendingImages.count >= 4)
                .accessibilityLabel("Attach screenshot")
                .onChange(of: selectedPhotoItems) { _, items in
                    guard !items.isEmpty else { return }
                    Task { await importPhotos(items) }
                }
                #endif

                TextField(composerPlaceholder, text: $coding.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await coding.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(
                    coding.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && coding.pendingImages.isEmpty
                )
            }
        }
        .disabled(!coding.isCodeViewSessionActive)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var composerPlaceholder: String {
        switch coding.selectedAgentMode {
        case .agent: return "Prompt… or /ask a question"
        case .plan: return "Describe what to plan…"
        case .ask: return "Ask about this repo…"
        case .debug: return "Describe the bug or paste an error…"
        }
    }

    #if canImport(UIKit)
    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        for item in items.prefix(max(0, 4 - coding.pendingImages.count)) {
            guard let original = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: original),
                  let compressed = Self.compressedPromptImage(image)
            else {
                continue
            }
            coding.addImage(
                data: compressed.data,
                mimeType: compressed.mimeType,
                width: compressed.width,
                height: compressed.height
            )
        }
    }

    /// Keep screenshot text readable while bounding JSON/base64 request size.
    private static func compressedPromptImage(
        _ image: UIImage
    ) -> (data: Data, mimeType: String, width: Int, height: Int)? {
        let maxDimension: CGFloat = 2_048
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(sourceSize.width, sourceSize.height))
        let size = CGSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        // PNG preserves small error text. Fall back to high-quality JPEG when
        // the PNG would exceed the bridge's 3 MB per-image limit.
        if let png = resized.pngData(), png.count <= 3_000_000 {
            return (png, "image/png", Int(size.width), Int(size.height))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.88),
              jpeg.count <= 3_000_000
        else { return nil }
        return (jpeg, "image/jpeg", Int(size.width), Int(size.height))
    }
    #endif

    @ViewBuilder
    private func previewAccessBanner(_ preview: BridgePreviewInfo) -> some View {
        let isRemote = preview.isRemoteAccess
        VStack(alignment: .leading, spacing: 4) {
            Label(
                isRemote
                    ? (preview.remoteVia == "tailscale"
                       ? "Remote preview via Tailscale"
                       : "Remote preview (bridge proxy)")
                    : "Same Wi‑Fi preview",
                systemImage: isRemote ? "network" : "wifi"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isRemote ? Color.orange : Color.secondary)
            if let hint = preview.accessHint, !hint.isEmpty {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !isRemote {
                Text("Safari opens a LAN port on the bridge PC. Away from home, use Tailscale on the phone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let lan = preview.lanUrl, isRemote, lan != preview.url {
                HStack(spacing: 8) {
                    Text(lan)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Copy LAN") {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = lan
                        #endif
                        coding.noteStatus("LAN preview URL copied")
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                if !coding.favoriteRepositories.isEmpty {
                    Section("Favorites") {
                        ForEach(coding.favoriteRepositories) { repo in
                            repoPickerRow(repo)
                        }
                    }
                }
                Section("Allowlisted repositories") {
                    if coding.repositories.isEmpty {
                        if !coding.statusMessage.isEmpty {
                            Text(coding.statusMessage)
                                .foregroundStyle(.red)
                        } else {
                            Text("No local repos under bridge roots yet. Clone one, create a project, or add roots in nova-bridge `.env` (`NOVA_REPO_ROOTS`).")
                                .foregroundStyle(.secondary)
                        }
                    } else if coding.filteredRepositories.isEmpty {
                        if coding.repoSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("All matching repos are in Favorites.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No repositories match “\(coding.repoSearchQuery)”.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(coding.filteredRepositories) { repo in
                            repoPickerRow(repo)
                        }
                    }
                }
            }
            .searchable(text: $coding.repoSearchQuery, prompt: "Search repos")
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

    private func repoPickerRow(_ repo: BridgeRepoSummary) -> some View {
        HStack(spacing: 10) {
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
            .buttonStyle(.plain)

            Button {
                Task { await coding.toggleFavoriteRepository(repo.id) }
            } label: {
                Image(systemName: coding.isFavoriteRepository(repo.id) ? "star.fill" : "star")
                    .foregroundStyle(coding.isFavoriteRepository(repo.id) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                coding.isFavoriteRepository(repo.id) ? "Remove favorite" : "Add favorite"
            )
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
                        .submitLabel(.go)
                        .onSubmit {
                            Task { await runCloneFromSheet() }
                        }
                } footer: {
                    Text("Uses the bridge PC’s existing GitHub CLI authentication. Only https://github.com/owner/repo URLs are accepted. If this repo is already on the PC, pick it from Repositories instead of cloning again.")
                }

                if coding.isRefreshingRepo {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Cloning…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !coding.statusMessage.isEmpty,
                          !coding.statusMessage.hasPrefix("Selected "),
                          !coding.statusMessage.hasPrefix("Cloned ")
                {
                    Section {
                        Text(coding.statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
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
                        Task { await runCloneFromSheet() }
                    }
                    .disabled(coding.cloneURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coding.isRefreshingRepo)
                }
            }
        }
    }

    private func runCloneFromSheet() async {
        let ok = await coding.cloneRepository()
        if ok {
            showClone = false
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
                Section("Agent paths to publish") {
                    if let status = coding.repoStatus {
                        LabeledContent("Branch now", value: status.branch)
                    }
                    let paths = coding.defaultPublishPaths()
                    if paths.isEmpty {
                        Text("No agent changes left to publish.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(paths, id: \.self) { path in
                            Text(path)
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
                    .disabled(
                        coding.isPublishing
                            || coding.defaultPublishPaths().isEmpty
                    )
                }
            }
            .onAppear { coding.preparePublishDraft() }
        }
    }

    private var promptHistorySheet: some View {
        NavigationStack {
            List {
                if coding.promptHistory.isEmpty {
                    Text("No recent prompts for this repository.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coding.promptHistory) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                showPromptHistory = false
                                Task { await coding.openHistoryEntry(entry) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.text)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(4)
                                    HStack(spacing: 8) {
                                        Text(entry.sentAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if entry.hasReviewableTranscript {
                                            Text("Tap to review")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("No saved chat yet")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 16) {
                                Button("Edit in composer") {
                                    coding.editHistoryEntry(entry)
                                    showPromptHistory = false
                                }
                                .font(.caption.weight(.semibold))
                                Button("Run again") {
                                    showPromptHistory = false
                                    Task { await coding.runHistoryEntry(entry) }
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Recent prompts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showPromptHistory = false }
                }
            }
        }
    }

    private var templatesSheet: some View {
        NavigationStack {
            List {
                Section("Built-in") {
                    ForEach(coding.builtInTemplates, id: \.title) { template in
                        Button {
                            coding.applyTemplate(template.body)
                            showTemplates = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.title)
                                    .foregroundStyle(.primary)
                                Text(template.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                Section("Saved for this repo") {
                    if coding.savedTemplates.isEmpty {
                        Text("No saved templates yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coding.savedTemplates) { template in
                            Button {
                                coding.applyTemplate(template.body)
                                showTemplates = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.title)
                                        .foregroundStyle(.primary)
                                    Text(template.body)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task { await coding.deleteTemplate(template) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showTemplates = false }
                }
            }
        }
    }

    private var sessionPicker: some View {
        NavigationStack {
            List {
                Section {
                    Button("End session", role: .destructive) {
                        Task {
                            await coding.endSession()
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

/// m:ss elapsed readout that ticks once per second while a run is active.
private struct ElapsedTimeText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "· %d:%02d", seconds / 60, seconds % 60))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Compact “last event Ns ago” that ticks while a coding run is active.
private struct LastEventAgeText: View {
    let since: Date
    var prefix: String = "· last "

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text("\(prefix)\(Self.format(seconds)) ago")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static func format(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let rem = seconds % 60
        return String(format: "%d:%02d", minutes, rem)
    }
}

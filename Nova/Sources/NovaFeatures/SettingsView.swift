import SwiftUI
import Charts
import NovaCore
import NovaDomain
#if canImport(UIKit)
import UIKit
#endif

/// Settings sheet: conversation prefs, Nova Bridge, diagnostics, about.
public struct SettingsView: View {
    @Bindable var settings: SettingsViewModel
    @Bindable var conversation: ConversationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var bridgeProfileEditor: BridgeProfileEditor?
    @State private var bridgeProfileName = ""

    public init(settings: SettingsViewModel, conversation: ConversationViewModel) {
        self.settings = settings
        self.conversation = conversation
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Follow-up suggestion chips", isOn: Binding(
                        get: { settings.followUpSuggestionsEnabled },
                        set: { value in Task { await settings.setFollowUpSuggestionsEnabled(value) } }
                    ))
                    Toggle("Speak follow-up suggestions", isOn: Binding(
                        get: { settings.spokenFollowUps },
                        set: { value in Task { await settings.setSpokenFollowUps(value) } }
                    ))
                    .disabled(!settings.followUpSuggestionsEnabled)
                    Toggle("Web search", isOn: Binding(
                        get: { settings.webSearchEnabled },
                        set: { value in Task { await settings.setWebSearchEnabled(value) } }
                    ))
                    Toggle("Local wake word first (save Realtime cost)", isOn: Binding(
                        get: { settings.useLocalWakeWord },
                        set: { value in Task { await settings.setUseLocalWakeWord(value) } }
                    ))
                    Toggle("Visual memory", isOn: Binding(
                        get: { settings.visualMemoryEnabled },
                        set: { value in Task { await settings.setVisualMemoryEnabled(value) } }
                    ))
                    Toggle("Meeting cloud transcription", isOn: Binding(
                        get: { settings.meetingCloudProcessingEnabled },
                        set: { value in Task { await settings.setMeetingCloudProcessingEnabled(value) } }
                    ))
                } header: {
                    Text("Cost & privacy")
                } footer: {
                    Text("Defaults favor lower spend: follow-ups, web search, and meeting cloud off; local wake word on for idle mode. Tapping Listen opens the voice Realtime session; typed chat works separately without enabling Listen. ChatGPT Plus does not cover these API calls — they bill your OpenAI API key.")
                }

                Section {
                    if let spend = settings.billingSpend {
                        HStack {
                            Text(spend.periodLabel)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(Self.formatUSD(spend.totalUSD))
                                .font(.title3.monospacedDigit().weight(.bold))
                        }
                        if spend.lineItems.isEmpty {
                            Text("No billed usage yet this month.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Chart(spend.chartItems()) { item in
                                BarMark(
                                    x: .value("USD", item.amountUSD),
                                    y: .value("API", item.name)
                                )
                                .foregroundStyle(.orange.gradient)
                            }
                            .chartXAxis {
                                AxisMarks(format: .currency(code: "USD"))
                            }
                            .frame(height: CGFloat(max(120, spend.chartItems().count * 28)))
                            .padding(.vertical, 4)

                            ForEach(spend.lineItems.prefix(12)) { item in
                                HStack {
                                    Text(item.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(Self.formatUSD(item.amountUSD))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else if settings.isLoadingBillingSpend {
                        HStack {
                            ProgressView()
                            Text("Loading OpenAI spend…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if !settings.hasOpenAIAdminKey {
                        Text("Paste an OpenAI Admin API key to show this month’s org spend by product.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !settings.billingSpendError.isEmpty {
                        Text(settings.billingSpendError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SecureField("OpenAI Admin API key (sk-admin-…)", text: $settings.openAIAdminKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Save Admin key") {
                            Task { await settings.saveOpenAIAdminKey() }
                        }
                        .disabled(settings.openAIAdminKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if settings.hasOpenAIAdminKey {
                            Button("Clear", role: .destructive) {
                                Task { await settings.clearOpenAIAdminKey() }
                            }
                        }
                        Spacer()
                        Button {
                            Task { await settings.refreshBillingSpend(force: true) }
                        } label: {
                            if settings.isLoadingBillingSpend {
                                ProgressView()
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(!settings.hasOpenAIAdminKey || settings.isLoadingBillingSpend)
                    }
                } header: {
                    Text("OpenAI spend")
                } footer: {
                    Text("Uses OpenAI’s organization Costs API for the current calendar month, grouped by line item. Requires an org Admin key — project keys cannot read billing. Key stays in Keychain on this device.")
                }

                Section {
                    Stepper(value: $settings.voiceRetentionDays, in: 0...365) {
                        Text(settings.voiceRetentionDays == 0
                              ? "Voice recordings: keep forever"
                              : "Voice recordings: \(settings.voiceRetentionDays) days")
                    }
                    Stepper(value: $settings.videoRetentionDays, in: 0...365) {
                        Text(settings.videoRetentionDays == 0
                              ? "Video recordings: keep forever"
                              : "Video recordings: \(settings.videoRetentionDays) days")
                    }
                    Stepper(value: $settings.visualMemoryRetentionDays, in: 0...365) {
                        Text(settings.visualMemoryRetentionDays == 0
                              ? "Visual memory: keep forever"
                              : "Visual memory: \(settings.visualMemoryRetentionDays) days")
                    }
                    Button("Save retention") {
                        Task { await settings.saveRetention() }
                    }
                } header: {
                    Text("Retention")
                } footer: {
                    Text("Older items are pruned on next app launch after you save.")
                }

                Section {
                    TextField("http://your-mac.local:8787", text: $settings.bridgeBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Bridge token", text: $settings.bridgeToken)
                    Button {
                        Task { await settings.scanForLocalBridge() }
                    } label: {
                        HStack {
                            Label("Find bridge on local network", systemImage: "wifi")
                            if settings.bridgeScanning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(settings.bridgeScanning || settings.bridgeChecking)
                    Button {
                        Task { await settings.saveBridge() }
                    } label: {
                        HStack {
                            Text("Save & run setup check")
                            if settings.bridgeChecking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(settings.bridgeChecking)
                    if !settings.bridgeStatus.isEmpty {
                        Text(settings.bridgeStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(settings.bridgeProfiles) { profile in
                        bridgeProfileRow(profile)
                    }

                    Button {
                        bridgeProfileName = ""
                        bridgeProfileEditor = .save
                    } label: {
                        Label("Save current as profile…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Nova Bridge")
                } footer: {
                    Text("Claude Code, Cursor, Realtime tokens, and repository clone/status/PR flow go through the bridge. Pick repositories in the Coding tab (opaque repo ids) — do not send absolute paths from the phone.")
                }

                Section {
                    HStack {
                        Text("Setup checklist")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(settings.bridgeSetupReadyCount)/\(settings.bridgeSetupSteps.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(settings.bridgeSetupSteps) { step in
                        bridgeSetupRow(step)
                    }
                    if let next = settings.bridgeSetupNextAction {
                        Text("Next: \(next)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        Task { await settings.refreshBridgeHealth() }
                    } label: {
                        Label("Re-check bridge", systemImage: "stethoscope")
                    }
                    .disabled(settings.bridgeChecking || settings.bridgeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Bridge setup")
                } footer: {
                    Text("Work top to bottom until Coding tools respond. Missing Cursor/OpenAI keys are configured on the PC in nova-bridge/.env, not in the app.")
                }

                Section {
                    Toggle(
                        "Open preview in Safari when ready",
                        isOn: Binding(
                            get: { settings.codingAutoOpenPreview },
                            set: { enabled in
                                Task { await settings.setCodingAutoOpenPreview(enabled) }
                            }
                        )
                    )
                } header: {
                    Text("Coding")
                } footer: {
                    Text("When enabled, a newly started preview opens in Safari exactly once as soon as it becomes ready. Away from home, keep Tailscale connected so remote preview URLs (Tailscale IP or bridge proxy) open correctly.")
                }

                Section {
                    HStack {
                        Text("Latency gate")
                        Spacer()
                        Text(conversation.latencyGateStatus)
                            .foregroundStyle(gateColor)
                            .fontWeight(.semibold)
                    }
                    if !conversation.latencyGateDetail.isEmpty {
                        Text(conversation.latencyGateDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if conversation.latencyHint.isEmpty {
                        Text("No samples yet — start a conversation to collect timing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(conversation.latencyHint)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if !conversation.usageHint.isEmpty {
                        Text(conversation.usageHint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh") {
                        conversation.refreshLatency()
                        conversation.refreshUsage()
                    }
                    #if DEBUG
                    Button("Copy latency JSON") {
                        let data = conversation.exportLatencyJSON()
                        if let text = String(data: data, encoding: .utf8) {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = text
                            #endif
                        }
                    }
                    #endif
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Gate: mic→WS p95 < 40ms and schedule p95 < 50ms (needs ≥5 samples each). Spend is an estimate only.")
                }

                Section("About") {
                    NavigationLink {
                        PatchNotesContent()
                    } label: {
                        Label("Patch Notes", systemImage: "sparkles")
                    }
                    LabeledContent("Build", value: NovaBuildStamp.id)
                    LabeledContent("Bundle", value: PatchNotesView.bundleVersion())
                    Text("Paste the Build line in chat when reporting Listen issues. (AltStore often rewrites Bundle to 1.0.)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Bridge profile",
                isPresented: Binding(
                    get: { bridgeProfileEditor != nil },
                    set: { if !$0 { bridgeProfileEditor = nil } }
                ),
                presenting: bridgeProfileEditor
            ) { editor in
                TextField("Name (e.g. Home, VPN)", text: $bridgeProfileName)
                    .textInputAutocapitalization(.words)
                Button(editor.actionTitle) {
                    let name = bridgeProfileName
                    bridgeProfileName = ""
                    Task {
                        switch editor {
                        case .save:
                            await settings.saveBridgeProfile(name: name)
                        case .rename(let profile):
                            await settings.renameBridgeProfile(profile, to: name)
                        }
                    }
                }
                .disabled(bridgeProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { bridgeProfileName = "" }
            } message: { editor in
                Text(editor.message)
            }
            .task { await settings.load() }
        }
    }

    private static func formatUSD(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...3)))
    }

    private func bridgeSetupRow(_ step: BridgeSetupStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: bridgeSetupSymbol(step.state))
                .foregroundStyle(bridgeSetupColor(step.state))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.medium))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(step.state.rawValue)")
        .accessibilityHint(step.detail)
    }

    private func bridgeSetupSymbol(_ state: BridgeSetupStep.State) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        }
    }

    private func bridgeSetupColor(_ state: BridgeSetupStep.State) -> Color {
        switch state {
        case .ready: return .green
        case .missing: return .orange
        case .pending: return .secondary
        }
    }

    private func bridgeProfileRow(_ profile: BridgeProfile) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await settings.applyBridgeProfile(profile) }
            } label: {
                HStack(spacing: 10) {
                    let isActive = settings.activeBridgeProfileID == profile.id
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                        Text(profile.baseURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(settings.bridgeChecking || settings.bridgeScanning)

            Menu {
                profileRenameButton(profile)
                profileRemoveButton(profile)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            .accessibilityLabel("Manage \(profile.name) profile")
        }
        .swipeActions(edge: .trailing) {
            profileRemoveButton(profile)
            profileRenameButton(profile)
                .tint(.blue)
        }
    }

    private func profileRenameButton(_ profile: BridgeProfile) -> some View {
        Button {
            bridgeProfileName = profile.name
            bridgeProfileEditor = .rename(profile)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
    }

    private func profileRemoveButton(_ profile: BridgeProfile) -> some View {
        Button(role: .destructive) {
            Task { await settings.deleteBridgeProfile(profile) }
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private var gateColor: Color {
        switch conversation.latencyGateStatus {
        case "Pass": return .green
        case "Fail": return .red
        default: return .secondary
        }
    }
}

private enum BridgeProfileEditor: Identifiable {
    case save
    case rename(BridgeProfile)

    var id: String {
        switch self {
        case .save: return "save"
        case .rename(let profile): return "rename-\(profile.id)"
        }
    }

    var actionTitle: String {
        switch self {
        case .save: return "Save"
        case .rename: return "Rename"
        }
    }

    var message: String {
        switch self {
        case .save:
            return "Saves the current bridge URL and token for one-tap switching."
        case .rename:
            return "Enter a new name for this saved connection."
        }
    }
}

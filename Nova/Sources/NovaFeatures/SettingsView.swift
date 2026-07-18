import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Settings sheet: conversation prefs, Nova Bridge, diagnostics, about.
public struct SettingsView: View {
    @Bindable var settings: SettingsViewModel
    @Bindable var conversation: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

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
                    Text("Disabling follow-ups or web search avoids paid API calls. Local wake word keeps Realtime closed until you say Nova.")
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
                        Task { await settings.saveBridge() }
                    } label: {
                        HStack {
                            Text("Save & test connection")
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
                    if let openai = settings.openaiConfigured {
                        LabeledContent("Realtime mint") {
                            Text(openai ? "Ready" : "Missing key")
                                .foregroundStyle(openai ? .green : .red)
                        }
                    }
                    if let cursor = settings.cursorConfigured {
                        LabeledContent("Cursor") {
                            Text(cursor ? "Ready" : "Missing key")
                                .foregroundStyle(cursor ? .green : .orange)
                        }
                    }
                } header: {
                    Text("Nova Bridge")
                } footer: {
                    Text("Claude Code, Cursor, Realtime tokens, and repository clone/status/PR flow go through the bridge. Pick repositories in the Coding tab (opaque repo ids) — do not send absolute paths from the phone.")
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
                    Text("When enabled, a newly started preview opens in Safari exactly once as soon as it becomes ready.")
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
                    LabeledContent("Version", value: PatchNotesView.bundleVersion())
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await settings.load() }
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

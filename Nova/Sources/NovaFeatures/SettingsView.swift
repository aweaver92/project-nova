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
                    Toggle("Speak follow-up suggestions", isOn: Binding(
                        get: { settings.spokenFollowUps },
                        set: { value in Task { await settings.setSpokenFollowUps(value) } }
                    ))
                } header: {
                    Text("Conversation")
                } footer: {
                    Text("When on, after each reply Nova also offers one suggested next step out loud. Chips still appear either way.")
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
                } header: {
                    Text("Nova Bridge")
                } footer: {
                    Text("Claude Code, Cursor, and Realtime token minting go through the bridge on your machine. Use a full URL (http:// or https://) and the token from the bridge .env.")
                }

                Section {
                    if conversation.latencyHint.isEmpty {
                        Text("No samples yet — start a conversation to collect timing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(conversation.latencyHint)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button("Refresh") {
                        conversation.refreshLatency()
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
                    Text("Mic→WS, speech-end→first audio, schedule, barge-in, plus drop/reconnect counters.")
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
}

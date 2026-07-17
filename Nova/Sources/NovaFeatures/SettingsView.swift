import SwiftUI

/// Settings tab: user preferences that tune Nova's behavior.
public struct SettingsView: View {
    @Bindable var settings: SettingsViewModel

    public init(settings: SettingsViewModel) {
        self.settings = settings
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
                    Text("When on, after each reply Nova also offers one suggested next step out loud. Suggestion chips still appear either way.")
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
            .task { await settings.load() }
        }
    }
}

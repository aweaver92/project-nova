import SwiftUI
import NovaDomain

/// Compact shared UI primitives for the power-user shell.
enum NovaUI {
    /// Horizontal status chips used on the Assistant HUD.
    struct StatusChip: View {
        let title: String
        let value: String
        let color: Color

        var body: some View {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text("\(title): \(value)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    /// Voice Listen controls for specialist main screens (same session as Assistant).
    /// Gates on bridge Realtime mint, shows compact listen health, and Interrupt.
    /// Tap the bar (outside Toggle / Interrupt) to expand or collapse; condensed is default.
    struct AgentVoiceChatBar: View {
        @Bindable var conversation: ConversationViewModel
        /// When true, Listen would fail until bridge has OPENAI_API_KEY (same as Assistant).
        var realtimeMintBlocked: Bool = false
        var onOpenSettings: (() -> Void)? = nil

        @State private var showRealtimeWarning = false
        /// Shared across agent screens; false = condensed (default).
        @AppStorage("nova.agentVoiceChatBar.expanded") private var isExpanded = false

        var body: some View {
            VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: conversation.isRunning ? "mic.fill" : "mic.slash")
                                .foregroundStyle(micIconColor)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isExpanded ? "Voice chat" : condensedTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if isExpanded {
                                    Text(statusCaption)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }

                            Spacer(minLength: 4)

                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse voice chat" : "Expand voice chat")

                    Button {
                        Task { await conversation.bargeIn() }
                    } label: {
                        Image(systemName: "hand.raised")
                            .frame(minWidth: 36, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!conversation.isRunning)
                    .accessibilityLabel("Interrupt")

                    Toggle(
                        "Voice chat",
                        isOn: Binding(
                            get: { conversation.isRunning },
                            set: { enabled in
                                Task { await setVoiceEnabled(enabled) }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.accentColor)
                }

                if isExpanded {
                    if showsHealthStrip {
                        healthStrip
                    }

                    if let error = conversation.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if conversation.isRunning {
                    // Slim meter so condensed mode still shows mic activity.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(healthColor.opacity(0.85))
                                .frame(width: max(3, geo.size.width * CGFloat(min(1, conversation.listenHealth.micLevel * 4))))
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, isExpanded ? 10 : 8)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .alert("Realtime unavailable", isPresented: $showRealtimeWarning) {
                if let onOpenSettings {
                    Button("Open Settings", action: onOpenSettings)
                }
                Button("Start anyway") {
                    Task { await conversation.start() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Bridge health reports OPENAI_API_KEY missing. Restart nova-bridge after adding the key, or open Settings to re-test.")
            }
        }

        private var condensedTitle: String {
            if conversation.isRunning {
                return conversation.listenHealth.statusLabel
            }
            if realtimeMintBlocked {
                return "Voice · blocked"
            }
            return "Voice chat"
        }

        private var statusCaption: String {
            if conversation.isRunning {
                let label = conversation.listenHealth.statusLabel
                let route = conversation.listenHealth.inputRoute
                if route != "—" && !route.isEmpty {
                    return "\(label) · \(route)"
                }
                return "\(label) — same session as Assistant"
            }
            if realtimeMintBlocked {
                return "Realtime blocked — bridge missing OPENAI_API_KEY"
            }
            return "Off — tap to talk with the active agent"
        }

        private var showsHealthStrip: Bool {
            conversation.isRunning
                || conversation.listenHealth.phase == .connecting
                || conversation.listenHealth.phase == .awaitingWakeWord
        }

        private var healthStrip: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(healthColor)
                        .frame(width: 7, height: 7)
                    Text(conversation.listenHealth.statusLabel)
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(conversation.listenHealth.inputRoute)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(healthColor.opacity(0.85))
                            .frame(width: max(4, geo.size.width * CGFloat(min(1, conversation.listenHealth.micLevel * 4))))
                    }
                }
                .frame(height: 6)
                if !conversation.listenHealth.detail.isEmpty {
                    Text(conversation.listenHealth.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var micIconColor: Color {
            if !conversation.isRunning { return .secondary }
            return healthColor
        }

        private var healthColor: Color {
            switch conversation.listenHealth.phase {
            case .hearingYou, .speaking: return .green
            case .waitingForSpeech, .connecting: return .orange
            case .awaitingWakeWord: return .purple
            case .micSilent, .streamStalled, .cloudQuiet, .error: return .red
            case .idle: return .secondary
            }
        }

        private func setVoiceEnabled(_ enabled: Bool) async {
            if enabled {
                if realtimeMintBlocked {
                    showRealtimeWarning = true
                } else {
                    await conversation.start()
                }
            } else {
                await conversation.stop()
            }
        }
    }

    /// Confirmation alert for destructive bulk clears.
    struct ClearConfirmModifier: ViewModifier {
        @Binding var isPresented: Bool
        let title: String
        let message: String
        let confirmTitle: String
        let onConfirm: () -> Void

        func body(content: Content) -> some View {
            content
                .alert(title, isPresented: $isPresented) {
                    Button("Cancel", role: .cancel) {}
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                } message: {
                    Text(message)
                }
        }
    }
}

extension View {
    func novaConfirmClear(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmTitle: String = "Delete All",
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(NovaUI.ClearConfirmModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            onConfirm: onConfirm
        ))
    }
}

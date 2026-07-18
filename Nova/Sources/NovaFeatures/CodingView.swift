import SwiftUI
import NovaDomain
#if canImport(UIKit)
import UIKit
#endif

public struct CodingView: View {
    @Bindable var coding: CodingViewModel
    var embedded: Bool
    @State private var showSessions = false

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
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New session") {
                        Task { await coding.startNewSession() }
                    }
                    Button("Refresh") {
                        Task { await coding.refreshSessions() }
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
        .sheet(isPresented: $showSessions) {
            sessionPicker
        }
        .task { await coding.load() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !coding.statusMessage.isEmpty && coding.items.isEmpty {
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

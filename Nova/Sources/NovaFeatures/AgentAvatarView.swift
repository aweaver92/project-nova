import SwiftUI
import NovaDomain
#if canImport(UIKit)
import UIKit
#endif

/// Circular agent portrait with amplitude-driven “talking” motion.
public struct AgentAvatarView: View {
    public let agent: Agent
    public var isSpeaking: Bool
    public var audioLevel: Float
    public var size: CGFloat

    @State private var smoothed: Float = 0
    @State private var breathe = false

    public init(
        agent: Agent,
        isSpeaking: Bool = false,
        audioLevel: Float = 0,
        size: CGFloat = 56
    ) {
        self.agent = agent
        self.isSpeaking = isSpeaking
        self.audioLevel = audioLevel
        self.size = size
    }

    private var talking: Bool {
        AssistantTalkMeter.isVisiblyTalking(
            smoothedLevel: smoothed,
            assistantSpeaking: isSpeaking
        )
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(palette.opacity(0.22))
            portrait
                .frame(width: size * 0.92, height: size * 0.92)
                .clipShape(Circle())
            Circle()
                .strokeBorder(palette.opacity(talking ? 0.85 : 0.25), lineWidth: talking ? 3 : 1.5)
                .scaleEffect(1 + CGFloat(smoothed) * 0.12)
            if talking {
                Capsule()
                    .fill(palette.opacity(0.9))
                    .frame(
                        width: size * (0.18 + CGFloat(smoothed) * 0.22),
                        height: size * (0.04 + CGFloat(smoothed) * 0.08)
                    )
                    .offset(y: size * 0.28)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(talking ? 1.04 : (breathe ? 1.02 : 1.0))
        .animation(.easeInOut(duration: 0.08), value: smoothed)
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)
        .onAppear { breathe = true }
        .onChange(of: audioLevel) { _, level in
            smoothed = AssistantTalkMeter.smooth(previous: smoothed, sample: level)
        }
        .onChange(of: isSpeaking) { _, speaking in
            if !speaking {
                smoothed = AssistantTalkMeter.smooth(previous: smoothed, sample: 0, release: 0.35)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(talking ? "\(agent.name), speaking" : agent.name)
    }

    @ViewBuilder
    private var portrait: some View {
        if let name = agent.resolvedAvatarAssetName, hasCatalogImage(name) {
            Image(name)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [palette, palette.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: agent.systemImage)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func hasCatalogImage(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(named: name) != nil
        #else
        false
        #endif
    }

    private var palette: Color {
        switch agent.id {
        case Agent.SeedID.nova: return Color(red: 0.35, green: 0.45, blue: 0.95)
        case Agent.SeedID.claude: return Color(red: 0.85, green: 0.45, blue: 0.25)
        case Agent.SeedID.max: return Color(red: 0.9, green: 0.25, blue: 0.3)
        case Agent.SeedID.sage: return Color(red: 0.3, green: 0.65, blue: 0.4)
        case Agent.SeedID.remy: return Color(red: 0.95, green: 0.55, blue: 0.2)
        case Agent.SeedID.scholar: return Color(red: 0.45, green: 0.35, blue: 0.75)
        case Agent.SeedID.ivy: return Color(red: 0.25, green: 0.7, blue: 0.45)
        default: return Color.accentColor
        }
    }
}

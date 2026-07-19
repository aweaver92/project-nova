import ActivityKit
import SwiftUI
import WidgetKit
import NovaLiveActivity

private let terracotta = Color(red: 0.80, green: 0.40, blue: 0.20)

/// Remy's cook-mode Live Activity — current step + optional running timer.
struct CookStepLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookStepAttributes.self) { context in
            CookLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(terracotta)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Step \(context.state.stepIndex + 1)/\(context.state.stepCount)")
                    } icon: {
                        Image(systemName: "frying.pan.fill").foregroundStyle(terracotta)
                    }
                    .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let endsAt = context.state.timerEndsAt {
                        CountdownText(endsAt: endsAt)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(terracotta)
                            .frame(width: 66)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.stepText)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "frying.pan.fill").foregroundStyle(terracotta)
            } compactTrailing: {
                if let endsAt = context.state.timerEndsAt {
                    CountdownText(endsAt: endsAt)
                        .foregroundStyle(terracotta)
                        .frame(width: 44)
                } else {
                    Text("\(context.state.stepIndex + 1)/\(context.state.stepCount)")
                        .foregroundStyle(terracotta)
                }
            } minimal: {
                Image(systemName: "frying.pan.fill").foregroundStyle(terracotta)
            }
            .keylineTint(terracotta)
        }
    }
}

private struct CookLockScreenView: View {
    let context: ActivityViewContext<CookStepAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.recipeTitle, systemImage: "frying.pan.fill")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(terracotta)
                    .lineLimit(1)
                Spacer()
                Text("Step \(context.state.stepIndex + 1) of \(context.state.stepCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                Text(context.state.stepText)
                    .font(.headline)
                    .lineLimit(3)
                Spacer(minLength: 0)
                if let endsAt = context.state.timerEndsAt {
                    CountdownText(endsAt: endsAt)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(terracotta)
                }
            }
        }
        .padding()
    }
}

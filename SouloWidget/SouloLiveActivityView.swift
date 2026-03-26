import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Lock Screen Banner

struct SouloLiveActivityView: View {
    let context: ActivityViewContext<SouloLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.keyword)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(context.state.platformName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("Soulo")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Compact Views

struct SouloLiveActivityCompactLeadingView: View {
    let context: ActivityViewContext<SouloLiveActivityAttributes>

    var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.indigo)
    }
}

struct SouloLiveActivityCompactTrailingView: View {
    let context: ActivityViewContext<SouloLiveActivityAttributes>

    var body: some View {
        Text(context.state.keyword)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct SouloLiveActivityMinimalView: View {
    let context: ActivityViewContext<SouloLiveActivityAttributes>

    var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.indigo)
    }
}

// MARK: - Widget

struct SouloLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SouloLiveActivityAttributes.self) { context in
            SouloLiveActivityView(context: context)
                .activityBackgroundTint(.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.indigo)
                        Text("Soulo")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.platformName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.keyword)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                SouloLiveActivityCompactLeadingView(context: context)
            } compactTrailing: {
                SouloLiveActivityCompactTrailingView(context: context)
            } minimal: {
                SouloLiveActivityMinimalView(context: context)
            }
            .keylineTint(.indigo)
        }
    }
}

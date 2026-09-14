import WidgetKit
import SwiftUI

@main
struct SouloWidgetBundle: WidgetBundle {
    var body: some Widget {
        SouloFilesWidget()
        SouloLiveActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            SouloSearchControl()
            SouloPrivateSearchControl()
            SouloDownloadsControl()
        }
    }
}

private struct FilesEntry: TimelineEntry { let date: Date }

private struct FilesProvider: TimelineProvider {
    func placeholder(in context: Context) -> FilesEntry { FilesEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (FilesEntry) -> Void) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FilesEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

struct SouloFilesWidget: Widget {
    // Retain the identifier so existing Home Screen widgets upgrade in place.
    let kind = "com.dkluge.Soulo.bookshelf"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FilesProvider()) { _ in
            FilesWidgetView()
                .containerBackground(for: .widget) { FilesGlassBackground() }
                .widgetURL(URL(string: "soulo://files"))
        }
        .configurationDisplayName("library_files_tab")
        .description(Text("files_widget_hint", tableName: "ReadingTools"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct FilesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
                    .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
                    .widgetAccentable()
                Spacer(minLength: 6)
                Text("library_files_tab").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                HStack {
                    Text("Soulo").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                }
            }
            if family == .systemMedium {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.blue.opacity(0.12))
                        .frame(width: 108, height: 106).rotationEffect(.degrees(-8))
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "photo.fill").font(.title2).foregroundStyle(.blue)
                        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.18)).frame(height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.10)).frame(width: 42, height: 4)
                    }
                    .padding(16).frame(width: 100, height: 116)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
                    .rotationEffect(.degrees(5))
                }
                .accessibilityHidden(true)
            }
        }
        .padding(4)
        .accessibilityElement(children: .combine)
    }

}

/// System material adapts to light, dark, and the Home Screen's tinted/clear modes.
/// No wallpaper copies or continuously refreshed bitmap effects are needed.
private struct FilesGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(uiColor: .secondarySystemBackground)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.25), .white.opacity(0.02), .blue.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                ContainerRelativeShape()
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0.5), lineWidth: 0.75)
            }
        }
    }
}

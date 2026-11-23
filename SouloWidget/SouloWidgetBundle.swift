import WidgetKit
import SwiftUI

@main
struct SouloWidgetBundle: WidgetBundle {
    var body: some Widget {
        SouloFilesWidget()
        if #available(iOSApplicationExtension 16.1, *) { SouloLiveActivity() }
        if #available(iOSApplicationExtension 18.0, *) {
            SouloSearchControl()
            SouloPrivateSearchControl()
            SouloDownloadsControl()
        }
    }
}

private struct FilesEntry: TimelineEntry {
    let date: Date
    let wallpaper: UIImage?
}

private struct FilesProvider: TimelineProvider {
    func placeholder(in context: Context) -> FilesEntry { FilesEntry(date: .now, wallpaper: nil) }
    func getSnapshot(in context: Context, completion: @escaping (FilesEntry) -> Void) { completion(currentEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FilesEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> FilesEntry {
        FilesEntry(date: .now, wallpaper: SouloWidgetWallpaper.load().flatMap { UIImage(data: $0) })
    }
}

struct SouloFilesWidget: Widget {
    // Retain the identifier so existing Home Screen widgets upgrade in place.
    let kind = SouloWidgetWallpaper.kind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FilesProvider()) { entry in
            FilesWidgetView()
                .modifier(FilesWidgetBackground(wallpaper: entry.wallpaper))
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
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: family == .systemMedium ? 26 : 23, weight: .medium))
                .frame(width: 45, height: 43)
                .background(.white.opacity(0.17), in: RoundedRectangle(cornerRadius: 13))
                .widgetAccentable()
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            HStack(alignment: .lastTextBaseline) {
                Text("library_files_tab")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .padding(4)
        .accessibilityElement(children: .combine)
    }

}

private struct FilesWallpaperBackground: View {
    let wallpaper: UIImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.26, green: 0.36, blue: 0.53), Color(red: 0.11, green: 0.16, blue: 0.25)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                if let wallpaper {
                    Image(uiImage: wallpaper).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    LinearGradient(colors: [.black.opacity(reduceTransparency ? 0.45 : 0.31), .black.opacity(0.58)],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                }
            }
            .clipped()
        }
    }
}

private struct FilesWidgetBackground: ViewModifier {
    let wallpaper: UIImage?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { FilesWallpaperBackground(wallpaper: wallpaper) }
        } else {
            content.padding(12).background(FilesWallpaperBackground(wallpaper: wallpaper))
        }
    }
}

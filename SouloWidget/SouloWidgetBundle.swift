import WidgetKit
import SwiftUI

@main
struct SouloWidgetBundle: WidgetBundle {
    var body: some Widget {
        SouloBookshelfWidget()
        SouloLiveActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            SouloSearchControl()
            SouloPrivateSearchControl()
            SouloDownloadsControl()
        }
    }
}

private struct BookshelfEntry: TimelineEntry { let date: Date }

private struct BookshelfProvider: TimelineProvider {
    func placeholder(in context: Context) -> BookshelfEntry { BookshelfEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (BookshelfEntry) -> Void) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BookshelfEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

struct SouloBookshelfWidget: Widget {
    let kind = "com.dkluge.Soulo.bookshelf"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BookshelfProvider()) { _ in
            BookshelfWidgetView()
                .containerBackground(for: .widget) { BookshelfGlassBackground() }
                .widgetURL(URL(string: "soulo://bookshelf"))
        }
        .configurationDisplayName("library_books_tab")
        .description(Text("bookshelf_hint", tableName: "ReadingTools"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct BookshelfWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
                    .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
                    .widgetAccentable()
                Spacer(minLength: 6)
                Text("library_books_tab").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                HStack {
                    Text("Soulo").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                }
            }
            if family == .systemMedium {
                HStack(alignment: .bottom, spacing: 5) {
                    book(color: Color(red: 0.25, green: 0.43, blue: 0.48), height: 94)
                    book(color: Color(red: 0.76, green: 0.48, blue: 0.31), height: 110)
                    book(color: Color(red: 0.71, green: 0.67, blue: 0.51), height: 100)
                }
                .accessibilityHidden(true)
            }
        }
        .padding(4)
        .accessibilityElement(children: .combine)
    }
    private func book(color: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(0.8).gradient)
            .frame(width: 28, height: height)
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.28), lineWidth: 0.5) }
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.4)).frame(height: 2).padding(.top, 12).padding(.horizontal, 4)
            }
    }
}

/// System material adapts to light, dark, and the Home Screen's tinted/clear modes.
/// No wallpaper copies or continuously refreshed bitmap effects are needed.
private struct BookshelfGlassBackground: View {
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

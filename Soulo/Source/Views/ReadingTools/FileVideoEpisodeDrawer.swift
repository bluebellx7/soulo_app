import SwiftUI
import UIKit

/// One episode drawer for inline and fullscreen playback, sized to leave a
/// tappable area of the video visible even on a narrow phone.
struct FileVideoEpisodeDrawer: ViewModifier {
    @Binding var isPresented: Bool
    var playlist: FileVideoPlaylist?
    var fullscreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.videoFullscreenInsets) private var windowInsets
    @State private var settingsVisible = false
    @State private var sourcesVisible = false
    @State private var closesAfterSelection = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var episodeMinimumWidth: CGFloat = 52

    func body(content: Content) -> some View {
        ZStack {
            content.allowsHitTesting(!isPresented)
            if isPresented, let playlist {
                GeometryReader { geometry in
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.38)
                            .contentShape(Rectangle())
                            .onTapGesture { isPresented = false }
                            .accessibilityHidden(true)
                        panel(playlist)
                            .padding(.top, fullscreen ? max(windowInsets.top, geometry.safeAreaInsets.top) : 0)
                            .padding(.bottom, fullscreen ? max(windowInsets.bottom, geometry.safeAreaInsets.bottom) : 0)
                            .padding(.trailing, fullscreen ? max(windowInsets.trailing, geometry.safeAreaInsets.trailing) : 0)
                            .frame(width: min(max(0, geometry.size.width - 24), min(380, max(280, geometry.size.width * 0.42))))
                            .frame(height: geometry.size.height, alignment: .top)
                            .background(fullscreen ? Color.black.opacity(0.94) : Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundStyle(fullscreen ? Color.white.opacity(0.9) : Color.primary)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("media.file.episodes.drawer")
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isPresented)
        .onAppear { updateEpisodeWidth() }
        .onCompatibleChange(of: playlist?.episodes) { _, _ in updateEpisodeWidth() }
        .onCompatibleChange(of: dynamicTypeSize) { _, _ in updateEpisodeWidth() }
        .onCompatibleChange(of: isPresented) { _, visible in
            if !visible { closesAfterSelection = false }
        }
        .onCompatibleChange(of: playlist?.selectedID) { _, selected in
            if closesAfterSelection, let selected, !selected.isEmpty {
                closesAfterSelection = false
                isPresented = false
            }
        }
        .onCompatibleChange(of: playlist?.failure) { _, failure in
            // Decoder failure can arrive after the selection drawer has closed.
            // Present the error and retry in the active fullscreen surface.
            if failure != nil { isPresented = true }
        }
        .sheet(isPresented: $settingsVisible) {
            NavigationStack { VideoSettingsView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { settingsVisible = false } }
            } }
        }
    }

    private func updateEpisodeWidth() {
        episodeMinimumWidth = EpisodeGridSizing.minimumWidth(titles: playlist?.episodes.map(\.title) ?? [],
            font: UIFont.preferredFont(forTextStyle: .subheadline))
    }

    private func panel(_ playlist: FileVideoPlaylist) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(ToolText.text("episodes")).font(.headline)
                Text("\(playlist.episodes.count)").font(.subheadline.monospacedDigit()).opacity(0.6)
                Spacer(minLength: 0)
                Button { settingsVisible = true } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(LanguageManager.shared.localizedString("settings"))
                .accessibilityIdentifier("media.file.episodes.settings")
                Button { isPresented = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(ToolText.text("close"))
                .accessibilityIdentifier("media.file.episodes.close")
            }
            .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 8)
            if playlist.sources.count > 1 {
                Button { sourcesVisible = true } label: {
                    HStack {
                        Text(playlist.sources.first { $0.id == playlist.selectedSourceID }?.title ?? ToolText.text("episodes")).lineLimit(1)
                        Spacer(); Image(systemName: "chevron.down").font(.caption)
                    }.font(.subheadline).padding(.horizontal, 20).frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("media.file.episodes.source")
                .videoMenuPopover(isPresented: $sourcesVisible) {
                    VStack(spacing: 0) {
                        ForEach(playlist.sources, id: \.id) { source in
                            Button {
                                closesAfterSelection = false
                                playlist.selectSource?(source.id); sourcesVisible = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: source.id == playlist.selectedSourceID ? "checkmark" : "").frame(width: 18)
                                    Text(source.title).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(source.title)
                        }
                    }.padding(8).frame(width: 220)
                }
            }
            if let failure = playlist.failure {
                HStack(alignment: .top, spacing: 8) {
                    Text(failure).font(.footnote).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("media.file.episodes.failure.text")
                    if let retry = playlist.retry {
                        Button(ToolText.text("retry")) {
                            closesAfterSelection = true
                            retry()
                        }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("media.file.episodes.retry")
                    }
                }
                .foregroundStyle(fullscreen ? Color.white.opacity(0.85) : .secondary)
                .padding(.horizontal, 20).padding(.bottom, 10)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("media.file.episodes.failure")
            }
            Divider().overlay(fullscreen ? Color.white.opacity(0.12) : Color.clear)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: episodeMinimumWidth), spacing: 10)], spacing: 10) {
                        ForEach(playlist.episodes) { episode in
                            let selected = episode.id == playlist.selectedID
                            let resolving = episode.id == playlist.resolvingID
                            Button {
                                guard !resolving else { return }
                                if !playlist.asynchronous || selected { isPresented = false }
                                else { closesAfterSelection = true }
                                playlist.select(episode.id)
                            } label: {
                                HStack(spacing: 5) {
                                    if resolving {
                                        ProgressView().controlSize(.mini).tint(.themePrimary)
                                            .accessibilityHidden(true)
                                    } else if selected {
                                        Image(systemName: "play.fill").font(.caption2).accessibilityHidden(true)
                                    }
                                    Text(episode.title).font(.subheadline.weight(selected || resolving ? .semibold : .regular))
                                        .lineLimit(2).truncationMode(.tail)
                                        .multilineTextAlignment(.center)
                                }
                                .foregroundStyle(selected ? Color.themePrimary : fullscreen ? Color.white.opacity(0.9) : Color.primary)
                                .padding(.horizontal, 6).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(selected ? Color.themePrimary.opacity(fullscreen ? 0.22 : 0.1)
                                            : fullscreen ? Color.white.opacity(0.08) : Color(uiColor: .tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    if resolving {
                                        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.themePrimary.opacity(0.55))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityLabel(episode.title)
                            .accessibilityValue(resolving ? ToolText.text("loading") : "")
                            .accessibilityIdentifier("media.file.episode.\(episode.id)")
                            .id(episode.id)
                        }
                    }.padding(10)
                }
                .onAppear { reader.scrollTo(playlist.selectedID, anchor: .center) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .buttonStyle(.plain)
    }
}

/// Use one width for the source, measured only when its titles or type size
/// change. Short episode numbers fit more columns; long names stay bounded.
enum EpisodeGridSizing {
    static func minimumWidth(titles: [String], font: UIFont) -> CGFloat {
        let longest = titles.reduce(CGFloat.zero) { max($0, ($1 as NSString).size(withAttributes: [.font: font]).width) }
        return min(140, max(52, ceil(longest) + 30))
    }
}

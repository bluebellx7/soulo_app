import SwiftUI

/// One episode drawer for inline and fullscreen playback, sized to leave a
/// tappable area of the video visible even on a narrow phone.
struct FileVideoEpisodeDrawer: ViewModifier {
    @Binding var isPresented: Bool
    var playlist: FileVideoPlaylist?
    var fullscreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.videoFullscreenInsets) private var windowInsets
    @State private var settingsVisible = false

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
        .sheet(isPresented: $settingsVisible) {
            NavigationStack { VideoSettingsView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { settingsVisible = false } }
            } }
        }
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
                Menu {
                    ForEach(playlist.sources, id: \.id) { source in
                        Button { playlist.selectSource?(source.id) } label: {
                            if source.id == playlist.selectedSourceID { Label(source.title, systemImage: "checkmark") }
                            else { Text(source.title) }
                        }
                    }
                } label: {
                    HStack {
                        Text(playlist.sources.first { $0.id == playlist.selectedSourceID }?.title ?? ToolText.text("episodes")).lineLimit(1)
                        Spacer(); Image(systemName: "chevron.down").font(.caption)
                    }.font(.subheadline).padding(.horizontal, 20).frame(minHeight: 44)
                }
            }
            if let failure = playlist.failure {
                Text(failure).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 10)
            }
            Divider().overlay(fullscreen ? Color.white.opacity(0.12) : Color.clear)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(playlist.episodes) { episode in
                            let selected = episode.id == playlist.selectedID
                            Button {
                                if !playlist.asynchronous { isPresented = false }
                                playlist.select(episode.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "play.fill").font(.caption)
                                        .opacity(selected ? 1 : 0).frame(width: 16)
                                    Text(episode.title).font(.subheadline.weight(selected ? .semibold : .regular))
                                        .lineLimit(2).truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if playlist.resolvingID == episode.id { ProgressView().controlSize(.small) }
                                }
                                .foregroundStyle(selected ? Color.themePrimary : fullscreen ? Color.white.opacity(0.9) : Color.primary)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .background(selected ? Color.themePrimary.opacity(fullscreen ? 0.22 : 0.1) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityLabel(episode.title)
                            .accessibilityIdentifier("media.file.episode.\(episode.id)")
                            .id(episode.id)
                        }
                    }.padding(10)
                }
                .onAppear { reader.scrollTo(playlist.selectedID, anchor: .center) }
                .onChange(of: playlist.selectedID) { _, _ in if playlist.asynchronous { isPresented = false } }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .buttonStyle(.plain)
    }
}

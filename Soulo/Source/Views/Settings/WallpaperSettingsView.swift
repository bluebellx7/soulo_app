import SwiftUI
import PhotosUI

@MainActor
struct WallpaperSettingsView: View {
    @ObservedObject var wallpaperManager = WallpaperManager.shared
    var showsFavoritesOnly = false
    var embedded = false
    @AppStorage("fav_section_collapsed") private var isFavCollapsed = false
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingAppearance: WallpaperAppearance = .light
    @State private var photoPreviews: [WallpaperAppearance: UIImage] = [:]
    @State private var photoTask: Task<Void, Never>?
    @State private var photoError: String?
    @State private var isSavingPhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var searchText = ""

    // Fullscreen state
    @State private var fullScreenContext: FullScreenContext? = nil
    @State private var wallpaperToDelete: RemoteWallpaper? = nil
    @State private var showDeleteConfirm = false

    let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        List {
            if !showsFavoritesOnly {
            // 1. Source Picker
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(WallpaperSource.allCases, id: \.self) { src in sourceTile(src) }
                    }.padding(.vertical, 10).padding(.horizontal, 4)
                }.accessibilityIdentifier("wallpaper.sources")
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            } header: { Label(LText("wallpaper_source"), systemImage: HomeToolbarAction.wallpaper.listSymbol) }

            if wallpaperManager.source.isRemote || wallpaperManager.source == .photo {
                Section {
                    Toggle(ToolText.text("wallpaper_image_overlay"), isOn: $wallpaperManager.imageOverlayEnabled)
                        .accessibilityIdentifier("wallpaper.image-overlay")
                    if wallpaperManager.imageOverlayEnabled {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(ToolText.text("wallpaper_overlay_amount"))
                                Spacer()
                                Text(wallpaperManager.imageOverlayAmount, format: .percent.precision(.fractionLength(0)))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: $wallpaperManager.imageOverlayAmount, in: 0...1)
                                .accessibilityLabel(ToolText.text("wallpaper_overlay_amount"))
                                .accessibilityIdentifier("wallpaper.overlay-amount")
                        }.padding(.vertical, 4)
                    }
                    Toggle(ToolText.text("wallpaper_image_blur"), isOn: $wallpaperManager.imageBlurEnabled)
                        .accessibilityIdentifier("wallpaper.image-blur")
                    if wallpaperManager.imageBlurEnabled {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(ToolText.text("wallpaper_blur_amount"))
                                Spacer()
                                Text(wallpaperManager.imageBlurAmount, format: .percent.precision(.fractionLength(0)))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: $wallpaperManager.imageBlurAmount, in: 0...1)
                                .accessibilityLabel(ToolText.text("wallpaper_blur_amount"))
                                .accessibilityIdentifier("wallpaper.blur-amount")
                        }.padding(.vertical, 4)
                    }
                }
            }

            if wallpaperManager.source.isRemote {
            // 2. Auto Refresh
            Section {
                Picker(LText("wallpaper_auto_refresh"), selection: $wallpaperManager.autoRefreshInterval) {
                    ForEach(WallpaperRefreshInterval.allCases, id: \.self) { interval in
                        Text(interval.localizedName).tag(interval)
                    }
                }

                Toggle(
                    LText("wallpaper_only_favorites"),
                    isOn: $wallpaperManager.onlyUseFavoriteWallpapers
                )
                .disabled(wallpaperManager.favorites.isEmpty)
                .accessibilityIdentifier("wallpaper.only-favorites")
                Text(LText("wallpaper_only_favorites_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !wallpaperManager.onlyUseFavoriteWallpapers {
                    Toggle(LText("wallpaper_random_sources"), isOn: $wallpaperManager.autoRandomizeRemoteSources)
                        .accessibilityIdentifier("wallpaper.randomSources")

                    if wallpaperManager.autoRandomizeRemoteSources {
                        ForEach([WallpaperSource.pexels, .pixabay, .bing], id: \.self) { src in
                            Toggle(src.localizedName, isOn: Binding(
                                get: { wallpaperManager.autoRemoteSources.contains(src) },
                                set: { wallpaperManager.setAutoRemoteSource(src, enabled: $0) }
                            ))
                        }
                        Text(LText("wallpaper_random_sources_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(LText("wallpaper_random_topics"), isOn: $wallpaperManager.autoRandomizeTopics)
                }
                Text(LText("wallpaper_auto_refresh_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: { Label(LText("wallpaper_auto_refresh_header"), systemImage: "clock.arrow.2.circlepath") }

            } else {
                appearanceSection
            }

            // 3. Search & Tags
            if wallpaperManager.source == .pexels || wallpaperManager.source == .pixabay {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        searchBarView
                        vibeTagsCloud
                    }.padding(.vertical, 4)
                } header: { Label(LText("wallpaper_discover"), systemImage: "sparkles") }
            }

            }
            // Storage management can reach favorites without changing the
            // currently selected wallpaper source or starting a remote search.
            if (showsFavoritesOnly || wallpaperManager.source.isRemote) && !wallpaperManager.favorites.isEmpty {
                Section {
                    if showsFavoritesOnly || !isFavCollapsed {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(wallpaperManager.favorites) { wall in favoriteTile(wall) }
                            }
                            .padding(.vertical, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                } header: {
                    Button { withAnimation(.spring()) { isFavCollapsed.toggle() } } label: {
                        HStack {
                            Label("\(LText("wallpaper_favorites")) (\(wallpaperManager.favorites.count))", systemImage: "heart.fill").foregroundStyle(.pink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .rotationEffect(.degrees(isFavCollapsed ? 0 : 90))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // 4. Results
            if showsFavoritesOnly {
                if wallpaperManager.favorites.isEmpty {
                    CompatibleUnavailableView(LText("wallpaper_favorites"), systemImage: "heart")
                }
            } else { sourceOptions }
        }
        .modifier(SettingsPageTitle(embedded: embedded, title: LText(showsFavoritesOnly ? "wallpaper_favorites" : "settings_wallpaper")))
        .onAppear { editingAppearance = WallpaperAppearance(colorScheme) }
        .task(id: wallpaperManager.source) { if !showsFavoritesOnly { await wallpaperManager.ensureCandidatesLoaded() } }
        .task(id: "\(wallpaperManager.source.rawValue)-\(wallpaperManager.customPhotoRevision)") {
            guard !showsFavoritesOnly else { return }
            for appearance in WallpaperAppearance.allCases {
                let pixels = wallpaperManager.source == .photo ? CGSize(width: 900, height: 1200) : CGSize(width: 240, height: 180)
                let image = await wallpaperManager.customPhotoPreview(for: appearance, targetPixels: pixels)
                guard !Task.isCancelled else { return }
                photoPreviews[appearance] = image
            }
        }
        .onDisappear { photoTask?.cancel() }
        .alert(LText("wallpaper_load_error"), isPresented: Binding(
            get: { photoError != nil }, set: { if !$0 { photoError = nil } }
        )) { Button(ToolText.text("done")) { photoError = nil } } message: { Text(photoError ?? "") }
        .fullScreenCover(item: $fullScreenContext) { ctx in
            FullScreenWallpaperView(
                wallpapers: ctx.wallpapers,
                initialSelection: ctx.initialSelection,
                wallpaperManager: wallpaperManager
            )
        }
        .alert(LText("wallpaper_delete_title"), isPresented: $showDeleteConfirm) {
            Button(LText("wallpaper_delete_confirm"), role: .destructive) {
                if let wall = wallpaperToDelete {
                    wallpaperManager.blockWallpaper(wall)
                    wallpaperToDelete = nil
                }
            }
            Button(LText("cancel"), role: .cancel) { wallpaperToDelete = nil }
        } message: {
            Text(LText("wallpaper_delete_msg"))
        }
    }

    // MARK: - Components
    private var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(LText("wallpaper_search_placeholder"), text: $searchText).submitLabel(.search).onSubmit { performSearch() }
            if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
        }.padding(8).background(Color(uiColor: .secondarySystemFill)).cornerRadius(10)
    }

    private var vibeTagsCloud: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(wallpaperManager.vibeTags, id: \.self) { tag in
                    let isSelected = wallpaperManager.searchTopic.lowercased() == tag.lowercased()
                    Button { searchText = tag; performSearch(); HapticsManager.selection() } label: {
                        HStack(spacing: 4) {
                            Text(tag).font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            if isSelected { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.themePrimary : Color(uiColor: .tertiarySystemFill))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .contextMenu {
                        Button(role: .destructive) {
                            withAnimation { wallpaperManager.removeVibeTag(tag) }
                        } label: {
                            Label(LText("delete"), systemImage: "trash")
                        }
                    }
                }
            }.padding(.horizontal, 4)
        }
    }

    private func sourceTile(_ src: WallpaperSource) -> some View {
        let selected = wallpaperManager.source == src
        return Button {
            HapticsManager.selection()
            Task { await wallpaperManager.selectSource(src) }
        } label: {
            VStack(spacing: 8) {
                sourceSample(src, appearance: wallpaperManager.source.isRemote ? WallpaperAppearance(colorScheme) : editingAppearance)
                    .frame(width: 70, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.themePrimary : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 0.5))
                    .accessibilityHidden(true)
                Text(src.localizedName).font(.system(size: 10, weight: selected ? .bold : .medium)).foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wallpaper.source.\(src.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task { await wallpaperManager.loadSourcePreview(for: src) }
    }

    private func sourceSample(_ source: WallpaperSource, appearance: WallpaperAppearance) -> some View {
        WallpaperSourceSample(source: source, appearance: appearance,
            image: source == .photo ? photoPreviews[appearance] : wallpaperManager.sourcePreviewImage(for: source),
            gradient: wallpaperManager.gradient(for: appearance), solidColor: wallpaperManager.solidColor(for: appearance),
            overlayOpacity: wallpaperManager.imageOverlayEnabled ? wallpaperManager.imageOverlayAmount : 0,
            blurRadius: wallpaperManager.imageBlurEnabled ? CGFloat(wallpaperManager.imageBlurAmount * 30) : 0,
            placeholderSymbol: sourceIcon(source))
    }

    @ViewBuilder
    private var sourceOptions: some View {
        switch wallpaperManager.source {
        case .gradient: gradientSection
        case .bing:     bingSection
        case .pexels:   remoteGridSection { await wallpaperManager.searchPexels(query: searchText.isEmpty ? wallpaperManager.searchTopic : searchText) }
        case .pixabay:  remoteGridSection { await wallpaperManager.searchPixabay(query: searchText.isEmpty ? wallpaperManager.searchTopic : searchText) }
        case .photo:    photoSection
        case .solid:    solidSection
        }
    }

    private func remoteGridSection(fetchAction: @escaping () async -> Void) -> some View {
        Section {
            HStack {
                Text(LText("wallpaper_current_vibe")).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                Text(wallpaperManager.searchTopic).font(.system(size: 12, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 2).background(Color.themePrimary.opacity(0.2)).foregroundStyle(Color.themePrimary).cornerRadius(4)
                Spacer()
                if wallpaperManager.networkLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await fetchAction() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold))
                    }
                }
            }.padding(.top, 4)
            if !wallpaperManager.lastRemoteError.isEmpty {
                Label(wallpaperManager.lastRemoteError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !wallpaperManager.networkLoading && wallpaperManager.lastRemoteError.isEmpty
                && wallpaperManager.candidateWallpapers.isEmpty {
                Text(LText("no_results"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            LazyVGrid(columns: columns, spacing: 12) { ForEach(wallpaperManager.candidateWallpapers) { wall in wallpaperTile(wall) } }.padding(.vertical, 8)
        }
    }

    private var bingSection: some View {
        Section {
            HStack {
                Spacer()
                Button { Task { await wallpaperManager.fetchBingWallpaper(random: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold))
                }
            }
            if !wallpaperManager.lastRemoteError.isEmpty {
                Label(wallpaperManager.lastRemoteError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let wall = wallpaperManager.candidateWallpapers.first { wallpaperTile(wall, isLarge: true) }
        }
    }

    private var appearanceSection: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(WallpaperAppearance.allCases) { appearance in
                    Button {
                        editingAppearance = appearance
                        selectedPhoto = nil
                        HapticsManager.selection()
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            appearanceSample(appearance)
                                .frame(height: 76)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            HStack(spacing: 6) {
                                Label(appearance.localizedName, systemImage: appearance == .light ? "sun.max" : "moon")
                                Spacer(minLength: 0)
                                if editingAppearance == appearance { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.themePrimary) }
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        }
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(editingAppearance == appearance ? Color.themePrimary : Color.primary.opacity(0.1), lineWidth: editingAppearance == appearance ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wallpaper.appearance." + appearance.rawValue)
                    .accessibilityAddTraits(editingAppearance == appearance ? .isSelected : [])
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2))
            .listRowBackground(Color.clear)
        } header: { Text(LText("appearance")) }
        footer: { Text(ToolText.text("wallpaper_appearance_hint")) }
    }

    private func appearanceSample(_ appearance: WallpaperAppearance) -> some View {
        sourceSample(wallpaperManager.source, appearance: appearance)
    }

    private var gradientSection: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(GradientPreset.presets) { preset in
                    let selected = wallpaperManager.gradientID(for: editingAppearance) == preset.id
                    Button { wallpaperManager.setGradient(preset.id, for: editingAppearance); HapticsManager.light() } label: {
                        ZStack {
                            LinearGradient(colors: preset.colors, startPoint: preset.startPoint, endPoint: preset.endPoint)
                                .frame(height: 80).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.themePrimary : .clear, lineWidth: 3))
                            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).font(.headline) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wallpaper.gradient.\(preset.id)")
                    .accessibilityLabel(preset.id)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.vertical, 4)
        } header: { Text(editingAppearance.localizedName) }
    }

    private var photoSection: some View {
        let choosePhotoTitle = LText("wallpaper_choose_photo")
        let savingPhoto = isSavingPhoto
        return Section {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                HStack {
                    Label(choosePhotoTitle, systemImage: "photo.on.rectangle")
                    Spacer()
                    if savingPhoto { ProgressView() }
                }
            }
            .disabled(isSavingPhoto)
            .onCompatibleChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                let appearance = editingAppearance
                photoTask?.cancel()
                isSavingPhoto = true
                photoTask = Task {
                    defer { isSavingPhoto = false }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw WebResourceDownloadError.invalidImage }
                        try Task.checkCancellation()
                        try await wallpaperManager.saveCustomPhoto(data, for: appearance)
                    } catch is CancellationError { }
                    catch { photoError = error.localizedDescription }
                }
            }
            if let image = photoPreviews[editingAppearance] {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } header: { Text(editingAppearance.localizedName) }
    }

    private var solidSection: some View {
        Section {
            ColorPicker(LText("wallpaper_color"), selection: Binding(get: { Color(hex: wallpaperManager.solidColor(for: editingAppearance)) }, set: { color in
                let uiColor = UIColor(color)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                guard uiColor.getRed(&r, green: &g, blue: &b, alpha: nil) else { return }
                wallpaperManager.setSolidColor(String(format: "#%02X%02X%02X", Int((r*255).rounded()), Int((g*255).rounded()), Int((b*255).rounded())), for: editingAppearance)
            }), supportsOpacity: false)
            .accessibilityIdentifier("wallpaper.color")
        } header: { Text(editingAppearance.localizedName) }
    }

    private func wallpaperTile(_ wall: RemoteWallpaper, isLarge: Bool = false) -> some View {
        let isFav = wallpaperManager.favorites.contains(where: { $0.id == wall.id })
        return Color.clear
            .frame(height: isLarge ? 200 : 120)
            .overlay(
                AsyncImage(url: URL(string: wall.previewURL)) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.1)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                HapticsManager.light()
                fullScreenContext = FullScreenContext(wallpapers: wallpaperManager.candidateWallpapers, initialSelection: wall.id)
            }
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isFav ? .pink : .white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.3))
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .onTapGesture { wallpaperManager.toggleFavorite(wall) }

                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.3))
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .onTapGesture { wallpaperToDelete = wall; showDeleteConfirm = true }
                }
                .padding(6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(wall.topic), \(wall.source)")
            .accessibilityHint(
                LanguageManager.shared.localizedString("accessibility_wallpaper_open_hint")
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                fullScreenContext = FullScreenContext(
                    wallpapers: wallpaperManager.candidateWallpapers,
                    initialSelection: wall.id
                )
            }
            .accessibilityAction(
                named: Text(
                    LanguageManager.shared.localizedString(
                        isFav ? "accessibility_remove_favorite" : "accessibility_add_favorite"
                    )
                )
            ) {
                wallpaperManager.toggleFavorite(wall)
            }
            .accessibilityAction(named: Text(LanguageManager.shared.localizedString("delete"))) {
                wallpaperToDelete = wall
                showDeleteConfirm = true
            }
    }

    private func favoriteTile(_ wall: RemoteWallpaper) -> some View {
        Color.clear
            .frame(width: 80, height: 120)
            .overlay(
                AsyncImage(url: URL(string: wall.previewURL)) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.1)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                HapticsManager.light()
                fullScreenContext = FullScreenContext(wallpapers: wallpaperManager.favorites, initialSelection: wall.id)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.pink.opacity(0.8))
                    .clipShape(Circle())
                    .shadow(radius: 2)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                    .onTapGesture { wallpaperManager.toggleFavorite(wall) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(wall.topic), \(wall.source)")
            .accessibilityHint(
                LanguageManager.shared.localizedString("accessibility_wallpaper_open_hint")
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                fullScreenContext = FullScreenContext(
                    wallpapers: wallpaperManager.favorites,
                    initialSelection: wall.id
                )
            }
            .accessibilityAction(
                named: Text(LanguageManager.shared.localizedString("accessibility_remove_favorite"))
            ) {
                wallpaperManager.toggleFavorite(wall)
            }
    }

    private func performSearch() {
        guard !searchText.isEmpty else { return }
        Task {
            if wallpaperManager.source == .pexels { await wallpaperManager.searchPexels(query: searchText) }
            else if wallpaperManager.source == .pixabay { await wallpaperManager.searchPixabay(query: searchText) }
        }
    }

    private func sourceIcon(_ src: WallpaperSource) -> String {
        switch src {
        case .bing:     return "globe.americas.fill"
        case .pexels:   return "camera.fill"
        case .pixabay:  return "photo.on.rectangle"
        case .gradient: return "paintpalette.fill"
        case .photo:    return "person.crop.rectangle"
        case .solid:    return "circle.fill"
        }
    }
}

// MARK: - FullScreen Context
/// A static miniature of the configured background, with the same image
/// effects as Home. Rendering a tile never changes the app's appearance.
struct WallpaperSourceSample: View {
    let source: WallpaperSource
    let appearance: WallpaperAppearance
    let image: UIImage?
    let gradient: GradientPreset
    let solidColor: String
    let overlayOpacity: Double
    let blurRadius: CGFloat
    var placeholderSymbol = "photo"

    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, geometry.size.width / max(1, UIScreen.main.bounds.width))
            ZStack {
                switch source {
                case .solid:
                    Color(hex: solidColor)
                case .gradient:
                    DynamicGradientView(colors: gradient.colors, isPaused: true)
                    WallpaperReadabilityScrim(source: source, appearance: appearance, isLight: gradient.isLight, scale: scale)
                default:
                    if let image {
                        WallpaperPhotoLayer(image: image, size: geometry.size, blurRadius: blurRadius * scale)
                        Color.black.opacity(overlayOpacity)
                        if overlayOpacity > 0 {
                            let isLight = image.cgImage.map { WallpaperContrast.imageLightness($0, overlayAmount: overlayOpacity).masked } ?? false
                            WallpaperReadabilityScrim(source: source, appearance: appearance, isLight: isLight, scale: scale)
                                .opacity(min(1, overlayOpacity / WallpaperContrast.defaultImageOverlayAmount))
                        }
                    } else {
                        Color(uiColor: .secondarySystemFill)
                        Image(systemName: placeholderSymbol).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .environment(\.colorScheme, appearance == .dark ? .dark : .light)
        // A scaled-to-fill image can retain hit bounds beyond its visual crop.
        // Only the enclosing source/appearance button should receive touches.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct FullScreenContext: Identifiable {
    let id = UUID()
    let wallpapers: [RemoteWallpaper]
    let initialSelection: String
}

// MARK: - FullScreen Viewer
struct FullScreenWallpaperView: View {
    let wallpapers: [RemoteWallpaper]
    let initialSelection: String
    @ObservedObject var wallpaperManager: WallpaperManager
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String = ""
    @State private var exportPreview: WallpaperExportPreviewModel?

    private var currentWall: RemoteWallpaper? {
        wallpapers.first { $0.id == selection }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(wallpapers) { wall in
                    WallpaperFullImage(wall: wall, wallpaperManager: wallpaperManager, onDismiss: { dismiss() })
                        .tag(wall.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Overlays
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white, .black.opacity(0.5))
                            .padding()
                    }
                    Spacer()
                }
                Spacer()

                HStack(spacing: 60) {
                    // Apply
                    Button {
                        guard let wall = currentWall else { return }
                        Task {
                            await wallpaperManager.applyWallpaper(wall)
                            HapticsManager.success()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.white, Color.themePrimary)
                            .shadow(radius: 4)
                    }

                    // Download
                    Button {
                        guard let wall = currentWall else { return }
                        exportPreview = wallpaperManager.exportPreview(for: wall)
                    } label: {
                        Image(systemName: "arrow.down.to.line.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.white, .black.opacity(0.5))
                            .shadow(radius: 4)
                    }
                    .disabled(currentWall == nil)
                    .accessibilityLabel(LText("wallpaper_download"))
                    .accessibilityIdentifier("wallpaper.download")
                }
                .padding(.bottom, 50)
                .opacity(currentWall != nil ? 1 : 0)
            }
        }
        .sheet(item: $exportPreview) { WallpaperExportPreview(model: $0) }
        .onAppear {
            selection = initialSelection
            // Fallback if initialSelection not found in array
            if currentWall == nil, let first = wallpapers.first {
                selection = first.id
            }
        }
    }

}

// MARK: - Single Wallpaper Full Image (uses HD cache → preview fallback)
private struct WallpaperFullImage: View {
    let wall: RemoteWallpaper
    let wallpaperManager: WallpaperManager
    var onDismiss: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImageSurface(image: Image(uiImage: image), onDismiss: onDismiss)
            } else {
                // Show preview via AsyncImage while loading HD
                AsyncImage(url: URL(string: wall.previewURL)) { phase in
                    if let img = phase.image {
                        ZoomableImageSurface(image: img, onDismiss: onDismiss)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task {
            // Try HD cache first
            if let cached = wallpaperManager.cachedHDImage(for: wall.id) {
                image = cached
                return
            }
            // Try loading HD from URL
            let urlString = wall.url.isEmpty ? wall.previewURL : wall.url
            guard let url = URL(string: urlString) else { return }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let loaded = UIImage(data: data) {
                image = loaded
            }
            // If HD fails, preview AsyncImage stays visible — no error shown
        }
    }
}


@MainActor
struct WallpaperExportPreview: View {
    @ObservedObject var model: WallpaperExportPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                if let image = model.image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .padding(16)
                        .frame(maxWidth: 900, maxHeight: .infinity)
                        .accessibilityLabel(LText("accessibility_wallpaper_preview"))
                        .accessibilityIdentifier("wallpaper.export.image")
                }
                if model.isLoading { ProgressView().padding(16).background(.ultraThinMaterial, in: Circle()) }
                if model.loadFailed {
                    VStack(spacing: 16) {
                        Label(LText("wallpaper_load_error"), systemImage: "photo.badge.exclamationmark")
                        Button(ToolText.text("retry")) { Task { await model.prepare() } }.buttonStyle(.borderedProminent)
                    }.foregroundStyle(.primary)
                }
            }
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle(LText("accessibility_wallpaper_preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ToolText.text("done")) { dismiss() }.disabled(model.isSaving)
                        .accessibilityIdentifier("wallpaper.export.close")
                }
            }
            .sheet(isPresented: $sharing) {
                if let file = model.file { WallpaperExportActivitySheet(file: file) }
            }
            .alert(LText("save_image"), isPresented: Binding(
                get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } }
            )) { Button(ToolText.text("done")) { model.saveError = nil } } message: { Text(model.saveError ?? "") }
        }
        .task { await model.prepare() }
        .interactiveDismissDisabled(model.isSaving)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if model.saved {
                Label(LText("wallpaper_saved"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.green)
                    .accessibilityIdentifier("wallpaper.export.saved")
            }
            HStack(spacing: 12) {
                Button { sharing = true } label: {
                    Label(LText("share"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }
                .accessibilityIdentifier("wallpaper.export.share")
                Button { Task { await model.saveToPhotos() } } label: {
                    HStack(spacing: 8) {
                        if model.isSaving { ProgressView().tint(.white) }
                        else { Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down") }
                        Text(LText("save_image"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(.white)
                    .background(Color.themePrimary, in: Capsule())
                }
                .disabled(model.isSaving || model.saved)
                .accessibilityIdentifier("wallpaper.export.save")
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.plain)
            .disabled(model.file == nil || model.isSaving)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

/// The controller keeps the temporary original alive even if its parent preview closes.
private struct WallpaperExportActivitySheet: UIViewControllerRepresentable {
    let file: WallpaperExportFile
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = RetainedWallpaperActivityController(file: file)
        controller.modalPresentationStyle = .pageSheet
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

private final class RetainedWallpaperActivityController: UIActivityViewController {
    private let file: WallpaperExportFile
    init(file: WallpaperExportFile) {
        self.file = file
        super.init(activityItems: [file.url], applicationActivities: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

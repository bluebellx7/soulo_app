import SwiftUI
import PhotosUI

@MainActor
struct WallpaperSettingsView: View {
    @ObservedObject var wallpaperManager = WallpaperManager.shared
    @AppStorage("fav_section_collapsed") private var isFavCollapsed = false
    
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var searchText = ""

    // Fullscreen state
    @State private var fullScreenContext: FullScreenContext? = nil
    @State private var wallpaperToDelete: RemoteWallpaper? = nil
    @State private var showDeleteConfirm = false

    let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        List {
            // 1. Source Picker
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(WallpaperSource.allCases, id: \.self) { src in sourceTile(src) }
                    }.padding(.vertical, 10).padding(.horizontal, 4)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            } header: { Label(LText("wallpaper_source"), systemImage: "photo.on.rectangle.angled") }

            // 2. Search & Tags
            if wallpaperManager.source == .pexels || wallpaperManager.source == .pixabay {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        searchBarView
                        vibeTagsCloud
                    }.padding(.vertical, 4)
                } header: { Label(LText("wallpaper_discover"), systemImage: "sparkles") }
            }

            // 3. Favorites (Collapsible)
            if !wallpaperManager.favorites.isEmpty {
                Section {
                    if !isFavCollapsed {
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
            sourceOptions
        }
        .navigationTitle(LText("settings_wallpaper"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { wallpaperManager.ensureLoaded() }
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
                        .background(isSelected ? Color.blue : Color(uiColor: .tertiarySystemFill))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .contextMenu { Button(role: .destructive) { withAnimation { wallpaperManager.removeVibeTag(tag) } } label: { Label("Remove", systemImage: "trash") } }
                }
            }.padding(.horizontal, 4)
        }
    }

    private func sourceTile(_ src: WallpaperSource) -> some View {
        let selected = wallpaperManager.source == src
        return Button { wallpaperManager.source = src; HapticsManager.selection() } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(selected ? Color.blue.opacity(0.15) : Color(uiColor: .secondarySystemFill)).frame(width: 80, height: 60)
                    Image(systemName: sourceIcon(src)).font(.system(size: 20)).foregroundStyle(selected ? Color.blue : .secondary)
                }.overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.blue : Color.clear, lineWidth: 2))
                Text(src.localizedName).font(.system(size: 10, weight: selected ? .bold : .medium)).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
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
                Text(wallpaperManager.searchTopic).font(.system(size: 12, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 2).background(Color.blue.opacity(0.2)).foregroundStyle(Color.blue).cornerRadius(4)
                Spacer()
                if wallpaperManager.networkLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await fetchAction() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold))
                    }
                }
            }.padding(.top, 4)
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
            if let wall = wallpaperManager.candidateWallpapers.first { wallpaperTile(wall, isLarge: true) }
        }
    }

    private var gradientSection: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(GradientPreset.presets) { preset in
                    Button { wallpaperManager.selectedGradientId = preset.id; HapticsManager.light() } label: {
                        ZStack {
                            LinearGradient(colors: preset.colors, startPoint: preset.startPoint, endPoint: preset.endPoint).frame(height: 80).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(wallpaperManager.selectedGradientId == preset.id ? Color.blue : .clear, lineWidth: 3))
                            if wallpaperManager.selectedGradientId == preset.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).font(.headline) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }.padding(.vertical, 4)
        }
    }

    private var photoSection: some View {
        Section {
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Label(LText("wallpaper_choose_photo"), systemImage: "photo.on.rectangle") }
            .onChange(of: selectedPhoto) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) { wallpaperManager.saveCustomImage(image) } } }
            if let image = wallpaperManager.customImage { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200).clipShape(RoundedRectangle(cornerRadius: 12)) }
        }
    }

    private var solidSection: some View {
        Section {
            ColorPicker(LText("wallpaper_color"), selection: Binding(get: { Color(hex: wallpaperManager.solidColor) }, set: { c in
                let uic = UIColor(c); var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0; uic.getRed(&r, green: &g, blue: &b, alpha: nil)
                wallpaperManager.solidColor = String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
            }))
        }
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
    @State private var isDownloading = false
    @State private var downloadSuccess = false

    private var currentWall: RemoteWallpaper? {
        wallpapers.first { $0.id == selection }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(wallpapers) { wall in
                    WallpaperFullImage(wall: wall, wallpaperManager: wallpaperManager)
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
                            .foregroundStyle(.white, .blue)
                            .shadow(radius: 4)
                    }

                    // Download
                    Button {
                        guard let wall = currentWall else { return }
                        downloadAndSave(wall: wall)
                    } label: {
                        if isDownloading {
                            ProgressView().tint(.white).frame(width: 50, height: 50)
                        } else {
                            Image(systemName: downloadSuccess ? "checkmark.seal.fill" : "arrow.down.to.line.circle.fill")
                                .font(.system(size: 50))
                                .foregroundStyle(.white, downloadSuccess ? .green : .black.opacity(0.5))
                                .shadow(radius: 4)
                        }
                    }
                    .disabled(isDownloading || currentWall == nil)
                }
                .padding(.bottom, 50)
                .opacity(currentWall != nil ? 1 : 0)
            }
        }
        .onAppear {
            selection = initialSelection
            // Fallback if initialSelection not found in array
            if currentWall == nil, let first = wallpapers.first {
                selection = first.id
            }
        }
    }

    private func downloadAndSave(wall: RemoteWallpaper) {
        isDownloading = true
        downloadSuccess = false
        Task {
            // Try HD cache first, then URL download
            if let cached = wallpaperManager.cachedHDImage(for: wall.id) {
                wallpaperManager.saveToAlbum(image: cached)
                await MainActor.run { HapticsManager.success(); isDownloading = false; downloadSuccess = true }
            } else {
                let urlString = wall.url.isEmpty ? wall.previewURL : wall.url
                guard let url = URL(string: urlString) else { await MainActor.run { isDownloading = false }; return }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let image = UIImage(data: data) {
                        wallpaperManager.saveToAlbum(image: image)
                        await MainActor.run { HapticsManager.success(); isDownloading = false; downloadSuccess = true }
                    } else {
                        await MainActor.run { isDownloading = false }
                    }
                } catch {
                    await MainActor.run { isDownloading = false }
                }
            }
            if downloadSuccess {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { downloadSuccess = false }
            }
        }
    }
}

// MARK: - Single Wallpaper Full Image (uses HD cache → preview fallback)
private struct WallpaperFullImage: View {
    let wall: RemoteWallpaper
    let wallpaperManager: WallpaperManager
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                // Show preview via AsyncImage while loading HD
                AsyncImage(url: URL(string: wall.previewURL)) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white)
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

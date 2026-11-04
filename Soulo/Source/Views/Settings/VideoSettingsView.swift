import SwiftUI

struct VideoSettingsView: View {
    @AppStorage(VideoPlaybackPreferences.showsToolsKey) private var showsTools = true
    @AppStorage(VideoPlaybackPreferences.defaultPlayerKey) private var defaultPlayer = "soulo"
    @AppStorage(VideoPlaybackPreferences.holdSpeedKey) private var holdSpeed = 2.0
    @AppStorage(VideoPlaybackPreferences.showsEpisodeDockKey) private var showsEpisodeDock = true

    var body: some View {
        List {
            Section {
                Toggle(ToolText.text("video_show_tools"), isOn: $showsTools)
                    .accessibilityIdentifier("video-settings.tools")
            } footer: {
                Text(ToolText.text("video_show_tools_desc"))
            }
            Section {
                Toggle(ToolText.text("video_show_episode_dock"), isOn: $showsEpisodeDock)
                    .accessibilityIdentifier("video-settings.episode-dock")
            } footer: {
                Text(ToolText.text("video_show_episode_dock_desc"))
            }
            Section {
                Picker(ToolText.text("video_default_player"), selection: $defaultPlayer) {
                    Text("Soulo").tag("soulo")
                    Text(ToolText.text("media_player_system")).tag("system")
                }
                .accessibilityIdentifier("video-settings.player")
            } footer: {
                Text(ToolText.text("video_default_player_desc"))
            }
            Section {
                Picker(ToolText.text("video_hold_speed"), selection: $holdSpeed) {
                    ForEach(VideoPlaybackPreferences.holdSpeeds, id: \.self) { speed in
                        Text(String(format: "%g×", speed)).tag(speed)
                    }
                }
                .accessibilityIdentifier("video-settings.hold-speed")
            } footer: {
                Text(ToolText.text("video_hold_speed_desc"))
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Soulo").font(.headline)
                    Text(ToolText.text("video_soulo_player_desc")).font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(ToolText.text("media_player_system")).font(.headline)
                    Text(ToolText.text("video_system_player_desc")).font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
        }
        .tint(Color.themePrimary)
        .listStyle(.insetGrouped)
        .navigationTitle(ToolText.text("video_settings"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

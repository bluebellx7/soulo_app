import SwiftUI

struct VideoSettingsView: View {
    @AppStorage(VideoPlaybackPreferences.showsToolsKey) private var showsTools = true
    @AppStorage(VideoPlaybackPreferences.defaultPlayerKey) private var defaultPlayer = "soulo"
    @AppStorage(VideoPlaybackPreferences.holdSpeedKey) private var holdSpeed = 2.0
    @AppStorage(VideoPlaybackPreferences.showsEpisodeDockKey) private var showsEpisodeDock = true

    var body: some View {
        List {
            Section {
                IllustratedFeatureIntro(scene: .playback,
                    message: ToolText.text("video_default_player_desc"),
                    accessibilityID: "video-settings.explanation")
            }
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
            Section {
                Text(FeatureText.text("Choose a duration or stop after the current item from the player menu. Local audio can continue in the background and advance through files in the same folder."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(FeatureText.text("Sleep timer"))
            }
        }
        .tint(Color.themePrimary)
        .listStyle(.insetGrouped)
        .navigationTitle(ToolText.text("video_settings"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

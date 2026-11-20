import SwiftUI

struct VideoSettingsView: View {
    @AppStorage(VideoPlaybackPreferences.takesOverWebPlayersKey) private var takesOverWebPlayers = false
    @AppStorage(VideoPlaybackPreferences.showsToolsKey) private var showsTools = true
    @AppStorage(VideoPlaybackPreferences.holdSpeedKey) private var holdSpeed = 2.0
    @AppStorage(VideoPlaybackPreferences.showsEpisodeDockKey) private var showsEpisodeDock = true

    var body: some View {
        List {
            Section {
                Toggle(FeatureText.text("Take over web players"), isOn: $takesOverWebPlayers)
                    .accessibilityIdentifier("video-settings.takeover")
            } footer: {
                Text(FeatureText.text("Only takes over website fullscreen. Extension players stay independent."))
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

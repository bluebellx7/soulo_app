import SwiftUI

struct PlaybackSleepTimerMenu: View {
    @ObservedObject private var timer = MediaSession.shared.sleepTimer
    var body: some View {
        Menu {
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button(Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide))) {
                    timer.start(after: TimeInterval(minutes * 60))
                }
            }
            Button(FeatureText.text("After this item")) { timer.stopAfterCurrentItem() }
            if timer.isActive {
                Divider()
                if let deadline = timer.deadline { Text(deadline, style: .time) }
                Button(LanguageManager.shared.localizedString("cancel"), role: .destructive) { timer.cancel() }
            }
        } label: {
            Label(FeatureText.text("Sleep timer"), systemImage: timer.isActive ? "moon.zzz.fill" : "moon.zzz")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("media.sleep-timer")
        .accessibilityValue(timer.stopsAfterCurrentItem ? FeatureText.text("After this item") : timer.deadline?.formatted(date: .omitted, time: .shortened) ?? "")
    }
}

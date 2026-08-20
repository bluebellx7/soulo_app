import AppIntents
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 18.0, *)
struct SouloSearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.dkluge.Soulo.control.search") {
            ControlWidgetButton(action: OpenSouloIntent()) {
                Label("control_search_title", systemImage: "magnifyingglass")
            }
        }
        .displayName("control_search_title")
        .description("control_search_description")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct SouloPrivateSearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.dkluge.Soulo.control.private-search") {
            ControlWidgetButton(action: NewPrivateSearchIntent()) {
                Label("control_private_search_title", systemImage: "eye.slash")
            }
        }
        .displayName("control_private_search_title")
        .description("control_private_search_description")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct SouloDownloadsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.dkluge.Soulo.control.downloads") {
            ControlWidgetButton(action: OpenSouloDownloadsIntent()) {
                Label("control_downloads_title", systemImage: "arrow.down.circle")
            }
        }
        .displayName("control_downloads_title")
        .description("control_downloads_description")
    }
}

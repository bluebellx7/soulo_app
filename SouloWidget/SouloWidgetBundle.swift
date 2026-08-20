import WidgetKit
import SwiftUI

@main
struct SouloWidgetBundle: WidgetBundle {
    var body: some Widget {
        SouloLiveActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            SouloSearchControl()
            SouloPrivateSearchControl()
            SouloDownloadsControl()
        }
    }
}

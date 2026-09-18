import WidgetKit
import SwiftUI

@main
struct AttendanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        AttendanceWidget()
        MeetingLiveActivityWidget()
    }
}

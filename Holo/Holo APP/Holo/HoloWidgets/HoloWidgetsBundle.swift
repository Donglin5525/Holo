//
//  HoloWidgetsBundle.swift
//  HoloWidgets
//
//  Holo 桌面小组件入口。
//

import WidgetKit
import SwiftUI

@main
struct HoloWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HoloVoiceLaunchWidget()
        HoloQuickActionsWidget()
        HoloFinanceWidget()
        HoloThoughtMemoryWidget()
    }
}


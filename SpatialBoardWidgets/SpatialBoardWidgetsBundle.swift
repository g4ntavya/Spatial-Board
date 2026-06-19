//
//  SpatialBoardWidgetsBundle.swift
//  SpatialBoardWidgets
//
//  Created by Gantavya ‎ on 19/6/26.
//

import WidgetKit
import SwiftUI

@main
struct SpatialBoardWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SpatialBoardWidgets()
        SpatialBoardWidgetsControl()
        SpatialBoardWidgetsLiveActivity()
    }
}

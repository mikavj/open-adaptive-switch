// Open Adaptive Switch - companion app.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

@main
struct AdaptSwitchApp: App {
    @StateObject private var manager = SwitchManager()

    var body: some Scene {
        WindowGroup {
            ScanView()
                .environmentObject(manager)
        }
    }
}

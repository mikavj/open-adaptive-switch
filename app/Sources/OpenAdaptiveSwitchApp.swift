// Open Adaptive Switch - companion app.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

@main
struct OpenAdaptiveSwitchApp: App {
    @StateObject private var store: SwitchStore
    @StateObject private var manager: SwitchManager

    init() {
        let store = SwitchStore()
        _store = StateObject(wrappedValue: store)
        _manager = StateObject(wrappedValue: SwitchManager(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ScanView()
                .environmentObject(manager)
                .environmentObject(store)
        }
    }
}

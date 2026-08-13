//
//  FireProspectApp.swift
//  FireProspect
//
//  Created by Work on 8/10/26.
//

import SwiftUI

@main
struct FireProspectApp: App {
    private var uiTestingDynamicTypeSize: DynamicTypeSize? {
        ProcessInfo.processInfo.environment["UI_TEST_ACCESSIBILITY_TEXT_SIZE"] == "1" ? .accessibility3 : nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.dynamicTypeSize, uiTestingDynamicTypeSize ?? .large)
        }
        .commands {
            CommandMenu("Navigate") {
                Button("Home") {
                    NotificationCenter.default.post(name: .showHomeDestination, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Search") {
                    NotificationCenter.default.post(name: .showSearchDestination, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Prospects") {
                    NotificationCenter.default.post(name: .showProspectsDestination, object: nil)
                }
                .keyboardShortcut("3", modifiers: .command)

            }
        }

        Settings {
            SettingsTabView()
                .frame(width: 620, height: 560)
        }
    }
}


extension Notification.Name {
    static let showHomeDestination = Notification.Name("showHomeDestination")
    static let showSearchDestination = Notification.Name("showSearchDestination")
    static let showProspectsDestination = Notification.Name("showProspectsDestination")
}

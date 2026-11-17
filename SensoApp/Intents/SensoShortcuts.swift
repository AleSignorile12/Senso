// SensoShortcuts.swift
// Makes StartPouringIntent available to Siri and the Action Button without any setup.

import AppIntents

struct SensoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartPouringIntent(),
            phrases: ["Start pouring with \(.applicationName)", "Pour with \(.applicationName)"],
            shortTitle: "Start pouring",
            systemImageName: "drop.fill"
        )
    }
}

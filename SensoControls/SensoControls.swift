// SensoControls.swift
// Control Center / Lock Screen / Action Button control: one tap opens Senso and starts listening.

import AppIntents
import SwiftUI
import WidgetKit

@main
struct SensoControlsBundle: WidgetBundle {
    var body: some Widget {
        StartPouringControl()
    }
}

struct StartPouringControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.alessandrosignorile.Senso.StartPouring") {
            ControlWidgetButton(action: StartPouringIntent()) {
                Label("Start pouring", systemImage: "drop.fill")
            }
        }
        .displayName("Start pouring")
        .description("Opens Senso and starts listening.")
    }
}

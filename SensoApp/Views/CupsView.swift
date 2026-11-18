// CupsView.swift
// The user's cups and pour settings. A calibration pour (empty cup → full) teaches Senso the cup's
// pitch range and how long it takes to fill, which makes the level estimate much less rough.

import Observation
import SwiftUI

/// Saved cups and settings, kept in UserDefaults (a handful of small values).
@Observable
final class CupStore {
    private(set) var cups: [ContainerProfile] = []
    var selectedID: ContainerProfile.ID? {
        didSet { defaults.set(selectedID?.uuidString, forKey: Keys.selected) }
    }
    var targetPercent: Int {
        didSet { defaults.set(targetPercent, forKey: Keys.target) }
    }
    var speechEnabled: Bool {
        didSet { defaults.set(speechEnabled, forKey: Keys.speech) }
    }
    /// Spoken tips for aiming the camera at the cup before pouring ("Move left"…). Off by default. The camera
    /// itself always runs before a pour, to check there is a cup.
    var cameraHelp: Bool {
        didSet { defaults.set(cameraHelp, forKey: Keys.cameraHelp) }
    }
    /// Start listening as soon as Senso opens, so there's no button to find.
    var autoStart: Bool {
        didSet { defaults.set(autoStart, forKey: Keys.autoStart) }
    }

    var selected: ContainerProfile? { cups.first { $0.id == selectedID } }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let cups = "senso.cups"
        static let selected = "senso.selectedCup"
        static let target = "senso.targetPercent"
        static let speech = "senso.speech"
        static let autoStart = "senso.autoStart"
        static let cameraHelp = "senso.cameraHelp"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cups = defaults.data(forKey: Keys.cups).flatMap { try? JSONDecoder().decode([ContainerProfile].self, from: $0) } ?? []
        selectedID = defaults.string(forKey: Keys.selected).flatMap(UUID.init)
        let target = defaults.integer(forKey: Keys.target)
        targetPercent = PourThresholds.targetRange.contains(target) ? target : PourThresholds.defaultTargetPercent
        speechEnabled = defaults.object(forKey: Keys.speech) as? Bool ?? true
        autoStart = defaults.bool(forKey: Keys.autoStart)
        cameraHelp = defaults.bool(forKey: Keys.cameraHelp)
    }

    @discardableResult
    func add(named name: String) -> ContainerProfile {
        let cup = ContainerProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        cups.append(cup)
        selectedID = cup.id
        save()
        return cup
    }

    func delete(_ cup: ContainerProfile) {
        cups.removeAll { $0.id == cup.id }
        if selectedID == cup.id { selectedID = nil }
        save()
    }

    func setCalibration(_ calibration: FillCalibration, for id: ContainerProfile.ID) {
        guard let index = cups.firstIndex(where: { $0.id == id }) else { return }
        cups[index].calibration = calibration
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(cups), forKey: Keys.cups)
    }
}

struct CupsView: View {
    @Bindable var store: CupStore
    let onCalibrate: (ContainerProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var addingCup = false
    @State private var showingIntro = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.cups) { cup in
                        HStack {
                            Button {
                                store.selectedID = cup.id
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cup.name)
                                    Text(calibrationText(cup.calibration))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            if cup.id == store.selectedID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                            Button("Calibrate") {
                                dismiss()
                                onCalibrate(cup)
                            }
                            .buttonStyle(.bordered)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(cup.id == store.selectedID ? .isSelected : [])
                        .accessibilityAction(named: "Calibrate") {
                            dismiss()
                            onCalibrate(cup)
                        }
                    }
                    .onDelete { offsets in offsets.map { store.cups[$0] }.forEach(store.delete) }

                    Button("Add a cup", systemImage: "plus") { addingCup = true }
                } header: {
                    Text("Cups")
                } footer: {
                    Text("Calibrate a cup once: start with it empty, pour until it’s full, then tap Full. Without calibration the level is a rough guess.")
                }

                Section {
                    Stepper(value: $store.targetPercent, in: PourThresholds.targetRange, step: 5) {
                        Text("Stop alert at \(store.targetPercent)%")
                    }
                    Toggle("Spoken guidance", isOn: $store.speechEnabled)
                    Toggle("Start listening when Senso opens", isOn: $store.autoStart)
                    Toggle("Spoken tips to aim the camera", isOn: $store.cameraHelp)
                } header: {
                    Text("Alert")
                } footer: {
                    Text("You can also say “Start pouring with Senso”, or add Start pouring to Control Center or the Action Button.")
                }

                Section("Help") {
                    Button("How Senso works") { showingIntro = true }
                    Link("Contact support by email", destination: Self.supportMail)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingIntro) { OnboardingView() }
            .alert("New cup", isPresented: $addingCup) {
                TextField("Name, for example Blue mug", text: $newName)
                Button("Add") {
                    if !newName.trimmingCharacters(in: .whitespaces).isEmpty { store.add(named: newName) }
                    newName = ""
                }
                Button("Cancel", role: .cancel) { newName = "" }
            }
        }
    }

    /// Support happens by email from inside the app, so there's no support website to run.
    private static let supportMail = URL(string: "mailto:alessandrosignorile06@gmail.com?subject=Senso%20support")!

    private func calibrationText(_ calibration: FillCalibration?) -> LocalizedStringKey {
        switch calibration {
        case nil: "Not calibrated"
        case let calibration? where calibration.hasPitch: "Calibrated"
        case let calibration?: "Calibrated by time only (\(Int(calibration.fillSeconds.rounded())) s)"
        }
    }
}

#Preview {
    CupsView(store: CupStore(defaults: UserDefaults(suiteName: "preview")!), onCalibrate: { _ in })
}

// AcknowledgementsView.swift
// Credits for the sounds the pour detector was trained on. Their CC BY licenses require naming each creator.
// MLTraining/PrepareExternalData.swift generates the list, which is bundled as TrainingDataCredits.txt.

import SwiftUI

struct AcknowledgementsView: View {
    private let credits: [String] = Bundle.main.url(forResource: "TrainingDataCredits", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
        .split(separator: "\n").map(String.init) ?? []

    var body: some View {
        List {
            Section {
                Text("Senso’s pour detector was trained on sounds from the FSD50K dataset by Fonseca, Favory, Pons, Font and Serra (2022), licensed CC BY 4.0, recorded by the Freesound.org community. Sounds licensed CC BY are credited below.")
                Link("FSD50K dataset", destination: URL(string: "https://zenodo.org/records/4060432")!)
            }
            Section("Sounds") {
                ForEach(Array(credits.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.footnote)
                }
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

#Preview {
    NavigationStack { AcknowledgementsView() }
}

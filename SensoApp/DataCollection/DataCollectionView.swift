// DataCollectionView.swift
// Developer screen for recording training clips: pick labels, record, review, export.
// Standard iOS styling on purpose. It's a tool, not part of the pouring experience.
// shortcut: labels show raw values ("paper cup"), not display names; fine for a Debug-only tool.

import SwiftUI

struct DataCollectionView: View {
    let recorder: DatasetRecorderService

    @State private var tags = RecordingMetadata(
        label: .pouring, containerType: .mug, material: .ceramic, liquidType: .water,
        pouringSpeed: .medium, groundTruthType: .unlabelled, recordedAt: .now, durationSeconds: 0, sampleRate: 0
    )
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TagPickers(metadata: $tags)
                } header: {
                    Text("Next recording")
                } footer: {
                    Text("Pouring: liquid flowing into a cup. Not pouring: other kitchen sounds. Background noise: the room only. Ambiguous: unsure, left out of training by default.")
                }

                Section {
                    recordButton
                } footer: {
                    Text("Lay the phone flat next to the cup with the microphone uncovered. Start just before the pour and stop right after it, so the clip has little silence.")
                }

                Section {
                    if recorder.recordings.isEmpty {
                        Text("No recordings yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recorder.recordings) { recording in
                        NavigationLink {
                            RecordingDetailView(recorder: recorder, recording: recording)
                        } label: {
                            RecordingRow(recorder: recorder, recording: recording)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { recorder.recordings[$0] }.forEach(recorder.delete)
                    }
                } header: {
                    Text("Recordings")
                } footer: {
                    Text(countsSummary)
                }

                Section {
                    ShareLink(item: DatasetArchive(root: recorder.root), preview: SharePreview("Sensow dataset")) {
                        Label("Export dataset (.zip)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(recorder.recordings.isEmpty || recorder.isRecording)
                } footer: {
                    Text("Unzip on your Mac and copy the class folders into MLTraining/Dataset. The clips are also in the Files app under On My iPhone › Sensow › Dataset.")
                }
            }
            .navigationTitle("Data Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(recorder.isRecording)
                }
            }
            .alert("Recording problem", isPresented: hasMessage) {
                Button("OK") {}
            } message: {
                Text(recorder.message ?? "")
            }
        }
        .interactiveDismissDisabled(recorder.isRecording)
        .onDisappear {
            recorder.stopRecording()
            recorder.stopPlayback()
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopRecording()
            } else {
                Task { await recorder.startRecording(tags) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title)
                if recorder.isRecording, let start = recorder.recordingStartedAt {
                    Text("Stop")
                    Spacer()
                    TimelineView(.periodic(from: start, by: 0.5)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    }
                    Text("\(Int(recorder.audio.inputLevelDB)) dB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Start recording")
                    Spacer()
                }
            }
            .font(.title3.weight(.semibold))
            .frame(minHeight: 56)
        }
        .foregroundStyle(recorder.isRecording ? .red : .accentColor)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    private var countsSummary: String {
        let counts = recorder.counts
        return SoundClass.allCases
            .map { "\(displayName($0.rawValue)): \(counts[$0, default: 0])" }
            .joined(separator: " · ")
    }

    private var hasMessage: Binding<Bool> {
        Binding(get: { recorder.message != nil }, set: { if !$0 { recorder.message = nil } })
    }
}

// MARK: - Row and detail

struct RecordingRow: View {
    let recorder: DatasetRecorderService
    let recording: Recording

    var body: some View {
        HStack(spacing: 12) {
            let playing = recorder.playingURL == recording.url
            Button {
                recorder.togglePlayback(recording)
            } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.borderless)
            .disabled(recorder.isRecording)
            .accessibilityLabel(playing ? "Stop playback" : "Play")

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let m = recording.metadata
        return [displayName(m.label.rawValue), seconds(m.durationSeconds), displayName(m.containerType.rawValue),
                displayName(m.liquidType.rawValue)].joined(separator: " · ")
    }
}

struct RecordingDetailView: View {
    let recorder: DatasetRecorderService
    let recording: Recording

    @State private var name: String
    @State private var metadata: RecordingMetadata
    @State private var error: String?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    init(recorder: DatasetRecorderService, recording: Recording) {
        self.recorder = recorder
        self.recording = recording
        _name = State(initialValue: recording.name)
        _metadata = State(initialValue: recording.metadata)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                Button {
                    recorder.togglePlayback(recording)
                } label: {
                    Label(recorder.playingURL == recording.url ? "Stop" : "Play",
                          systemImage: recorder.playingURL == recording.url ? "stop.fill" : "play.fill")
                }
                LabeledContent("Length", value: seconds(metadata.durationSeconds))
                LabeledContent("Sample rate", value: "\(Int(metadata.sampleRate)) Hz")
                LabeledContent("Recorded", value: metadata.recordedAt.formatted(date: .abbreviated, time: .standard))
            }
            Section {
                TagPickers(metadata: $metadata)
            } header: {
                Text("Labels")
            } footer: {
                Text("Changing the sound label moves the clip to that class folder.")
            }
            Section {
                Button("Delete recording", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle("Recording")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try recorder.update(recording, name: name, metadata: metadata)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
        .confirmationDialog("Delete this recording? This can't be undone.", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                recorder.delete(recording)
                dismiss()
            }
        }
        .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
        .onDisappear { recorder.stopPlayback() }
    }
}

// MARK: - Pickers

struct TagPickers: View {
    @Binding var metadata: RecordingMetadata

    var body: some View {
        EnumPicker("Sound", selection: $metadata.label)
        EnumPicker("Container", selection: $metadata.containerType)
        EnumPicker("Material", selection: $metadata.material)
        EnumPicker("Liquid", selection: $metadata.liquidType)
        EnumPicker("Pouring speed", selection: $metadata.pouringSpeed)
        EnumPicker("Fill level", selection: $metadata.groundTruthType)
        TextField("Notes (optional)", text: $metadata.notes, axis: .vertical)
    }
}

/// A picker over any string-backed enum, one row per case.
struct EnumPicker<Value: CaseIterable & Hashable & RawRepresentable<String>>: View
where Value.AllCases: RandomAccessCollection {
    let title: LocalizedStringKey
    @Binding var selection: Value

    init(_ title: LocalizedStringKey, selection: Binding<Value>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Value.allCases, id: \.self) { value in
                Text(displayName(value.rawValue)).tag(value)
            }
        }
    }
}

/// "paper_cup" → "Paper cup".
private func displayName(_ raw: String) -> String {
    let words = raw.replacingOccurrences(of: "_", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
}

private func seconds(_ value: Double) -> String {
    value > 0 ? String(format: "%.1f s", value) : "–"
}

#Preview {
    DataCollectionView(recorder: DatasetRecorderService(audio: AudioCaptureService()))
}

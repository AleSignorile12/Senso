// TrainSensoModels.swift
// Senso: macOS-only training + evaluation for the Core ML models the app loads.
// Create ML only runs on a Mac, so this is a command-line script, not part of the app.
// Full workflow: README.md in this folder.
//
//   cd MLTraining
//   xcrun swift TrainSensoModels.swift train-sound [--version N] [--iterations 25] [--include-ambiguous]
//   xcrun swift TrainSensoModels.swift evaluate-sound Models/SensoSoundClassifier_v1.mlmodel [--test TestDataset]
//   xcrun swift TrainSensoModels.swift train-objects  [--dataset VisionDataset]   (template)
//   xcrun swift TrainSensoModels.swift train-activity [--dataset MotionDataset]   (template)

import CoreML
import CreateML
import Foundation
import SoundAnalysis

// MARK: - Arguments and helpers

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func flag(_ name: String) -> Bool { args.contains(name) }

let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

func path(_ relative: String) -> URL {
    URL(fileURLWithPath: relative, relativeTo: workingDirectory).standardizedFileURL
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

func percent(_ value: Double) -> String {
    value.isFinite ? String(format: "%.1f%%", value * 100) : "n/a"
}

/// Accuracy, or "n/a" when Create ML had no data for that split (tiny datasets).
func accuracy(_ metrics: MLClassifierMetrics) -> String {
    metrics.isValid ? percent(1 - metrics.classificationError) : "n/a (\(metrics.error?.localizedDescription ?? "no data"))"
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Next free version number for `<prefix>_v<N>.mlmodel` inside `folder`.
func nextVersion(prefix: String, in folder: URL) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let used = names.compactMap { name -> Int? in
        guard name.hasPrefix(prefix + "_v"), name.hasSuffix(".mlmodel") else { return nil }
        return Int(name.dropFirst(prefix.count + 2).dropLast(".mlmodel".count))
    }
    return (used.max() ?? 0) + 1
}

func modelURL(prefix: String) throws -> URL {
    let folder = path(option("--out") ?? "Models")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let version = option("--version").flatMap(Int.init) ?? nextVersion(prefix: prefix, in: folder)
    return folder.appendingPathComponent("\(prefix)_v\(version).mlmodel")
}

func metadata(_ description: String, version url: URL, license: String? = nil) -> MLModelMetadata {
    // Version string comes from the file name so app logs can say exactly which model ran.
    MLModelMetadata(
        author: "Senso",
        shortDescription: description,
        license: license,
        version: url.deletingPathExtension().lastPathComponent,
        additional: ["trainedAt": ISO8601DateFormatter().string(from: Date())]
    )
}

// MARK: - Sound classifier (Stage 1: pouring vs not pouring)

/// Folder names. Must match `SoundClass` raw values in SharedModels/SensoModels.swift.
let soundClasses = ["pouring", "not_pouring", "background_noise", "ambiguous"]
let audioExtensions: Set<String> = ["wav", "caf", "aif", "aiff", "m4a"]
let overlapFactor = 0.75
let minFilesPerClass = 5
let minFilesForHoldout = 10

func collectAudio(in root: URL, includeAmbiguous: Bool) -> [String: [URL]] {
    var result: [String: [URL]] = [:]
    for label in soundClasses where includeAmbiguous || label != "ambiguous" {
        let folder = root.appendingPathComponent(label, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let audio = files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        if !audio.isEmpty { result[label] = audio }
    }
    return result
}

func printCounts(_ files: [String: [URL]], title: String) {
    print(title)
    for label in files.keys.sorted() { print("  \(label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(files[label]!.count) files") }
}

func trainSound() async throws {
    let datasetURL = path(option("--dataset") ?? "Dataset")
    let includeAmbiguous = flag("--include-ambiguous")
    let all = collectAudio(in: datasetURL, includeAmbiguous: includeAmbiguous)
    printCounts(all, title: "Dataset: \(datasetURL.path)")

    guard all.count >= 2 else {
        fail("Need audio in at least 2 class folders (pouring + one other). Record with the app's Data Collection screen.")
    }
    if let thin = all.first(where: { $0.value.count < minFilesPerClass }) {
        fail("'\(thin.key)' has \(thin.value.count) files; need at least \(minFilesPerClass) per class.")
    }

    // Honest evaluation needs files the model never saw. Prefer a separate TestDataset folder
    // (ideally recorded on another day / in another room); else hold out 20% per class.
    let testURL = path(option("--test") ?? "TestDataset")
    var train = all
    var test = collectAudio(in: testURL, includeAmbiguous: includeAmbiguous)
    if !test.isEmpty {
        printCounts(test, title: "Held-out test set: \(testURL.path)")
    } else if all.values.allSatisfy({ $0.count >= minFilesForHoldout }) {
        let split = try MLSoundClassifier.DataSource.filesByLabel(all).stratifiedSplit(proportions: [0.8, 0.2], seed: 42)
        train = split[0]
        test = split[1]
        print("No TestDataset/ folder: holding out 20% of files per class for evaluation.")
    } else {
        print("⚠ Fewer than \(minFilesForHoldout) files in some class and no TestDataset/: training on everything, NO honest evaluation.")
        test = [:]
    }

    let iterations = option("--iterations").flatMap(Int.init) ?? 25
    let parameters = MLSoundClassifier.ModelParameters(
        validation: .split(strategy: .automatic),
        maxIterations: iterations,
        overlapFactor: overlapFactor,
        algorithm: .transferLearning(
            featureExtractor: .audioFeaturePrint(type: .sound),
            classifier: .logisticRegressor
        )
    )

    print("Training MLSoundClassifier (audioFeaturePrint .sound, overlap \(overlapFactor), \(iterations) iterations)…")
    let classifier = try MLSoundClassifier(trainingData: .filesByLabel(train), parameters: parameters)
    print("  training accuracy:   \(accuracy(classifier.trainingMetrics))")
    print("  validation accuracy: \(accuracy(classifier.validationMetrics))  (windows from training files; optimistic)")

    // PrepareExternalData.swift names clips from non-commercial datasets with these prefixes.
    let nonCommercial = train.values.joined().filter { ["sow_", "esc50_"].contains(where: $0.lastPathComponent.hasPrefix) }.count
    let license = nonCommercial > 0
        ? "NOT FOR RELEASE: \(nonCommercial) training clips come from non-commercial datasets (ESC-50, The Sound of Water)."
        : "Trained on commercial-use data only: FSD50K CC0/CC BY clips, plus any of the developer's own recordings. Credits: TrainingDataCredits.txt."
    if nonCommercial > 0 { print("⚠ \(license)") }

    let url = try modelURL(prefix: "SensoSoundClassifier")
    try classifier.write(to: url, metadata: metadata("Senso Stage 1 pour sound classifier: \(train.keys.sorted().joined(separator: ", "))", version: url, license: license))
    print("✓ Wrote \(url.path)")

    if !test.isEmpty { try await evaluateSound(modelURL: url, testFiles: test) }
}

/// Collects the top label of every analysis window SoundAnalysis produces.
final class WindowCollector: NSObject, SNResultsObserving {
    var topLabels: [String] = []
    var failure: (any Error)?

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult, let top = result.classifications.first else { return }
        topLabels.append(top.identifier)
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) { failure = error }
}

/// Runs the model through SoundAnalysis (the same framework the iPhone uses) on held-out files.
/// Every window inherits its file's label, so trim silence from recordings or recall looks worse than it is.
func evaluateSound(modelURL: URL, testFiles: [String: [URL]]) async throws {
    let compiled = try await MLModel.compileModel(at: modelURL)
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let model = try MLModel(contentsOf: compiled, configuration: configuration)

    var confusion: [String: [String: Int]] = [:]
    var windowCount = 0
    var computeSeconds = 0.0
    var windowSeconds = 0.0
    let clock = ContinuousClock()

    for (actual, files) in testFiles {
        for file in files {
            let analyzer = try SNAudioFileAnalyzer(url: file)
            let request = try SNClassifySoundRequest(mlModel: model)
            request.overlapFactor = overlapFactor
            windowSeconds = request.windowDuration.seconds
            let collector = WindowCollector()
            try analyzer.add(request, withObserver: collector)
            computeSeconds += seconds(clock.measure { analyzer.analyze() })
            if let error = collector.failure {
                print("  ! skipped \(file.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            windowCount += collector.topLabels.count
            for predicted in collector.topLabels { confusion[actual, default: [:]][predicted, default: 0] += 1 }
        }
    }
    guard windowCount > 0 else { fail("No analysis windows produced. Are the test files shorter than one window (\(windowSeconds)s)?") }

    let modelLabels = model.modelDescription.classLabels?.compactMap { $0 as? String } ?? []
    let labels = Set(modelLabels).union(confusion.keys).union(confusion.values.flatMap(\.keys)).sorted()
    let width = max(12, (labels.map(\.count).max() ?? 0) + 2)
    func cell(_ text: String) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }

    print("\nEvaluation on \(windowCount) windows from \(testFiles.values.map(\.count).reduce(0, +)) held-out files")
    print("\nConfusion matrix (rows = actual, columns = predicted):")
    print(cell("") + labels.map(cell).joined())
    for actual in labels where confusion[actual] != nil {
        print(cell(actual) + labels.map { cell("\(confusion[actual]?[$0] ?? 0)") }.joined())
    }

    print("\n" + cell("class") + cell("precision") + cell("recall") + cell("support"))
    var correct = 0
    for label in labels {
        let truePositives = confusion[label]?[label] ?? 0
        let predictedTotal = confusion.values.reduce(0) { $0 + ($1[label] ?? 0) }
        let actualTotal = confusion[label]?.values.reduce(0, +) ?? 0
        correct += truePositives
        let precision = predictedTotal > 0 ? Double(truePositives) / Double(predictedTotal) : .nan
        let recall = actualTotal > 0 ? Double(truePositives) / Double(actualTotal) : .nan
        print(cell(label) + cell(percent(precision)) + cell(percent(recall)) + cell("\(actualTotal)"))
    }
    print("\nWindow accuracy: \(percent(Double(correct) / Double(windowCount)))")

    let hop = windowSeconds * (1 - overlapFactor)
    print("\nLatency")
    print("  analysis window: \(String(format: "%.3f", windowSeconds)) s, new result every \(String(format: "%.3f", hop)) s (overlap \(overlapFactor))")
    print("  Mac compute per window: \(String(format: "%.2f", computeSeconds / Double(windowCount) * 1000)) ms (includes file decoding; measure on iPhone too)")
}

// MARK: - Container detector (template, Vision pipeline)

func trainObjects() throws {
    let dataset = path(option("--dataset") ?? "VisionDataset")
    guard FileManager.default.fileExists(atPath: dataset.appendingPathComponent("annotations.json").path) else {
        fail("No \(dataset.path)/annotations.json. Put images + a Create ML JSON annotation file there (README → Vision template).")
    }
    print("Training MLObjectDetector on \(dataset.path)…")
    let detector = try MLObjectDetector(
        trainingData: .directoryWithImagesAndJsonAnnotation(at: dataset),
        parameters: .init(validation: .split(strategy: .automatic)),
        annotationType: .boundingBox()
    )
    print("  validation mAP@IoU50: \(percent(detector.validationMetrics.meanAveragePrecision.IoU50))")
    let url = try modelURL(prefix: "SensoContainerDetector")
    try detector.write(to: url, metadata: metadata("Senso container detector (cup, mug, glass)", version: url))
    print("✓ Wrote \(url.path)")
}

// MARK: - Watch motion classifier (template, watchOS pipeline)

/// CSV columns each motion recording must have, sampled at 50 Hz on the Watch.
let motionFeatures = ["roll", "pitch", "yaw", "rotationX", "rotationY", "rotationZ", "accelX", "accelY", "accelZ"]

func trainActivity() throws {
    let dataset = path(option("--dataset") ?? "MotionDataset")
    guard FileManager.default.fileExists(atPath: dataset.path) else {
        fail("No \(dataset.path). Expected <label>/<recording>.csv with columns: \(motionFeatures.joined(separator: ",")) (README → Motion template).")
    }
    print("Training MLActivityClassifier on \(dataset.path) (1 s windows at 50 Hz)…")
    let classifier = try MLActivityClassifier(
        trainingData: .labeledDirectories(at: dataset),
        featureColumns: motionFeatures,
        parameters: .init(validation: .split(strategy: .automatic), batchSize: 32, maximumIterations: 20, predictionWindowSize: 50)
    )
    print("  training accuracy:   \(accuracy(classifier.trainingMetrics))")
    print("  validation accuracy: \(accuracy(classifier.validationMetrics))")
    let url = try modelURL(prefix: "SensoWatchMotion")
    try classifier.write(to: url, metadata: metadata("Senso wrist pour-tilt classifier", version: url))
    print("✓ Wrote \(url.path)")
}

// MARK: - Entry point

do {
    switch command {
    case "train-sound":
        try await trainSound()
    case "evaluate-sound":
        guard args.count > 1, !args[1].hasPrefix("--") else { fail("Usage: evaluate-sound <model.mlmodel> [--test TestDataset]") }
        let test = collectAudio(in: path(option("--test") ?? "TestDataset"), includeAmbiguous: flag("--include-ambiguous"))
        guard !test.isEmpty else { fail("No audio in the test folder. Put held-out recordings in TestDataset/<class>/.") }
        try await evaluateSound(modelURL: path(args[1]), testFiles: test)
    case "train-objects":
        try trainObjects()
    case "train-activity":
        try trainActivity()
    default:
        print("""
        Senso model training (macOS).
          train-sound      Train the pour sound classifier from Dataset/<class>/*.wav, then evaluate it
          evaluate-sound   Evaluate an existing .mlmodel on TestDataset/<class>/*.wav
          train-objects    Template: container detector from VisionDataset/
          train-activity   Template: Watch tilt classifier from MotionDataset/
        See README.md.
        """)
    }
} catch {
    fail(error.localizedDescription)
}

// PrepareExternalData.swift
// Turns the downloaded public datasets in External/ into Dataset/<class>/ and TestDataset/<class>/
// clips for TrainSensoModels.swift. Files it writes start with "sow_", "esc50_" or "fsd_", so your own
// recordings in the same folders are never touched. Re-running replaces only those files.
//
//   cd MLTraining
//   xcrun swift PrepareExternalData.swift                          # App Store model: commercial-use data only
//   xcrun swift PrepareExternalData.swift --include-noncommercial  # research comparison only, never ship it
//
// Sources (see External/ATTRIBUTION.md):
//   • FSD50K (Fonseca et al., 2022; CC0 and CC BY clips only, listed in External/fsd50k/manifest.csv):
//     "Pour" and "Fill (with liquid)" from many Freesound recordists, plus negatives: kitchen sounds, speech,
//     music, room and street noise, and water that isn't a pour (rain, streams, toilets). Commercial use is
//     allowed with attribution, so this is the only source used by default.
//     Test = FSD50K eval clips from half of the eval recordists (a stable hash of the uploader name); the
//     other half train, so test clips always come from recordists the model never heard.
//   • With --include-noncommercial only:
//     The Sound of Water (Bagad et al., 2025; no license stated): 790 pours, every file is "pouring"
//     (the files are already trimmed to the pour). Test = every 4th container.
//     ESC-50 (Piczak, 2015; CC BY-NC 3.0): pouring_water plus 49 other categories as negatives. Test = fold 5.

import AVFoundation
import Foundation

let external = URL(fileURLWithPath: "External")
let prefixes = ["sow_", "esc50_", "fsd_"]
let includeNonCommercial = CommandLine.arguments.contains("--include-noncommercial")

/// ESC-50 categories → Senso class. Steady ambient sound is background_noise; every other category,
/// including water that isn't a pour (drops, toilet flush, waves), is not_pouring.
let escPouring: Set = ["pouring_water"]
let escBackground: Set = [
    "airplane", "engine", "helicopter", "train", "rain", "sea_waves", "thunderstorm", "wind", "crackling_fire",
    "vacuum_cleaner", "washing_machine", "chainsaw", "hand_saw", "crickets", "insects", "chirping_birds",
]
func escLabel(_ category: String) -> String {
    escPouring.contains(category) ? "pouring" : escBackground.contains(category) ? "background_noise" : "not_pouring"
}

// MARK: - Audio helpers

func readMono(_ url: URL) throws -> (samples: [Float], format: AVAudioFormat) {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let mono = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)!
    return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), mono)
}

/// Writes samples[from..<to] (in seconds) as 16-bit WAV, if at least `minimum` seconds long.
@discardableResult
func writeSegment(_ samples: [Float], format: AVAudioFormat, from start: Double, to end: Double,
                  minimum: Double = 1.2, to url: URL) throws -> Bool {
    let rate = format.sampleRate
    let first = max(0, Int(start * rate))
    let last = min(samples.count, Int(end * rate))
    guard Double(last - first) / rate >= minimum else { return false }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first))!
    buffer.frameLength = AVAudioFrameCount(last - first)
    samples[first..<last].withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: last - first) }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    return true
}

/// ESC-50 clips are padded with digital silence to 5 s; drop it so silence isn't labelled "pouring".
func trimmedSilence(_ samples: [Float], rate: Double) -> (start: Double, end: Double) {
    let threshold: Float = 0.001
    let first = samples.firstIndex { abs($0) > threshold } ?? 0
    let last = samples.lastIndex { abs($0) > threshold } ?? 0
    return (Double(first) / rate, Double(last) / rate)
}

func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    for character in text {
        switch character {
        case "\"": quoted.toggle()
        case "," where !quoted: row.append(field); field = ""
        case "\n" where !quoted, "\r\n" where !quoted: row.append(field); rows.append(row); row = []; field = ""  // Swift reads CRLF as one Character
        case "\r": break
        default: field.append(character)
        }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

/// String.hashValue changes every run; the train/test split must not.
func stableHash(_ text: String) -> UInt32 {
    text.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }  // FNV-1a
}

func folder(_ split: String, _ label: String) throws -> URL {
    let url = URL(fileURLWithPath: split == "test" ? "TestDataset" : "Dataset").appending(path: label)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Clean previous output

for split in ["Dataset", "TestDataset"] {
    for label in ["pouring", "not_pouring", "background_noise", "ambiguous"] {
        let dir = URL(fileURLWithPath: split).appending(path: label)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where prefixes.contains(where: name.hasPrefix) {
            try FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }
}

// The script is single-threaded; Swift 6 still wants global state marked.
nonisolated(unsafe) var counts: [String: Int] = [:]
func count(_ split: String, _ label: String) { counts["\(split)/\(label)", default: 0] += 1 }

// MARK: - The Sound of Water

let sow = external.appending(path: "sound-of-water")
var sowRows: [String: (file: String, container: String)] = [:]
for name in includeNonCommercial ? ["train", "test_I", "test_II", "test_III"] : [] {
    guard let text = try? String(contentsOf: sow.appending(path: "splits/\(name).csv"), encoding: .utf8) else { continue }
    let rows = parseCSV(text)
    let header = rows[0]
    func column(_ key: String) -> Int { header.firstIndex(of: key)! }
    for row in rows.dropFirst() where row.count == header.count {
        let id = row[column("video_id")]
        guard sowRows[id] == nil else { continue }
        sowRows[id] = (row[column("file_name")].split(separator: "/").last!.replacingOccurrences(of: ".mp4", with: ".wav"),
                       row[column("container_id")])
    }
}
// The dataset's own test splits share containers, so split by container instead.
let containers = Set(sowRows.values.map(\.container)).sorted()
let testContainers = Set(containers.enumerated().filter { $0.offset % 4 == 1 }.map(\.element))
let sowSplit = sowRows.mapValues { testContainers.contains($0.container) ? "test" : "train" }
print(includeNonCommercial ? "Sound of Water: \(sowRows.count) annotated recordings" : "Commercial-use data only (FSD50K CC0/CC BY)")
for (id, row) in sowRows.sorted(by: { $0.key < $1.key }) {
    let url = sow.appending(path: "audios/\(row.file)")
    guard let (samples, format) = try? readMono(url) else { continue }
    let split = sowSplit[id]!
    let duration = Double(samples.count) / format.sampleRate
    // The file is the pour; trim the edges in case the cut isn't frame-exact.
    if try writeSegment(samples, format: format, from: 0.2, to: duration - 0.15,
                        to: folder(split, "pouring").appending(path: "sow_\(id).wav")) { count(split, "pouring") }
}

// MARK: - ESC-50

let esc = external.appending(path: "esc50/ESC-50-master")
if includeNonCommercial, let text = try? String(contentsOf: esc.appending(path: "meta/esc50.csv"), encoding: .utf8) {
    let rows = parseCSV(text)
    let header = rows[0]
    func column(_ key: String) -> Int { header.firstIndex(of: key)! }
    for row in rows.dropFirst() where row.count == header.count {
        let label = escLabel(row[column("category")])
        let split = row[column("fold")] == "5" ? "test" : "train"
        let name = row[column("filename")]
        guard let (samples, format) = try? readMono(esc.appending(path: "audio/\(name)")) else { continue }
        let (start, end) = trimmedSilence(samples, rate: format.sampleRate)
        if try writeSegment(samples, format: format, from: start, to: end + 0.05, minimum: 1.0,
                            to: folder(split, label).appending(path: "esc50_\(name)")) { count(split, label) }
    }
} else {
    print("ESC-50 skipped (needs --include-noncommercial, and the files at \(esc.path))")
}

// MARK: - FSD50K

let fsd = external.appending(path: "fsd50k")
nonisolated(unsafe) var credits: [String] = []
nonisolated(unsafe) var trainPours: [URL] = [], trainNoise: [URL] = [], trainTalk: [URL] = []
if let text = try? String(contentsOf: fsd.appending(path: "manifest.csv"), encoding: .utf8) {
    let rows = parseCSV(text)
    let header = rows[0]
    func column(_ key: String) -> Int { header.firstIndex(of: key)! }
    for row in rows.dropFirst() where row.count == header.count {
        let (name, fsdSplit, label) = (row[column("fname")], row[column("split")], row[column("senso_label")])
        let split = fsdSplit == "eval" && stableHash(row[column("freesound_uploader")]) % 2 == 0 ? "test" : "train"
        guard let (samples, format) = try? readMono(fsd.appending(path: "\(fsdSplit)/\(name).wav")) else { continue }
        let (start, end) = trimmedSilence(samples, rate: format.sampleRate)
        if try writeSegment(samples, format: format, from: start, to: end + 0.05, minimum: 1.0,
                            to: folder(split, label).appending(path: "fsd_\(name).wav")) {
            count(split, label)
            if split == "train" {
                let written = try folder(split, label).appending(path: "fsd_\(name).wav")
                let labels = row[column("fsd50k_labels")]
                if label == "pouring" { trainPours.append(written) }
                if label == "background_noise" { trainNoise.append(written) }
                if label == "not_pouring", labels.contains("Speech") || labels.contains("Conversation") { trainTalk.append(written) }
            }
            let license = row[column("license")]
            if license.contains("/by/") {
                let version = license.split(separator: "/").last.map(String.init) ?? ""
                credits.append("“\(row[column("title")])” by \(row[column("freesound_uploader")]), CC BY \(version), freesound.org/s/\(name)/")
            }
        }
    }
    // CC BY requires crediting each creator; the app shows this file under Settings › Help › Acknowledgements.
    let creditsURL = URL(fileURLWithPath: "Models/TrainingDataCredits.txt")
    try credits.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: "\n")
        .write(to: creditsURL, atomically: true, encoding: .utf8)
    print("\(credits.count) CC BY credits written to \(creditsURL.path). Copy it next to the model in SensoApp/ML/.")
} else {
    print("FSD50K manifest not found at \(fsd.path): skipping")
}

// MARK: - Augmented pours (training only)
//
// FSD50K has about 6× more not-pouring audio than pouring, and Create ML's sound classifier has no class
// weights. Each training pour is written twice more: mixed with room noise, and with someone talking, at
// 5–20 dB below the pour (the phone sits next to the cup). Noise comes from training clips only, so nothing
// from the test set leaks in. Test clips are never augmented.

/// SplitMix64: seeded, so re-running the script writes the same mixes.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func rms(_ samples: [Float]) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
}

/// Writes `pour` with `noise` added `snr` dB below it (noise looped from a random offset).
func mix(_ pourURL: URL, with noiseURL: URL, snr: Float, generator: inout SeededGenerator, to url: URL) throws -> Bool {
    let (pour, format) = try readMono(pourURL)
    let (noise, noiseFormat) = try readMono(noiseURL)
    let pourLevel = rms(pour), noiseLevel = rms(noise)
    guard format.sampleRate == noiseFormat.sampleRate, pourLevel > 0, noiseLevel > 0 else { return false }
    let offset = Int.random(in: 0..<noise.count, using: &generator)
    let gain = pourLevel / (noiseLevel * pow(10, snr / 20))
    var mixed = pour.indices.map { pour[$0] + gain * noise[(offset + $0) % noise.count] }
    let peak = mixed.map(abs).max() ?? 0
    if peak > 0.99 { mixed = mixed.map { $0 * 0.99 / peak } }
    return try writeSegment(mixed, format: format, from: 0, to: Double(mixed.count) / format.sampleRate, minimum: 1.0, to: url)
}

var generator = SeededGenerator(state: 42)
if !trainNoise.isEmpty, !trainTalk.isEmpty {
    for pour in trainPours {
        let name = pour.deletingPathExtension().lastPathComponent.dropFirst(4)  // drop "fsd_"
        for (kind, pool) in [("noise", trainNoise), ("talk", trainTalk)] {
            let noise = pool.randomElement(using: &generator)!
            let snr = Float.random(in: 5...20, using: &generator)
            if try mix(pour, with: noise, snr: snr, generator: &generator,
                       to: folder("train", "pouring").appending(path: "fsd_mix\(kind)_\(name).wav")) { count("train", "pouring (mixed)") }
        }
    }
}

print("\nWritten clips:")
for key in counts.keys.sorted() { print("  \(key.padding(toLength: 26, withPad: " ", startingAt: 0)) \(counts[key]!)") }

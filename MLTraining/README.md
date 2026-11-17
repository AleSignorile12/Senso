# Senso ML training

This folder trains the Core ML models the Senso app loads. It runs on a **Mac** only, because Create ML is macOS-only. The app never trains anything.

The app ships with `SensoSoundClassifier_v3`, trained on commercial-use public data (below). Without a bundled model it falls back to a DSP heuristic and labels itself **"DSP Mode (Uncalibrated)"**.

## 0. Train from public data (what the App Store model uses)

You don't have to record hundreds of clips. The bundled model, **v3**, is trained only on data that allows
commercial use: FSD50K clips licensed CC0 or CC BY. Licenses and per-clip credits are in
`External/ATTRIBUTION.md`; the app shows the CC BY credits under Settings › Help › Acknowledgements.

| Source | What it gives | Where it goes | Used by default |
| --- | --- | --- | --- |
| FSD50K (HF `Fhrozen/FSD50k`, CC0/CC BY clips only) | 359 pours by many recordists; kitchen sounds, speech, music, room and street noise, water that isn't a pour | `External/fsd50k/` with `manifest.csv` | Yes |
| The Sound of Water (HF `bpiyush/sound-of-water`, `audios/`) | 790 pours into 48 containers. **No license stated** | `External/sound-of-water/` | Only with `--include-noncommercial` |
| ESC-50 (GitHub `karolpiczak/ESC-50`, unzipped) | pouring_water plus 49 other categories. **Non-commercial** | `External/esc50/ESC-50-master/` | Only with `--include-noncommercial` |

```bash
xcrun swift PrepareExternalData.swift          # fsd_ clips into Dataset/ and TestDataset/, plus Models/TrainingDataCredits.txt
xcrun swift TrainSensoModels.swift train-sound --iterations 100
cp Models/SensoSoundClassifier_vN.mlmodel Models/TrainingDataCredits.txt ../SensoApp/ML/   # and remove the old model
```

- **Test split:** FSD50K eval clips from half of the eval recordists, chosen by a stable hash of the
  uploader name. The test numbers therefore come from people and microphones the model never heard.
- **Augmentation:** FSD50K has about 6 times more not-pouring audio than pouring, and Create ML's sound
  classifier has no class weights. So the prep script also writes each training pour mixed with room noise
  and with speech, 5–20 dB below the pour. Test clips are never mixed.
- **Your own recordings:** the prep script never touches files in the same folders that aren't its own, so
  you can add your recordings and retrain.
- **Licence check:** `train-sound` writes the data licence into the model's metadata. If any training clip
  comes from a non-commercial source, it prints a warning and marks the model NOT FOR RELEASE.

### Results (16 Nov 2026, 531 held-out FSD50K clips, 0.975 s windows)

"Through the app's rule" replays each clip through the start/keep/pause rule in `PourEstimationEngine`:
start at ≥ 0.7, keep at ≥ 0.4, pause after 1.5 s.

| Model | Training data | Top-label pouring precision / recall | Pours detected | Pour time detected | False starts per minute of non-pour audio |
| --- | --- | --- | --- | --- | --- |
| v1 | Sound of Water, ESC-50, FSD50K (not publishable) | 68.6 % / 68.2 % | 99 % | 82 % | 1.9 |
| v2 | FSD50K, no augmentation | 80.4 % / 58.9 % | 91 % | 70 % | 0.7 |
| **v3** (bundled) | FSD50K + mixed pours | 65.1 % / 71.9 % | 96 % | 83 % | 1.4 |

- **Why v3:** the pour-time column matters most. If detection drops mid-pour, the level estimate freezes and
  Stop comes late; a false start only causes an early "pouring" message.
- **Threshold:** the start threshold of 0.7 was chosen on this test set (0.6 gave 84 % and 2.0 per minute),
  so the v3 numbers are slightly optimistic.
- **Clean close-up pours:** on The Sound of Water and ESC-50 test pours (information only, not used for
  training), v3 detects all 252 pours and 93 % of pour time. v1 gets 99 %, but it trained on those datasets.
  On the FSD50K test above, v3 is at least as good as v1.
- **Not verified:** an iPhone microphone in a real kitchen. Record a few real pours with Data Collection
  (Debug builds), put them in `TestDataset/`, and run `evaluate-sound` before release.

## Fill level (no training)

The fill estimate isn't a trained model. `SensoApp/ML/FillEstimator.swift` tracks the air-column resonance, whose period falls in a straight line as the cup fills, and a one-pour calibration per cup measures its empty and full pitch. Replay it on Sound of Water with:

```bash
xcrun swiftc -O -parse-as-library ../SharedModels/SensoModels.swift ../SensoApp/ML/FillEstimator.swift EvaluateFillEstimator.swift -o evaluate-fill
./evaluate-fill --target 0.9
```

Read the numbers as a sanity check only: Sound of Water pours don't reliably end at "full", so its fill ground truth is weak. The tracker follows the physics well on tall cylinders for roughly 15–65 % of the pour; near the brim the resonance often fades and the estimate extrapolates the fill rate. Measuring real accuracy needs recordings with a known final level (Data Collection, ground truth "measured").

## One-time setup

The Mac's command-line tools must point at Xcode, not at the stand-alone Command Line Tools:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

If you prefer not to change that, put `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of every command below.

## 1. Collect audio

Put one recording per file into the matching class folder:

| Folder | What goes in it |
|---|---|
| `Dataset/pouring/` | Liquid actually flowing into a container, from first drop to last |
| `Dataset/not_pouring/` | Kitchen sounds near the phone that are **not** pouring: setting a cup down, a kettle clicking, stirring, tapping |
| `Dataset/background_noise/` | Room tone only: fridge hum, TV, talking, street noise |
| `Dataset/ambiguous/` | Clips you are unsure about. Ignored unless you pass `--include-ambiguous` |

The folder names are a contract with the app (`SoundClass` in `SharedModels/SensoModels.swift`). Don't rename them.

Tips that matter more than model settings:

- **Record the way the app will be used.** Phone flat on the counter, next to the cup, microphone not covered.
- **Vary everything.** Ceramic mug, glass, paper cup, thermos; water, tea, milk; slow and fast pours; quiet and noisy rooms.
- **Trim silence.** Every 1-second window of a file gets the file's label. A pouring clip with 3 s of silence before the pour teaches the model that silence means pouring.
- **Aim for 50+ clips per class.** Under 50, Create ML can't make its own validation split. Under 5, the script refuses to train.
- Formats: `.wav`, `.caf`, `.aiff`, `.m4a`. Mono, 16 kHz or higher.

The app's **Data Collection** screen records clips in exactly this layout, with a `.json` metadata file next to each clip (container, material, liquid, speed, ground-truth type). The training script ignores the `.json` files. They are there so you can see what your dataset covers.

To use it:

1. Run Senso from Xcode (a Debug build: the App Store and TestFlight builds don't include Data Collection). On the start screen, tap the small waveform button at the top right.
2. Pick the labels, tap **Start recording**, pour, tap **Stop**. Clips shorter than 1 second aren't saved.
3. Tap a clip to play it back, rename it, change its labels, or delete it. Changing the sound label moves the clip to that folder.
4. Tap **Export dataset (.zip)** and AirDrop it to your Mac. Unzip it, then copy the class folders into `Dataset/`. Copy them into `TestDataset/` instead if that batch is your held-out test set.

The clips are also in the iPhone's Files app under **On My iPhone › Senso › Dataset**.

## 2. Keep a separate test set

A model scored on clips it trained on always looks better than it is. For an honest score, record a second batch on another day or in another room, and put it in `TestDataset/` with the same four folders.

If `TestDataset/` is missing, the script holds back 20% of the clips in each class instead. That's weaker, because clips from the same session sound alike.

## 3. Train

```bash
cd MLTraining
xcrun swift TrainSensoModels.swift train-sound
```

This trains an `MLSoundClassifier` (Apple's `audioFeaturePrint` sound features, overlap factor 0.75), writes `Models/SensoSoundClassifier_v<N>.mlmodel` with the next free version number, and then evaluates it on the held-out clips.

Options: `--version 3`, `--iterations 40`, `--include-ambiguous`, `--dataset <folder>`, `--test <folder>`, `--out <folder>`.

To re-score an existing model:

```bash
xcrun swift TrainSensoModels.swift evaluate-sound Models/SensoSoundClassifier_v3.mlmodel
```

## 4. Read the results honestly

The evaluation prints:

- **Confusion matrix.** Rows are the true class, columns are what the model said. Big numbers off the diagonal are mistakes.
- **Precision for `pouring`.** When the model says "pouring", how often it's right. Low precision means false alarms.
- **Recall for `pouring`.** Of all real pouring, how much the model caught. **This is the safety number.** A missed pour means a missed warning.
- **Latency.** Each analysis window is about 1 s of audio. A new result arrives every ~0.24 s at overlap 0.75. Mac compute time is not iPhone compute time, so check it on a device too.

"Validation accuracy" during training uses windows from the training clips. Trust the held-out evaluation, not that number.

## 5. Put the model in the app

1. Drag `Models/SensoSoundClassifier_v<N>.mlmodel` into Xcode and tick the **Senso** target.
2. Build. Xcode compiles it into the app bundle.
3. The app loads the highest-numbered `SensoSoundClassifier_v*` it finds. Its badge changes from "DSP Mode (Uncalibrated)" to the model version.

Keep old versions out of the app target, so a bad model can't be loaded by mistake.

## Stages

1. **Stage 1, shipped (v3):** pouring vs. not pouring vs. noise (this classifier).
2. **Stage 2:** discrete fill stages (for example `fill_low`, `fill_mid`, `fill_high`). Same script, new folders. Needs recordings labelled by fill level.
3. **Stage 3:** continuous fill %. Today this comes from physics (resonance pitch plus calibration, see "Fill level" above), not a trained model. A trained version needs recordings with **measured** ground truth (for example, filled on a kitchen scale).

## Templates (no data yet)

These subcommands compile and run, but stop with instructions until their dataset exists.

### Container detector: `train-objects`

`VisionDataset/` holds images plus one `annotations.json` in Create ML format:

```json
[
  { "image": "mug_001.jpg",
    "annotations": [ { "label": "mug", "coordinates": { "x": 320, "y": 240, "width": 180, "height": 200 } } ] }
]
```

`x`/`y` are the box centre in pixels, measured from the top-left corner. Output: `Models/SensoContainerDetector_v<N>.mlmodel`.

### Watch tilt classifier: `train-activity`

`MotionDataset/<label>/<recording>.csv`, for example `MotionDataset/pouring_tilt/` and `MotionDataset/idle/`. Each CSV is sampled at 50 Hz with these columns:

```
roll,pitch,yaw,rotationX,rotationY,rotationZ,accelX,accelY,accelZ
```

Prediction window: 50 samples (1 s). Output: `Models/SensoWatchMotion_v<N>.mlmodel`.

## Privacy

Recordings can pick up voices. Don't commit `Dataset/` or `TestDataset/` audio to a public repository.

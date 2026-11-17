# Training data attribution

The sound classifier (`Models/SensoSoundClassifier_v*.mlmodel`) is trained on clips that
`PrepareExternalData.swift` cuts from public datasets. None of the audio is redistributed in the app, only
the trained model.

**The App Store model (v3 onward) uses FSD50K CC0 and CC BY clips only.** The Sound of Water and ESC-50 are
used only when you pass `--include-noncommercial`. That's for research comparisons; such a model must never
ship, and `train-sound` marks it NOT FOR RELEASE in its metadata. v1 was trained with them and is no longer in
the app.

Their files were deleted from `External/` on 16 Nov 2026 to save space (1.6 GB). To run a research
comparison again, download them from the links below into `External/sound-of-water/` and
`External/esc50/ESC-50-master/`, then pass `--include-noncommercial`.

## The Sound of Water (research comparison only, not in the App Store model)

- Bagad, P., Tapaswi, M., Snoek, C. G. M., Zisserman, A. "The Sound of Water: Inferring Physical Properties
  from Pouring Liquids." ICASSP 2025. https://bpiyush.github.io/pouring-water-website/
- Data: https://huggingface.co/datasets/bpiyush/sound-of-water (805 pours into 50 containers).
- **License: not stated for the dataset** (the README license section is empty; the code is MIT, the paper
  CC BY 4.0). Ask the authors before shipping commercially.
- Used: every audio file as "pouring" (the files are already trimmed to the pour).

## ESC-50 (research comparison only, not in the App Store model)

- Piczak, K. J. "ESC: Dataset for Environmental Sound Classification." ACM Multimedia 2015.
  https://github.com/karolpiczak/ESC-50
- **License: CC BY-NC 3.0 (non-commercial).** Clips come from Freesound.org; per-clip authors are listed in
  the dataset's `meta/esc50.csv` (`src_file`) and on Freesound.
- Used: `pouring_water` as pouring, all 49 other categories as not_pouring or background_noise.

## FSD50K (pouring and all negatives; the only source the App Store model uses)

- Fonseca, E., Favory, X., Pons, J., Font, F., Serra, X. "FSD50K: An Open Dataset of Human-Labeled Sound
  Events." IEEE/ACM TASLP 30, 2022. https://zenodo.org/records/4060432
  (mirror used: https://huggingface.co/datasets/Fhrozen/FSD50k).
- **Licence:** the dataset is CC BY 4.0, and each clip keeps its own Freesound licence. **Only CC0 and CC BY
  clips were downloaded** (3,207 clips). `fsd50k/manifest.csv` lists every clip with its licence, Freesound
  uploader and title.
- **Attribution:** `PrepareExternalData.swift` writes `Models/TrainingDataCredits.txt`, one line per CC BY
  clip it used, with the title, creator, licence and Freesound link. That file is bundled in the app
  (`SensoApp/ML/`) and shown under Settings › Help › Acknowledgements, with a credit and link for FSD50K
  itself. CC0 clips need no credit.
- **Used:**
  - Pouring: "Pour" and "Fill (with liquid)", all 359 CC0/CC BY clips.
  - Not pouring: dishes, cutlery, microwave, frying, boiling and dripping (first selection); then speech,
    conversation, music, cupboards, drawers, doors, typing, footsteps, clinking glass, paper, coughs,
    laughter, pets, ringtones and toilet flushes.
  - Background noise: fans, traffic, crowds, hiss, buzz, idling engines, wind, rain, streams, waves and
    trains.

  Negatives never include taps, sinks or trickling water, which can sound like a real pour. The extra
  negatives were picked with a fixed random seed, at most 3 clips per recordist per category.

## Commercial release checklist

- `xcrun swift PrepareExternalData.swift` with no flags.
- Train, then check that `train-sound` printed no NOT FOR RELEASE warning.
- Copy the model and `Models/TrainingDataCredits.txt` into `SensoApp/ML/`, and delete older models there.

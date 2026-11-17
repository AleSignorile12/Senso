# Test fixtures

`SyntheticToneVsNoise.mlmodel` is a tiny sound classifier trained by `MLTraining/TrainSensoModels.swift`
on **synthetic** audio: white noise labelled `pouring`, sine tones labelled `not_pouring`. It exists only
so tests can exercise the trained-model code path. It knows nothing about real pouring and is never
part of the app.

## 4.0.3 (2026-11-22)

With `quranlab_tajweedformer` 4.0.3. No change to the microphone helper.

## 4.0.2 (2026-11-22)

With `quranlab_tajweedformer` 4.0.2, where nothing waits for Wi-Fi (the `unmeteredOnly` option of `prefetch()` is
gone, with no shim: downloads and uploads use any network) and errors carry their `cause`. No change to the
microphone helper.

## 4.0.1

With `quranlab_tajweedformer` 4.0.1. No change to the microphone helper.

## 4.0.0

The first release on pub.dev (2026-11-19), with `quranlab_tajweedformer` 4.0.0.

- `TajweedRecorder` captures 16 kHz mono 16-bit PCM with `record` 7 and pushes it into a TajweedFormer take. Apps
  that use the SDK's own microphone (`model.listen()`) do not need it.

History: a 1.0.0 was built with the plugin's 1.0.0 and never published.

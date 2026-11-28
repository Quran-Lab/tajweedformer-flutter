/* What the Flutter plugin keeps for the process on Windows and Linux, across a Dart hot restart.
 *
 * The C SDK allows one Client per process, and the Dart isolate that made it does not survive a hot restart (nor
 * does a second Flutter engine share it). The plugin keeps the Client, the Model and the open Session here, with a
 * fingerprint of the key, so the same key finds the same Client again, as on Android and iOS. Pointers only: this
 * library calls nothing of the SDK and links nothing. */
#ifndef QURANLAB_TAJWEEDFORMER_SHIM_H
#define QURANLAB_TAJWEEDFORMER_SHIM_H

#include <stdint.h>

#if defined(_WIN32)
#define QLTF_API __declspec(dllexport)
#else
#define QLTF_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum { QLTF_CLIENT = 0, QLTF_MODEL = 1, QLTF_SESSION = 2, QLTF_KEY = 3, QLTF_SLOTS = 4 };

/* The value of a slot (0 when none). */
QLTF_API intptr_t qltf_get(int32_t slot);
/* Sets a slot; returns its value before. */
QLTF_API intptr_t qltf_set(int32_t slot, intptr_t value);

#ifdef __cplusplus
}
#endif
#endif

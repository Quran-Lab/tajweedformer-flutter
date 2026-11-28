/* See quranlab_tajweedformer_shim.h. Each slot is one pointer-sized value, read and written atomically: the main
 * isolate and the plugin's engine isolate may run on different threads. */
#include "quranlab_tajweedformer_shim.h"

#if defined(_WIN32)
#include <windows.h>
static volatile LONG_PTR slots[QLTF_SLOTS];
QLTF_API intptr_t qltf_get(int32_t slot) {
  if (slot < 0 || slot >= QLTF_SLOTS) return 0;
  return (intptr_t)InterlockedCompareExchangePointer((PVOID volatile *)&slots[slot], NULL, NULL);
}
QLTF_API intptr_t qltf_set(int32_t slot, intptr_t value) {
  if (slot < 0 || slot >= QLTF_SLOTS) return 0;
  return (intptr_t)InterlockedExchangePointer((PVOID volatile *)&slots[slot], (PVOID)value);
}
#else
static intptr_t slots[QLTF_SLOTS];
QLTF_API intptr_t qltf_get(int32_t slot) {
  if (slot < 0 || slot >= QLTF_SLOTS) return 0;
  return __atomic_load_n(&slots[slot], __ATOMIC_SEQ_CST);
}
QLTF_API intptr_t qltf_set(int32_t slot, intptr_t value) {
  if (slot < 0 || slot >= QLTF_SLOTS) return 0;
  return __atomic_exchange_n(&slots[slot], value, __ATOMIC_SEQ_CST);
}
#endif

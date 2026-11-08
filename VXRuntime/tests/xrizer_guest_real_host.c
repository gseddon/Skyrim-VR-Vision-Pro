// Test-only forwarding to a real, explicitly selected native xrizer library.
#include "vx.h"
#include <dlfcn.h>
#include <stdlib.h>

typedef struct { void **vtable; void *native_core; } guest_core;
typedef void *(*native_factory_fn)(const char *, int *);
typedef int (*native_init_fn)(void *, int, const char *);
typedef int (*native_version_fn)(void *, const char *);
typedef uint8_t (*native_present_fn)(void *);
static void *table[7];
static guest_core object = {table, NULL};
static void *library;
static void **native_table(guest_core *self) {
    if (self != &object || !self->native_core) abort();
    return *(void ***)self->native_core;
}
static WINAPI void unsupported(void) { vx_log("xrizer_guest_real: unsupported test slot"); abort(); }
static WINAPI int core_init(guest_core *self, int type, const char *startup) {
    native_init_fn fn = (native_init_fn)native_table(self)[0];
    return fn(self->native_core, type, startup);
}
static WINAPI int core_version(guest_core *self, const char *version) {
    native_version_fn fn = (native_version_fn)native_table(self)[2];
    return fn(self->native_core, version);
}
static WINAPI uint8_t core_present(guest_core *self) {
    native_present_fn fn = (native_present_fn)native_table(self)[4];
    return fn(self->native_core);
}
static WINAPI void *FixtureGetClientCore(int *error) {
    const char *path = getenv("VXRT_ABI_XRIZER_DYLIB");
    if (!path || library) { vx_log("xrizer_guest_real: need one explicit native library"); abort(); }
    library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) { vx_log("xrizer_guest_real: dlopen failed: %s", dlerror()); abort(); }
    native_factory_fn factory = (native_factory_fn)dlsym(library, "VRClientCoreFactory");
    if (!factory) abort();
    object.native_core = factory("IVRClientCore_003", error);
    vx_log("xrizer_guest_real: actual native ClientCore factory pointer %p error %d", object.native_core, error ? *error : -1);
    return object.native_core ? &object : NULL;
}
static const vx_export exports[] = { VX_EXPORT(FixtureGetClientCore) };
__attribute__((constructor)) static void register_fixture(void) {
    for (int i = 0; i < 7; ++i) table[i] = unsupported;
    table[0] = core_init; table[2] = core_version; table[4] = core_present;
    vx_register_module("vxrt_guest_real_fixture.dll", exports, sizeof exports / sizeof *exports);
}
#ifdef __aarch64__
#include "thunks/xrizer_guest_real_host.c.inc"
#endif

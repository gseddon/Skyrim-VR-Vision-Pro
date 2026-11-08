/* Native host ABI smoke test: Apple must refuse initialization until a backend exists. */
#include <dlfcn.h>
#include <stdio.h>

typedef void *(*factory_fn)(const char *, int *);
typedef int (*init_fn)(void *, int, const char *);

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    factory_fn factory = (factory_fn)dlsym(library, "VRClientCoreFactory");
    if (!factory) return 1;
    int error = -1;
    void *core = factory("IVRClientCore_003", &error);
    if (!core || error != 0) return 1;
    init_fn init = *(init_fn *)*(void **)core;
    int result = init(core, 1, NULL);
    if (result != 150) { fprintf(stderr, "unexpected init result: %d\n", result); return 1; }
    puts("Apple backend unavailable: initialization correctly refused");
    return 0;
}

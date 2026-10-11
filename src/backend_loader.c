#include "backend_loader.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stddef.h>

/* Best first. The tiers nest — each has every feature of the ones below it —
 * so the first that loads is the best this CPU can run. Must name exactly what
 * tool/build_android.sh ships. */
static const char * const k_modules[] = {
#if defined(__aarch64__)
    "libggml-cpu-android_armv8.6_1.so", /* + i8mm */
    "libggml-cpu-android_armv8.2_2.so", /* + fp16 arithmetic */
    "libggml-cpu-android_armv8.2_1.so", /* + dotprod */
    "libggml-cpu-android_armv8.0_1.so",
#elif defined(__x86_64__)
    "libggml-cpu-haswell.so", /* AVX2, FMA, F16C */
    "libggml-cpu-x64.so",
#endif
    NULL,
};

typedef void * (*ggml_backend_load_fn)(const char * path);

static pthread_once_t s_once = PTHREAD_ONCE_INIT;
static const char *   s_loaded;

/* Once per process, not per isolate. Every Dart isolate that touches the
 * engine runs this, and ggml's registry is process-wide: a second load would
 * register a second CPU backend, and two isolates racing a check-then-load
 * could both get past the check. */
static void load_once(void) {
    /* Already a dependency of libtranscribe.so, so this is the copy the engine
     * will use; opening it first just reaches its loader. */
    void * ggml = dlopen("libggml.so", RTLD_NOW);
    if (ggml == NULL) {
        return;
    }
    ggml_backend_load_fn load = (ggml_backend_load_fn) dlsym(ggml, "ggml_backend_load");
    if (load == NULL) {
        return;
    }
    for (size_t i = 0; k_modules[i] != NULL; i++) {
        if (load(k_modules[i]) != NULL) {
            s_loaded = k_modules[i];
            return;
        }
    }
}

const char * tcshim_load_cpu_backend(void) {
    pthread_once(&s_once, load_once);
    return s_loaded;
}

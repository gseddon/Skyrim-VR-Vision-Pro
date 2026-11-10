// The shader library cache, shared by the Direct3D 11 and 12 renderers (d3d11_draw.m, d3d12.m): compiled Metal libraries
// kept on disk under a key of the translated source and the compile options (language version, math mode), the
// writable folder (VXRT_SHADER_CACHE) and the read-only one shipped in the app (VXRT_D3D12_SHADER_CACHE_RO). Moved out of
// d3d12.m unchanged so the Direct3D 11 replayer (tools/d3d11_replay.m) links it too.
#include "d3d_common.h"
#include <sys/time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>
static uint64_t fnv1a12(uint64_t h, const void *data, size_t size) {
    const uint8_t *p = data;
    for (size_t i = 0; p && i < size; i++) { h ^= p[i]; h *= 0x100000001b3ull; }
    return h;
}
static uint64_t fs_now12(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
// The compiled shaders kept on disk (VXRT_D3D12_SHADER_CACHE=<folder>, default ~/Library/Caches/VXRuntime/metallib;
// 0: none). Metal caches the GPU code of a library, not the compile of its source, and a game's large shaders take
// seconds to tens of seconds there each start (Cyberpunk 2077's 634912c2: 20-30 s, with its engine watchdog ending
// the game at 120 s of loading). A shader whose source took over 0.2 s is compiled again in the background by the
// offline compiler (xcrun metal, when it is there) into <folder>/<hash of source and options>.metallib, which the
// next start loads instead.
// Keeps the folder to VXRT_SHADER_CACHE_MAX_MB (default 1024): over that, the least recently used libraries (a hit
// touches the file) go until it is 80% of it; temporary files a crashed compile left (an hour old) go too. Done once
// per process, in the background. Another process doing the same at once only makes an unlink fail.
static void shader_cache_trim(const char *dir) {
#if !VX_XROS
    NSString *folder = @(dir);
    const char *m = getenv("VXRT_SHADER_CACHE_MAX_MB");
    unsigned long long cap = (m && atoll(m) > 0 ? (unsigned long long)atoll(m) : 1024ull) << 20;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray *libs = [NSMutableArray array];
        unsigned long long total = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:folder error:nil]) {
            NSString *path = [folder stringByAppendingPathComponent:name];
            NSDictionary *a = [fm attributesOfItemAtPath:path error:nil];
            if (!a) continue;
            if ([name containsString:@".tmp."] || [name hasSuffix:@".metal"]) {
                if (-[a.fileModificationDate timeIntervalSinceNow] > 3600) unlink(path.fileSystemRepresentation);
            } else if ([name hasSuffix:@".metallib"]) {
                total += a.fileSize;
                [libs addObject:@[ path, a.fileModificationDate ?: [NSDate distantPast], @(a.fileSize) ]];
            }
        }
        if (total <= cap) return;
        [libs sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) { return [x[1] compare:y[1]]; }];
        for (NSArray *e in libs) {
            if (total <= cap / 5 * 4) break;
            if (unlink([e[0] fileSystemRepresentation]) == 0) total -= [e[2] unsignedLongLongValue];
        }
    });
#else
    (void)dir;
#endif
}
const char *vx_shader_cache_dir(void) {
    static char dir[1024];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // (VXRT_SHADER_CACHE is the same for every renderer; VXRT_D3D12_SHADER_CACHE wins for Direct3D 12 alone)
        const char *e = getenv("VXRT_D3D12_SHADER_CACHE");
        if (!e || !*e) e = getenv("VXRT_SHADER_CACHE");
        if (e && !strcmp(e, "0")) return;
        if (e && *e) snprintf(dir, sizeof dir, "%s", e);
#if VX_XROS
        // (visionOS: the app's Documents/shadercache, filled from the Mac: tools/xros_shadercache.sh)
        else if (getenv("HOME")) snprintf(dir, sizeof dir, "%s/Documents/shadercache", getenv("HOME"));
#endif
        else if (getenv("HOME")) snprintf(dir, sizeof dir, "%s/Library/Caches/VXRuntime/metallib", getenv("HOME"));
        if (*dir) {
            [[NSFileManager defaultManager] createDirectoryAtPath:@(dir) withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @0700 } error:nil];
            shader_cache_trim(dir);
        }
    });
    return *dir ? dir : NULL;
}
uint64_t vx_shader_cache_key(NSString *source, MTLCompileOptions *options, int *std32, int *min_lod, int *safe) {
    const char *src = source.UTF8String;
    *std32 = options.languageVersion == MTLLanguageVersion3_2;
    *min_lod = options.preprocessorMacros[@"VXRT_HAS_MIN_LOD_CLAMP"] != nil;
    *safe = !options.fastMathEnabled;
    if (@available(macOS 15.0, *)) *safe = options.mathMode == MTLMathModeSafe;
    uint64_t h = fnv1a12(0xcbf29ce484222325ull, src, src ? strlen(src) : 0);
    uint8_t flags[4] = { 2 /* (the key's version) */, (uint8_t)*std32, (uint8_t)*min_lod, (uint8_t)*safe };
    return fnv1a12(h, flags, sizeof flags);
}
void vx_shader_cache_store(NSString *source, uint64_t key, int std32, int min_lod, int safe) {
#if VX_XROS
    // visionOS: no offline compiler on the device. Every source compiled here is written to <folder>/pending/<key>.metal
    // with its options (<key>.flags: std32 min_lod safe); tools/xros_shadercache.sh takes them to the Mac, compiles
    // them there with xcrun -sdk xros metal into <key>.metallib under the same key and puts those in <folder>, which
    // the next start loads instead of compiling (VISIONOS_PORT.md, "shaders").
    const char *dir = vx_shader_cache_dir();
    if (!dir) return;
    char base[1200];
    snprintf(base, sizeof base, "%s/pending", dir);
    mkdir(base, 0755);
    snprintf(base, sizeof base, "%s/pending/%016llx", dir, (unsigned long long)key);
    NSString *b = @(base);
    [source writeToFile:[b stringByAppendingString:@".metal"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSString stringWithFormat:@"%d %d %d\n", std32, min_lod, safe] writeToFile:[b stringByAppendingString:@".flags"] atomically:YES
                                                                         encoding:NSUTF8StringEncoding error:nil];
}
#else
    const char *dir = vx_shader_cache_dir();
    if (!dir) return;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("vxrt.metallib", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    NSString *text = [source copy];
    char base[1200];
    snprintf(base, sizeof base, "%s/%016llx", dir, (unsigned long long)key);
    NSString *b = @(base);
    // (the temporary names carry the process: several runs may compile the same library at once, and only the
    // rename, which is atomic, makes a file the cache has)
    NSString *mine = [NSString stringWithFormat:@"%s/%016llx.%d", dir, (unsigned long long)key, (int)getpid()];
    void (^work)(void) = ^{
        NSString *metal = [mine stringByAppendingString:@".metal"], *tmp = [mine stringByAppendingString:@".tmp.metallib"];
        if (![text writeToFile:metal atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-sdk", @"macosx", @"metal", std32 ? @"-std=metal3.2" : @"-std=metal3.1", nil];
        if (min_lod) [args addObject:@"-DVXRT_HAS_MIN_LOD_CLAMP=1"];
        if (safe) [args addObject:@"-fno-fast-math"];
        [args addObjectsFromArray:@[ @"-w", @"-o", tmp, metal ]];
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
        task.arguments = args;
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        NSError *e = nil;
        if ([task launchAndReturnError:&e]) {
            [task waitUntilExit];
            if (task.terminationStatus == 0) rename(tmp.UTF8String, [b stringByAppendingString:@".metallib"].UTF8String);
            else unlink(tmp.UTF8String);
        }
        unlink(metal.UTF8String);
    };
    // (VXRT_SHADER_CACHE_SYNC=1: done before returning, for the tests, which end the process at once)
    if (getenv("VXRT_SHADER_CACHE_SYNC")) work(); else dispatch_async(q, work);
}
#endif
// The same folder for the other renderers (Direct3D 11: d3d11_draw.m). vx_library_cache_load returns the library
// compiled before for this source and these options (NULL: none, or unreadable, which also removes it), with the key
// to give vx_library_cache_store, which queues the source of a miss for the offline compiler (tools/shadercache_fill.sh).
// The options must not be NULL.
// VXRT_SHADER_CACHE=0 (or VXRT_D3D12_SHADER_CACHE=0): neither does anything.
static unsigned g_cache_hits_x, g_cache_misses_x, g_cache_stored_x, g_cache_unreadable_x;
static uint64_t g_cache_load_ns_x;
static unsigned g_cache_reused_x;
// (d3d11_draw.m: a request for a source it already has a library for in this process; it never reaches the cache)
void vx_library_cache_note_reuse(void) { __atomic_add_fetch(&g_cache_reused_x, 1, __ATOMIC_RELAXED); }
// One line at exit: every lookup was a hit (loaded), a miss (compiled from source) or unreadable (compiled again).
// (also every 5 s while the numbers change, since the runtime may end with _exit, which skips atexit)
static void vx_library_cache_summary(void) {
    static unsigned last;
    if (!vx_shader_cache_dir()) return;
    unsigned h = g_cache_hits_x, m = g_cache_misses_x;
    unsigned sig = h + m + g_cache_unreadable_x + g_cache_stored_x + g_cache_reused_x;
    if (sig == last) return;
    last = sig;
    if (h + m + g_cache_unreadable_x + g_cache_reused_x)
        vx_log("shader cache summary: %u hits, %u misses (compiled from source), %u damaged, %u distinct sources queued for the fill script; %.1f ms loading libraries; %u requests answered from this process's own libraries",
               h, m, g_cache_unreadable_x, g_cache_stored_x, g_cache_load_ns_x / 1e6, g_cache_reused_x);
}
void vx_library_cache_finish(void) { vx_library_cache_summary(); }
id vx_library_cache_load(id<MTLDevice> mtl, NSString *source, MTLCompileOptions *options, uint64_t *key_out) {
    const char *dir = vx_shader_cache_dir();
    if (!dir || !source || !options) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        atexit(vx_library_cache_summary);
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(t, ^{ vx_library_cache_summary(); });
        dispatch_resume(t);
        (void)CFBridgingRetain(t);
    });
    int std32, min_lod, safe;
    uint64_t key = vx_shader_cache_key(source, options, &std32, &min_lod, &safe);
    *key_out = key;
    char path[1200];
    snprintf(path, sizeof path, "%s/%016llx.metallib", dir, (unsigned long long)key);
    const char *ro = getenv("VXRT_D3D12_SHADER_CACHE_RO");
    if (ro && *ro && access(path, R_OK) != 0) {
        char p2[1200];
        snprintf(p2, sizeof p2, "%s/%016llx.metallib", ro, (unsigned long long)key);
        if (access(p2, R_OK) == 0) snprintf(path, sizeof path, "%s", p2);
    }
    if (access(path, R_OK) != 0) {
        unsigned n = __atomic_add_fetch(&g_cache_misses_x, 1, __ATOMIC_RELAXED);
        if (n <= 3 || !(n & (n - 1))) vx_log("shader cache: MISS %016llx (math %s, Metal %s): compiled from source (miss %u)", (unsigned long long)key, safe ? "safe" : "fast", std32 ? "3.2" : "3.1", n);
        return nil;
    }
    uint64_t t0 = fs_now12();
    NSError *le = nil;
#if VX_XROS
    // visionOS: the file is mapped and closed, and the library is made from that data, so a loaded library holds no
    // descriptor. (newLibraryWithURL keeps the file open: 10,201 libraries at startup hit the 10,240-descriptor cap of
    // device run 3 and the other 606 were "unreadable: Too many open files".)
    id<MTLLibrary> lib = nil;
    {
        int lfd = open(path, O_RDONLY | O_CLOEXEC);
        struct stat lst;
        if (lfd >= 0 && !fstat(lfd, &lst) && lst.st_size > 0) {
            void *map = mmap(NULL, (size_t)lst.st_size, PROT_READ, MAP_PRIVATE, lfd, 0);
            close(lfd);
            if (map != MAP_FAILED) {
                size_t len = (size_t)lst.st_size;
                dispatch_data_t data = dispatch_data_create(map, len, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ munmap(map, len); });
                lib = [mtl newLibraryWithData:data error:&le];
            }
        } else if (lfd >= 0) close(lfd);
    }
#else
    id<MTLLibrary> lib = [mtl newLibraryWithURL:[NSURL fileURLWithPath:@(path)] error:&le];
#endif
    __atomic_add_fetch(&g_cache_load_ns_x, fs_now12() - t0, __ATOMIC_RELAXED);
    if (!lib) {
        __atomic_add_fetch(&g_cache_unreadable_x, 1, __ATOMIC_RELAXED);
        vx_log("shader cache: %016llx.metallib unreadable (%s): compiled again", (unsigned long long)key, le.localizedDescription.UTF8String ?: "?");
        if (!ro || strncmp(path, ro, strlen(ro))) unlink(path);
        return nil;
    }
    utimes(path, NULL);
    unsigned n = __atomic_add_fetch(&g_cache_hits_x, 1, __ATOMIC_RELAXED);
    if (n <= 3 || !(n & (n - 1))) vx_log("shader cache: HIT %016llx.metallib loaded (%.1f ms; hit %u)", (unsigned long long)key, (fs_now12() - t0) / 1e6, n);
    return lib;
}
// A miss: the source is written to <folder>/pending/<key>.metal with its options (<key>.flags: std32 min_lod safe), once
// per process and not when the library is there already, for tools/shadercache_fill.sh to compile after the game
// (the game itself never runs the offline compiler). The write is in the background (VXRT_SHADER_CACHE_SYNC=1: now).
void vx_library_cache_store(NSString *source, MTLCompileOptions *options, uint64_t key, uint64_t took_ns) {
    (void)took_ns;
    const char *dir = vx_shader_cache_dir();
    if (!key || !dir) return;
    static NSMutableSet *seen;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; q = dispatch_queue_create("vxrt.shadercache.pending", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    @synchronized (seen) {
        if ([seen containsObject:@(key)]) return;
        [seen addObject:@(key)];
    }
    char path[1200];
    snprintf(path, sizeof path, "%s/%016llx.metallib", dir, (unsigned long long)key);
    if (access(path, R_OK) == 0) return;
    int std32, min_lod, safe;
    uint64_t k = vx_shader_cache_key(source, options, &std32, &min_lod, &safe);
    if (k != key) return;
    unsigned n = __atomic_add_fetch(&g_cache_stored_x, 1, __ATOMIC_RELAXED);
    if (n <= 3 || !(n & (n - 1))) vx_log("shader cache: %016llx queued in pending/ for tools/shadercache_fill.sh (%u so far)", (unsigned long long)key, n);
    NSString *text = [source copy], *folder = @(dir);
    void (^work)(void) = ^{
        NSString *pend = [folder stringByAppendingPathComponent:@"pending"];
        [[NSFileManager defaultManager] createDirectoryAtPath:pend withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @0700 } error:nil];
        NSString *b = [pend stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx", (unsigned long long)key]];
        [text writeToFile:[b stringByAppendingString:@".metal"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [[NSString stringWithFormat:@"%d %d %d\n", std32, min_lod, safe] writeToFile:[b stringByAppendingString:@".flags"] atomically:YES
                                                                           encoding:NSUTF8StringEncoding error:nil];
    };
    if (getenv("VXRT_SHADER_CACHE_SYNC")) work(); else dispatch_async(q, work);
}

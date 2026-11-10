// vxrt-shader-manifest: translates the DXBC shaders of a shader manifest (VISIONOS_PORT.md, "Shaders from a manifest") to Metal source and queues
// each as the runtime would on a cache miss: <out>/pending/<key>.metal and <key>.flags, written by the runtime's own
// vx_library_cache_store, so the files and the key are the ones a game run makes for the same shader.
//   vxrt-shader-manifest --manifest FILE --dxbc DIR --out DIR [--report FILE]
// DIR holds <sha256>.dxbc (tools/shader_manifest_build finds them in the game install). Exit 0 when every entry was
// translated and its key is the one the manifest recorded (when it records one).
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include "../src/dxbc.h"

extern MTLCompileOptions *vx_d3d11_library_options(void);
extern uint64_t vx_shader_cache_key(NSString *source, MTLCompileOptions *options, int *std32, int *min_lod, int *safe);
extern void vx_library_cache_store(NSString *source, MTLCompileOptions *options, uint64_t key, uint64_t took_ns);
extern NSString *vx_d3d11_dual_source(const char *msl);
extern NSString *vx_d3d11_vs_kernel_source(const char *msl_kernel, const char *kinds);

int vx_trace;
void vx_log(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("[vxrt] ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
}

static NSData *read_file(NSString *path) { return [NSData dataWithContentsOfFile:path]; }
static NSString *hex(const unsigned char *d, int n) {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < n; i++) [s appendFormat:@"%02x", d[i]];
    return s;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *manifest = NULL, *dxbc_dir = NULL, *out = NULL, *report = NULL;
        for (int i = 1; i + 1 < argc; i += 2) {
            if (!strcmp(argv[i], "--manifest")) manifest = argv[i + 1];
            else if (!strcmp(argv[i], "--dxbc")) dxbc_dir = argv[i + 1];
            else if (!strcmp(argv[i], "--out")) out = argv[i + 1];
            else if (!strcmp(argv[i], "--report")) report = argv[i + 1];
            else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
        }
        if (!manifest || !dxbc_dir || !out) { fprintf(stderr, "usage: vxrt-shader-manifest --manifest FILE --dxbc DIR --out DIR [--report FILE]\n"); return 2; }
        // (the runtime's cache writer, pointed at <out>; synchronous, and a folder that is never trimmed)
        setenv("VXRT_SHADER_CACHE", out, 1);
        setenv("VXRT_SHADER_CACHE_SYNC", "1", 1);
        setenv("VXRT_SHADER_CACHE_MAX_MB", "1000000", 1);
        NSString *text = [NSString stringWithContentsOfFile:@(manifest) encoding:NSUTF8StringEncoding error:nil];
        if (!text) { fprintf(stderr, "%s: unreadable\n", manifest); return 1; }
        MTLCompileOptions *options = vx_d3d11_library_options();
        FILE *rep = report ? fopen(report, "w") : NULL;
        unsigned total = 0, ok = 0, missing = 0, failed = 0, mismatch = 0, unchecked = 0;
        NSMutableDictionary *translated = [NSMutableDictionary dictionary];   // sha -> NSValue(dxbc_shader *): translated once
        NSMutableSet *queued = [NSMutableSet set];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if (!line.length || [line hasPrefix:@"#"]) continue;
            NSArray *f = [line componentsSeparatedByString:@"\t"];
            if (f.count < 5) { failed++; continue; }
            total++;
            NSString *sha = f[0], *kind = f[2], *params = f[3], *want_key = f.count > 5 ? f[5] : @"";
            const char *status = "ok";
            uint64_t key = 0;
            NSData *code = read_file([NSString stringWithFormat:@"%s/%@.dxbc", dxbc_dir, sha]);
            if (!code) { status = "missing-dxbc"; missing++; goto report; }
            {
                unsigned char d[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256(code.bytes, (CC_LONG)code.length, d);
                if (![hex(d, sizeof d) isEqualToString:sha]) { status = "dxbc-hash-differs"; failed++; goto report; }
                NSValue *held = translated[sha];
                dxbc_shader *sh = held ? held.pointerValue : NULL;
                if (!sh) {
                    sh = calloc(1, sizeof *sh);
                    if (dxbc_translate(code.bytes, code.length, sh)) { status = "translate-failed"; failed++; free(sh); goto report; }
                    translated[sha] = [NSValue valueWithPointer:sh];
                }
                NSString *source = nil;
                if (![kind compare:@"base"]) source = @(sh->msl);
                else if (![kind compare:@"dual-source"]) source = vx_d3d11_dual_source(sh->msl);
                else if (![kind compare:@"pass-through"]) source = sh->msl_passthrough ? @(sh->msl_passthrough) : nil;
                else if (![kind compare:@"vs-kernel"]) source = sh->msl_kernel ? vx_d3d11_vs_kernel_source(sh->msl_kernel, params.UTF8String) : nil;
                if (!source) { status = "no-such-variant"; failed++; goto report; }
                int std32, min_lod, safe;
                key = vx_shader_cache_key(source, options, &std32, &min_lod, &safe);
                if (want_key.length) {
                    if ([want_key.lowercaseString isEqualToString:[NSString stringWithFormat:@"%016llx", (unsigned long long)key]]) ok++;
                    else { status = "key-differs"; mismatch++; }
                } else { unchecked++; ok++; status = "ok-unchecked"; }
                if (![queued containsObject:@(key)]) { [queued addObject:@(key)]; vx_library_cache_store(source, options, key, 0); }
            }
        report:
            if (rep) fprintf(rep, "%s\t%s\t%016llx\t%s\n", sha.UTF8String, kind.UTF8String, (unsigned long long)key, status);
        }
        if (rep) fclose(rep);
        for (NSValue *v in translated.allValues) { dxbc_shader *sh = v.pointerValue; dxbc_free(sh); free(sh); }
        printf("manifest: %u entries: %u ok (%u without a recorded key), %u key differs, %u DXBC missing, %u failed; %lu distinct sources queued in %s/pending\n",
               total, ok, unchecked, mismatch, missing, failed, (unsigned long)queued.count, out);
        return (mismatch || missing || failed) ? 1 : 0;
    }
}

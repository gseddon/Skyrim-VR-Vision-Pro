#import <Foundation/Foundation.h>
#include <string.h>
#include <stdio.h>
// Dither for 8-bit unorm render targets (VXRT_DITHER_8BIT=1): the pixel shader with up to 0.49 of an 8-bit step of
// position-hashed noise added to the colour of each float4 output before it is stored. A value that is an exact
// multiple of 1/255 stays where it is (the noise is below half a step), a value between two codes rounds to either with
// the probability that matches its fraction: the very dark gradients Skyrim draws (the title-screen smoke is bytes 0-2)
// come out as a mix of codes instead of flat bands with hard edges. nil when the shader has no float4 colour output.
NSString *vx_d3d11_dither_source(const char *msl) {
    if (!msl) return nil;
    const char *def = strstr(msl, "#define VX_RETURN return (VxOut{");
    const char *structure = strstr(msl, "struct VxOut {");
    if (!def || !structure) return nil;
    const char *list = def + strlen("#define VX_RETURN return (VxOut{");
    const char *list_end = strstr(list, "})\n");
    if (!list_end) return nil;
    NSMutableString *stores = [NSMutableString string];
    for (const char *q = structure; (q = strstr(q, "    float4 o")) && q < def; q++) {
        unsigned r = 0; int used = 0;
        if (sscanf(q, "    float4 o%u [[color(%u)]];%n", &r, &r, &used) >= 2 && used)
            [stores appendFormat:@" vx_r.o%u.xyz = vx_dither3(vx_r.o%u.xyz, VXPOS);", r, r];
    }
    if (!stores.length) return nil;
    // the pixel position: the shader's own [[position]] input if it has one, else one more argument
    NSString *pos = @"vx_dpos.xy";
    NSMutableString *source = [NSMutableString stringWithUTF8String:msl];
    NSRange input = [source rangeOfString:@" [[position]];"];
    BOOL have_input = NO;
    if (input.location != NSNotFound) {                            // "    float4 v<N> [[position]];" in VxIn
        NSRange line = [source rangeOfString:@"float4 v" options:NSBackwardsSearch range:NSMakeRange(0, input.location)];
        if (line.location != NSNotFound) {
            NSString *name = [source substringWithRange:NSMakeRange(line.location + 7, input.location - line.location - 7)];
            if ([name rangeOfString:@" "].location == NSNotFound && [name rangeOfString:@"\n"].location == NSNotFound && [source rangeOfString:@"struct VxIn"].location != NSNotFound) {
                pos = [NSString stringWithFormat:@"vin.%@.xy", name]; have_input = YES;
            }
        }
    }
    if (!have_input) {
        NSRange fn = [source rangeOfString:@"fragment VxOut vx_main("];
        if (fn.location == NSNotFound) return nil;
        NSUInteger at = fn.location + fn.length;
        BOOL empty = [source characterAtIndex:at] == ')';
        [source insertString:empty ? @"float4 vx_dpos [[position]]" : @"float4 vx_dpos [[position]], " atIndex:at];
    }
    NSString *helper = @"float3 vx_dither3(float3 c, float2 p) {\n"
        "    float n = fract(52.9829189f * fract(dot(floor(p), float2(0.06711056f, 0.00583715f))));\n"
        "    return c + (n - 0.5f) * (0.98f / 255.0f);\n}\n";
    NSRange st = [source rangeOfString:@"struct VxOut {"];
    [source insertString:helper atIndex:st.location];
    NSString *old = [NSString stringWithFormat:@"#define VX_RETURN return (VxOut{%.*s})\n", (int)(list_end - list), list];
    NSString *body = [NSString stringWithFormat:@"#define VX_RETURN do { VxOut vx_r = VxOut{%.*s};%@ return vx_r; } while (0)\n",
                      (int)(list_end - list), list, [stores stringByReplacingOccurrencesOfString:@"VXPOS" withString:pos]];
    if ([source replaceOccurrencesOfString:old withString:body options:0 range:NSMakeRange(0, source.length)] != 1) return nil;
    return source;
}

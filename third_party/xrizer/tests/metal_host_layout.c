#include "../include/metal_host_bridge.h"
_Static_assert(sizeof(XrizerMetalTexture) == 48, "texture ABI size");
_Static_assert(offsetof(XrizerMetalTexture, format) == 24, "texture format ABI");
_Static_assert(offsetof(XrizerMetalTexture, width) == 32, "texture width ABI");
_Static_assert(sizeof(XrizerMetalCopy) == 40, "copy ABI size");
_Static_assert(offsetof(XrizerMetalCopy, eye) == 16, "copy eye ABI");
_Static_assert(sizeof(XrizerMetalHost) == 56, "host ABI size");
int main(void) { return 0; }

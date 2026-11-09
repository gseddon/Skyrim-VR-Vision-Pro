// Address ranges the arm64 host holds from the moment dyld maps it, before any library initializer or malloc runs.
//
// The recompiled modules (translator/aot.c) are made for fixed addresses: the program's own image at its preferred base
// (0x140000000 for most x64 programs) and an arena at 0xf00000000 for the images of its DLLs. macOS places the first
// mappings of a process (malloc's 128 MB chunks, two 12 GB regions, libraries) at random inside 0x100000000-0x1000000000,
// so those ranges were taken in about 4 starts in 10 (the arena) and 1 in 12 (the program: a program mapped anywhere else
// is relocated and none of its modules' code is used). A segment of the host's own Mach-O is mapped by the kernel and
// dyld with the host, so nothing else can be there. Its address moves with the host's ASLR slide (observed 0 to 0x5000000
// over 3000 starts), so each segment starts SLIDE_MARGIN below the address wanted and runs past its end by as much; the
// wanted range is always inside. The loader and aot.c map their ranges over the segment (VM_FLAGS_OVERWRITE) after checking
// it contains them; anything else (another arena address, a bigger program) takes the old way and, failing that, the restart.
// The pages are never touched, so the segments cost address space only. Placed by the link flags in the Makefile
// (-segaddr/-segprot for __VXIMG and __VXARN: keep both in step with the sizes here).
//
//   __VXIMG: 0x13a000000 (0x140000000 - 0x6000000), 0x26000000 bytes: up to a 512 MB program at 0x140000000
//   __VXARN: 0xefa000000 (0xf00000000 - 0x6000000), 0x26000000 bytes: the 512 MB arena at 0xf00000000
.globl _vx_resv_img
.globl _vx_resv_arena
.zerofill __VXIMG,__img,_vx_resv_img,0x26000000,14
.zerofill __VXARN,__arn,_vx_resv_arena,0x26000000,14

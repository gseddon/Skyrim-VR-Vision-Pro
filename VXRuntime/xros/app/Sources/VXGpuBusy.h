// The GPU's working time for this process, and the shaders it had compiled, for the performance panel (VXStatsPanel.swift).
// See VXGpuBusy.m.
#ifndef VX_GPU_BUSY_H
#define VX_GPU_BUSY_H

// Starts counting. Returns 1 when every command buffer committed from here on is counted, 0 where there is no Metal device or its
// command buffers cannot be extended. Once per process; later calls return what the first one did.
int vx_gpu_busy_install(void);
// The seconds the GPU worked on this process's command buffers since the last call, overlapping spans counted once, and how many
// buffers that was. Negative while nothing is installed.
double vx_gpu_busy_take(unsigned long *buffers);
// How many times the process asked Metal for a library from source or a render pipeline state since the last call, in two counts:
// the requests that took long enough to have been compiled, and the ones answered at once from what the system had compiled before.
void vx_gpu_compiles_take(unsigned long *compiled, unsigned long *cached);

#endif

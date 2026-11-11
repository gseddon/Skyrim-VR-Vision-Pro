---
description: Make Skyrim VR run on VXRuntime's Mac dev host — measure it with the harness, fix what stops it, prove it with a run
argument-hint: (optional: the problem to look at)
---
Make Skyrim VR run its harness scenario on VXRuntime's Mac dev host. {{args}}

1. Get the brief: `python3 tools/vxrt_doctor.py skyrim --goal support --agent {{agent}}`. It gives the goal, when the task is done, the facts, the tools to use first, the rules and when to stop. Follow it.

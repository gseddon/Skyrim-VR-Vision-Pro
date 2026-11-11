---
description: Write a GitHub issue draft for Skyrim VR failing on the Mac dev host, from the harness evidence (never posts it)
argument-hint: [what you tried]
---
Write an issue draft about Skyrim VR (profile `skyrim`) from the evidence. Never post it. What was tried: `{{args}}`.

1. Use the newest harness run in `runs/`; if there is none, run one first (vxrt MCP `run_game`, or `python3 tools/vxrt_run.py skyrim`) and report a refusal's reason instead of working around it (another Skyrim run being active is a refusal: wait for it).
2. Write the draft with the vxrt MCP `prepare_issue` (or `python3 tools/vxrt_issue.py draft skyrim --run runs/<run_id> --kind <kind> --tried "<what was tried and what each run showed>"`). Pick the kind (support, crash, performance, rendering) from the evidence.
3. Show the user the draft's path, its title and the similar issues it lists. Posting is theirs: `python3 tools/vxrt_issue.py submit runs/issues/<draft>.md`, in their own Terminal, asks them before it posts.

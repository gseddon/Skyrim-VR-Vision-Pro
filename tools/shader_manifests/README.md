# Shader manifests

These files list the shader variants a game needs, so that `tools/shader_manifest_build` can build the whole Metal shader cache offline from the user's own game install. No game boot is needed. See VXRuntime/VISIONOS_PORT.md, "Shaders from a manifest".

A manifest holds **hashes and parameters only**: no game shader bytecode, no translated MSL, and no other game content. Each line is tab-separated:

| Column | Meaning |
|---|---|
| dxbc-sha256 | SHA-256 of the game's DXBC container, located in the user's install at build time |
| stage | `vs`, `ps` or `cs` |
| kind | variant kind (`base`, `pass-through`, `vs-kernel`, `dual-source`) |
| params | variant parameters, `reg:kind,...` for `vs-kernel`, empty otherwise |
| translator | `DXBC_TRANSLATOR_REV` the line was recorded with |
| cache-key | the runtime's shader cache key, used to check offline output |

## Files

- `skyrimvr-611670.tsv.gz`: Skyrim VR (Steam app 611670), with 10,807 entries and translator rev 1.
  - It was recorded on 2026-11-10 from a replay of a Mac capture that runs from start-up into the Helgen cart, with `VXRT_SHADER_MANIFEST`.
  - Built offline, it matched the runtime's cache keys for all 10,807 entries.
  - Shaders seen only later in the game are not in it yet. The device and the Mac still compile and queue those in `pending/`.
  - Checked in on the user's decision, 2026-11-10.

## Regenerating

To regenerate, replay a capture, or run the game on the Mac, with `VXRT_SHADER_MANIFEST=<file>` and an empty `VXRT_SHADER_CACHE`. Then `gzip -9 -n`.

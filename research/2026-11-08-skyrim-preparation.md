# Skyrim VR private prepared-image investigation

8 November 2026. Subject: static inspection of a privately prepared owned Skyrim VR image on macOS ARM64. No game, headset, SteamVR, or guest code was launched; no target SDK applies. These observations do not establish game startup, strict AOT execution, or playability.

Steamless upstream commit `cd770bf9749d3e4f438d23ac643917ad1a804257` identifies the input as SteamStub Variant 3.1 x64. Its unmodified CLI and x64 plugin reported successful code-section decryption, removal of `.bind`, and writing a separate output; exit 0. Its default options were used without payload dumps or checksum recalculation. The installed game EXE was hashed before and after and remained `6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971`. The private output SHA-256 is `8daf05196ecad57963be61614ce4a4cd5c4dc27d222db14e01c262b36b3d46d4`. It was renamed byte-preservingly to `prepared/SkyrimVR.exe` and is distinct from the copied original. Both and their logs are under the ignored `build/private/skyrimvr/<original-sha>/` directory with owner-only access. Steamworks is not emulated; Steamless does not remove its API integration.

## Host route and provenance

[Steamless](https://github.com/atom0s/Steamless) is licensed CC BY-NC-ND 4.0; its upstream source includes license and copyright notices. All source, private SDK-style project files, and built binaries remain under ignored `build/private/skyrim-tools/`; they are not distributed. The original CLI, API, and Variant 3.0 and 3.1 x64 plugin source files were compiled unchanged using private SDK-style project files targeting .NET 8; UI-only `ViewModelBase` and `NavigatedEventArgs` were excluded. The original projects target .NET Framework 4.5.2 and include Windows UI dependencies. The CLI's default checksum option was off, avoiding its Windows `imagehlp.dll` import. The .NET SDK 8.0.427 for macOS ARM64 was installed locally using Microsoft's `dotnet-install.sh`; `DOTNET_CLI_HOME`, `NUGET_PACKAGES`, and `TMPDIR` point to repository-local directories. No global installation or configuration was changed. Builds succeeded, with two .NET warnings that `AesCryptoServiceProvider` is obsolete. The private `manifest.json` records plugin, command, hashes of tool binaries and installer, source identity, architecture, and both PE layouts; `steamless.log` preserves its actual output.

## Before/after static comparison

The same `tools/skyrim_pe_audit.py` with the same locally built decoder analyzed both private images (exit 0). The same `VXRuntime/build/vxrt-aot analyze` examined each (exit 0); original analyzer evidence is under `runs/native-darwin-integration/skyrim-static/` and the prepared analyzer log is in the private artifact directory. Raw `audit.json` contains the paired results.

| Observation | Original | Prepared |
| --- | ---: | ---: |
| Entry RVA / section | `0x392e310` / `.bind` | `0x138afb8` / `.text` |
| Main `.text` entropy | 8.0000 | 6.4278 |
| Main `.text` full pages >= 7.9 entropy | 5,501 / 5,501 | 0 / 5,501 |
| Exception-range starts accepted by decoder | 106,975 / 118,450 | 118,446 / 118,450 |
| Analyzer undecodable candidate starts | 232,946 | 974 |
| Analyzer recognized jump tables | 0 | 659 |
| Analyzer unexplained executable section bytes | 78.98% | 0.86% |

Both PE images have AMD64/PE32+ headers, 118,450 same-executable-section exception ranges with file-backed unwind addresses, and image base `0x140000000`. The private manifest's separate structural pass checks raw section bounds, file-backed data directories, PE machine/class and a file-backed executable entry; it recorded the complete layouts and directory offsets. It does not validate table contents, overlap or runtime semantics. The prepared image has nine sections and `.bind` is absent. Independent `xcrun llvm-objdump` disassembly at its restored entry shows a plausible stack adjustment, direct call, stack restoration, and jump; output is retained privately in `entry-disassembly.log`. This is a coherent sample, not proof that all functions, imports, relocation/TLS/unwind semantics, or runtime paths work. Four `.pdata` starts remain undecoded or unbacked and 974 analyzer candidate starts remain undecodable; their significance is unresolved. Indirect targets and unexplained ranges are not proven complete.

The actual image and full manifest still require review before use as trusted compiler input. The result supports continuing static discovery and translation experiments on this exact prepared hash, not treating generation as successful execution. Nothing here establishes Skyrim compatibility or a scene.

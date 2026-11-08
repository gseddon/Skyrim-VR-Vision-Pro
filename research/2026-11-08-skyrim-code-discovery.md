# Skyrim VR static code-discovery feasibility audit

8 November 2026. Subject: read-only static analysis of the installed Windows PE, not game execution. Source revision `b4a205f80e0cd0b6cfd5fb964f3df5274b883a0c`; the audit script and its test are the accompanying local changes. No original binaries were modified or executed. The game EXE SHA-256 is `6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971`.

## Findings

The existing analyzer reports 78.98% of executable-section bytes unexplained and 232,946 undecodable candidate starts. These are discovery results, not an instruction translation failure rate. It seeds recursive descent from multiple metadata and heuristic roots, including pointers and branch targets. A candidate can be data or a misaligned target. Zero recognized jump tables does not establish that there are none.

The audit gives a stronger reason to question whether ordinary instructions are present in the original main section. The EXE entry RVA `0x392e310` is in `.bind`, whereas all 118,450 exception entries describe ranges within `.text`. Their union covers 19,407,888 of the 22,533,468 virtual/file-backed `.text` bytes; all entries have a nonempty same-section executable range and a file-backed unwind address. This is a structural check only: it does not validate unwind records semantically or establish reachability. Of these 118,450 entry starts, VXRuntime's decoder accepts 106,975 and rejects 11,475. Acceptance of an isolated start is not evidence that it is an instruction or that its function is usable.

The main section's aggregate Shannon entropy is 8.0000 bits/byte, and all 5,501 complete 4 KiB pages have entropy at least 7.9; none is below 6. The `.bind` section is 7.9439 overall, with 38 of 42 full pages at least 7.9 and three below 6. These measurements strongly differentiate the main file bytes from the controls but do not identify encryption, compression, protection, or any particular transformation. High entropy is not proof of any one cause. The bytes `00`, `90`, and `CC` total 264,840 in `.text`; counting individual bytes is not equivalent to recognizing padding runs.

| Read-only subject | SHA-256 | Main executable section entropy | Full executable pages ≥ 7.9 | .pdata start decode failures | Analyzer unexplained |
| --- | --- | ---: | ---: | ---: | ---: |
| SkyrimVR.exe | `6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971` | 8.0000 | 5,539 / 5,543 | 11,475 / 118,450 | 78.98% |
| openvr_api.dll | `d079238dae5a1cbfbcba014b644ad550a5c8c088007097a463a94b6ad6f7e184` | 6.4667 | 0 / 90 | 0 / 1,830 | 0.78% |
| binkw64.dll | `152aeb57ba9a5c36cc721a61ae69878ad43c7f6c5cfb87904a1eed037496dedd` | 6.4774 | 0 / 43 | 0 / 666 | 0.53% |
| Owned recomp suite | `f5f75d0e4cde51edf3d096ebd4adf9be9046ddbbc09a97d10806821b1bb28eab` | 6.3943 | 0 / 7 | 0 / 36 | 1.18% |

LLVM's linear disassembly comparison with `x86dec_check` gave 99.9749% reported length agreement for Skyrim, with 1,277 decoder refusals and 945,428 byte readings LLVM labeled unknown; openvr and the suite each showed 100% reported agreement and zero decoder refusals. The checker counts LLVM's unknown readings as agreements and excludes 26,208 Skyrim APX/AVX-512-looking readings; its denominator therefore is not a valid-code coverage measurement. Linear interpretation of high-entropy data is also not evidence of executable code. The comparison does not explain away the discovery gap as a generic decoder failure, nor does it prove all instructions are supported by the ARM64 translator.

## Consequence and next discriminating test

Whether the bytes needed by Skyrim become available through its normal startup remains unknown. Strict AOT requires the actual reachable code and cannot translate instructions absent or different at artifact generation time. The next discriminating observation is a bounded, authorized, unmodified-original startup checkpoint with a hash-matched strict-AOT artifact, isolated writable overlay, no fallback, and recorded actual first missing or changed code address, execution entries, exit and logs. Confirm that no game session is active first and respect harness preconditions. A startup refusal or changed/unavailable code should be recorded as a blocker under current constraints; do not alter originals, bypass protection or infer a successful scene. No such run occurred in this audit.

## Reproduction and limits

Run from the selected checkout. The local evidence is under `runs/skyrim-feasibility/code-audit/`, ignored by Git; the existing Skyrim analyzer log is under `runs/native-darwin-integration/skyrim-static/`. The audit only reads PEs and emits aggregate JSON. Build its local decoder with `clang -dynamiclib -O2 VXRuntime/translator/x86dec.c -o runs/skyrim-feasibility/code-audit/libx86dec.dylib`, then invoke `python3 tools/skyrim_pe_audit.py <dylib> <PE>...`. The exact subjects and hashes are in `metadata.json`. `python3 -m unittest discover -s tests -p skyrim_pe_audit_test.py -v` passed the synthetic overlapping/invalid range and decoder-root test. Run `VXRuntime/build/vxrt-aot analyze <PE>` for analyzer controls. `xcrun llvm-objdump -d --no-show-raw-insn <PE> | VXRuntime/build/x86dec_check <PE>` produced pipeline statuses 0/1 for Skyrim (the checker reports disagreements) and 0/0 for suite and openvr. Logs can contain disassembly examples and are intentionally local, not committed. No target SDK or execution mode applies to these static-only checks.

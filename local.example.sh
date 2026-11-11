# Template for your personal settings. Copy it:   mkdir -p local && cp local.example.sh local/env.sh
# local/ is git-ignored: nothing in it is ever committed. tools/vxrt_build.py, tools/vxrt_doctor_skyrim.py and
# tools/play_skyrim_dev.sh read local/env.sh themselves; for plain `make` run   . local/env.sh   in your shell first.
# (VXRT_LOCAL_ENV=<file> reads another file.) Every variable is optional unless marked REQUIRED.

# --- Apple (REQUIRED for a signed build for the headset) ---------------------------------------------------------
# A paid Apple Developer Program team: the app needs the extended-virtual-addressing and increased-memory-limit
# entitlements, which free teams are not granted.
export XROS_TEAM_ID=ABCDE12345                      # 10 characters: developer.apple.com > Membership, or Xcode > Settings > Accounts
export XROS_BUNDLE_PREFIX=com.yourname.vxrt         # your reverse-DNS prefix; the Skyrim app becomes <prefix>.SkyrimVR
export VXRT_DEVICE_ID=00000000-0000-0000-0000-000000000000   # your Vision Pro: `xcrun devicectl list devices` (Identifier column)
# export XROS_ALLOW_PROVISIONING=1                  # first build with a new bundle id: lets Xcode create the App ID

# --- Your own Skyrim VR (REQUIRED) ----------------------------------------------------------------------------------
# The folder that holds SkyrimVR.exe and Data/, from your own Steam download (read only). It is never modified.
export SKYRIM_ASSET_ROOT="$HOME/path/to/steamapps/common/SkyrimVR"
# SteamVR's bin/vrwebhelper/win64 folder (a source of msvcp140.dll), from your own SteamVR (Steam app 250820).
# export STEAMVR_WIN64_DLLS="$HOME/path/to/steamapps/common/SteamVR/bin/vrwebhelper/win64"

# --- Where everything derived from your game goes (all git-ignored, never committed) ----------------------------------
# export VXRT_PRIVATE_ROOT="$PWD/build/private"     # default: <checkout>/build/private
# export VXRT_SKYRIM_DIR=...                        # default: $VXRT_PRIVATE_ROOT/skyrimvr/<sha of the original exe>
# export VXRT_AOT_INPUTS=...                        # default: $VXRT_SKYRIM_DIR/inputs  (Steam DLLs the pipeline compiles)
# export VXRT_REDIST_DIR=...                        # default: $VXRT_SKYRIM_DIR/redist  (d3dx9_42, X3DAudio1_7)
# export XROS_GAME_FW=...                           # default: $VXRT_PRIVATE_ROOT/game_fw-xros  (the aot stage's output)
# export XROS_SHADER_DIR=...                        # default: $VXRT_PRIVATE_ROOT/shadercache-xros-manifest
# export XRIZER_RUST_ROOT=...                       # default: <checkout>/build/toolchains/xrizer-rust (tools/setup_rust.sh)

# --- Nexus Mods (optional: only for mods fetched with `tools/vxrt_build.py mods-fetch`) -------------------------------
# Your personal API key: nexusmods.com > Site preferences > API Keys. Not your password (the API has no password login).
# Never commit it. Put it here directly, or read it from a password manager, for example 1Password:
# export NEXUS_API_KEY="YOUR_KEY"
# export NEXUS_API_KEY="$(op item get "Nexus Mods" --vault Private --fields label=apikey --reveal 2>/dev/null)"   # item needs a field labelled "apikey"

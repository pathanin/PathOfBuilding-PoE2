# CLAUDE.md

Path of Building for Path of Exile 2 — an offline build planner written in Lua (LuaJIT 2.1 / Lua 5.1 semantics) on top of **SimpleGraphic**, a native C++ host library that supplies the window, an ANGLE-backed OpenGL ES renderer, input, and the Lua API (plus native modules `lcurl`, `lzip`, `lua-utf8`, `socket`). All application logic lives in `src/`; `runtime/` holds the shipped binaries and pure-Lua libraries. PRs target the `dev` branch.

The host boots the app by calling `src/Launch.lua` with the script path as `argv[0]` (not the program name), then `launch:OnInit()`.

Before searching for a file or symbol, read `.claude/graph.md` — it maps modules, key symbols, and where to add new code.

## Conventions

- Lua style comes from `.editorconfig`: **tabs** for indentation, `max_line_length` 360, and **trailing whitespace is not trimmed** — don't let an editor reformat it away.
- Classes are instantiated through the `new("ClassName", ...)` system in `src/Modules/Common.lua`, not plain metatable OO. One class per file under `src/Classes/`.
- `src/Data/ModCache.lua` is generated — never hand-edit it.

## Tests

busted + LuaJIT run against `src/HeadlessWrapper.lua`, which stubs the SimpleGraphic API so the whole app loads without a GUI. `.busted` runs from `src` with spec root `spec/` and excludes the `builds` tag by default. CI runs in `ghcr.io/pathofbuildingcommunity/pathofbuilding-tests:latest`; spellcheck is cspell, whose config and dictionaries are fetched at CI time from `Nightblade/pob-dict` — there is no `cspell.json` in this repo to edit.

```sh
busted --lua=luajit                                                 # all tests, from repo root
cd src && busted --lua=luajit ../spec/System/TestDefence_spec.lua   # one spec, CI style
```

If a change affects mod parsing, regenerate `ModCache.lua` and commit the result — **CI fails when it is stale**:

```sh
cd src && LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua" REGENERATE_MOD_CACHE=1 luajit HeadlessWrapper.lua
```

## Running the app

Running from a repo checkout auto-enables **dev mode** (detected by `manifest.xml` having no branch/platform attributes): the auto-updater (`UpdateCheck.lua` / `UpdateApply.lua`, win32-only) is disabled and the user path for saved builds and settings becomes the script path `src/` — so launching the app writes build files into the working tree.

- Windows `./runtime/Path of Building-PoE2.exe` — macOS `./runtime/pob-poe2`, or the `~/Applications/Path of Building PoE2.app` bundle.
- In dev mode: `F5` restarts in place, `Ctrl+~` toggles the debug console, `ConPrintf()` prints to it, holding `Alt` shows extra tooltip debug info.

## macOS native runtime

Official builds are Windows-only; this checkout has a working native arm64 macOS runtime (built 2026-07). Runtime source is `~/Documents/PathOfBuilding-SimpleGraphic`, a clone of `PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic` carrying macOS fixes **not yet upstreamed** (LuaJIT vcpkg-port fixes including a null-safe `getenv` patch, CMake platform-source fixes, missing includes, Win32 `Sleep` removal — see the git diff there). Its launcher `~/Documents/PathOfBuilding-SimpleGraphic/macos-launcher/pob_launch.c` replaces the Windows .exe: it dlopens `libSimpleGraphic.dylib`, calls `RunLuaFileAsWin`, sets `LUA_PATH`/`LUA_CPATH` to exe-relative paths (Unix LuaJIT lacks Windows' `!\lua\?.lua` defaults), and re-execs once with `DYLD_LIBRARY_PATH` set so GLFW's `dlopen("libEGL.dylib")` finds the ANGLE dylibs (`runtime/libEGL.dylib` symlinks to `liblibEGL_angle.dylib`). Staged artifacts in `runtime/` (dylibs, `*.so` modules, `pob-poe2`) are untracked and listed in `.git/info/exclude`.

Rebuild after changing SimpleGraphic:

```sh
cd ~/Documents/PathOfBuilding-SimpleGraphic
cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DVCPKG_TARGET_TRIPLET=arm64-osx-dynamic -DVCPKG_HOST_TRIPLET=arm64-osx-dynamic \
  -DCMAKE_TOOLCHAIN_FILE=vcpkg/scripts/buildsystems/vcpkg.cmake   # host triplet must match target
cmake --build build
cp build/libSimpleGraphic.dylib ~/Documents/PathOfBuilding-PoE2/runtime/
# native Lua modules go in as .so: liblcurl.dylib → lcurl.so, liblzip.dylib → lzip.so,
# liblua-utf8.dylib → lua-utf8.so, libsocket.dylib → socket.so
# (re-run `install_name_tool -add_rpath @loader_path` on replaced files)
```

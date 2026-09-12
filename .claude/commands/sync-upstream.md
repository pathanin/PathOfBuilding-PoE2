Sync this fork's `dev` with upstream `PathOfBuildingCommunity/PathOfBuilding-PoE2`, **and** sync the companion native-runtime repo `PathOfBuilding-SimpleGraphic`'s `master` with its own upstream, resolving anything in either repo that would break the macOS native port, then merge both — and leave the macOS runtime rebuilt and working.

**Run this end-to-end without asking the user anything.** Every decision point below has a deterministic rule. When a rule leaves genuine ambiguity, the answer is never "ask" — it is **bail out of that one repo cleanly** (leave it exactly as it was found, nothing pushed) and carry on with the other, then say so in the final report. A partial, clean result plus an honest report always beats a prompt.

Manual-only: only run this procedure when the user explicitly invokes `/sync-upstream`. Never start it proactively from conversation content about updates or syncing.

Dry-run detection: trim `$ARGUMENTS` and check the leading word(s), not a substring match anywhere in the text — trigger dry-run only if the trimmed args are exactly `check` / `dry-run`, or start with `check ` / `dry-run ` (e.g. `check`, `dry-run`, `check both repos`). A sentence that merely mentions "check" in passing (e.g. "also check SimpleGraphic and sync it") is a normal sync request, not a dry-run — do not misfire on it. When dry-run triggers: do only step 1 for **both** repos (report what upstream has that we don't, and vice versa, for each) and stop — no branch, no PR, no merge, no rebuild, for either repo.

Arguments other than `check`/`dry-run` are context, not instructions to re-plan: run the normal full procedure.

---

## Hard invariants — never violate, no exception

1. **Never push to, merge into, or open a PR against `upstream`.** `upstream` is fetch-only. Every push targets `origin` (the user's fork). Enforce mechanically:
   - Pass `--repo <fork>` on **every single `gh` call** — `create`, `view`, `checks`, `merge`, `reopen`, `api`. Never rely on `gh`'s repo auto-detection.
   - Before any push, assert the target: `git remote get-url origin` must contain `pathanin/`. If it contains `PathOfBuildingCommunity`, abort that repo immediately.
   - `gh pr create` must carry both `--repo <fork>` and `--base <sync branch>`; after creating, verify `gh pr view <n> --repo <fork> --json baseRefName,headRepositoryOwner` reports the fork. If it reports the community org, close the PR and abort that repo.
   - **Why this is mechanical, not paranoid:** on 2026-07-23 a bare `gh pr merge 3` in the SimpleGraphic clone resolved to `PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic#3` — an unrelated 2020 PR — because that clone had no `gh` default repo. It was a harmless no-op only by luck. Defaults are now set on both clones, but `--repo` is the guard that does not depend on config.
2. **Never delete a topic branch until the PR is confirmed merged** (see step 8). `git branch -d` checks the *upstream tracking* branch, not the sync branch, so it happily deletes unmerged work once pushed — and deleting a PR's head branch on `origin` **closes** the PR.
3. **Never leave a repo half-merged.** Any bail-out path runs `git merge --abort` (or `git reset --hard <pre-merge sha>`), returns to the sync branch, and confirms a clean tree.
4. **Never overwrite `runtime/` without a backup** taken first (step 10).
5. **When a choice affects the macOS port, the macOS port wins.** Upstream's Windows-oriented change is never a reason to drop a fork fix.

---

## Context (verify, don't assume — remotes/paths may have changed)

Confirm both repos against this table each run before acting on it:

| | PoB-PoE2 (this repo) | PathOfBuilding-SimpleGraphic |
|---|---|---|
| Path | cwd (`~/Documents/PathOfBuilding-PoE2`) | `~/Documents/PathOfBuilding-SimpleGraphic` — a separate clone, **not** a submodule |
| `origin` (push here) | `pathanin/PathOfBuilding-PoE2` | `pathanin/PathOfBuilding-SimpleGraphic` |
| `upstream` (fetch only) | `PathOfBuildingCommunity/PathOfBuilding-PoE2` | `PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic` |
| Sync branch | `dev` | `master` |
| Branch protection on `origin` | Yes — PR required | None, but use topic branch + PR anyway |
| Tests | `busted --lua=luajit` (step 4) | None — C++ repo, CI only builds |
| `gh` default repo | `pathanin/PathOfBuilding-PoE2` (set) | `pathanin/PathOfBuilding-SimpleGraphic` (set 2026-07-23) — still pass `--repo` |

Where the fork-only macOS-port patches live — orientation only, **never ground truth**; step 1 computes the real list every run, since the port grows:

- **PoB-PoE2:** a few files under `src/`, notably `src/Launch.lua`'s `jit.os == "OSX"` JIT-disable block (`jit.off()`).
- **SimpleGraphic:** `vcpkg-ports/ports/luajit/<version>/` (exec bit on `configure`, `INSTALL_TSYMNAME=luajit-lnk`, null-safe getenv macros in `pob-wide-crt.patch`), `cmake/FindLuaJIT.cmake`, `CMakeLists.txt`, several files under `engine/` (missing includes, `Sleep()` → `sleep_for`, ANGLE Metal backend, Cmd→CTRL), `macos-launcher/pob_launch.c`, `vcpkg.json` / `vcpkg-configuration.json`, and submodule pins.

**CI runs on both forks** (verified 2026-07-23 — supersedes an older "0 workflow runs" belief). PoB-PoE2: `check_modcache`, `run_tests` ×3, `spellcheck` — ~2 min. SimpleGraphic: `build_dll (x64, windows-2022)` — **~24 min**, builds deps from source.

**Windows CI cannot validate the macOS fixes.** In `pob-wide-crt.patch` the `_lua_getenvcopy`/`_lua_getenvfree` **macros** live in the `#else` non-Windows branch; Windows compiles the **function bodies** instead. `INSTALL_TSYMNAME` and the `configure` exec bit are osx-triplet-only. Windows green only proves the patch still applies and Windows isn't regressed. **Corollary: a Windows CI failure is provably not caused by macOS-only patch edits** — investigate upstream's change, never revert the fork's macOS fixes to make CI pass.

**Submodule gotcha (SimpleGraphic only):** it pins third-party submodules (`vcpkg`, `libs/luautf8`, `libs/luasocket`, `dep/imgui`, `dep/glm`, `dep/compressonator`, `libs/Lua-cURLv3`) at their real upstreams — not forked, no push access, fork-and-PR does not apply. If a fork-only commit bumped a pin, verify reachability: `cd <submodule> && git branch -a --contains <sha>`. A commit made on a detached HEAD inside a submodule can be a local-only orphan that breaks every fresh clone (has happened). If unreachable, repin to an equivalent commit that *is* reachable from the submodule's own remote; do not fork the submodule.

Merge convention on both forks: real merge commits via `gh pr merge --merge` (never squash).

---

## Decision policies (these replace every former "ask the user" gate)

**P1 — Topic branch name collision.** Use `sync-upstream-<YYYY-MM-DD>`. If that branch already exists locally or on `origin`, append `-r2`, `-r3`, … until unused. Never reuse or force-overwrite an existing branch.

**P2 — Textual merge conflict.** For each conflicted file:
- **Not a fork-only-patch file** → take upstream's side (`git checkout --theirs -- <file>`). Upstream owns files the port never touched.
- **Is a fork-only-patch file** → keep both: start from upstream's side, then re-apply the fork's delta for that file (`git diff upstream/<branch>...<pre-merge sync branch> -- <file>`). Verify every fork signature line (P4) is present afterward.
- **Re-application does not apply cleanly** → bail out of this repo per invariant 3 and report the file plus both diffs. Do not hand-merge C/C++ or patch-file hunks by guesswork.
- **The resolution invents something that is neither side's code** → finish the merge, then land that delta as **its own commit** on the sync branch before opening the PR. This is the case where you keep upstream's structure but fix a bug in it, or combine both sides into something better than either. A delta that exists only inside a merge commit has **no P4 signature** — `git show <merge-sha> -- <file>` yields nothing usable — so the next sync cannot see it and will silently take upstream's side. When the merged code is already correct, a comment-only commit marking the deviating lines is enough; the point is that the lines become detectable, not that they change. Happened 2026-07-29 in `src/Classes/TradeQueryRequests.lua`: the resolution of upstream's `c8e0ff03f` kept upstream's `processLine` refactor but fixed two bugs in it (a dropped flag prefix, a nil-crash guard), and those two lines were invisible to P4 until commit `a3e01e572` marked them.

**P3 — Clean merge, but upstream touched a file the fork patches** (the dangerous silent case). Run the P4 verification. If signatures survive → continue. If any is gone → re-apply that fork delta, commit it separately (`Forward-port macOS fix …`), then continue.

**P4 — Fork-signature verification (mechanical).** Record `PRE=$(git rev-parse <branch>)` before merging; `verify-port.sh <PRE> <branch>` (step 5) does the mechanics after. It compares the fork delta before and after the merge, each measured against the upstream point its side was built on — **the three-dot form on `PRE` is essential**, since `PRE` predates the merge and a two-dot diff against the moved-ahead upstream tip reports all of upstream's new work as fork delta. It also checks file **modes** (an exec bit is part of the fix). What it reports, you decide:
- **Ground truth is `git diff upstream/<branch> <branch> -- <file>`**, not the commit list. Signatures are derived from commits and can disagree with it in both directions, so when they conflict, believe the diff:
  - *Unsignatured delta* — the diff shows fork lines that no fork-only non-merge commit accounts for. It came from a merge resolution and P4 is blind to it. Treat per P2's fourth bullet: give it a standalone commit now, before it gets silently reverted by a later sync.
  - *Stale signature* — a signature's lines are absent because upstream legitimately refactored the region and the fork delta was re-expressed on top, not because anything was dropped. Confirm against the diff and move on; **do not** "restore" the old lines over upstream's refactor.

**P5 — Re-versioned vendored directory (the LuaJIT trap — expect this repeatedly).** Upstream bumps LuaJIT by **adding a new port dir** (`vcpkg-ports/ports/luajit/<newdate>_1/`) and repointing the baseline in `vcpkg-configuration.json`, rather than editing the existing one. The new dir is a copy of the old **without** the fork's fixes, so P4 sees nothing wrong — no path overlap, no conflict — and the next build silently uses an unpatched port. `verify-port.sh` detects it (sub-steps 1-2); repairing it is yours (sub-steps 3-7):
  1. The script lists directories added by the merge that are a versioned sibling of a dir the fork patched (`vcpkg-ports/ports/<name>/<version>_<n>/`).
  2. It names the previous version dir(s) carrying the fork delta.
  3. For every file present in both, `diff` old vs new. Where the difference is the fork's own delta, re-apply it to the new dir. Copy file modes, including the exec bit on `configure`.
  4. **Success check:** when upstream's new copy is verbatim except for the fork delta — the 2026-07-20 case — each forward-ported file ends up byte-identical to its counterpart in the old dir (`diff` returns nothing). That is the narrow, easy case, not the norm: on a bump where the patch content itself genuinely changed, old-vs-new will not reduce to the fork delta, and sub-step 7 will bail. A bail there is the safety rule working, not a malfunction.
  5. Confirm `vcpkg-configuration.json`'s baseline and `vcpkg-ports/versions/*.json` point at the new dir, so you know which port is live.
  6. Commit as its own `Forward-port macOS … fixes to <newversion>` commit. Editing in place is correct because the registry entry is path-based (`"path": "$/ports/luajit/<ver>"`), not git-tree-pinned.
  7. If the old-vs-new diff contains changes that are **not** attributable to the fork's delta, do not guess — bail out of this repo per invariant 3 and report.

**P6 — CI wait budget.** Read the check status after creating the PR. A red result always blocks the merge: leave the PR open, sync branch untouched, and report the failing job URL.

How long to wait for a pending result differs per repo, because their value differs:
- **PoB-PoE2** — checks finish in ~2 min and `run_tests`/`check_modcache` exercise real Lua logic. Worth a short bounded wait (cap ~6 min); if still pending at the cap, proceed and note it in the report.
- **SimpleGraphic** — `build_dll` takes ~24 min and, per the Context section, cannot validate the macOS fixes at all. Don't hold the run for it; proceed once the status has been read once. The step-12 smoke test is the gate that actually protects the port here.

Either way, note in the report what CI said and that checks may still be running afterward. This budget reflects the user's stated low regard for these forks' CI (2026-07-23); it is the knob to turn if that changes.

**P7 — Anything unexpected** (a missing path, remotes not matching, an unreadable state, a step erroring twice): bail out of that repo per invariant 3, finish the other repo, report precisely what happened. Never retry blindly more than once; never ask.

---

## Procedure

Both repos run **in parallel through step 7**, not one repo fully then the other. They are independent, and the expensive waits (PoB-PoE2's ~2 min CI, SimpleGraphic's build) overlap for free. A bail-out in one must never stop the other.

1. **Preflight + diff, both repos — one call.** Run `bash .claude/scripts/sync-upstream/preflight.sh`. It performs the whole read-only opening in a single invocation, for both repos: dirty check, HEAD-branch check, remote assertion against the Context table, fetch, both-direction commit lists, the fork-only file list (`git diff upstream/<branch>...<branch>` — P4's ground truth, not the commit list), the P3 intersection, and submodule pins sitting in the fork delta.

   Read its per-repo verdict and decide:
   - `SKIP:` → that repo is out for this run; the other proceeds. `SKIP: on '<x>', expected '<branch>'` normally means **a previous sync left a topic branch checked out** — report it, don't clean it up.
   - `>>> UP TO DATE` → that repo has nothing to merge; skip steps 2-9 for it and cover it in the report.
   - An empty P3 intersection does **not** mean safe. P5 is exactly the case that hides from it, so step 5 runs regardless.
   - Any flagged submodule pin → run the reachability check from the Context section.
   - Dry-run, or both repos up to date → stop here and report.

   The script reports facts only; every decision stays yours.

2. **Branch, both repos.** In each repo that has upstream commits: record `PRE=$(git rev-parse <branch>)`, then `git checkout -b <name> <branch>` using P1. Keep each repo's `PRE` — step 5 needs it.

3. **Merge.** `git merge upstream/<branch> --no-edit`. Conflicts → P2. Clean → continue.

4. **Test (PoB-PoE2 only).** Run `busted --lua=luajit` from the repo root if both are on `PATH`; if not, say so plainly and rely on CI (`run_tests`, `check_modcache`). SimpleGraphic has no suite — instead record whether the merge touched C++/CMake/vcpkg-port files, which decides step 10.

5. **Verify + repair the macOS port.** Run `bash <PoB-PoE2>/.claude/scripts/sync-upstream/verify-port.sh <PRE> <branch>` from inside the repo. It mechanizes P4 and P5: the fork delta measured before and after the merge against the same upstream point, per-file dropped lines, merge-resolution lines that no fork commit accounts for, file-mode changes, and newly added versioned sibling port dirs.

   Act on its findings — the script never repairs anything:
   - `!! <file> — N fork line(s) gone` → a dropped patch (P3), **or** a stale signature if upstream legitimately refactored the region (P4's last bullet). Read the diff before deciding; never "restore" old lines over an upstream refactor. A real drop gets re-applied and committed separately as `Forward-port macOS fix …`.
   - `?? <file> — N fork line(s) that were not there before` → a merge-resolution delta with no P4 signature. P2's fourth bullet: give it its own commit now, even a comment-only one, so the next sync can see it.
   - `!! <dir> is a new sibling of a fork-patched port dir` → P5. Forward-port the fork delta into the new dir, preserve file modes, confirm the baseline points at it, commit as `Forward-port macOS … fixes to <newversion>`. If old-vs-new contains changes not attributable to the fork delta, bail per invariant 3 — that bail is the safety rule working.
   - Re-run the submodule reachability check if the merge touched any pin.
   - Anything unrepairable → P7.

6. **Push + PR.** Assert invariant 1, push the topic branch to `origin`, then `gh pr create --repo <fork> --base <branch> --head <topic>` with a body stating which upstream commits were merged, whether any macOS fix needed forward-porting (and exactly what was re-applied), and the verification performed. Verify the PR's base repo is the fork.

7. **Open both PRs before waiting on either.** Do not read CI for repo A and sit on it while repo B is untouched. Finish steps 2-6 for both repos first, then apply P6 once, reading both repos' checks together.

8. **Merge + cleanup, per repo.** `gh pr merge <n> --repo <fork> --merge`. **Confirm the merge actually happened before touching any branch:** `gh pr view <n> --repo <fork> --json state,mergeCommit` must report `MERGED`, and `git ls-remote origin <branch>` must equal that merge commit — `gh` printing nothing is not proof. Only then: `git checkout <branch>`, `git fetch origin <branch>`, `git merge --ff-only origin/<branch>`, and delete the topic branch locally and on `origin`. If the merge did not happen, leave every branch in place and report.

   Keep these as separate commands, never `&&`-compounds — splitting them is what clears an auto-mode denial. Then assert `git rev-list --count <branch>..upstream/<branch>` is 0, the tree is clean, and the fork delta survived on the sync branch.

9. **Refresh `.claude/graph.md`** — PoB-PoE2 only, once its merge has landed on `dev`. A sync pulls in upstream's Lua refactors, so the repo graph goes stale on most runs; catching it here beats having a `Stop` hook block an unrelated turn days later. Run the checker the hook already uses:

   ```sh
   echo '{}' | python3 .claude/claude-graph/verify_graph.py Stop
   ```

   Silence means clean — nothing to do. Otherwise it names dead paths and dead symbols. Fix **only** the rows it names: re-derive that file's symbols from the current code, drop what is gone, add what replaced it, leave every other row untouched. Then bump the `<!-- generated: <date> @ <sha> -->` stamp in the header to today and the new sync-branch SHA, and re-run the checker until it is silent.

   Two things not to do:
   - Do **not** regenerate the whole file. The checker only verifies; there is no generator, and a wholesale rewrite loses hand-curated rows.
   - Ignore a `Directories with no row` advisory for `src`, `src/Export`, `src/Export/Classes`, `src/Modules`. That one is a known artifact of this graph using per-file rows, not real staleness — do not hand-patch it.

   A symbol the checker names may have been folded into another function rather than deleted (`setConnectorColor` → `renderConnector`, 2026-09-12). Check before assuming it vanished; if its replacement is already listed, deleting the dead name is the whole fix.


10. **Rebuild + restage the macOS runtime** — only if SimpleGraphic actually merged changes to C++/CMake/vcpkg-port files (step 4). This is part of the command: without it the staged runtime is stale and the sync hasn't really landed for macOS. Takes ~5 min.
   1. Build from the synced SimpleGraphic tree (see `CLAUDE.md` for the canonical command; host triplet must match target):
      ```sh
      cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DVCPKG_TARGET_TRIPLET=arm64-osx-dynamic -DVCPKG_HOST_TRIPLET=arm64-osx-dynamic \
        -DCMAKE_TOOLCHAIN_FILE=vcpkg/scripts/buildsystems/vcpkg.cmake && cmake --build build
      ```
      Check the **real** exit codes of configure and build, not a wrapper's. Build failure → stop here, leave `runtime/` untouched, report (the sync itself already succeeded).
   2. Confirm from the log that vcpkg built the **patched** port (e.g. `luajit:arm64-osx-dynamic@<newversion>` resolving to the local filesystem registry path).
   3. **Back up first** (invariant 4): copy every file about to be replaced — plus the existing `libluajit-*` dylib and its symlinks — to `~/Documents/pob-runtime-backup-<YYYY-MM-DD>/` with `cp -a` to preserve symlinks. Verify each file arrived.
   4. **Restaging is never a one-file copy.** A LuaJIT bump changes the versioned soname (e.g. `libluajit-5.1.2.1.1753364724.dylib` → `…1784580905.dylib`), and `libSimpleGraphic.dylib` *and all four Lua modules* record it in their `@rpath` load commands. Stage the full set: `libSimpleGraphic.dylib`; `liblcurl.dylib`→`lcurl.so`, `liblzip.dylib`→`lzip.so`, `liblua-utf8.dylib`→`lua-utf8.so`, `libsocket.dylib`→`socket.so`; the new `libluajit-*.dylib` from `build/vcpkg_installed/arm64-osx-dynamic/lib/`, repointing `libluajit-5.1.2.dylib` and `libluajit-5.1.dylib` at it and removing the stale one. Then `install_name_tool -add_rpath @loader_path` on each replaced binary that lacks it.
   5. **Verify before trusting:** for every staged binary, each `@rpath` dependency must exist in `runtime/`. Ignore a dylib's own `LC_ID_DYLIB` (the first `otool -L` line) — the modules keep ids like `@rpath/liblcurl.dylib` while staged as `.so`, which is correct and pre-existing. Any genuinely unresolved dep → roll back from the backup and report.
   6. **Smoke-test:** launch `runtime/pob-poe2` for ~25 s, then terminate it and confirm no stray process. Pass = process survives with no `dyld` / `Library not loaded` / `Symbol not found` error. Good signs: `Renderer initialised`, `using GL_EXT_texture_compression_bptc` (ANGLE **Metal** backend live — its absence means the legacy-GL fallback regressed), `Unicode support detected` (a module on the new soname loaded), uniques/rares loaded. Failure → roll back from the backup, verify the restored runtime launches, and report. If the app cannot launch for environmental reasons (no display), skip the smoke test, keep the staged build, and say so.

11. **Report.** Per repo: what was merged, whether the macOS port needed forward-porting and exactly what was re-applied, CI outcome, final SHA on the sync branch, anything skipped or bailed out of and why, plus whether `.claude/graph.md` needed rows fixed and which. Then the runtime outcome: rebuilt/restaged/smoke-tested, or why not, plus the backup path for rollback. State plainly what was **not** verified — Windows CI does not cover the macOS fixes, and `lzip.so`/`socket.so` load on demand so a boot test doesn't exercise them.

---

## Known-benign noise — do not chase, do not "fix"

- **`CMake Warning` from `z_vcpkg_fixup_rpath_macho.cmake` containing `install_name_tool: … larger updated load commands do not fit`** about `tools/luajit/luajit`. Affects only the standalone luajit CLI's rpath, not `libluajit` or `libSimpleGraphic.dylib`. Build still exits 0.
- **`Auth token expired` / `Failed to recreate auth token: Response code: 400`** at app startup — the user's expired PoE OAuth token. Unrelated to the runtime.
- **`missing node <id>` lines** during passive-tree processing — pre-existing tree-data warnings, independent of LuaJIT version.
- **`SimpleGraphic v2.5 x86 Release`** in the banner on arm64 — cosmetic version string.
- **Startup ~9 s vs a historical ~3.7 s** — the `Startup time:` figure prints before the OAuth calls, so those don't explain it; the likely cause is the macOS `jit.off()` patch. Expected tradeoff, not a regression. Do not open a perf investigation.

---
name: headless-pob
description: Drive Path of Building PoE2 without opening the GUI — decode a pasted export code or a poe.ninja PoB link, load it into the app's own engine headlessly via LuaJIT, and answer "what if" questions (gem swaps, passive tree changes, gear/item swaps, enemy/boss assumptions) with real numbers from PoB itself, or generate a trade search link for current gear. Use whenever the user asks about their build, pastes a PoB export code or poe.ninja/poe2/pob/ link, asks whether some change would help/hurt their damage or defence, asks about passive tree respecs, or wants a trade link for an item.
---

# Headless PoB2 build analysis

Answers build questions ("is X worth swapping for Y?") using this repo's *own*
engine, headlessly — no GUI, no manual math, no guessing. Prefer this over reasoning
from game-data files alone whenever a concrete number is possible: static-data
reasoning ("this stat isn't referenced in the calc code") is a good sanity check,
but the headless run is what actually confirms it.

This covers five kinds of mutation, all following the same load → mutate → recalc
shape: **gem swaps** (§4), **passive tree changes** (§5), **enemy/boss assumptions
via the Configuration tab** (§6), **gear/item swaps** (§7), and **trade search link
generation** (§8) — this last one doesn't need a recalc at all, it's a pure data
transform. Combine them freely in one scratch script (e.g. set enemy resist, then
test a gem swap under that assumption — see the §6 gotcha, this exact combo caught
a wrong conclusion in an earlier session).

## 1. Get the build XML

**Pasted export code**: the user may paste a raw base64 PoB code directly into chat.
These frequently get corrupted in transit (a single flipped character breaks the
whole zlib stream) — if `decode_pob.py` fails with a zlib error, don't fight it,
ask for a poe.ninja link or a re-paste instead of debugging byte-by-byte.

**poe.ninja link** (`https://poe.ninja/poe2/pob/<id>`): fetch the raw code directly,
which is far more reliable than anything pasted through chat:

```sh
curl -sL "https://poe.ninja/poe2/pob/raw/<id>" -o /tmp/pob_code.txt
```

**Decode** (works for either source):

```sh
python3 .claude/skills/headless-pob/scripts/decode_pob.py /tmp/pob_code.txt /tmp/build.xml
```

If it throws `zlib.error`, the input is corrupted — go back to the poe.ninja link.

## 2. Make sure luajit is available

This repo's tests need `luajit`, but a fresh checkout may only have the runtime
`.dylib`, not the CLI. Check first:

```sh
which luajit || /opt/homebrew/opt/luajit/bin/luajit -v
```

If missing: `brew install luajit` (fast, ~2MB, safe to install).

## 3. Run the build headlessly

Copy `scripts/dps_compare.lua.template` to `src/_scratch_<name>.lua` (this pattern
is gitignored via `.git/info/exclude` — never commit these), fill in the build XML
path and the socket-group index you care about, then run from `src/`:

```sh
cd src
LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" \
LUA_CPATH="../runtime/?.so;;" \
luajit _scratch_<name>.lua
```

Both env vars **must** end in `;;` — that tells Lua to append the default search
path instead of replacing it. Without it, the app's own modules (`Data/*`,
`Classes/*`, etc.) won't resolve and you'll get cryptic "module not found" errors.

Key API surface (all available once `loadBuildFromXML` has run):

- `build.skillsTab.socketGroupList` — array of skill groups; each has `.gemList`
  (array of gem instances) and `.mainActiveSkillCalcs` (index into `.gemList` for
  which gem is the *active* skill being calculated, vs. a support).
- `build.mainSocketGroup` — which group index PoB's Calc tab treats as "main."
  Set it to any group index to get that group's numbers; it isn't fixed to
  whatever the export had.
- `build.calcsTab:BuildOutput()` — recomputes; populates `build.calcsTab.mainOutput`
  (`TotalDPS`, `CombinedDPS`, `CritChance`, `AverageDamage`, etc.) and
  `build.calcsTab.mainEnv`.
- Always follow a mutation with: `build.buildFlag = true; runCallback("OnFrame");
  build.calcsTab:BuildOutput(); runCallback("OnFrame")`.

## 4. Swapping a gem

Mutate the gem instance table in place, then re-resolve it:

```lua
local grp = build.skillsTab.socketGroupList[GROUP_INDEX]
local target -- find by nameSpec, or by position in grp.gemList
target.nameSpec = "New Gem Name"
target.gemId = "Metadata/Items/Gems/SkillGemNewGem"  -- see gotcha below
target.skillId = nil
target.gemData = nil
target.grantedEffect = nil
build.skillsTab:ProcessSocketGroup(grp)
```

**Gotcha — gemId format.** The exported build XML's `gemId` attribute (and a
gem's `skillId`/`grantedEffectId`) are *not* the same string as the key in
`src/Data/Gems.lua`. The XML/`gameId` form looks like
`Metadata/Items/Gem/SupportGemFoo`; the `Data/Gems.lua` table key looks like
`Metadata/Items/Gems/SkillGemFoo` — different path (`Gem` vs `Gems`) and prefix
(`SupportGem`/bare name vs always `SkillGem`, even for support gems). Using the
wrong one makes `ProcessSocketGroup` silently fail to resolve (`gemData` stays
nil) and the swap becomes a no-op — no error, just wrong data.

Two ways to get it right:
1. `grep -n '"Gem Display Name"' src/Data/Gems.lua` and copy the surrounding
   `["Metadata/Items/Gems/..."]` key.
2. Safest: copy `nameSpec`/`gemId`/`skillId` verbatim from another gem instance
   already in the same build that uses the target gem (e.g. a comparison
   setup, or the same support on a different link).

**Sanity-check every swap.** Before trusting a "no DPS change" result, do a swap
you know must move a specific number (e.g. into a crit-chance support that's
type-compatible with the skill) and confirm that output field actually changed.
A silent no-op swap and a genuinely-inert gem both look identical in the output —
the only way to tell them apart is to prove the mechanism works first.

**Type compatibility.** Not every support applies to every skill — check
`requireSkillTypes` in `src/Data/Skills/sup_*.lua` for the support before
assuming it's valid on your target skill (e.g. supports requiring
`SkillType.Attack` are invalid on spells like Arc).

## 5. Passive tree changes

`build.spec` is the live `PassiveSpec` instance (`src/Classes/PassiveSpec.lua`);
`build.treeTab` just wraps it for the GUI — mutate `build.spec` directly, no
separate tab touch needed for calc purposes.

**Look up a node.** There's no name→id map for tree nodes; scan `spec.nodes`
(keyed by id):

```lua
local target
for id, node in pairs(build.spec.nodes) do
	if node.name == "Chaos Damage and Resistance" and not node.alloc then
		target = node
		break
	end
end
```

Class/ascendancy names *do* have a lookup: `build.spec.tree.classNameMap[className]`
→ classId.

**Allocate / deallocate:**

```lua
build.spec:AllocNode(target)
-- ... recalc, compare ...
build.spec:DeallocNode(target)
```

**Class / ascendancy change:**

```lua
build.spec:SelectClass(classId)
build.spec:SelectAscendClass(ascendClassId)  -- 0 = none
```

Both rebuild the tree's internal path/dependency data themselves — no manual
`ProcessStats()` call needed. Recalc after either kind of change with the same
sequence as a gem swap: `build.buildFlag = true; build.modFlag = true;
runCallback("OnFrame"); build.calcsTab:BuildOutput(); runCallback("OnFrame")`.
`spec:AddUndoState()` is GUI-only (undo history) — skip it headless.

**Gotcha — `AllocNode` pulls in the whole path, `DeallocNode` doesn't give it
back.** `AllocNode(node)` allocates every intermediate connector node on the
route from the nearest already-allocated node to `node` (verified: one test
node needed 5 filler nodes actually allocated alongside it). `DeallocNode(node)`
only deallocates nodes that *depend on* `node` downstream — it does **not**
remove the upstream filler nodes `AllocNode` added. Dealloc'ing such a node
therefore leaves the filler nodes in place and produces **identical output**
to the still-allocated state — a silent non-revert that looks exactly like "this
node has zero effect" if you're not watching for it.

To get a clean, provably-reverted A/B test: either pick a node with
`#target.path == 1` (directly adjacent to your current tree, no filler needed),
or explicitly `DeallocNode` every node that was in the original `path` array,
not just the one you cared about.

## 6. Enemy/boss assumptions (Configuration tab)

There is no GUI checkbox headless, but Configuration-tab values are just data —
`build.configTab.input` is a flat table (`src/Classes/ConfigTab.lua`) keyed by
the `var` names defined in `src/Modules/ConfigOptions.lua` (grep `var = "..."`
there for the full list — e.g. `enemyLightningResist`, `conditionEnemyLowLife`,
`enemyIsBoss`, `enemyDamageType`).

```lua
build.configTab.input["enemyLightningResist"] = 40
build.configTab:BuildModList()   -- regenerates modList/enemyModList from .input — required, see gotcha
build.buildFlag = true
runCallback("OnFrame")
build.calcsTab:BuildOutput()
runCallback("OnFrame")
```

**Gotcha.** Writing to `.input` alone does nothing — you must call
`build.configTab:BuildModList()` before the usual buildFlag/OnFrame/BuildOutput
recalc, or the change is silently ignored and you'll wrongly conclude the config
option has no effect.

**This matters more than it looks.** A previous session tested Lightning
Penetration against the *default* enemy (0% resistance everywhere) and got a
result byte-identical to no support gem at all — because penetration against 0%
resistance genuinely does nothing (`src/Modules/CalcOffence.lua`: `resist > minPen
and m_max(resist - pen, minPen) or resist` — the branch is skipped entirely when
resist isn't above the floor). That's not "the gem is bad," it's "the test target
was a strawman." Verified fix: setting `enemyLightningResist = 40` before the same
swap moved TotalDPS from a no-op to a real, different number
(813116.91 baseline → 764446.73 at 40% resist with Execute III still socketed,
→ 587149.54 after swapping to Lightning Penetration under that resist). **Always
set a plausible enemy resistance before evaluating a penetration/exposure-type
support**, and say what resistance value you assumed when reporting results.

Player-side conditions like `LowLife` are *not* config-tab toggles — they're
derived live every recalc from actual reservation/life math
(`src/Modules/CalcDefence.lua`, `data.misc.LowPoolThreshold = 0.35`). Read them
via `env.player.modDB.conditions["LowLife"]` after a `BuildOutput()`
(`build.calcsTab.mainEnv` is `env`) rather than trying to force them through
`configTab.input`.

## 7. Gear / item swaps

Items parse from PoB's standard paste format — the same text you'd paste into
PoB's "Create custom item" box, or copy from in-game/a trade site.

```lua
local newItem = new("Item", itemRawText)
if not newItem.base then
	error("item failed to parse — see gotcha below")
end
build.itemsTab:EquipItemInSet(newItem, build.itemsTab.activeItemSetId)
-- EquipItemInSet already sets build.buildFlag = true internally
build.buildFlag = true
runCallback("OnFrame")
build.calcsTab:BuildOutput()
runCallback("OnFrame")
```

`EquipItemInSet` (`src/Classes/ItemsTab.lua`) resolves the target slot itself via
`item:GetPrimarySlot()` — you don't pick the slot — and auto-assigns an item id if
the item has none. Use `activeItemSetId` (a key), not `activeItemSet` (the
resolved table).

**Fastest way to get a valid item to mutate:** copy an already-equipped item's raw
text and edit specific mod lines, rather than hand-writing one from scratch —
`build.itemsTab.items[slot.selItemId].raw` gives you a real, parser-valid
template. Exact line syntax (mod wording, `{fractured}`/`{crafted}` bracket tags,
the "Unique ID" line, etc.) must match PoB's parser precisely.

**Gotcha — same silent-no-op shape as the gem-swap gotcha.** A malformed item text
doesn't error, it just leaves `newItem.base == nil`, and `EquipItemInSet` on a
base-less item is a no-op. Always check `newItem.base ~= nil` before trusting the
equip, then confirm a specific output field you expect to move (e.g. `Spirit`,
`Life`, a resistance) actually changed.

## 8. Trade search link for an item

This one's a pure data transform — no recalc, no network call needed just to
produce the URL. Build the query table yourself using the same helpers PoB's GUI
popup uses internally; don't call the popup's own `buildURL`/`openPopup` in
`src/Classes/CompareBuySimilar.lua` directly, since those are wired to live GUI
controls (checkboxes/dropdowns) that don't exist headless.

```lua
local CBS = LoadModule("Classes/CompareBuySimilar")
local tradeHelpers = LoadModule("Classes/TradeHelpers")
local dkjson = require("dkjson")

local item = build.itemsTab.items[slot.selItemId]  -- or whichever equipped item

local modTypeSources = {
	{ list = item.enchantModLines,  type = "enchant" },
	{ list = item.implicitModLines, type = "implicit" },
	{ list = item.explicitModLines, type = "explicit" },
}
local modEntries = CBS.addModEntries(item, modTypeSources)
local categoryStr = tradeHelpers.getTradeCategory(slotName, item)

local queryTable = {
	query = { status = { option = "online" }, stats = { { type = "and", filters = {} } } },
	sort = { price = "asc" },
}
if item.rarity == "UNIQUE" or item.rarity == "RELIC" then
	queryTable.query.name = (item.title or item.name):gsub("^Foulborn%s+", "")
	queryTable.query.type = item.baseName
else
	queryTable.query.filters = { type_filters = { filters = { category = { option = categoryStr } } } }
	for _, e in ipairs(modEntries) do
		if #e.tradeIds == 1 and not e.isOption then
			local val = e.invert and -e.value or e.value
			table.insert(queryTable.query.stats[1].filters, { id = e.tradeIds[1], value = { min = val } })
		end
	end
end

local url = "https://www.pathofexile.com/trade2/search/Standard?q=" .. urlEncode(dkjson.encode(queryTable))
print(url)
```

This builds a "find something at least as good as my current item" search: for
rares/magics it filters by category plus a `min` threshold on each explicit/
implicit/enchant mod at its current roll; for uniques/relics it searches by name
+ base type instead of stats. `urlEncode` and `dkjson` are already loaded by
`HeadlessWrapper`.

**Gotchas:**
- Mod lines whose `tradeIds` has more than one entry (ambiguous trade-stat
  mapping) need a `type="count"` sub-filter, not a flat `min` filter — the
  snippet above only handles the common single-id case; skip or special-case
  multi-id mods rather than silently dropping them into the wrong filter shape.
- Defence stats (armour/evasion/ES/ward) and item-level filters are GUI-only
  inputs in the original popup — add them manually via `item.armourData` if the
  user wants them.
- League defaults to `"Standard"` in the URL above; ask or infer the actual
  current league if it matters.
- This only *builds the link* — actually fetching live listings needs
  `TradeQueryRequests.lua` and network access via `lcurl`, which is out of scope
  here; hand the URL to the user to open themselves.

## 9. Know the engine's gaps

PoB2 is early-access software; not every stat that exists in `Data/Skills/*.lua`
is wired into the actual damage/rate math in `src/Modules/*.lua` yet. Before
trusting that a stat changes the DPS PoB shows, grep for it:

```sh
grep -rn "the_stat_name" src/Modules/*.lua
```

Zero hits means PoB doesn't model that mechanic's effect on the number it shows
you — even if the gem is "real" and does something in-game. Say so explicitly
rather than presenting PoB's number as the whole answer.

## 10. Clean up

Delete `src/_scratch_*.lua` files when done. Never leave them staged or committed.

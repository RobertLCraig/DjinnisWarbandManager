# Headless testing for WoW addons

A portable recipe for unit-testing a World of Warcraft addon **without the game
client** — using [busted] for tests, [luacheck] for static analysis, a small
mock of the WoW API, and GitHub Actions for CI. This document is written so you
can lift the setup into any other addon; the **"Porting to a new addon"**
section at the end is the checklist.

[busted]: https://lunarmodules.github.io/busted/
[luacheck]: https://github.com/lunarmodules/luacheck

---

## 1. Why this works (and what it doesn't cover)

You can't run the actual WoW client headlessly in CI, and these tests don't try
to. What they *do* test is the part of an addon that is plain Lua: functions
that **read state and return a result** — target/threshold math, plan builders,
filters, formatters, parsers, data-model resolution. In a well-structured addon
that's most of the logic and the part most likely to regress.

What this **cannot** test:

- Anything that depends on real frames, secure templates, taint, or combat
  lockdown (UI layout, `SetPoint`, secure click handlers).
- The actual *effects* of API calls that mutate game state
  (`C_Container.PickupContainerItem`, `C_Bank.DepositMoney`, …). You can test
  the **decision** to call them and with what arguments, but the server-side
  result still needs a live smoke test.
- Event timing / ordering races, server-confirmed async settling, etc.

The practical split: **unit-test the pure planners; smoke-test the side effects
in-game.** Keep your decision logic in functions that return data (a "plan", a
number, a list) rather than functions that both decide *and* act — that's what
makes it testable and is good design regardless.

---

## 2. Layout

```
MyAddon/
├── MyAddon.toc
├── Core.lua
├── Modules/...
├── Locales/enUS.lua
├── .luacheckrc                 # static-analysis config
├── .busted                     # busted runner config
├── tests/
│   ├── wow_stub.lua            # the mock WoW client + addon loader (reusable)
│   ├── purposes_spec.lua       # *_spec.lua files are the tests
│   └── ...
└── .github/workflows/ci.yml    # CI: install toolchain, run luacheck + busted
```

`tests/wow_stub.lua` is the reusable heart of this. Everything else is small.

---

## 3. Toolchain

Lua 5.1 (WoW runs a 5.1-compatible VM), LuaRocks, busted, luacheck.

### Local (Debian/Ubuntu)

```sh
sudo apt-get update
sudo apt-get install -y lua5.1 liblua5.1-0-dev luarocks
sudo luarocks install busted
sudo luarocks install luacheck
```

### macOS

```sh
brew install lua@5.1 luarocks
luarocks install busted
luarocks install luacheck
```

Run from the addon root:

```sh
luacheck Core.lua Modules/ Locales/ tests/
busted
```

---

## 4. The mock WoW client (`tests/wow_stub.lua`)

This is the only non-trivial file, and it has three jobs:

1. **Shim the libraries the addon loads at file scope** — for Ace3 addons that's
   `LibStub` plus minimal `AceAddon`, `AceLocale`, `AceDB`. Event/timer/bucket
   mixins are no-ops.
2. **Install a fake WoW API** (`C_Container`, `C_Item`, `C_Bank`, `Enum`,
   `GetMoney`, `Unit*`, …) backed by a mutable `state` table so tests can arrange
   an inventory / character before calling in.
3. **Load the addon's `.lua` files the way the client does** — each file is a
   chunk called with the `ADDON_NAME, ns` vararg. Load them in **TOC order**, and
   skip UI-only files (they need real frames).

The key technique for loading an addon file:

```lua
-- WoW calls each addon file as: chunk("AddonName", privateNamespaceTable)
-- so the file's `local ADDON_NAME, ns = ...` works. We replicate that:
local ns = {}
for _, rel in ipairs(LOAD_ORDER) do
    local chunk = assert(loadfile(rel))   -- rel is relative to the addon root
    chunk("MyAddon", ns)                  -- same `ns` table shared across files
end
```

### 4a. Ace3 shims

Only what's needed to make files *load* and `OnInitialize` run. Events and
timers are no-ops — tests call planner functions directly rather than waiting
for events to fire.

```lua
local function addAceMixins(o)
    local noop = function() end
    for _, m in ipairs({
        "RegisterEvent", "UnregisterEvent", "UnregisterAllEvents",
        "RegisterMessage", "SendMessage", "RegisterChatCommand",
        "CancelTimer", "CancelAllTimers", "UnregisterBucket",
    }) do o[m] = noop end
    o.ScheduleTimer       = function() return {} end   -- return a dummy handle
    o.RegisterBucketEvent = function() return {} end
    o.Print  = function() end
    o.Printf = function() end
    return o
end

local function makeLibStub()
    local locales = {}
    local localeMT = { __index = function(_, k) return k end }  -- missing key -> the key

    local AceAddon = {}
    function AceAddon:NewAddon(name)
        local addon = addAceMixins({ name = name, modules = {} })
        function addon:NewModule(n) local m = addAceMixins({}); self.modules[n] = m; return m end
        function addon:GetModule(n) return self.modules[n] end
        function addon:EnableModule() end
        return addon
    end

    local AceLocale = {}
    function AceLocale:NewLocale(name) locales[name] = locales[name] or setmetatable({}, localeMT); return locales[name] end
    function AceLocale:GetLocale(name) return locales[name] or setmetatable({}, localeMT) end

    local AceDB = {}
    function AceDB:New(_, defaults)            -- deep-copies your `defaults` table
        local function dc(t) if type(t)~="table" then return t end local o={} for k,v in pairs(t) do o[k]=dc(v) end return o end
        local db = { profile = dc(defaults.profile or {}), global = dc(defaults.global or {}), char = dc(defaults.char or {}) }
        db.RegisterCallback = function() end
        return db
    end

    local registry = {
        ["AceAddon-3.0"]  = AceAddon,
        ["AceLocale-3.0"] = AceLocale,
        ["AceDB-3.0"]     = AceDB,
    }
    -- LibStub(name)       -> lib or error (unknown lib = a real bug to surface)
    -- LibStub(name, true) -> lib or nil   (the "silent" form addons use for optionals)
    return function(name, silent)
        local lib = registry[name]
        if not lib and not silent then error("wow_stub: unregistered library: "..tostring(name)) end
        return lib
    end
end
```

Two deliberate behaviors:

- **Missing locale keys return the key itself** (`localeMT`). So `L["FOO"]` is
  always a string and `:format(...)` never errors even if you don't stub every
  string. Real AceLocale does the same.
- **`LibStub(name, true)` returns `nil` for libraries you didn't register.** This
  is what lets you *not* shim optional libs (LibDataBroker, LibDBIcon, …): the
  addon's `LibStub("LibDataBroker-1.1", true)` guard takes the nil path. Don't
  register a lib you want to stay optional.

### 4b. Fake WoW API backed by `state`

Model the inventory as `state.bags[bag][slot] = { id, count, locked, quality }`
and implement the container/item/bank functions over it. Only stub what your
addon calls — keep it lean.

```lua
_G.C_Container = {
    GetContainerNumSlots = function(bag) return state.numSlots[bag] or 0 end,
    GetContainerItemID   = function(bag, slot) local e = state.bags[bag] and state.bags[bag][slot]; return e and e.id end,
    GetContainerItemInfo = function(bag, slot)
        local e = state.bags[bag] and state.bags[bag][slot]; if not e then return nil end
        return { stackCount = e.count, isLocked = e.locked or false, quality = e.quality or 1 }
    end,
    -- Mutating calls are call-recording no-ops; assert on state.calls if you care
    -- which moves were issued, but don't rely on them changing the model.
    PickupContainerItem = function(...) state.calls[#state.calls+1] = {"pickup", ...} end,
    SplitContainerItem  = function(...) state.calls[#state.calls+1] = {"split", ...} end,
}
```

Gotchas that bite WoW mocks specifically:

- **`C_Item.GetItemInfo` returns max-stack as the 8th value.** Addons do
  `select(8, C_Item.GetItemInfo(id))`. Return enough positional values:
  `return name, link, quality, level, minLevel, type, subType, maxStack`.
- **`C_Item.GetItemCount(id, includeBank, includeUses, includeReagentBank,
  includeAccountBank)`** — the flag order matters. If your addon distinguishes
  "on character" from "in the bank", honor the flags (or at least the ones it
  passes) so you actually test that distinction.
- **`time`, `date`, `wipe`, `strsplit` etc. are globals in WoW**, not in stock
  Lua. Alias them: `_G.time = os.time`. Add `wipe`, `strsplit`, … as your addon
  needs.
- **`Enum.*`** is a real nested table in-game. Stub the members you use, e.g.
  `Enum.BankType.Account`, `Enum.BagIndex.ReagentBag`.

### 4c. Reset between tests

Re-load the addon fresh in each test so module-level state (sessions, flags,
caches) never leaks across cases. Expose helpers for arranging state:

```lua
function M.reset()
    local state = { charGold = 0, bags = {}, numSlots = {}, items = {}, calls = {}, ... }
    _G.LibStub = makeLibStub()
    installGlobals(state)

    local ns = {}
    for _, rel in ipairs(LOAD_ORDER) do assert(loadfile(rel))("MyAddon", ns) end
    local Addon = ns.Addon
    Addon:OnInitialize()             -- builds db from defaults, seeds, etc.

    local env = { ns = ns, Addon = Addon, state = state }
    function env.setBags(map)   ... end
    function env.defineItem(id, name, max) state.items[id] = { name = name, max = max } end
    return env
end
```

> If your `OnInitialize` calls into UI setup, guard those calls in the addon
> (`if ns.SetupOptions then ... end`) so they no-op when the UI file isn't
> loaded — which is also just good module hygiene.

---

## 5. Writing specs (`tests/*_spec.lua`)

```lua
local H = require("tests.wow_stub")

describe("Balancer plan", function()
    local env
    before_each(function() env = H.reset() end)

    it("deposits the surplus above target", function()
        env.defineItem(1001, "Widget", 200)
        env.setBags({ [1001] = 30 })
        env.Addon.db.profile.purposes.Test = { items = { [1001] = { qty = 10, mode = "keepmin" } } }
        local plan = env.Addon:GetModule("ItemEngine"):BuildPlan()
        assert.equals(1, #plan)
        assert.equals("deposit", plan[1].dir)
        assert.equals(20, plan[1].amount)
    end)
end)
```

Tips:

- One behavior per `it`; arrange state explicitly in each so failures are
  self-explanatory.
- Test the **planner**, not the executor: assert on the returned plan / number /
  list. If you must check that a move was issued, assert against
  `state.calls`.
- Cover the boundaries: empty inputs, "nothing to do", caps/clamps, mode gates,
  and the "still short after using everything available" case.

---

## 6. `.busted`

```lua
return {
    default = {
        lpath = "./?.lua",       -- so `require("tests.wow_stub")` resolves
        ROOT = { "tests" },
        pattern = "_spec%.lua$",
    },
}
```

`wow_stub.lua` uses `loadfile("Core.lua")` etc. with paths **relative to the
addon root**, and busted runs from the root, so the relative loads just work.

---

## 7. `.luacheckrc`

luacheck doesn't know the WoW API, so declare it as read-only globals (only what
you use — a short list keeps it honest about typos), and silence the
conventions that are noise in an Ace addon.

```lua
std = "lua51"
max_line_length = false
codes = true

-- Ace methods are `function X:Method(self, ...)` by convention, so an unused
-- self/vararg is expected. ADDON_NAME from `local ADDON_NAME, ns = ...` is
-- often unused in a given file.
ignore = { "212/self", "212/...", "211/ADDON_NAME" }

exclude_files = { "libs/", ".luarocks/" }   -- don't lint vendored libraries

globals = { "MyAddon" }                      -- globals your addon intentionally sets

read_globals = {
    "time", "date", "wipe", "strsplit", "strtrim",
    "LibStub", "CreateFrame", "UIParent", "GameTooltip",
    "C_Bank", "C_Container", "C_Item", "C_Timer", "Enum", "ItemLocation",
    "GetMoney", "UnitName", "UnitGUID", "UnitFullName", "UnitClass", "GetRealmName",
    -- ...add the rest of what you actually call
}

-- Tests install the fake client by assigning to _G; allow that under tests/.
files["tests/"] = {
    std = "lua51+busted",
    globals = { "time", "print", "Enum", "C_Item", "C_Bank", "C_Container", "LibStub", "CreateFrame", "UnitGUID" },
}
```

Aim for a **clean (zero-warning) baseline** so CI failing means something. When
luacheck flags real dead code (unused locals/functions), delete it rather than
ignoring it — that's the linter earning its keep.

---

## 8. CI (`.github/workflows/ci.yml`)

```yaml
name: CI
on:
  push:
    branches: [ master, "claude/**" ]
  pull_request:
jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Lua 5.1 + LuaRocks
        run: |
          sudo apt-get update
          sudo apt-get install -y lua5.1 liblua5.1-0-dev luarocks
      - name: Install luacheck + busted
        run: |
          sudo luarocks install luacheck
          sudo luarocks install busted
      - name: Luacheck
        run: luacheck Core.lua Modules/ Locales/ tests/
      - name: Busted
        run: busted
```

(For faster CI you can swap the apt/luarocks steps for the
`leafo/gh-actions-lua` + `leafo/gh-actions-luarocks` actions, but the plain
install above has no extra dependencies and is easy to read.)

---

## 9. Keep test files out of the shipped addon

If you package with the BigWigs packager / `.pkgmeta`, exclude the dev files so
players don't download them:

```yaml
ignore:
  - tests
  - .busted
  - .luacheckrc
  - .github
  - TESTING.md
```

(If you ship by other means, make sure your zip step excludes them too.)

---

## 10. Porting to a new addon — checklist

1. Copy `tests/wow_stub.lua`, `.busted`, `.luacheckrc`, `.github/workflows/ci.yml`.
2. In `wow_stub.lua`:
   - Set `LOAD_ORDER` to your TOC's load order, **omitting UI-only files**
     (anything that needs real frames at load).
   - Change the `chunk("MyAddon", ns)` addon name to yours.
   - Register only the libraries your files load at scope; leave optional libs
     unregistered so `LibStub(name, true)` returns nil.
   - Add/trim the faked WoW API to exactly what your addon calls.
   - Update `reset()`'s helpers to arrange the state your code reads.
3. In `.luacheckrc`: set `globals` to your addon's intentional globals and trim
   `read_globals` to the APIs you use.
4. In CI + `.pkgmeta`: fix the addon name and the lint path list.
5. Write `tests/*_spec.lua` against your pure planners. Get to a green
   luacheck baseline, then keep both green in CI.

The recurring principle: **the more your logic lives in functions that return
data instead of poking the game, the more of your addon this can cover.**

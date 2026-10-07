-- Offline check for the AH plan (card 0001). Run from the addon folder:
--
--     lua tests/test_ahplan.lua
--
-- No game client. It loads the real Purposes.lua, AHPlan.lua and ItemEngine.lua against fake
-- bags, a fake warband, a fake guild bank and a fake Syndicator, and checks the decisions the
-- engine makes: what it deposits, what it withdraws, and through which bank. It cannot prove the
-- client accepts the calls; that is the in-game check on the card.

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end

-- ---------------------------------------------------------------------------
-- Fake world
-- ---------------------------------------------------------------------------

local SECRET = setmetatable({}, { __eq = function() error("attempt to compare secret value") end })
local world

local function reset()
    world = {
        bags = {},          -- [bag][slot] = { id, count, bound }
        warband = {},       -- [slot] = { id, count }
        guild = {},         -- [tab][slot] = { id, count }
        me = "Buyme-Aggra(Português)",
        syndicator = {},    -- [char] = { auctions = {...}, mail = {...} }
        calls = {},
    }
    for bag = 0, 5 do world.bags[bag] = {} end
    for tab = 1, 2 do world.guild[tab] = {} end
end

local function put(list, id, count, extra)
    local e = { id = id, count = count }
    for k, v in pairs(extra or {}) do e[k] = v end
    list[#list + 1] = e
end

local function log(name, ...) world.calls[#world.calls + 1] = { name = name, ... } end

-- Container API: bags 0-5, warband tab 12.
local WB_TAB = 12
local function container(bag)
    if bag == WB_TAB then return world.warband end
    return world.bags[bag]
end

_G.Enum = { BankType = { Character = 0, Guild = 1, Account = 2 }, BagIndex = { ReagentBag = 5 } }
_G.NUM_BAG_SLOTS = 4
_G.C_Container = {
    GetContainerNumSlots = function(bag) return 20 end,
    GetContainerItemID = function(bag, slot) local e = container(bag)[slot]; return e and e.id end,
    GetContainerItemInfo = function(bag, slot)
        local e = container(bag)[slot]
        return e and { stackCount = e.count, isLocked = false, quality = 3, itemID = e.id }
    end,
    UseContainerItem = function(...) log("UseContainerItem", ...) end,
    PickupContainerItem = function(...) log("PickupContainerItem", ...) end,
    SplitContainerItem = function(...) log("SplitContainerItem", ...) end,
    SortBank = function() end,
}
_G.C_Bank = {
    FetchPurchasedBankTabIDs = function() return { WB_TAB } end,
    -- As the live client behaves (2026-10-07): "no" for EVERY item with the
    -- guild bank type, so the engine must not ask it about the guild bank.
    IsItemAllowedInBankType = function(bankType, loc)
        if bankType == Enum.BankType.Guild then return false end
        return not loc.bound
    end,
}
_G.ItemLocation = {
    CreateFromBagAndSlot = function(_, bag, slot)
        local e = container(bag)[slot]
        return { bound = e and e.bound, IsValid = function() return e ~= nil end }
    end,
}
_G.C_Item = {
    GetItemInfo = function(id) return "item" .. id, nil, nil, nil, nil, nil, nil, 1 end,
    GetItemInfoInstant = function(link) return tonumber(link:match("item:(%d+)")) end,
    IsBound = function(loc) return loc.bound and true or false end,
}
_G.GetTime = function() return world.now or 0 end
_G.GetCursorInfo = function() return nil end
_G.ClearCursor = function() end

-- Guild bank API, as Blizzard_GuildBankUI calls it.
_G.GetNumGuildBankTabs = function() return #world.guild end
_G.GetGuildBankTabInfo = function(tab) return "Tab" .. tab, nil, true, true, 0, -1 end
_G.GetGuildBankItemLink = function(tab, slot)
    local e = world.guild[tab][slot]; return e and ("item:" .. e.id)
end
_G.GetGuildBankItemInfo = function(tab, slot)
    local e = world.guild[tab][slot]; return nil, e and e.count or 0, false
end
_G.QueryGuildBankTab = function() end
_G.GetCurrentGuildBankTab = function() return world.currentTab or 1 end
_G.SetCurrentGuildBankTab = function(tab) world.currentTab = tab; log("SetCurrentGuildBankTab", tab) end
_G.PickupGuildBankItem = function(...) log("PickupGuildBankItem", ...) end
_G.AutoStoreGuildBankItem = function(...) log("AutoStoreGuildBankItem", ...) end
_G.SplitGuildBankItem = function(...) log("SplitGuildBankItem", ...) end
_G.IsInGuild = function() return true end
_G.GetGuildInfo = function() return "Anything for Profit" end

_G.issecretvalue = function(v) return v == nil and false or rawequal(v, SECRET) end
_G.UnitName = function() return world.me:match("^(.-)%-") end
_G.GetNormalizedRealmName = function() return world.me:match("%-(.*)$") end
_G.C_Secrets = { ShouldUnitIdentityBeSecret = function() return false end }

_G.Syndicator = { API = {
    GetCurrentCharacter = function() return world.me end,
    GetByCharacterFullName = function(name) return world.syndicator[name] end,
} }

-- ---------------------------------------------------------------------------
-- Fake addon object (Ace pieces the three files use)
-- ---------------------------------------------------------------------------

local ns = {}
local DWM = { printed = {} }
ns.Addon = DWM
ns.L = setmetatable({}, { __index = function(_, k) return k end })
ns.BANKTYPE_ACCOUNT = 2
ns.Roster = { Current = function() return { purpose = "Default" } end }

function DWM:NewModule(name)
    local m = {}
    function m:RegisterBucketEvent() return {} end
    function m:UnregisterBucket() end
    function m:ScheduleTimer() return {} end
    function m:CancelTimer() end
    return m
end
function DWM:Debug() end
function DWM:Print(msg) self.printed[#self.printed + 1] = msg end
function DWM:LogTxn() end
function DWM:IsWarbandUsable() return true end
function DWM:GetOnCharacterCount(id)
    local n = 0
    for bag = 0, 5 do
        for _, e in pairs(world.bags[bag]) do if e.id == id then n = n + e.count end end
    end
    return n
end

local function loadModule(path)
    local chunk = assert(loadfile(path))
    chunk("DjinnisWarbandManager", ns)
end
loadModule("Modules/Purposes.lua")
loadModule("Modules/AHPlan.lua")
loadModule("Modules/ItemEngine.lua")

local function freshDB()
    DWM.db = {
        profile = {
            mode = "both", defaultPurpose = "Default", itemEnabled = true,
            itemFirstRunConfirmed = true, ahPlanEnabled = true, ahPlanConfirmed = true,
            purposes = { Default = { gold = 0, items = { [38682] = { qty = 500, mode = "exact" } } } },
        },
        global = { characters = {} },
    }
end

ns.AHPlanData = {
    transportGuild = "Anything for Profit",
    posters = {
        ["Buyme-Aggra(Português)"] = { [100] = 1 },
        ["What-Shadowsong"] = { [200] = 1 },
    },
}

local function planOf(kind)
    local plan = ns.ItemEngine:BuildPlan(kind)
    local byId = {}
    for _, e in ipairs(plan) do byId[e.itemID] = e end
    return byId, plan
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

-- 1. Buyme at the guild bank deposits what belongs elsewhere, keeps its own, ignores the rest.
reset(); freshDB()
put(world.bags[0], 100, 1); put(world.bags[0], 100, 1)   -- two copies, plan says keep one
put(world.bags[0], 200, 1)                                -- What's item
put(world.bags[0], 300, 1)                                -- not in the plan
put(world.warband, 38682, 20)                             -- vellum for the purpose target
do
    local p = planOf("guild")
    check("guild: surplus of own item deposits 1", p[100] and p[100].dir == "deposit" and p[100].amount == 1)
    check("guild: other poster's item deposits", p[200] and p[200].dir == "deposit" and p[200].amount == 1)
    check("guild: unplanned item untouched", p[300] == nil)
    check("guild: purpose item never at guild bank", p[38682] == nil)
end

-- 2. The same character at the warband bank deposits nothing from the plan.
do
    local p = planOf("warband")
    check("warband: plan deposits blocked", p[100] == nil and p[200] == nil)
    check("warband: purpose item still balanced", p[38682] ~= nil)
end

-- 3. A posted copy counts as held: one in bags + one posted, plan 1 -> deposit the bag copy.
reset(); freshDB()
put(world.bags[0], 100, 1)
world.syndicator[world.me] = { auctions = { { itemID = 100, itemCount = 1 } }, mail = {} }
do
    local p = planOf("guild")
    check("pending: posted copy makes the bag copy surplus", p[100] and p[100].dir == "deposit" and p[100].amount == 1)
end

-- 4. What withdraws its planned copy from the guild bank, unless one is already posted.
reset(); freshDB()
world.me = "What-Shadowsong"
put(world.guild[1], 200, 1)
do
    local p = planOf("guild")
    check("withdraw: What takes its copy", p[200] and p[200].dir == "withdraw" and p[200].amount == 1)
end
world.syndicator[world.me] = { auctions = {}, mail = { { itemID = 200, itemCount = 1 } } }
do
    local p = planOf("guild")
    check("withdraw: copy in the mail stops a second withdraw", p[200] == nil)
end

-- 5. What also withdraws from the warband (storage copies sit there).
reset(); freshDB()
world.me = "What-Shadowsong"
put(world.warband, 200, 1)
do
    local p = planOf("warband")
    check("warband: withdraw allowed for plan items", p[200] and p[200].dir == "withdraw")
end

-- 6. Plan switched off: no plan targets anywhere.
reset(); freshDB()
DWM.db.profile.ahPlanEnabled = false
put(world.bags[0], 200, 1)
do
    local p = planOf("guild")
    check("off: nothing from the plan", p[200] == nil)
end

-- 7. A character outside the plan gets nothing.
reset(); freshDB()
world.me = "Pouches-Aggra(Português)"
put(world.bags[0], 200, 1)
do
    local p = planOf("guild")
    check("not a poster: nothing", p[200] == nil)
end

-- 8. A secret identity is never compared: no key, no plan, no error.
reset(); freshDB()
local savedGet = Syndicator.API.GetCurrentCharacter
Syndicator.API.GetCurrentCharacter = function() return SECRET end
C_Secrets.ShouldUnitIdentityBeSecret = function() return true end
put(world.bags[0], 200, 1)
do
    local ok, p = pcall(planOf, "guild")
    check("secret: no error", ok, tostring(p))
    check("secret: nothing moves", ok and p[200] == nil)
end
Syndicator.API.GetCurrentCharacter = savedGet
C_Secrets.ShouldUnitIdentityBeSecret = function() return false end

-- 9. Soulbound copy is never deposited.
reset(); freshDB()
put(world.bags[0], 200, 1, { bound = true })
do
    local plan = ns.ItemEngine:BuildPlan("guild")
    local issued = ns.ItemEngine:_DoOneGuildMove(plan)
    check("bound: no move issued", issued == false)
end

-- 10. The guild move calls: a whole stack deposits like a right-click (the server picks the
-- slot), a partial stack by cursor onto an empty slot, a withdraw by AutoStore.
reset(); freshDB()
put(world.bags[2], 200, 1)
put(world.guild[1], 999, 1)            -- slot 1 of tab 1 taken
do
    local plan = ns.ItemEngine:BuildPlan("guild")
    ns.ItemEngine:_DoOneGuildMove(plan)
    local c1 = world.calls[1]
    check("deposit: whole stack uses the bag item", c1 and c1.name == "UseContainerItem" and c1[1] == 2 and c1[2] == 1)
    check("deposit: no cursor for a whole stack", #world.calls == 1)
end
reset(); freshDB()
put(world.bags[2], 100, 5)             -- plan keeps 1, so 4 of 5 deposit
for slot = 1, 98 do put(world.guild[1], 999, 1) end   -- tab 1 full
do
    local plan = ns.ItemEngine:BuildPlan("guild")
    ns.ItemEngine:_DoOneGuildMove(plan)
    local c1, c2, c3 = world.calls[1], world.calls[2], world.calls[3]
    check("split: switches to the tab with space", c1 and c1.name == "SetCurrentGuildBankTab" and c1[1] == 2)
    check("split: splits the right amount", c2 and c2.name == "SplitContainerItem" and c2[3] == 4)
    check("split: drops on the empty guild slot", c3 and c3.name == "PickupGuildBankItem" and c3[1] == 2 and c3[2] == 1)
end
reset(); freshDB()
world.me = "What-Shadowsong"
put(world.guild[2], 200, 1)
do
    local plan = ns.ItemEngine:BuildPlan("guild")
    ns.ItemEngine:_DoOneGuildMove(plan)
    local c1 = world.calls[1]
    check("withdraw: AutoStoreGuildBankItem on the right slot", c1 and c1.name == "AutoStoreGuildBankItem" and c1[1] == 2 and c1[2] == 1)
end

-- 11. Not confirmed: opening the guild bank moves nothing, the window's Move items button does.
reset(); freshDB()
DWM.db.profile.enabled = true
DWM.db.profile.ahPlanConfirmed = false
ns.guildBankOpen = true
put(world.bags[2], 200, 1)
do
    local ok, err = pcall(ns.ItemEngine.Run, ns.ItemEngine, "bank-open", "guild")
    check("unconfirmed: bank-open run has no error", ok, tostring(err))
    local moved = false
    for _, c in ipairs(world.calls) do if c.name == "UseContainerItem" then moved = true end end
    check("unconfirmed: bank-open run moves nothing", not moved)
    ns.ItemEngine.session = nil
    world.calls = {}
    ok, err = pcall(ns.ItemEngine.Run, ns.ItemEngine, "panel", "guild")
    check("panel: run has no error", ok, tostring(err))
    moved = false
    for _, c in ipairs(world.calls) do if c.name == "UseContainerItem" then moved = true end end
    check("panel: Move items button moves the item", moved)
    ns.ItemEngine.session = nil
end
ns.guildBankOpen = false

-- 12. The server drops a guild move: the engine re-sends it instead of giving up, and after a
-- confirmed move it waits GUILD_GAP before the next one.
reset(); freshDB()
DWM.db.profile.enabled = true
ns.guildBankOpen = true
world.now = 100
put(world.bags[1], 200, 1)                -- What's item: deposit
put(world.bags[2], 100, 1); put(world.bags[3], 100, 1)   -- Buyme keeps 1: deposit 1
do
    local E = ns.ItemEngine
    local function uses()
        local n = 0
        for _, c in ipairs(world.calls) do if c.name == "UseContainerItem" then n = n + 1 end end
        return n
    end
    E:Run("panel", "guild")
    check("pacing: first move sent", uses() == 1)
    for _ = 1, 4 do E:_Step() end          -- nothing changed: the server dropped it
    check("retry: dropped move is sent again", uses() == 2, "uses=" .. uses())
    check("retry: session still running", E.session ~= nil)
    local last = world.calls[#world.calls]  -- now the server accepts it
    world.bags[last[1]][last[2]] = nil
    E:_Step()
    check("gap: no move straight after a confirmed one", uses() == 2, "uses=" .. uses())
    world.now = world.now + 1
    E:_Step()
    check("gap: next move after the pause", uses() == 3, "uses=" .. uses())
    check("moves counted once each", E.session and E.session.moves == 2,
        "moves=" .. tostring(E.session and E.session.moves))
    E.session = nil
end
ns.guildBankOpen = false

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)

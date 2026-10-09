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
        return e and { stackCount = e.count, isLocked = e.locked or false, quality = 3, itemID = e.id,
                       hyperlink = e.link or ("item:" .. e.id) }
    end,
    UseContainerItem = function(...) log("UseContainerItem", ...) end,
    PickupContainerItem = function(...) world.cursor = nil; log("PickupContainerItem", ...) end,
    SplitContainerItem = function(...) world.cursor = "item"; log("SplitContainerItem", ...) end,
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
_G.GetCursorInfo = function() return world.cursor end
_G.ClearCursor = function() world.cursor = nil end

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
_G.GetGuildInfo = function() return world.guildName or "Anything for Profit" end

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
    function m:RegisterEvent() end
    function m:UnregisterBucket() end
    function m:ScheduleTimer() return {} end
    function m:CancelTimer() end
    return m
end
function DWM:Debug(m) if os.getenv("DBG") then print(m) end end
function DWM:Print(msg) self.printed[#self.printed + 1] = msg end
function DWM:LogTxn() end
function DWM:IsWarbandUsable() return true end
function DWM:GetOnCharacterCount(id)
    local n = 0
    for bag = 0, 5 do
        for _, e in pairs(world.bags[bag]) do if e.id == id then n = n + e.count end end
    end
    -- Like C_Item.GetItemCount: worn gear and equipped bags count too.
    return n + ((world.worn or {})[id] or 0)
end

local function loadModule(path)
    local chunk = assert(loadfile(path))
    chunk("DjinnisWarbandManager", ns)
end
loadModule("Modules/PetKeys.lua")
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

-- 11b. A worn copy (or an equipped bag) is not in the plan, and a bound bag copy is not either.
reset(); freshDB()
world.worn = { [200] = 1 }
put(world.bags[0], 300, 1)
do
    local p = planOf("guild")
    check("worn: worn copy is never a deposit", p[200] == nil)
end
put(world.bags[0], 200, 1, { bound = true })
do
    local p = planOf("guild")
    check("bound: bound bag copy is never a deposit", p[200] == nil)
end
world.worn = nil

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

-- 13. Feeder (card 0004): Jinn takes planned copies out of Transmog DOESNT Sell, puts them in
-- the warband bank, and never takes out more than the plan says, across visits.
ns.AHPlanData.generated = "2026-10-08 10:30"
ns.AHPlanData.feeders = { ["Jinn-Shadowsong"] = { guild = "Transmog DOESNT Sell", items = { [500] = 2 } } }
reset(); freshDB()
DWM.db.profile.enabled = true
world.me = "Jinn-Shadowsong"
world.guildName = "Transmog DOESNT Sell"
ns.guildBankOpen = true
world.now = 200
for _ = 1, 3 do put(world.guild[1], 500, 1) end
do
    local E = ns.ItemEngine
    check("feeder: role", ns.AHPlan:Role() == "feeder" and ns.AHPlan:GuildRole() == "feeder")
    local p = planOf("guild")
    check("feeder: withdraws the planned 2 of 3", p[500] and p[500].dir == "withdraw" and p[500].amount == 2,
        p[500] and (p[500].dir .. " " .. p[500].amount) or "nil")
    check("feeder: nothing to deposit at the guild bank", not (p[500] and p[500].dir == "deposit"))

    E:Run("panel", "guild")
    local c = world.calls[#world.calls]
    check("feeder: AutoStore from the guild bank", c and c.name == "AutoStoreGuildBankItem")
    world.guild[c[1]][c[2]] = nil           -- the server moves it into the bags
    put(world.bags[0], 500, 1)
    E:_Step()
    check("feeder: confirmed copy is counted as taken", ns.AHPlan:Pulled(500) == 1, "pulled=" .. ns.AHPlan:Pulled(500))
    E.session = nil

    -- At the warband bank the bag copy goes in, and the next guild visit wants only 1 more.
    ns.guildBankOpen = false
    p = planOf("warband")
    check("feeder: deposits its bag copy at the warband bank", p[500] and p[500].dir == "deposit" and p[500].amount == 1)
    world.bags[0] = {}
    ns.guildBankOpen = true
    p = planOf("guild")
    check("feeder: second visit takes only the rest", p[500] and p[500].dir == "withdraw" and p[500].amount == 1)

    -- Wrong guild: nothing at all.
    world.guildName = "Anything for Profit"
    check("feeder: other guild bank is not its job", ns.AHPlan:GuildRole() == nil and not ns.AHPlan:CanUseGuildBank())

    -- A new plan build starts the count again.
    ns.AHPlanData.generated = "2026-10-09 09:00"
    check("feeder: new plan resets the count", ns.AHPlan:Pulled(500) == 0)
end
-- 14. Warband batch (card 0005, TSM's method): every move is sent in one step, each from its own
-- source slot to its own empty warband slot, and the next batch waits until they have landed.
ns.AHPlanData.feeders["Jinn-Shadowsong"].items = { [500] = 3, [501] = 1 }
reset(); freshDB()
DWM.db.profile.enabled = true
world.me = "Jinn-Shadowsong"
world.guildName = "Transmog DOESNT Sell"
ns.bankState = "ready"
world.now = 300
put(world.bags[0], 500, 1); put(world.bags[1], 500, 1); put(world.bags[2], 500, 1); put(world.bags[3], 501, 1)
put(world.warband, 999, 1)              -- warband slot 1 taken
do
    local E = ns.ItemEngine
    E:Run("panel", "warband")
    -- Whole stacks: Blizzard's warband deposit, UseContainerItem with the warband bank type.
    local uses, toWarband, splits = 0, 0, 0
    for _, c in ipairs(world.calls) do
        if c.name == "UseContainerItem" then
            uses = uses + 1
            if c[4] == Enum.BankType.Account then toWarband = toWarband + 1 end
        end
        if c.name == "SplitContainerItem" then splits = splits + 1 end
    end
    check("batch: all 4 moves sent in one step", uses == 4 and splits == 0, uses .. "/" .. splits)
    check("batch: every deposit aimed at the warband bank", toWarband == 4)
    check("batch: total for the progress bar", E.session and E.session.total == 4)

    world.calls = {}
    E:_Step()                               -- nothing landed yet: wait, do not re-send
    check("batch: waits while moves are in flight", #world.calls == 0, "calls=" .. #world.calls)

    for bag = 0, 3 do world.bags[bag] = {} end   -- the server lands all four
    E:_Step()
    check("batch: done once every move landed", E.session == nil)
end
-- 15. Warband withdraw on a poster (What, 2026-10-08): a whole stack is a right-click, even when
-- the slot reads locked, and a batch never sends more take-outs than there are free bag slots.
reset(); freshDB()
DWM.db.profile.enabled = true
world.me = "What-Shadowsong"
world.guildName = "Anything for Profit"
ns.bankState = "ready"
ns.AHPlanData.feeders = nil

local savedWhat = ns.AHPlanData.posters["What-Shadowsong"]
ns.AHPlanData.posters["What-Shadowsong"] = { [100] = 1, [200] = 2 }   -- ids already in the cached plan set
for bag = 0, 4 do for slot = 1, 20 do put(world.bags[bag], 999, 1) end end   -- bags 0-4 full
world.bags[4][20] = nil                                                        -- but one free slot
put(world.warband, 100, 1, { locked = true })   -- whole stack, reads as locked: still a right-click
put(world.warband, 200, 5, { locked = true })   -- no free slot left for it
do
    local E = ns.ItemEngine
    E:Run("panel", "warband")
    local uses, splits = {}, 0
    for _, c in ipairs(world.calls) do
        if c.name == "UseContainerItem" then uses[#uses + 1] = c end
        if c.name == "SplitContainerItem" then splits = splits + 1 end
    end
    check("withdraw: whole stack is a right-click on the warband slot",
        #uses == 1 and uses[1][1] == WB_TAB and uses[1][2] == 1, "uses=" .. #uses)
    check("withdraw: no more take-outs than free bag slots", #uses + splits == 1, "splits=" .. splits)

    -- The server never lets the locked item go (stale lock, 2026-10-08): three stalled batches,
    -- then stop and say to log out. A refused move is not counted.
    DWM.printed = {}
    local session = E.session
    local resent = 0
    for _ = 1, 8 do
        if E.session then
            world.calls = {}
            world.now = (world.now or 0) + 5; E:_Step()
            for _, c in ipairs(world.calls) do
                if c.name == "UseContainerItem" and c[2] == 1 then resent = resent + 1 end
            end
        end
    end
    check("stale lock: a slot sent from is never sent again", resent == 0, "resent=" .. resent)
    local said = false
    for _, msg in ipairs(DWM.printed) do if msg == "MSG_ITEM_STALE_LOCK" then said = true end end
    check("stale lock: stops and says to log out", E.session == nil and said)
    check("stale lock: refused moves not counted", session.moves == 0, "moves=" .. tostring(session.moves))
end

-- 16. A sale item never waits in the warband bank (Rob, 2026-10-08): What takes every copy, its
-- own and the ones planned for others, then puts the others' copies into the transport guild bank.
reset(); freshDB()
DWM.db.profile.enabled = true
world.me = "What-Shadowsong"
world.guildName = "Anything for Profit"
ns.bankState = "ready"
ns.AHPlanData.posters["What-Shadowsong"] = { [200] = 1 }
put(world.warband, 100, 2)      -- Buyme's item: none planned for What
put(world.warband, 200, 3)      -- What keeps 1, carries 2
do
    local p = planOf("warband")
    check("carry: takes another poster's copies out of the warband",
        p[100] and p[100].dir == "withdraw" and p[100].amount == 2)
    check("carry: takes every copy of its own item", p[200] and p[200].dir == "withdraw" and p[200].amount == 3)
    ns.bankState = "closed"
    world.warband = {}
    put(world.bags[0], 100, 1); put(world.bags[0], 100, 1)
    put(world.bags[1], 200, 1); put(world.bags[1], 200, 1); put(world.bags[1], 200, 1)
    ns.guildBankOpen = true
    local g = planOf("guild")
    check("carry: guild bank gets the other poster's copies", g[100] and g[100].dir == "deposit" and g[100].amount == 2)
    check("carry: guild bank gets what is over its own quantity", g[200] and g[200].dir == "deposit" and g[200].amount == 2)
    ns.guildBankOpen = false
end
ns.AHPlanData.posters["What-Shadowsong"] = savedWhat

-- 17. PetScan (card 0006): a guild bank pet cage gives a plain item 82800 link. The species comes
-- from the tooltip data, else from the tooltip's name line; a cage neither read knows is kept as
-- "none" so the report can say how many are missing.
loadModule("Modules/PetScan.lua")
reset(); freshDB()
world.me = "Lostpets-Aggra(Português)"
world.guildName = "Bank of Requirement"
_G.time = os.time
_G.C_TooltipInfo = { GetGuildBankItem = function(tab, slot)
    local e = world.guild[tab][slot]
    if not e then return nil end
    return { battlePetSpeciesID = e.species, battlePetLevel = e.species and 25, battlePetBreedQuality = e.species and 3,
             lines = { { leftText = e.petName } } }
end }
_G.C_PetJournal = {
    FindPetIDByName = function(n) if n == "Mr. Bigglesworth" then return 1234, "guid" end end,
    GetPetInfoBySpeciesID = function(s) return "Pet " .. s, 1000 + s end,
}
world.guild[1][1] = { id = 82800, count = 1, species = 868 }
world.guild[1][2] = { id = 82800, count = 1, petName = "Mr. Bigglesworth" }
world.guild[1][3] = { id = 82800, count = 1, petName = "Unknown" }
world.guild[1][4] = { id = 1234, count = 5 }          -- not a pet: ignored
do
    ns.PetScan:ScanCurrentTab()
    local rec = DWM.db.global.petScan and DWM.db.global.petScan["Bank of Requirement"]
    local t = rec and rec.tabs[1] or {}
    check("pets: species from the tooltip data", t[1] and t[1].species == 868 and t[1].level == 25 and t[1].how == "tooltip")
    check("pets: species from the name line", t[2] and t[2].species == 1234 and t[2].how == "name")
    check("pets: unread cage kept as none", t[3] and t[3].species == nil and t[3].how == "none")
    check("pets: other items ignored", t[4] == nil)
end
world.guildName = nil
ns.bankState = "closed"
ns.AHPlanData.feeders = nil
world.guildName = nil
ns.guildBankOpen = false

-- 18. Pets (card 0006): a caged pet is keyed by -species. Lostpets, a feeder whose pets sit in its
-- bags, puts only the planned pets into the warband bank and counts them as they land. A poster
-- takes only its own pets, and pets never go through the guild bank.
local function cage(species) return { link = "|Hbattlepet:" .. species .. ":25:3:1:1:1:0|h[Pet]|h" } end
local savedPosters, savedFeeders = ns.AHPlanData.posters, ns.AHPlanData.feeders
ns.AHPlanData.posters = { ["What-Shadowsong"] = { [-868] = 1 } }
ns.AHPlanData.feeders = { ["Lostpets-Aggra(Português)"] = { bags = true, items = { [-868] = 1 } } }
reset(); freshDB()
DWM.db.profile.enabled = true
world.me = "Lostpets-Aggra(Português)"
world.guildName = "Bank of Requirement"
ns.bankState = "ready"
put(world.bags[0], 82800, 1, cage(868)); put(world.bags[0], 82800, 1, cage(868))
put(world.bags[0], 82800, 1, cage(999))                    -- not planned: stays
do
    local p = planOf("warband")
    check("pets: bag feeder puts in only the planned pet", p[-868] and p[-868].dir == "deposit"
        and p[-868].amount == 1 and p[-999] == nil)
    local E = ns.ItemEngine
    E:Run("panel", "warband")
    check("pets: one move sent", E.session and E.session.batch and #E.session.batch == 1)
    world.bags[0][1] = nil                                  -- it lands
    E:_Step()
    check("pets: landed pet counted for the feeder", ns.AHPlan:Pulled(-868) == 1)
    local p2 = planOf("warband")
    check("pets: second visit puts in nothing more", p2[-868] == nil)
end
reset(); freshDB()
DWM.db.profile.enabled = true
world.me = "What-Shadowsong"
world.guildName = "Anything for Profit"
ns.bankState = "ready"
put(world.warband, 82800, 1, cage(868)); put(world.warband, 82800, 1, cage(868))
do
    local p = planOf("warband")
    check("pets: poster takes only its own pets", p[-868] and p[-868].dir == "withdraw" and p[-868].amount == 1)
    ns.bankState = "closed"
    world.warband = {}
    put(world.bags[0], 82800, 1, cage(868)); put(world.bags[0], 82800, 1, cage(868))
    ns.guildBankOpen = true
    local g = planOf("guild")
    check("pets: never go through the guild bank", g[-868] == nil)
    ns.guildBankOpen = false
end

-- 19. In flight (Lostpets, 2026-10-08): copies still on their way read as locked. The run waits for
-- them, not one second but up to 10 with nothing landing, then says the game holds a lock.
reset(); freshDB()
DWM.db.profile.enabled = true
world.me = "Lostpets-Aggra(Português)"
world.guildName = "Bank of Requirement"
ns.bankState = "ready"
world.now = 1000
local inFlight = cage(868); inFlight.locked = true
put(world.bags[0], 82800, 1, inFlight)
do
    local E = ns.ItemEngine
    DWM.printed = {}
    E:Run("panel", "warband")
    check("in flight: nothing sent, the run waits", E.session ~= nil and #world.calls == 0)
    world.now = 1005; E:_Step()
    check("in flight: still waiting after 5 s", E.session ~= nil)
    world.now = 1011; E:_Step()
    local said = false
    for _, msg in ipairs(DWM.printed) do if msg == "MSG_ITEM_STALE_LOCK" then said = true end end
    check("in flight: after 10 s with nothing landed, says to log out", E.session == nil and said)
end

-- 20. One move per frame, as TSM does: the first move goes now, the rest on the next frames.
reset(); freshDB()
DWM.db.profile.enabled = true
world.me = "Lostpets-Aggra(Português)"
world.guildName = "Bank of Requirement"
ns.bankState = "ready"
ns.AHPlanData.feeders["Lostpets-Aggra(Português)"].items = { [-868] = 3 }
for _ = 1, 3 do put(world.bags[0], 82800, 1, cage(868)) end
local frames = {}
_G.C_Timer = { After = function(_, fn) frames[#frames + 1] = fn end }
do
    local E = ns.ItemEngine
    E:Run("panel", "warband")
    local function sent()
        local n = 0
        for _, c in ipairs(world.calls) do if c.name == "UseContainerItem" then n = n + 1 end end
        return n
    end
    check("one per frame: only the first move goes at once", sent() == 1, "sent=" .. sent())
    while #frames > 0 do table.remove(frames, 1)() end
    check("one per frame: the rest follow on later frames", sent() == 3, "sent=" .. sent())
    E:Abort("test")
end
_G.C_Timer = nil

ns.AHPlanData.posters, ns.AHPlanData.feeders = savedPosters, savedFeeders
world.guildName = nil

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)

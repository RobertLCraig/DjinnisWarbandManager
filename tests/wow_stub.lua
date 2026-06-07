--[[
    Headless WoW environment for standalone unit tests.

    There is no way to run the actual game client in CI, but DWM's decision
    logic is pure (it reads state and returns plans), so we can exercise it
    against a fake WoW API. This module installs that fake API as globals,
    loads the addon's Lua files the same way the client would (passing the
    `ADDON_NAME, ns` vararg), and exposes small helpers for arranging an
    inventory / warband / character before calling into the addon.

    UI-only files (BankButton, Options) are intentionally NOT loaded - they
    need real frames and aren't where the testable logic lives.
]]

local M = {}

-- Files loaded in TOC order. enUS first (populates the locale), Core (defines
-- the addon object), then the logic modules. No BankButton / Options.
local LOAD_ORDER = {
    "Locales/enUS.lua",
    "Core.lua",
    "Modules/Roster.lua",
    "Modules/Purposes.lua",
    "Modules/ProfessionDetect.lua",
    "Modules/Balancer.lua",
    "Modules/ItemEngine.lua",
    "Modules/ItemLedger.lua",
}

local PLAYER_BAGS  = { 0, 1, 2, 3, 4, 5 }   -- carried bags incl. reagent bag (5)
local WARBAND_TABS = { 12, 13 }             -- two purchased warband tabs

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return out
end

--============================================================================
-- Ace shims (no-op event/timer/bucket; functional AceDB / AceLocale)
--============================================================================

local function addAceMixins(o)
    local noop = function() end
    for _, name in ipairs({
        "RegisterEvent", "UnregisterEvent", "UnregisterAllEvents",
        "RegisterMessage", "SendMessage", "RegisterChatCommand",
        "CancelTimer", "CancelAllTimers", "UnregisterBucket",
    }) do o[name] = noop end
    o.ScheduleTimer          = function() return {} end
    o.ScheduleRepeatingTimer = function() return {} end
    o.RegisterBucketEvent    = function() return {} end
    o.RegisterBucketMessage  = function() return {} end
    o.Print  = function(_, ...) end
    o.Printf = function(_, ...) end
    return o
end

local function makeLibStub()
    local locales = {}
    local localeMT = { __index = function(_, k) return k end }  -- missing key -> key

    local AceAddon = {}
    function AceAddon:NewAddon(name, ...)
        local addon = addAceMixins({ name = name, modules = {} })
        function addon:NewModule(mname, ...)
            local m = addAceMixins({ moduleName = mname })
            self.modules[mname] = m
            return m
        end
        function addon:GetModule(mname) return self.modules[mname] end
        function addon:EnableModule() end
        return addon
    end

    local AceLocale = {}
    function AceLocale:NewLocale(name)
        locales[name] = locales[name] or setmetatable({}, localeMT)
        return locales[name]
    end
    function AceLocale:GetLocale(name)
        return locales[name] or setmetatable({}, localeMT)
    end

    local AceDB = {}
    function AceDB:New(_, defaults)
        defaults = defaults or {}
        local db = {
            profile = deepcopy(defaults.profile or {}),
            global  = deepcopy(defaults.global or {}),
            char    = deepcopy(defaults.char or {}),
        }
        db.RegisterCallback = function() end
        db.RegisterDefaultProfile = function() end
        return db
    end

    local registry = {
        ["AceAddon-3.0"]  = AceAddon,
        ["AceLocale-3.0"] = AceLocale,
        ["AceDB-3.0"]     = AceDB,
    }

    -- LibStub(name)        -> registered lib (or error if unknown)
    -- LibStub(name, true)  -> registered lib or nil (silent; used for optionals)
    return function(name, silent)
        local lib = registry[name]
        if not lib and not silent then
            error("wow_stub: unregistered library requested: " .. tostring(name))
        end
        return lib
    end
end

--============================================================================
-- Fake WoW client API backed by a mutable `state` table
--============================================================================

local function installGlobals(state)
    _G.time = os.time
    _G.date = os.date
    _G.print = function(...) end   -- silence addon chat output during tests

    _G.NUM_BAG_SLOTS = 4
    _G.Enum = {
        BankType = { Character = 0, Guild = 1, Account = 2 },
        PlayerInteractionType = { Banker = 8, CharacterBanker = 67, AccountBanker = 68 },
        BagIndex = { ReagentBag = 5 },
    }

    -- Character identity (stable; one test character).
    _G.UnitGUID     = function() return state.guid end
    _G.UnitName     = function() return state.name end
    _G.UnitFullName = function() return state.name, state.realm end
    _G.UnitClass    = function() return "Mage", "MAGE" end
    _G.GetRealmName = function() return state.realm end
    _G.GetMoney     = function() return state.charGold end
    _G.GetProfessions   = function() return nil end
    _G.GetProfessionInfo = function() return nil end

    _G.GetCursorInfo = function() return nil end
    _G.ClearCursor   = function() end
    _G.CreateFrame   = function() return addAceMixins({
        SetSize = function() end, SetPoint = function() end,
        ClearAllPoints = function() end, Hide = function() end, Show = function() end,
        CreateTexture = function() return {} end, SetScript = function() end,
    }) end

    local function bagsFor(bagset, id)
        local n = 0
        for _, bag in ipairs(bagset) do
            local c = state.bags[bag]
            if c then
                for _, e in pairs(c) do
                    if e and e.id == id then n = n + (e.count or 0) end
                end
            end
        end
        return n
    end

    _G.C_Item = {
        GetItemCount = function(id) return bagsFor(PLAYER_BAGS, id) end,
        RequestLoadItemDataByID = function() end,
        GetItemInfo = function(id)
            local info = state.items[id]
            if not info then return nil end
            -- name, link, quality, level, minLevel, type, subType, maxStack(8th)
            return info.name, "item:" .. id, 1, 0, 0, "", "", info.max or 1
        end,
    }

    _G.C_Bank = {
        CanUseBank             = function() return true end,
        FetchNumPurchasedBankTabs = function() return #WARBAND_TABS end,
        FetchPurchasedBankTabIDs  = function() return { unpack(WARBAND_TABS) } end,
        FetchDepositedMoney    = function() return state.warbandGold end,
        CanDepositMoney        = function() return true end,
        CanWithdrawMoney       = function() return true end,
        DepositMoney           = function(_, c) state.warbandGold = state.warbandGold + c; state.charGold = state.charGold - c end,
        WithdrawMoney          = function(_, c) state.warbandGold = state.warbandGold - c; state.charGold = state.charGold + c end,
        IsItemAllowedInBankType = function() return true end,
    }
    _G.ItemLocation = { CreateFromBagAndSlot = function() return {} end }

    _G.C_Container = {
        GetContainerNumSlots = function(bag) return state.numSlots[bag] or 0 end,
        GetContainerItemID   = function(bag, slot)
            local e = state.bags[bag] and state.bags[bag][slot]
            return e and e.id or nil
        end,
        GetContainerItemInfo = function(bag, slot)
            local e = state.bags[bag] and state.bags[bag][slot]
            if not e then return nil end
            return { stackCount = e.count, isLocked = e.locked or false,
                     quality = e.quality or 1, hyperlink = "item:" .. e.id }
        end,
        -- Executors are call-recording no-ops; logic tests call planners directly.
        UseContainerItem    = function(...) state.calls[#state.calls + 1] = { "use", ... } end,
        SplitContainerItem  = function(...) state.calls[#state.calls + 1] = { "split", ... } end,
        PickupContainerItem = function(...) state.calls[#state.calls + 1] = { "pickup", ... } end,
        SortBank            = function(...) state.calls[#state.calls + 1] = { "sortbank", ... } end,
    }
end

--============================================================================
-- Loader + public helpers
--============================================================================

-- Build a fresh fake client, load the addon clean, and return an `env` with
-- the addon handles and state-arranging helpers. Call this in each test so
-- module-level state (sessions, flags) never leaks between cases.
function M.reset()
    local state = {
        guid = "Player-1-AAAA", name = "Tester", realm = "TestRealm",
        charGold = 0, warbandGold = 0,
        bags = {}, numSlots = {}, items = {}, calls = {},
    }
    for _, bag in ipairs(PLAYER_BAGS)  do state.bags[bag] = {}; state.numSlots[bag] = 20 end
    for _, bag in ipairs(WARBAND_TABS) do state.bags[bag] = {}; state.numSlots[bag] = 10 end

    _G.LibStub = makeLibStub()
    installGlobals(state)

    local ns = {}
    for _, rel in ipairs(LOAD_ORDER) do
        local chunk = assert(loadfile(rel))
        chunk("DjinnisWarbandManager", ns)
    end

    local DWM = ns.Addon
    DWM:OnInitialize()   -- builds db (from defaults), seeds purposes, registers char

    local env = { ns = ns, DWM = DWM, state = state,
                  PLAYER_BAGS = PLAYER_BAGS, WARBAND_TABS = WARBAND_TABS }

    function env.defineItem(id, name, max)
        state.items[id] = { name = name or ("item:" .. id), max = max or 200 }
    end

    -- Place carried stacks: { [itemID] = totalCount } -> one stack each in bag 0.
    function env.setBags(map)
        state.bags[0] = {}
        local slot = 1
        for id, count in pairs(map) do
            state.bags[0][slot] = { id = id, count = count }
            slot = slot + 1
        end
    end

    -- Place warband stacks: list of { id, count } across the warband tabs in
    -- order, so tests can build fragmented stacks for consolidation cases.
    function env.setWarband(stacks)
        for _, bag in ipairs(WARBAND_TABS) do state.bags[bag] = {} end
        local ti, slot = 1, 1
        for _, s in ipairs(stacks) do
            local bag = WARBAND_TABS[ti]
            state.bags[bag][slot] = { id = s.id, count = s.count }
            slot = slot + 1
            if slot > state.numSlots[bag] then ti = ti + 1; slot = 1 end
        end
    end

    function env.setCharGold(c)    state.charGold = c end
    function env.setWarbandGold(c) state.warbandGold = c end

    -- Convenience: set the current character's purpose / gold override.
    function env.setPurpose(name)
        local rec = ns.Roster:Current(); rec.purpose = name
    end
    function env.setOverrideGold(goldUnits)
        local rec = ns.Roster:Current(); rec.goldOverride = goldUnits
    end

    return env
end

M.PLAYER_BAGS  = PLAYER_BAGS
M.WARBAND_TABS = WARBAND_TABS
return M

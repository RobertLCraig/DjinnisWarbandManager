--[[
    Djinni's Warband Manager - ItemLedger (Phase 5, DESIGN §14)

    Persistent, ADVISORY account snapshots so cross-character item supply/
    demand and warband shortages can be shown away from the bank. Snapshots
    never gate a move - the live scan at the bank stays authoritative
    (convergent model, §13.11). Missing snapshots render "unknown", never error.
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local ItemLedger = DWM:NewModule("ItemLedger", "AceEvent-3.0", "AceTimer-3.0", "AceBucket-3.0")
ns.ItemLedger = ItemLedger

--============================================================================
-- Snapshots (lazy db.global, like global.characters / global.log)
--============================================================================

function ItemLedger:SnapshotWarband()
    if not DWM:IsWarbandUsable() then return end
    local IE = ns.ItemEngine
    if not (IE and IE.ScanWarband) then return end
    local name = UnitName("player") or "?"
    DWM.db.global.warband = {
        items = IE:ScanWarband(),
        scannedAt = time(),
        scannedBy = name,
    }
end

-- Snapshot the CURRENT character's on-hand counts, but only for items managed
-- for it (keeps SV O(managed), not full-bag). Rebuilt fresh each time so the
-- set self-prunes as config changes. Skipped for managed=false.
function ItemLedger:SnapshotCurrentChar()
    -- NB: `a and b:c()` truncates to one value, so fetch rec/key explicitly.
    if not ns.Roster then return end
    ns.Roster:EnsureCurrent()   -- event order vs Core isn't guaranteed
    local rec, key = ns.Roster:Current()
    if not rec or not key then return end
    if rec.managed == false then
        rec.itemCounts, rec.itemCountsAt = nil, nil
        return
    end
    local targets = ns.Purposes and ns.Purposes:ResolveItemsFor(rec) or {}
    local counts = {}
    for id in pairs(targets) do
        counts[id] = DWM:GetOnCharacterCount(id)
    end
    rec.itemCounts   = counts
    rec.itemCountsAt = time()
end

-- Clear a character's cached counts (it stopped being managed, so it will
-- never snapshot again to self-prune). DESIGN §14.1 lifecycle.
function ItemLedger:WipeCharItems(key)
    local g = DWM.db and DWM.db.global and DWM.db.global.characters
    local rec = g and key and g[key]
    if rec then rec.itemCounts, rec.itemCountsAt = nil, nil end
end

--============================================================================
-- Relative-time display
--============================================================================

function ItemLedger:Age(t)
    if not t then return L["LEDGER_NEVER"] end
    local d = time() - t
    if d < 60 then return L["LEDGER_JUSTNOW"] end
    if d < 3600 then return math.floor(d / 60) .. L["LEDGER_MIN"] end
    if d < 86400 then return math.floor(d / 3600) .. L["LEDGER_HR"] end
    return math.floor(d / 86400) .. L["LEDGER_DAY"]
end

--============================================================================
-- Report (pure; shared by /dwm ledger, and later the tab/status/broker)
--============================================================================

-- Mode-agnostic on purpose: the report answers "is there enough, and who
-- needs/offers what" from the configured TARGETS, independent of the
-- deposit/withdraw toggle (which only gates live moves).
local function Intent(have, qty, mode)
    if have == nil then return "unknown", 0 end
    if mode == "depositall" then
        return (have > 0) and "deposit" or "ok", have
    elseif mode == "keepmin" then
        return (have > qty) and "deposit" or "ok", math.max(0, have - qty)
    else -- exact
        if have > qty then return "deposit", have - qty end
        if have < qty then return "withdraw", qty - have end
        return "ok", 0
    end
end

-- Returns sorted array; each entry:
-- { id, name, warband, demand, supply, shortBy, unknown, scannedAt, scannedBy,
--   chars = { { name, age, qty, mode, have(or nil), intent, amount }, ... } }
function ItemLedger:BuildReport()
    local g    = DWM.db.global
    local wbItems = (g.warband and g.warband.items) or {}
    local idset   = ns.Purposes and ns.Purposes:AllManagedItemIDs() or {}

    local ids = {}
    for id in pairs(idset) do ids[#ids + 1] = id end
    table.sort(ids)

    -- stable character order
    local recs = {}
    for key, rec in pairs(g.characters or {}) do
        if rec.managed ~= false then recs[#recs + 1] = { key = key, rec = rec } end
    end
    table.sort(recs, function(a, b)
        return (a.rec.name or a.key) < (b.rec.name or b.key)
    end)

    local report = {}
    for _, id in ipairs(ids) do
        local wb = wbItems[id] or 0
        local demand, surplusSupply, unknown = 0, 0, 0
        local chars = {}
        for _, e in ipairs(recs) do
            local rec  = e.rec
            local spec = ns.Purposes:ResolveItemsFor(rec)[id]
            if spec then
                local have = rec.itemCounts and rec.itemCounts[id]
                local intent, amount = Intent(have, spec.qty or 0, spec.mode or "keepmin")
                if intent == "unknown" then
                    unknown = unknown + 1
                elseif intent == "withdraw" then
                    demand = demand + amount
                elseif intent == "deposit" then
                    surplusSupply = surplusSupply + amount
                end
                chars[#chars + 1] = {
                    name = ns.Roster:Display(rec),
                    age = self:Age(rec.itemCountsAt),
                    qty = spec.qty or 0, mode = spec.mode or "keepmin",
                    have = have, intent = intent, amount = amount,
                }
            end
        end
        local supply  = wb + surplusSupply
        report[#report + 1] = {
            id = id, name = (C_Item.GetItemInfo(id)) or ("item:" .. id),
            warband = wb, demand = demand, supply = supply,
            shortBy = math.max(0, demand - supply),
            unknown = unknown,
            scannedAt = g.warband and g.warband.scannedAt,
            scannedBy = g.warband and g.warband.scannedBy,
            chars = chars,
        }
    end
    return report
end

--============================================================================
-- Chat print (primary testable entry point - /dwm ledger, §14.6d)
--============================================================================

function ItemLedger:Print()
    local report = self:BuildReport()
    if #report == 0 then DWM:Print(L["LEDGER_EMPTY"]); return end
    local g = DWM.db.global
    local haveWarband = g.warband ~= nil
    DWM:Print(L["LEDGER_HEADER"]:format(
        (g.warband and self:Age(g.warband.scannedAt)) or L["LEDGER_NEVER"],
        (g.warband and g.warband.scannedBy) or "?"))
    if not haveWarband then DWM:Print("|cFFFFCC00" .. L["LEDGER_HINT_BANK"] .. "|r") end
    for _, r in ipairs(report) do
        -- Honest status: never claim "OK" while data is missing/unknown.
        local tag
        if r.shortBy > 0 then
            tag = "|cFFFF5555" .. L["LEDGER_SHORT"]:format(r.shortBy) .. "|r"
        elseif (not haveWarband) or r.unknown > 0 then
            tag = "|cFFFFCC00" .. L["LEDGER_NODATA"] .. "|r"
        else
            tag = "|cFF55FF55" .. L["LEDGER_OK"] .. "|r"
        end
        DWM:Print(("%s |cFFAAAAAA(%d)|r  warband %d  %s%s"):format(
            r.name, r.id, r.warband, tag,
            r.unknown > 0 and ("  |cFFFFCC00" .. L["LEDGER_UNKNOWN"]:format(r.unknown) .. "|r") or ""))
        for _, c in ipairs(r.chars) do
            local h = (c.have ~= nil) and tostring(c.have) or "?"
            local intent = (c.intent == "ok") and L["LEDGER_KEEP"]
                or (c.intent == "unknown") and "?"
                or ((c.intent == "deposit" and L["ITEM_DEPOSIT"] or L["ITEM_WITHDRAW"])
                    .. " " .. c.amount)
            DWM:Print(("   %s: have %s / want %d [%s] -> %s |cFF666666(%s)|r"):format(
                c.name, h, c.qty, c.mode, intent, c.age))
        end
    end
end

--============================================================================
-- Triggers (own bucket; DESIGN §14.1 - NOT ItemEngine's session bucket)
--============================================================================

function ItemLedger:_OnBucket()
    self:SnapshotCurrentChar()
    self:SnapshotWarband()   -- no-ops unless the warband is reachable
end

function ItemLedger:OnEnable()
    self:RegisterEvent("PLAYER_LOGIN", "SnapshotCurrentChar")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "SnapshotCurrentChar")
    self:RegisterBucketEvent(
        { "BAG_UPDATE_DELAYED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED" },
        0.5, "_OnBucket")
end

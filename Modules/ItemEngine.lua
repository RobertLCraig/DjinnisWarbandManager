--[[
    Djinni's Warband Manager - ItemEngine (Phase 3)

    Balances stackable reagents toward per-character targets, the same model as
    gold. The hard part - moving items to/from the WARBAND bank - follows
    DESIGN.md:

      * Full-stack moves use C_Container.UseContainerItem(bag, slot, nil,
        Enum.BankType.Account, false) - bank-context-aware, NO cursor, so no
        cross-addon cursor contention (DESIGN appendix). Deposits from a bag
        slot; withdraws from a warband-tab slot.
      * Partial moves (target lands mid-stack) use SplitContainerItem +
        PickupContainerItem, guarded by an empty-cursor precondition (S13.4).
      * Sequencing is EVENT-DRIVEN, never fixed timers: pace on
        BAG_UPDATE_DELAYED + re-querying GetContainerItemInfo().isLocked
        (S13.3/S13.5), with a watchdog only as a failsafe.
      * Convergent (S13.11): every step re-derives the plan from live state, so
        a partial/failed/concurrent run self-corrects next visit. No locks.

    Safety: items are OFF by default, the first real run needs explicit
    confirmation, and `simulate` predicts capacity (S8 / S13.8).
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local ItemEngine = DWM:NewModule("ItemEngine", "AceEvent-3.0", "AceTimer-3.0", "AceBucket-3.0")
ns.ItemEngine = ItemEngine

local BANKTYPE_ACCOUNT = ns.BANKTYPE_ACCOUNT
local REAGENT_BAG = (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5

local ITER_CAP = 100        -- hard ceiling on physical moves per pass
local WATCHDOG = 2.0        -- failsafe only; real pacing is event-driven

--============================================================================
-- Inventory helpers
--============================================================================

local function PlayerBags()
    local t = { 0 }
    for i = 1, (NUM_BAG_SLOTS or 4) do t[#t + 1] = i end
    t[#t + 1] = REAGENT_BAG
    return t
end

local function WarbandTabs()
    if C_Bank and C_Bank.FetchPurchasedBankTabIDs then
        return C_Bank.FetchPurchasedBankTabIDs(BANKTYPE_ACCOUNT) or {}
    end
    return {}
end

local function SlotInfo(bag, slot)
    local info = C_Container and C_Container.GetContainerItemInfo
        and C_Container.GetContainerItemInfo(bag, slot)
    return info
end

local function MaxStack(itemID)
    local s = select(8, C_Item.GetItemInfo(itemID))
    if not s then
        if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
        return nil   -- unknown this pass; empty-slot deposits still work
    end
    return s
end

local function ItemName(itemID)
    local n = C_Item.GetItemInfo(itemID)
    return n or ("item:" .. tostring(itemID))   -- S13.12: never block on data
end

-- Eligible to deposit this physical slot into the warband bank?
local function DepositEligible(bag, slot, info)
    if not info or info.isLocked then return false end
    if info.quality == 0 then return false end                  -- poor (S13.10)
    if C_Bank and C_Bank.IsItemAllowedInBankType and ItemLocation then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and not C_Bank.IsItemAllowedInBankType(BANKTYPE_ACCOUNT, loc) then
            return false
        end
    end
    return true
end

-- Count itemID currently in the warband bank.
local function WarbandCount(itemID)
    local n = 0
    for _, bag in ipairs(WarbandTabs()) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == itemID then
                local info = SlotInfo(bag, slot)
                n = n + ((info and info.stackCount) or 0)
            end
        end
    end
    return n
end

-- First non-locked player stack of itemID: bag, slot, count.
local function FindPlayerStack(itemID)
    for _, bag in ipairs(PlayerBags()) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == itemID then
                local info = SlotInfo(bag, slot)
                if info and not info.isLocked and DepositEligible(bag, slot, info) then
                    return bag, slot, info.stackCount or 0
                end
            end
        end
    end
end

-- First non-locked warband stack of itemID: bag, slot, count.
local function FindWarbandStack(itemID)
    for _, bag in ipairs(WarbandTabs()) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == itemID then
                local info = SlotInfo(bag, slot)
                if info and not info.isLocked then
                    return bag, slot, info.stackCount or 0
                end
            end
        end
    end
end

-- A destination slot for a partial move: prefer a same-item stack with room,
-- else an empty slot. `bags` is the destination container list.
local function FindDestSlot(bags, itemID)
    local max = MaxStack(itemID)
    local emptyBag, emptySlot
    for _, bag in ipairs(bags) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id == itemID and max then
                local info = SlotInfo(bag, slot)
                if info and not info.isLocked and (info.stackCount or 0) < max then
                    return bag, slot
                end
            elseif id == nil and not emptyBag then
                emptyBag, emptySlot = bag, slot
            end
        end
    end
    return emptyBag, emptySlot
end

local function FreeSlots(bags)
    local n = 0
    for _, bag in ipairs(bags) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == nil then n = n + 1 end
        end
    end
    return n
end

local function CursorBusy()
    local kind = GetCursorInfo()
    return kind ~= nil
end

--============================================================================
-- Plan (pure) - used by simulate (S13.8) and by the executor
--============================================================================

-- Returns sorted list of { itemID, dir, amount, have, wb, qty, mode } and a
-- list of human-readable capacity warnings.
function ItemEngine:BuildPlan()
    local targets = ns.Purposes and ns.Purposes:ResolveItemsForCurrent() or {}
    local mode = DWM.db.profile.mode or "both"
    local canDep = (mode == "deposit" or mode == "both")
    local canWd  = (mode == "withdraw" or mode == "both")

    local ids = {}
    for id in pairs(targets) do ids[#ids + 1] = id end
    table.sort(ids)   -- deterministic order (S13.9)

    local plan, warns = {}, {}
    local wbFreeApprox  = FreeSlots(WarbandTabs())
    local bagFreeApprox = FreeSlots(PlayerBags())

    for _, id in ipairs(ids) do
        local spec = targets[id]
        local qty  = spec.qty or 0
        local md   = spec.mode or "keepmin"
        local have = DWM:GetOnCharacterCount(id)
        local wb   = WarbandCount(id)

        local dir, amount
        if md == "depositall" then
            if canDep and have > 0 then dir, amount = "deposit", have end
        elseif md == "keepmin" then
            if canDep and have > qty then dir, amount = "deposit", have - qty end
        else -- exact
            if have > qty and canDep then
                dir, amount = "deposit", have - qty
            elseif have < qty and canWd then
                dir, amount = "withdraw", math.min(qty - have, wb)
            end
        end

        if dir and amount and amount > 0 then
            plan[#plan + 1] = {
                itemID = id, dir = dir, amount = amount,
                have = have, wb = wb, qty = qty, mode = md,
            }
            if dir == "deposit" and wbFreeApprox <= 0 then
                warns[#warns + 1] = L["MSG_ITEM_NO_WB_SPACE"]:format(ItemName(id))
            elseif dir == "withdraw" then
                if wb <= 0 then
                    warns[#warns + 1] = L["MSG_ITEM_NONE_IN_WB"]:format(ItemName(id))
                elseif bagFreeApprox <= 0 then
                    warns[#warns + 1] = L["MSG_ITEM_NO_BAG_SPACE"]:format(ItemName(id))
                end
            end
        end
    end
    return plan, warns
end

-- Signature of live state for no-progress detection (S13.11 safety).
local function PlanSig(plan)
    local parts = {}
    for _, e in ipairs(plan) do
        parts[#parts + 1] = e.itemID .. ":" .. e.dir .. ":" .. e.amount
    end
    return table.concat(parts, "|")
end

--============================================================================
-- Executor - one physical move per step, paced by events, convergent
--============================================================================

function ItemEngine:_Finish(reason)
    if not self.session then return end
    local s = self.session
    self.session = nil
    if self._bucket then self:UnregisterBucket(self._bucket); self._bucket = nil end
    if self._wd then self:CancelTimer(self._wd); self._wd = nil end
    ClearCursor()
    if s.moves > 0 or s.verbose then
        DWM:Print(L["MSG_ITEM_DONE"]:format(s.moves))
    end
end

function ItemEngine:Abort(reason)
    if not self.session then return end
    if self._bucket then self:UnregisterBucket(self._bucket); self._bucket = nil end
    if self._wd then self:CancelTimer(self._wd); self._wd = nil end
    local v = self.session.verbose
    self.session = nil
    -- Return any half-moved split stack to where it came from.
    ClearCursor()
    if v then DWM:Print(L["MSG_ITEM_ABORTED"]) end
end

-- Issue exactly ONE physical move toward the first actionable plan entry.
-- Returns true if a move was issued (caller then waits for the bank to settle).
function ItemEngine:_DoOneMove(plan)
    for _, e in ipairs(plan) do
        if e.dir == "deposit" then
            local bag, slot, count = FindPlayerStack(e.itemID)
            if bag then
                if count <= e.amount then
                    C_Container.UseContainerItem(bag, slot, nil, BANKTYPE_ACCOUNT, false)
                    return true
                end
                -- partial: need a warband destination + empty cursor (S13.4)
                if CursorBusy() then return false end
                local dBag, dSlot = FindDestSlot(WarbandTabs(), e.itemID)
                if dBag then
                    ClearCursor()
                    C_Container.SplitContainerItem(bag, slot, e.amount)
                    C_Container.PickupContainerItem(dBag, dSlot)
                    return true
                end
            end
        else -- withdraw
            local bag, slot, count = FindWarbandStack(e.itemID)
            if bag then
                if count <= e.amount then
                    -- 2-arg form: the slot is already IN a warband tab, so this
                    -- moves it OUT to bags. (bankType is only for targeting the
                    -- warband on a *deposit* from a bag slot.)
                    C_Container.UseContainerItem(bag, slot)
                    return true
                end
                if CursorBusy() then return false end
                local dBag, dSlot = FindDestSlot(PlayerBags(), e.itemID)
                if dBag then
                    ClearCursor()
                    C_Container.SplitContainerItem(bag, slot, e.amount)
                    C_Container.PickupContainerItem(dBag, dSlot)
                    return true
                end
            end
        end
    end
    return false   -- nothing actionable (blocked: no space / locked / missing)
end

function ItemEngine:_Step()
    local s = self.session
    if not s then return end
    if not DWM:IsWarbandUsable() then return self:Abort("warband-gone") end

    s.iters = s.iters + 1
    if s.iters > ITER_CAP then return self:_Finish("cap") end

    local plan = self:BuildPlan()
    if #plan == 0 then return self:_Finish("done") end

    -- No-progress guard: identical actionable state two steps running.
    local sig = PlanSig(plan)
    if sig == s.lastSig then
        s.stall = (s.stall or 0) + 1
        if s.stall >= 2 then
            if s.verbose then DWM:Print(L["MSG_ITEM_BLOCKED"]) end
            return self:_Finish("blocked")
        end
    else
        s.stall = 0
    end
    s.lastSig = sig

    if CursorBusy() then
        -- Another addon (or us) holds the cursor; wait and retry briefly, then
        -- give up rather than fight over it (S13.4).
        s.cursorWaits = (s.cursorWaits or 0) + 1
        if s.cursorWaits > 3 then
            if s.verbose then DWM:Print(L["MSG_ITEM_ABORTED"]) end
            return self:_Finish("cursor")
        end
        self:_Arm()
        return
    end
    s.cursorWaits = 0

    local issued = self:_DoOneMove(plan)
    if not issued then
        if s.verbose then DWM:Print(L["MSG_ITEM_BLOCKED"]) end
        return self:_Finish("blocked")
    end
    s.moves = s.moves + 1
    self:_Arm()
end

-- Wait for the bank to settle, then step again. Event-driven (S13.3/13.5);
-- the timer is only a failsafe.
function ItemEngine:_Arm()
    if self._wd then self:CancelTimer(self._wd); self._wd = nil end
    self._wd = self:ScheduleTimer(function()
        self._wd = nil
        if self.session then self:_Step() end
    end, WATCHDOG)
end

function ItemEngine:_OnBankChanged()
    if not self.session then return end
    -- Coalesced BAG_UPDATE_DELAYED: the move landed; re-derive and continue.
    if self._wd then self:CancelTimer(self._wd); self._wd = nil end
    self:_Step()
end

--============================================================================
-- Entry point
--============================================================================

-- reason: "bank-open" (quiet when nothing to do) | "manual" (verbose)
function ItemEngine:Run(reason)
    if self.session then return end                       -- one pass at a time

    local manual   = (reason == "manual")
    local simulate = DWM.db.profile.simulate and true or false
    local verbose  = manual or simulate

    if not DWM.db.profile.itemEnabled then
        if verbose then DWM:Print(L["MSG_ITEMS_DISABLED"]) end
        return
    end
    if not manual then
        if not DWM.db.profile.enabled then return end
        if ns.sessionPaused then return end
    end
    if not DWM:IsWarbandUsable() then
        if verbose then DWM:Print(L["MSG_NO_WARBAND"]) end
        return
    end
    local rec = ns.Roster and ns.Roster:Current()
    if rec and rec.managed == false then
        if verbose then DWM:Print(L["MSG_UNMANAGED_SKIP"]) end
        return
    end

    local plan, warns = self:BuildPlan()

    -- First real run must be explicitly confirmed (DESIGN S8).
    local forcedSim = false
    if not DWM.db.profile.itemFirstRunConfirmed and not simulate then
        forcedSim = true
        DWM:Print(L["MSG_ITEM_FIRSTRUN"])
    end

    if simulate or forcedSim then
        if #plan == 0 then
            if verbose or forcedSim then DWM:Print(L["MSG_ITEM_SIM_NOTHING"]) end
        else
            DWM:Print(L["MSG_ITEM_SIM_HEADER"])
            for _, e in ipairs(plan) do
                local verb = (e.dir == "deposit") and L["ITEM_DEPOSIT"] or L["ITEM_WITHDRAW"]
                DWM:Print(("  %s %d x %s  (have %d -> %d)"):format(
                    verb, e.amount, ItemName(e.itemID), e.have,
                    e.dir == "deposit" and (e.have - e.amount) or (e.have + e.amount)))
            end
            for _, w in ipairs(warns) do DWM:Print("  |cFFFFCC00" .. w .. "|r") end
        end
        return
    end

    if #plan == 0 then return end

    self.session = { iters = 0, moves = 0, verbose = verbose, lastSig = nil, stall = 0 }
    if not self._bucket then
        self._bucket = self:RegisterBucketEvent(
            { "BAG_UPDATE_DELAYED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED" },
            0.3, "_OnBankChanged")
    end
    self:_Step()
end

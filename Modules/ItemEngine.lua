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

local ITER_CAP = 400        -- hard ceiling on physical moves per pass (an AH plan pass can be ~300)
local WATCHDOG = 2.0        -- failsafe only; real pacing is event-driven
local MAX_WAIT = 8          -- settle ticks with no count change -> give up
-- Guild bank pacing (card 0002). The server handles one guild bank move at a
-- time and silently drops a request that arrives while the last one is still
-- in flight (seen in game 2026-10-07: 2 to 4 moves per click, then stuck).
-- TSM sends the next guild move as soon as the last one shows, with no pause
-- (Core/Service/Banking/Core.lua MoveThread). A short one is kept here,
-- because the retry below already covers a dropped move.
local GUILD_GAP = 0.3       -- seconds between confirmed guild moves
local GUILD_RETRY_WAIT = 3  -- settle ticks before re-sending a dropped guild move
local GUILD_RETRIES = 3     -- re-sends of one move before giving up

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

local BANKTYPE_GUILD = (Enum and Enum.BankType and Enum.BankType.Guild) or 1

-- Eligible to deposit this physical slot into the given bank (default the
-- warband)? Soulbound and warbound copies fail here and are left alone.
local function DepositEligible(bag, slot, info, bankType)
    if not info or info.isLocked then return false end
    if info.quality == 0 then return false end                  -- poor (S13.10)
    -- Guild bank: C_Bank.IsItemAllowedInBankType answers "no" for every item
    -- with BankType.Guild (seen in game 2026-10-07: 16 planned deposits, 0
    -- moves), and Blizzard only ever calls it for the character and warband
    -- banks. A guild bank takes anything that is not bound, so test that.
    if bankType == BANKTYPE_GUILD then
        if C_Item and C_Item.IsBound and ItemLocation then
            local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
            if loc and loc:IsValid() and C_Item.IsBound(loc) then return false end
        end
        return true
    end
    if C_Bank and C_Bank.IsItemAllowedInBankType and ItemLocation then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and not C_Bank.IsItemAllowedInBankType(bankType or BANKTYPE_ACCOUNT, loc) then
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

-- One-pass scan of the whole warband bank -> { [itemID] = totalCount }.
-- Shared with ItemLedger (§14.1) so there is a single scan implementation.
-- Only valid while the warband bank is reachable; caller checks readiness.
function ItemEngine:ScanWarband()
    local out = {}
    for _, bag in ipairs(WarbandTabs()) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id then
                local info = SlotInfo(bag, slot)
                out[id] = (out[id] or 0) + ((info and info.stackCount) or 0)
            end
        end
    end
    return out
end

-- One pass over the bags for the AH plan: { [itemID] = copies in bags } and
-- { [itemID] = copies that may go into bankType }. GetItemCount also counts
-- worn gear and equipped bags, which no move can reach (seen in game
-- 2026-10-07: a worn robe and an equipped reagent bag planned as deposits).
local function BagCounts(bankType)
    local inBags, movable = {}, {}
    for _, bag in ipairs(PlayerBags()) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id then
                local info = SlotInfo(bag, slot)
                local n = (info and info.stackCount) or 0
                inBags[id] = (inBags[id] or 0) + n
                -- Locked is in flight, not unmovable: count it as movable.
                local probe = info and { quality = info.quality, isLocked = false }
                if probe and DepositEligible(bag, slot, probe, bankType) then
                    movable[id] = (movable[id] or 0) + n
                end
            end
        end
    end
    return inBags, movable
end

-- First non-locked player stack of itemID: bag, slot, count.
local function FindPlayerStack(itemID, bankType)
    for _, bag in ipairs(PlayerBags()) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == itemID then
                local info = SlotInfo(bag, slot)
                if info and not info.isLocked and DepositEligible(bag, slot, info, bankType) then
                    return bag, slot, info.stackCount or 0
                end
            end
        end
    end
end

-- For a SPLIT placement we must use a strictly EMPTY slot. Dropping a split
-- stack onto an existing partial stack overflows max-stack and strands items
-- on the cursor (observed: deposit "stuck"). Full-stack moves go through
-- UseContainerItem instead, where the server merges safely.
local function FindEmptyDestSlot(bags)
    for _, bag in ipairs(bags) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == nil then
                return bag, slot
            end
        end
    end
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

-- Any bag slot locked? The client locks a slot while a move from it is in
-- flight, and unlocks it when the server answers either way.
local function BagsLocked()
    for _, bag in ipairs(PlayerBags()) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = SlotInfo(bag, slot)
            if info and info.isLocked then return true end
        end
    end
    return false
end

--============================================================================
-- Guild bank helpers (card 0001: AH plan transport only)
--
-- Checked against wow-ui-source 12.1.0 Blizzard_GuildBankUI: contents are
-- only readable after QueryGuildBankTab(tab); a bag item deposits by being
-- picked up and dropped on a guild slot; AutoStoreGuildBankItem(tab, slot)
-- withdraws a whole stack into the bags; SplitGuildBankItem takes part of one.
-- GetGuildBankTabInfo's remainingWithdrawals is -1 for unlimited.
--============================================================================

local GB_SLOTS = 98   -- MAX_GUILDBANK_SLOTS_PER_TAB, local to Blizzard's file

-- { { tab, canDeposit, canWithdraw } } for every tab this character can see.
local function GuildTabs()
    local t = {}
    for tab = 1, (GetNumGuildBankTabs() or 0) do
        local _, _, isViewable, canDeposit, _, remaining = GetGuildBankTabInfo(tab)
        if isViewable then
            t[#t + 1] = { tab = tab, canDeposit = canDeposit,
                          canWithdraw = (remaining == nil) or remaining ~= 0 }
        end
    end
    return t
end

local function GuildItemID(tab, slot)
    local link = GetGuildBankItemLink(tab, slot)
    if not link then return nil end
    return (C_Item.GetItemInfoInstant(link))
end

-- One pass over the visible guild tabs -> { [itemID] = totalCount }.
local function ScanGuild()
    local out = {}
    for _, t in ipairs(GuildTabs()) do
        for slot = 1, GB_SLOTS do
            local id = GuildItemID(t.tab, slot)
            if id then
                local _, count = GetGuildBankItemInfo(t.tab, slot)
                out[id] = (out[id] or 0) + (count or 0)
            end
        end
    end
    return out
end

-- First unlocked guild stack of itemID on a tab we may withdraw from.
local function FindGuildStack(itemID)
    for _, t in ipairs(GuildTabs()) do
        if t.canWithdraw then
            for slot = 1, GB_SLOTS do
                if GuildItemID(t.tab, slot) == itemID then
                    local _, count, locked = GetGuildBankItemInfo(t.tab, slot)
                    if not locked then return t.tab, slot, count or 0 end
                end
            end
        end
    end
end

-- First empty guild slot on a tab we may deposit into.
local function FindEmptyGuildSlot()
    for _, t in ipairs(GuildTabs()) do
        if t.canDeposit then
            for slot = 1, GB_SLOTS do
                if not GetGuildBankItemLink(t.tab, slot) then return t.tab, slot end
            end
        end
    end
end

local function GuildFreeSlots()
    local n = 0
    for _, t in ipairs(GuildTabs()) do
        if t.canDeposit then
            for slot = 1, GB_SLOTS do
                if not GetGuildBankItemLink(t.tab, slot) then n = n + 1 end
            end
        end
    end
    return n
end

--============================================================================
-- Plan (pure) - used by simulate (S13.8) and by the executor
--============================================================================

-- kind: "warband" (default) | "guild". Returns sorted list of
-- { itemID, dir, amount, have, wb, qty, mode } and a list of capacity
-- warnings. `wb` is the count in whichever bank `kind` names.
--
-- The AH plan (spec.ah) deposits into the GUILD bank only, so the warband
-- stays Rob's storage; it withdraws from either. Purpose targets never touch
-- the guild bank.
function ItemEngine:BuildPlan(kind)
    kind = kind or "warband"
    local targets = ns.Purposes and ns.Purposes:ResolveItemsForCurrent() or {}
    local mode = DWM.db.profile.mode or "both"
    local canDep = (mode == "deposit" or mode == "both")
    local canWd  = (mode == "withdraw" or mode == "both")

    local ids = {}
    for id, spec in pairs(targets) do
        if kind == "warband" or spec.ah then ids[#ids + 1] = id end
    end
    table.sort(ids)   -- deterministic order (S13.9)

    DWM:Debug(("BuildPlan[%s]: %d target(s), mode=%s canDep=%s canWd=%s")
        :format(kind, #ids, tostring(mode), tostring(canDep), tostring(canWd)))

    local plan, warns = {}, {}
    local bankFreeApprox = (kind == "guild") and GuildFreeSlots() or FreeSlots(WarbandTabs())
    local bagFreeApprox  = FreeSlots(PlayerBags())
    -- One bank scan for the whole plan. The AH plan can carry hundreds of
    -- targets, and a per-item count would rescan every tab for each one.
    local bankCounts = (kind == "guild") and ScanGuild() or self:ScanWarband()
    local bagHave, bagMovable = BagCounts((kind == "guild") and BANKTYPE_GUILD or BANKTYPE_ACCOUNT)

    for _, id in ipairs(ids) do
        local spec = targets[id]
        local qty  = spec.qty or 0
        local md   = spec.mode or "keepmin"
        -- AH plan items: only bag copies count. The plan was built from bags,
        -- banks and auctions, never from worn gear, and only a bag copy that
        -- is not bound can be deposited.
        local have = spec.ah and (bagHave[id] or 0) or DWM:GetOnCharacterCount(id)
        local canMove = spec.ah and (bagMovable[id] or 0) or have
        local wb   = bankCounts[id] or 0
        -- Copies posted or in the mail (AH plan only) count as held, but only
        -- bag copies can actually be deposited.
        local held = have + (spec.pending or 0)
        local dep  = canDep and not (spec.ah and kind == "warband")

        local dir, amount
        if md == "feed" then
            -- AH plan feeder (card 0004): take planned copies out of its
            -- storage guild bank, put every bag copy into the warband bank.
            if kind == "guild" then
                if canWd and (spec.remaining or 0) > 0 then
                    dir, amount = "withdraw", math.min(spec.remaining, wb)
                end
            elseif canDep and canMove > 0 then
                dir, amount = "deposit", canMove
            end
        elseif md == "depositall" then
            if dep and canMove > 0 then dir, amount = "deposit", canMove end
        elseif md == "keepmin" then
            if dep and held > qty then dir, amount = "deposit", math.min(canMove, held - qty) end
        else -- exact
            if held > qty then
                if dep then dir, amount = "deposit", math.min(canMove, held - qty) end
            elseif held < qty and canWd then
                dir, amount = "withdraw", math.min(qty - held, wb)
            end
        end

        if dir and amount and amount > 0 then
            plan[#plan + 1] = {
                itemID = id, dir = dir, amount = amount,
                have = have, wb = wb, qty = qty, mode = md,
                ah = spec.ah, feed = spec.feed,
            }
            if dir == "deposit" and bankFreeApprox <= 0 then
                warns[#warns + 1] = L[kind == "guild" and "MSG_ITEM_NO_GB_SPACE" or "MSG_ITEM_NO_WB_SPACE"]
                    :format(ItemName(id))
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

-- §14.5: quantified residual shortfalls from CURRENT live state. Only `exact`
-- can be "short" (keepmin/depositall never withdraw). short = how many still
-- missing even if we took every one the warband has. Returns sorted list:
-- { id, name, short, have, qty, wb }.
function ItemEngine:ResidualShortfalls()
    local targets = ns.Purposes and ns.Purposes:ResolveItemsForCurrent() or {}
    local ids = {}
    for id in pairs(targets) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local spec = targets[id]
        -- AH plan targets are not reported: a planned copy that sold or is
        -- still on another character is expected, not a shortage.
        if (spec.mode or "keepmin") == "exact" and not spec.ah then
            local qty  = spec.qty or 0
            local have = DWM:GetOnCharacterCount(id)
            if have < qty then
                local wb = WarbandCount(id)
                local short = qty - have - wb
                if short > 0 then
                    out[#out + 1] = {
                        id = id, name = ItemName(id),
                        short = short, have = have, qty = qty, wb = wb,
                    }
                end
            end
        end
    end
    return out
end

-- Print residual shortfalls. Always shown (even on silent bank-open runs):
-- "not enough in the warband" is exactly what the user asked to be told.
function ItemEngine:_ReportShortfalls()
    local short = self:ResidualShortfalls()
    if #short == 0 then return end
    DWM:Print(L["MSG_ITEM_SHORT_HEADER"])
    for _, s in ipairs(short) do
        DWM:Print("  |cFFFF5555" .. L["MSG_ITEM_STILL_SHORT"]:format(
            s.short, s.name, s.wb) .. "|r")
    end
end

-- Settle signature: ON-CHARACTER counts ONLY. The next decision (deposit vs
-- withdraw vs done) keys on `have`, and GetItemCount lags server-confirmed
-- warband transfers (DESIGN S13.3). Earlier this also hashed the warband
-- count, which updates FIRST - so the gate saw "settled" while `have` was
-- still stale and issued a redundant move (observed: withdraw 735 then
-- deposit 235 back). Waiting only on the on-character count serializes moves
-- correctly. Convergence still guarantees the final state regardless.
local function CountSig()
    local targets = ns.Purposes and ns.Purposes:ResolveItemsForCurrent() or {}
    local ids = {}
    for id in pairs(targets) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        parts[#parts + 1] = id .. "=" .. DWM:GetOnCharacterCount(id)
    end
    return table.concat(parts, "|")
end

--============================================================================
-- Executor - one physical move per step, paced by events, convergent
--============================================================================

-- True only if some MANAGED item is fragmented in the warband: more stacks
-- than strictly needed (#stacks > ceil(total / maxStack)). A single stack, or
-- already-optimal full stacks, returns false - so a sort that wouldn't
-- actually consolidate anything is skipped (the reported over-eager sort).
function ItemEngine:_WarbandNeedsTidy()
    local targets = ns.Purposes and ns.Purposes:ResolveItemsForCurrent() or {}
    -- One pass over the warband, counting stacks per managed item.
    local stacksOf, totalOf = {}, {}
    for _, bag in ipairs(WarbandTabs()) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id and targets[id] then
                local info = SlotInfo(bag, slot)
                local c = (info and info.stackCount) or 0
                if c > 0 then
                    stacksOf[id] = (stacksOf[id] or 0) + 1
                    totalOf[id] = (totalOf[id] or 0) + c
                end
            end
        end
    end
    for id in pairs(targets) do
        local stacks, total = stacksOf[id] or 0, totalOf[id] or 0
        if stacks >= 2 then
            local max = MaxStack(id)
            if max and max > 0 and stacks > math.ceil(total / max) then
                return true
            end
        end
    end
    return false
end

function ItemEngine:_Finish(reason)
    if not self.session then return end
    local s = self.session
    DWM:Debug(("_Finish reason=%s moves=%d iters=%d"):format(
        tostring(reason), s.moves or 0, s.iters or 0))
    self.session = nil
    if self._bucket then self:UnregisterBucket(self._bucket); self._bucket = nil end
    if self._wd then self:CancelTimer(self._wd); self._wd = nil end
    ClearCursor()
    -- Optional explicit full sort, ONLY when our moves actually left a managed
    -- item fragmented (>1 stack that could be combined). Note: this is the
    -- addon's C_Container.SortBank; the bank's own per-deposit category reflow
    -- is Blizzard and not controlled here.
    if s.moves > 0 and s.kind ~= "guild" and C_Container and C_Container.SortBank then
        if not DWM.db.profile.sortAfterItems then
            DWM:Debug("sort: disabled (sortAfterItems=false) - not sorting")
        elseif self:_WarbandNeedsTidy() then
            DWM:Debug("sort: fragmentation found -> C_Container.SortBank")
            pcall(C_Container.SortBank, BANKTYPE_ACCOUNT)
        else
            DWM:Debug("sort: enabled but nothing fragmented -> skip")
        end
    end
    if s.moves > 0 or s.verbose then
        DWM:Print(L["MSG_ITEM_DONE"]:format(s.moves))
    end
    -- §14.5: after the pass, tell the user about anything still short because
    -- the warband ran out - always, even on a silent bank-open run. Not at the
    -- guild bank: the warband cannot be read there, so every count looks short.
    if s.kind ~= "guild" then self:_ReportShortfalls() end
    if ns.AHPlanPanel then ns.AHPlanPanel:OnEngineFinished(reason, s.done or 0, s.total or 0) end
end

function ItemEngine:Abort(reason)
    if not self.session then return end
    if self._bucket then self:UnregisterBucket(self._bucket); self._bucket = nil end
    if self._wd then self:CancelTimer(self._wd); self._wd = nil end
    local s = self.session
    self.session = nil
    -- Return any half-moved split stack to where it came from.
    ClearCursor()
    if s.verbose then DWM:Print(L["MSG_ITEM_ABORTED"]) end
    if ns.AHPlanPanel then ns.AHPlanPanel:OnEngineFinished(reason, s.done or 0, s.total or 0) end
end

-- Log a guild move and remember it for the AH plan window's progress line.
function ItemEngine:_NoteGuildMove(dir, n, itemID)
    DWM:LogTxn(L["MSG_LOG_ITEM_GUILD"]:format(dir == "deposit" and L["ITEM_DEPOSIT"] or L["ITEM_WITHDRAW"],
        n, ItemName(itemID)))
    if self.session then
        self.session.lastAmount = n
        self.session.current = ItemEngine.MoveText(dir, n, itemID)
    end
end

-- Guild bank version of _DoOneMove (card 0001). A whole stack deposits the way
-- a right-click does (UseContainerItem with the guild bank open, as in
-- ContainerFrame.lua): the SERVER picks the slot in the current tab, so a tab
-- whose contents have not loaded yet can never cause a swap. Only a partial
-- stack goes through the cursor onto a slot we believe is empty. Each move
-- re-queries the tab it touched, because guild contents refresh on request.
function ItemEngine:_DoOneGuildMove(plan)
    for _, e in ipairs(plan) do
        if e.dir == "deposit" then
            local bag, slot, count = FindPlayerStack(e.itemID, BANKTYPE_GUILD)
            local tab, gSlot = FindEmptyGuildSlot()
            DWM:Debug(("_DoOneGuildMove deposit item:%d amount=%d bag=%s slot=%s -> tab=%s slot=%s")
                :format(e.itemID, e.amount, tostring(bag), tostring(slot), tostring(tab), tostring(gSlot)))
            if bag and tab then
                if GetCurrentGuildBankTab() ~= tab then SetCurrentGuildBankTab(tab) end
                if count <= e.amount then
                    C_Container.UseContainerItem(bag, slot)
                    QueryGuildBankTab(tab)
                    self:_NoteGuildMove("deposit", count, e.itemID)
                    return true
                end
                if CursorBusy() then DWM:Debug("_DoOneGuildMove: cursor busy, defer"); return false end
                ClearCursor()
                C_Container.SplitContainerItem(bag, slot, e.amount)
                PickupGuildBankItem(tab, gSlot)
                QueryGuildBankTab(tab)
                self:_NoteGuildMove("deposit", e.amount, e.itemID)
                return true
            end
        else -- withdraw
            local tab, gSlot, count = FindGuildStack(e.itemID)
            -- A full bag cannot take it: the server would refuse every try.
            -- Backpack and bags 1-4 only: the reagent bag takes reagents only.
            local dBag, dSlot = FindEmptyDestSlot({ 0, 1, 2, 3, 4 })
            DWM:Debug(("_DoOneGuildMove withdraw item:%d amount=%d -> tab=%s slot=%s count=%s bagSlot=%s")
                :format(e.itemID, e.amount, tostring(tab), tostring(gSlot), tostring(count), tostring(dSlot)))
            if tab and dBag then
                local moved = math.min(count, e.amount)
                -- A feeder's copy counts as taken out once the bags show it.
                if self.session then self.session.lastFeed = e.feed and { e.itemID, moved } or nil end
                if count <= e.amount then
                    AutoStoreGuildBankItem(tab, gSlot)
                    QueryGuildBankTab(tab)
                    self:_NoteGuildMove("withdraw", count, e.itemID)
                    return true
                end
                if CursorBusy() then DWM:Debug("_DoOneGuildMove: cursor busy, defer"); return false end
                ClearCursor()
                SplitGuildBankItem(tab, gSlot, e.amount)
                C_Container.PickupContainerItem(dBag, dSlot)
                QueryGuildBankTab(tab)
                self:_NoteGuildMove("withdraw", e.amount, e.itemID)
                return true
            end
        end
    end
    DWM:Debug("_DoOneGuildMove: nothing actionable (no stack / no slot / no withdrawals left)")
    return false
end

-- BuildPlan, minus the AH plan's entries when skipAH. A bank visit leaves AH
-- plan items alone until "Move items by themselves" is ticked; the AH plan
-- window lists them and its Move items button moves them.
function ItemEngine:_Plan(kind, skipAH)
    local plan, warns = self:BuildPlan(kind)
    if not skipAH then return plan, warns end
    local out = {}
    for _, e in ipairs(plan) do if not e.ah then out[#out + 1] = e end end
    return out, warns
end

-- Issue exactly ONE physical move toward the first actionable plan entry.
-- Guild bank only: the warband bank and the bank move in batches (_StepBatch).
-- Returns true if a move was issued (caller then waits for the bank to settle).
function ItemEngine:_DoOneMove(plan)
    return self:_DoOneGuildMove(plan)
end

-- Text for the AH plan window's progress line.
local function MoveText(dir, n, itemID)
    return ("%s %d x %s"):format(dir == "deposit" and L["AHPANEL_GIVE"] or L["AHPANEL_TAKE"], n, ItemName(itemID))
end
ItemEngine.MoveText = MoveText

--============================================================================
-- Batch moves for the warband bank and the bank (card 0005)
--
-- The way TSM does it (TradeSkillMaster Core/Service/Banking/Core.lua
-- MoveThread and MoveContext.lua): plan every move first, give each one its
-- own source slot and its own EMPTY target slot, send them all at once, then
-- wait until every source slot shows the move. Nothing collides, because no
-- two moves share a slot. One move per server round trip was the old pace.
--============================================================================

local BATCH_MAX = 60        -- moves sent in one go
local BATCH_TIMEOUT = 4     -- seconds to wait for a batch before re-planning
local BATCH_STALLS = 3      -- batches in a row with nothing landed -> give up

-- Empty slots in the given containers, in order: { {bag, slot}, ... }.
local function EmptySlots(bags)
    local out = {}
    for _, bag in ipairs(bags) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == nil then out[#out + 1] = { bag, slot } end
        end
    end
    return out
end

-- Bags an ordinary item may land in: the backpack and bags 1-4, never the
-- reagent bag, which takes crafting reagents only.
local function NormalBags()
    local t = {}
    for bag = 0, NUM_BAG_SLOTS or 4 do t[#t + 1] = bag end
    return t
end

-- Turn plan entries into slot-to-slot moves: { bag, slot, to, n, endQty, itemID, dir }.
function ItemEngine:_BuildBatch(plan)
    local wbEmpty, bagEmpty = EmptySlots(WarbandTabs()), EmptySlots(NormalBags())
    local moves = {}
    for _, e in ipairs(plan) do
        local deposit = (e.dir == "deposit")
        local left = e.amount
        for _, bag in ipairs(deposit and PlayerBags() or WarbandTabs()) do
            for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
                if left <= 0 or #moves >= BATCH_MAX then break end
                if C_Container.GetContainerItemID(bag, slot) == e.itemID then
                    local info = SlotInfo(bag, slot)
                    local ok = info and not info.isLocked
                    if ok and deposit then ok = DepositEligible(bag, slot, info, BANKTYPE_ACCOUNT) end
                    local to = ok and table.remove(deposit and wbEmpty or bagEmpty, 1)
                    if to then
                        local count = info.stackCount or 0
                        local n = math.min(count, left)
                        moves[#moves + 1] = { bag = bag, slot = slot, to = to, n = n,
                                              endQty = count - n, itemID = e.itemID, dir = e.dir }
                        left = left - n
                    end
                end
            end
        end
    end
    return moves
end

-- Has every move in the batch left its source slot? Returns done, landed copies.
local function BatchState(batch)
    local done, landed = true, 0
    for _, m in ipairs(batch) do
        local id = C_Container.GetContainerItemID(m.bag, m.slot)
        local info = id == m.itemID and SlotInfo(m.bag, m.slot) or nil
        local q = info and info.stackCount or 0
        if (info and info.isLocked) or q > m.endQty then
            done = false
        else
            landed = landed + m.n
        end
    end
    return done, landed
end

function ItemEngine:_StepBatch()
    local s = self.session
    if s.batch then
        local done, landed = BatchState(s.batch)
        if not done and GetTime() - s.batchAt < BATCH_TIMEOUT then return self:_Arm(0.25) end
        s.done = (s.done or 0) + landed
        s.stalls = (landed == 0) and (s.stalls or 0) + 1 or 0
        s.batch = nil
        if ns.AHPlanPanel then ns.AHPlanPanel:OnEngineChanged() end
        if s.stalls >= BATCH_STALLS then
            if s.verbose then DWM:Print(L["MSG_ITEM_BLOCKED"]) end
            return self:_Finish("stuck")
        end
    end

    s.iters = s.iters + 1
    if s.iters > ITER_CAP then return self:_Finish("cap") end
    local plan = self:_Plan(s.kind, s.skipAH)
    if #plan == 0 then return self:_Finish("done") end
    if CursorBusy() then
        s.cursorWaits = (s.cursorWaits or 0) + 1
        if s.cursorWaits > 3 then
            if s.verbose then DWM:Print(L["MSG_ITEM_ABORTED"]) end
            return self:_Finish("cursor")
        end
        return self:_Arm(0.5)
    end
    s.cursorWaits = 0

    local moves = self:_BuildBatch(plan)
    if #moves == 0 then
        -- A stack still in flight from the last batch cannot be picked yet.
        if BagsLocked() and (s.lockWaits or 0) < MAX_WAIT then
            s.lockWaits = (s.lockWaits or 0) + 1
            return self:_Arm(0.5)
        end
        if s.verbose then DWM:Print(L["MSG_ITEM_BLOCKED"]) end
        return self:_Finish("blocked")
    end
    s.lockWaits = 0

    for _, m in ipairs(moves) do
        ClearCursor()
        C_Container.SplitContainerItem(m.bag, m.slot, m.n)
        if GetCursorInfo() == "item" then
            C_Container.PickupContainerItem(m.to[1], m.to[2])
        end
        ClearCursor()
        DWM:LogTxn(L["MSG_LOG_ITEM"]:format(m.dir == "deposit" and L["ITEM_DEPOSIT"] or L["ITEM_WITHDRAW"],
            m.n, ItemName(m.itemID)))
    end
    DWM:Debug(("_StepBatch: sent %d moves"):format(#moves))
    s.moves = s.moves + #moves
    local last = moves[#moves]
    s.current = MoveText(last.dir, last.n, last.itemID)
    s.batch, s.batchAt = moves, GetTime()
    if ns.AHPlanPanel then ns.AHPlanPanel:OnEngineChanged() end
    self:_Arm(0.25)
end

function ItemEngine:_Step()
    local s = self.session
    if not s then return end
    if s.kind == "guild" then
        if not ns.guildBankOpen then return self:Abort("guild-bank-gone") end
    elseif not DWM:IsWarbandUsable() then
        return self:Abort("warband-gone")
    end
    if s.kind ~= "guild" then return self:_StepBatch() end

    -- GUILD BANK: one move at a time. The server takes one guild bank move
    -- at a time and drops a request sent while the last is in flight.
    -- SETTLE GATE: never issue the next move until the previous one is
    -- actually reflected in live counts (DESIGN S13.3/S13.11).
    if s.awaiting then
        if CountSig() == s.preSig then
            s.waitTicks = (s.waitTicks or 0) + 1
            -- A dropped move leaves nothing locked in the bags, so sending it
            -- again cannot double-move. A move still in flight keeps its bag
            -- slot locked, and then we only wait.
            if s.waitTicks > GUILD_RETRY_WAIT
               and (s.retries or 0) < GUILD_RETRIES and not BagsLocked() then
                s.retries = (s.retries or 0) + 1
                s.moves = s.moves - 1     -- the re-send below counts it again
                s.lastFeed = nil          -- and records its feeder copy again
                DWM:Debug("_Step: guild move dropped, re-sending (" .. s.retries .. ")")
                s.awaiting = false
                s.waitTicks = 0
            elseif s.waitTicks > MAX_WAIT then
                if s.verbose then DWM:Print(L["MSG_ITEM_BLOCKED"]) end
                return self:_Finish("stuck")
            else
                return self:_Arm()       -- still in transit; keep waiting
            end
        else
            s.awaiting = false           -- prior move confirmed
            s.waitTicks = 0
            s.retries = 0
            s.lastConfirmed = GetTime()
            s.done = (s.done or 0) + (s.lastAmount or 0)
            if s.lastFeed and ns.AHPlan then
                ns.AHPlan:AddPulled(s.lastFeed[1], s.lastFeed[2])
            end
            s.lastFeed = nil
            if ns.AHPlanPanel then ns.AHPlanPanel:OnEngineChanged() end
        end
    end

    -- Leave the server a moment after each confirmed move.
    if s.lastConfirmed then
        local left = GUILD_GAP - (GetTime() - s.lastConfirmed)
        if left > 0 then return self:_Arm(left) end
    end

    s.iters = s.iters + 1
    if s.iters > ITER_CAP then return self:_Finish("cap") end

    local plan = self:_Plan(s.kind, s.skipAH)
    if #plan == 0 then return self:_Finish("done") end

    if CursorBusy() then
        -- Another addon (or us) holds the cursor; wait briefly, then give up
        -- rather than fight over it (S13.4).
        s.cursorWaits = (s.cursorWaits or 0) + 1
        if s.cursorWaits > 3 then
            if s.verbose then DWM:Print(L["MSG_ITEM_ABORTED"]) end
            return self:_Finish("cursor")
        end
        return self:_Arm()
    end
    s.cursorWaits = 0

    -- Snapshot live counts BEFORE issuing so the settle gate can detect the
    -- effect of exactly this move.
    s.preSig = CountSig()
    local issued = self:_DoOneMove(plan)
    -- A stack still locked by the last move cannot be picked yet.
    -- That is a wait, not a dead end.
    if not issued and BagsLocked() and (s.lockWaits or 0) < MAX_WAIT then
        s.lockWaits = (s.lockWaits or 0) + 1
        return self:_Arm()
    end
    s.lockWaits = 0
    if not issued then
        if s.verbose then DWM:Print(L["MSG_ITEM_BLOCKED"]) end
        return self:_Finish("blocked")
    end
    s.moves = s.moves + 1
    if ns.AHPlanPanel then ns.AHPlanPanel:OnEngineChanged() end
    s.awaiting = true
    s.waitTicks = 0
    self:_Arm()
end

-- Wait for the bank to settle, then step again. Event-driven (S13.3/13.5);
-- the timer is only a failsafe.
function ItemEngine:_Arm(delay)
    if self._wd then self:CancelTimer(self._wd); self._wd = nil end
    self._wd = self:ScheduleTimer(function()
        self._wd = nil
        if self.session then self:_Step() end
    end, delay or WATCHDOG)
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
-- kind:   "warband" | "guild"; nil means the guild bank if it is open.
function ItemEngine:Run(reason, kind)
    kind = kind or (ns.guildBankOpen and "guild" or "warband")
    if self.session then
        DWM:Debug("ItemEngine:Run skipped - a session is already in progress")
        return
    end

    -- "panel": the AH plan window's Move items button. The person has just
    -- read the list of moves, so that press IS the confirmation.
    local fromPanel = (reason == "panel")
    local manual   = (reason == "manual") or fromPanel
    local simulate = DWM.db.profile.simulate and true or false
    local verbose  = manual or simulate

    DWM:Debug(("ItemEngine:Run reason=%s manual=%s sim=%s itemEnabled=%s confirmed=%s")
        :format(tostring(reason), tostring(manual), tostring(simulate),
                tostring(DWM.db.profile.itemEnabled),
                tostring(DWM.db.profile.itemFirstRunConfirmed)))

    if not DWM.db.profile.itemEnabled then
        DWM:Debug("Run: bail - itemEnabled is false")
        if verbose then DWM:Print(L["MSG_ITEMS_DISABLED"]) end
        return
    end
    if not manual then
        if not DWM.db.profile.enabled then return end
        if ns.sessionPaused then return end
    end
    if kind == "guild" then
        if not (ns.guildBankOpen and ns.AHPlan and ns.AHPlan:CanUseGuildBank()) then
            DWM:Debug("Run: bail - guild bank not open, or not the AH plan's transport guild")
            if verbose then DWM:Print(L["MSG_AHPLAN_NOGUILD"]) end
            return
        end
    elseif not DWM:IsWarbandUsable() then
        DWM:Debug("Run: bail - IsWarbandUsable() false")
        if verbose then DWM:Print(L["MSG_NO_WARBAND"]) end
        return
    end
    local rec = ns.Roster and ns.Roster:Current()
    if rec and rec.managed == false then
        DWM:Debug("Run: bail - character not managed")
        if verbose then DWM:Print(L["MSG_UNMANAGED_SKIP"]) end
        return
    end

    -- The AH plan (card 0001) has its own opt-in: it can move hundreds of
    -- items that no purpose ever touched. Until "Move items by themselves"
    -- is ticked, a bank visit leaves its items alone and the AH plan window's
    -- list is the dry run (card 0002).
    local skipAH = not fromPanel and not DWM.db.profile.ahPlanConfirmed
    local plan, warns = self:_Plan(kind, skipAH)
    DWM:Debug("Run: BuildPlan -> " .. #plan .. " entr" .. (#plan == 1 and "y" or "ies"))
    for _, e in ipairs(plan) do
        DWM:Debug(("  plan: %s %d x item:%d (have %d, wb %d, qty %d, mode %s)")
            :format(e.dir, e.amount, e.itemID, e.have, e.wb, e.qty, e.mode))
    end

    -- First real run must be explicitly confirmed (DESIGN S8).
    local forcedSim = false
    if not DWM.db.profile.itemFirstRunConfirmed and not simulate and not fromPanel then
        forcedSim = true
        DWM:Print(L["MSG_ITEM_FIRSTRUN"])
    end

    if simulate or forcedSim then
        if #plan == 0 then
            if verbose or forcedSim then DWM:Print(L["MSG_ITEM_SIM_NOTHING"]) end
        else
            DWM:Print(L["MSG_ITEM_SIM_HEADER"])
            local SIM_LINES = 40   -- an AH plan run can list hundreds; chat cannot
            for i, e in ipairs(plan) do
                if i > SIM_LINES then
                    DWM:Print("  " .. L["MSG_ITEM_SIM_MORE"]:format(#plan - SIM_LINES))
                    break
                end
                local verb = (e.dir == "deposit") and L["ITEM_DEPOSIT"] or L["ITEM_WITHDRAW"]
                DWM:Print(("  %s %d x %s  (have %d -> %d)"):format(
                    verb, e.amount, ItemName(e.itemID), e.have,
                    e.dir == "deposit" and (e.have - e.amount) or (e.have + e.amount)))
            end
            for _, w in ipairs(warns) do DWM:Print("  |cFFFFCC00" .. w .. "|r") end
        end
        -- §14.5: quantified shortage prediction in the dry-run, even when the
        -- plan is empty (nothing to do, yet still short because warband=0).
        if kind ~= "guild" then self:_ReportShortfalls() end
        return
    end

    if #plan == 0 then
        DWM:Debug("Run: bail - empty plan (nothing to balance)")
        return
    end

    DWM:Debug("Run: starting session")
    local total = 0
    for _, e in ipairs(plan) do total = total + e.amount end
    self.session = {
        iters = 0, moves = 0, verbose = verbose, kind = kind, skipAH = skipAH,
        awaiting = false, waitTicks = 0, preSig = nil, cursorWaits = 0,
        total = total, done = 0,   -- copies, for the AH plan window's progress line
    }
    if not self._bucket then
        self._bucket = self:RegisterBucketEvent(
            { "BAG_UPDATE_DELAYED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", "GUILDBANKBAGSLOTS_CHANGED" },
            0.3, "_OnBankChanged")
    end
    self:_Step()
end

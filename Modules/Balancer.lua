--[[
    Djinni's Warband Manager - Balancer (Phase 1: gold only)

    Convergent by design (DESIGN.md S13.11): every pass re-derives the move
    from live state, so a partial/failed/concurrent run is simply corrected on
    the next bank visit instead of being tracked or locked.
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local Balancer = DWM:NewModule("Balancer")

local BANKTYPE_ACCOUNT = ns.BANKTYPE_ACCOUNT

-- Warband bank gold ceiling (same value the live client enforces: 9,999,999g).
local WARBAND_GOLD_CAP_COPPER = 99999990000
ns.WARBAND_GOLD_CAP_COPPER = WARBAND_GOLD_CAP_COPPER

local inProgress = false

--============================================================================
-- Public
--============================================================================

-- reason: "bank-open" (quiet when nothing to do) | "manual" (always verbose)
function Balancer:RunGold(reason)
    if inProgress then return end

    local manual = (reason == "manual")
    local simulate = DWM.db.profile.simulate and true or false
    local verbose = manual or simulate

    -- Auto path respects enabled/pause; an explicit manual run overrides them.
    if not manual then
        if not DWM.db.profile.enabled then return end
        if ns.sessionPaused then
            if verbose then DWM:Print(L["MSG_PAUSED_SKIP"]) end
            return
        end
    end

    if not DWM:IsWarbandUsable() then
        if verbose then DWM:Print(L["MSG_NO_WARBAND"]) end
        return
    end

    inProgress = true
    local ok, err = pcall(self._DoGold, self, manual, simulate, verbose)
    inProgress = false
    if not ok then
        DWM:Print("Balancer error: " .. tostring(err))
    end
end

-- Phase 1 gold moves are single server calls with nothing queued, so there is
-- nothing to unwind; the hook exists for Core's combat/close handling and for
-- the item engine in Phase 3.
function Balancer:Abort(_reason)
    inProgress = false
end

--============================================================================
-- Internal
--============================================================================

function Balancer:_DoGold(manual, simulate, verbose)
    local mode = DWM.db.profile.mode or "both"
    local charGold = GetMoney() or 0
    local warbandGold = DWM:GetWarbandGold()
    local target = DWM:GetEffectiveTargetCopper()

    -- DEPOSIT: more on character than the target.
    if charGold > target and (mode == "deposit" or mode == "both") then
        local excess = charGold - target

        -- Pre-check the warband gold cap (DESIGN S13.7): no documented
        -- FetchBankLockedReason value for "full", so clamp proactively.
        local headroom = WARBAND_GOLD_CAP_COPPER - warbandGold
        if headroom <= 0 then
            if verbose then DWM:Print(L["MSG_DEPOSIT_CAP"]:format(DWM:FormatMoney(0))) end
            return
        end
        local capped = false
        if excess > headroom then excess = headroom; capped = true end
        if excess <= 0 then
            if verbose then DWM:Print(L["MSG_NOTHING"]) end
            return
        end

        if simulate then
            DWM:Print(L["MSG_SIM_DEPOSIT"]:format(DWM:FormatMoney(excess)))
            return
        end
        if C_Bank.CanDepositMoney and not C_Bank.CanDepositMoney(BANKTYPE_ACCOUNT) then
            if verbose then DWM:Print(L["MSG_DEPOSIT_FAILED"]) end
            return
        end

        local ok = pcall(C_Bank.DepositMoney, BANKTYPE_ACCOUNT, excess)
        if ok then
            if capped then
                DWM:Print(L["MSG_DEPOSIT_CAP"]:format(DWM:FormatMoney(excess)))
            else
                DWM:Print(L["MSG_DEPOSITED"]:format(DWM:FormatMoney(excess)))
            end
        else
            DWM:Print(L["MSG_DEPOSIT_FAILED"])
        end
        return
    end

    -- WITHDRAW: less on character than the target.
    if charGold < target and (mode == "withdraw" or mode == "both") then
        local needed = target - charGold
        local short = false
        if needed > warbandGold then needed = warbandGold; short = true end
        if needed <= 0 then
            if verbose then DWM:Print(L["MSG_NOTHING"]) end
            return
        end

        if simulate then
            DWM:Print(L["MSG_SIM_WITHDRAW"]:format(DWM:FormatMoney(needed)))
            return
        end
        if C_Bank.CanWithdrawMoney and not C_Bank.CanWithdrawMoney(BANKTYPE_ACCOUNT) then
            if verbose then DWM:Print(L["MSG_WITHDRAW_FAILED"]) end
            return
        end

        local ok = pcall(C_Bank.WithdrawMoney, BANKTYPE_ACCOUNT, needed)
        if ok then
            if short then
                DWM:Print(L["MSG_WITHDRAW_SHORT"]:format(DWM:FormatMoney(needed)))
            else
                DWM:Print(L["MSG_WITHDREW"]:format(DWM:FormatMoney(needed)))
            end
        else
            DWM:Print(L["MSG_WITHDRAW_FAILED"])
        end
        return
    end

    -- Already at target (or mode forbids the needed direction).
    if verbose then
        DWM:Print(simulate and L["MSG_SIM_NOTHING"] or L["MSG_NOTHING"])
    end
end

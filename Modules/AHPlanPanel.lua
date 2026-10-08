--[[
    Djinni's Warband Manager - AHPlanPanel (cards 0002, 0004, 0005)

    The AH plan's window, so nobody has to remember /dwm commands. It opens by
    itself when an AH character opens the plan's guild bank, or a feeder opens
    its storage guild bank (card 0004), and closes with it. At an ordinary
    bank it opens only when the AH plan has moves there.

      * Two checkboxes: "Use the AH plan" (ahPlanEnabled) and "Move items by
        themselves" (ahPlanConfirmed). With the second one off, nothing moves
        until "Move items" is pressed; the list IS the dry run.
      * A list of the moves the item engine would make now, with item
        tooltips. It stays live while items move, so it shrinks as they land.
      * "Move items" runs the engine once. A progress bar and a status line
        show what is moving, how many have landed, and why a run stopped.

    Each line is anchored under the one above it, so a summary or hint that
    wraps onto more lines pushes the rest down instead of overlapping it.

    Plain frame, no secure code, so combat lockdown does not apply; the engine
    itself aborts on combat. Movable by dragging, and from Blizzard Edit Mode
    (the same selection-box pattern as DjinnisDelveTracker/UI/Tracker.lua).
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local Panel = DWM:NewModule("AHPlanPanel", "AceEvent-3.0", "AceTimer-3.0")
ns.AHPlanPanel = Panel

local ROW_H = 22
local frame, scrollBox, summaryText, hintText, enableCheck, autoCheck, moveBtn
local bar, statusText
local editPreview = false   -- shown only because Edit Mode is open
local lastResult            -- { reason, done, total } of the last run, until the next one
local CurrentKind, AHMoves  -- defined under Refresh, used by the buttons

local function P() return DWM.db.profile end

local function SavePosition(f)
    local point, _, relPoint, x, y = f:GetPoint()
    local cfg = P().ahPlanPanel
    cfg.point, cfg.relPoint, cfg.x, cfg.y = point, relPoint, x, y
end

local function ApplyPosition(f)
    local cfg = P().ahPlanPanel
    f:ClearAllPoints()
    f:SetPoint(cfg.point or "CENTER", UIParent, cfg.relPoint or "CENTER", cfg.x or 380, cfg.y or 40)
end

local function Engine() return DWM:GetModule("ItemEngine", true) end
local function Running() local e = Engine(); return e and e.session ~= nil end

local function ItemText(itemID)
    local name = C_Item.GetItemNameByID(itemID)
    if not name then C_Item.RequestLoadItemDataByID(itemID) end
    return name or ("item:" .. itemID)
end

--============================================================================
-- Build
--============================================================================

local function InitRow(row, e)
    if not row.icon then
        row:SetHeight(ROW_H)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 4, 0)
        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", -4, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    row.itemID = e.itemID
    row.icon:SetTexture(C_Item.GetItemIconByID(e.itemID))
    local deposit = (e.dir == "deposit")
    local verb = deposit and ("|cFFFFCC00" .. L["AHPANEL_GIVE"] .. "|r")
                          or ("|cFF33FF66" .. L["AHPANEL_TAKE"] .. "|r")
    local after = deposit and (e.have - e.amount) or (e.have + e.amount)
    -- Copies taken beyond this character's own quantity go on to the guild bank.
    local carry = 0
    if not deposit and e.ah and not e.feed then
        carry = math.min(e.amount, (e.held or e.have) + e.amount - (e.qty or 0))
    end
    local extra = carry > 0 and ("  |cFF66CCFF" .. L["AHPANEL_CARRY"]:format(carry) .. "|r") or ""
    row.text:SetText(("%s %d x %s  |cFFAAAAAA(%d -> %d)|r%s"):format(
        verb, e.amount, ItemText(e.itemID), e.have, after, extra))
end

local function MakeCheck(label, tip, anchor, x, y, onClick)
    local c = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    c:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x, y)
    c.Text:SetText(label)
    c.Text:SetFontObject("GameFontHighlight")
    c:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    c:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 1, 1)
        GameTooltip:AddLine(tip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

-- Blizzard's Edit Mode selection box over the window. The stock scripts hand
-- the frame to EditModeManagerFrame:SelectSystem, which only knows Blizzard
-- systems, so drag and click are replaced (as in DjinnisDelveTracker).
local function AddToEditMode()
    if not (EditModeManagerFrame and EventRegistry) then return end
    local sel = CreateFrame("Frame", nil, frame, "EditModeSystemSelectionTemplate")
    sel:SetAllPoints()
    sel:SetFrameStrata("DIALOG")
    sel.system = { GetSystemName = function() return L["AHPANEL_TITLE"] end }
    sel:Hide()
    sel:SetScript("OnDragStart", function()
        if not InCombatLockdown() then frame:StartMoving() end
    end)
    sel:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SavePosition(frame)
    end)
    sel:SetScript("OnMouseDown", function()
        EditModeManagerFrame:ClearSelectedSystem()
        sel:ShowSelected()
    end)
    hooksecurefunc(EditModeManagerFrame, "SelectSystem", function()
        if sel:IsShown() then sel:ShowHighlighted() end
    end)
    EventRegistry:RegisterCallback("EditMode.Enter", function()
        if not frame:IsShown() then Panel:Show(); editPreview = true end
        sel:ShowHighlighted()
    end, sel)
    EventRegistry:RegisterCallback("EditMode.Exit", function()
        sel:Hide()
        if editPreview then editPreview = false; if not ns.guildBankOpen then frame:Hide() end end
    end, sel)
    if EditModeManagerFrame:IsEditModeActive() then sel:ShowHighlighted() end
end

local function Build()
    frame = CreateFrame("Frame", "DWMAHPlanPanel", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(420, 540)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self) end)
    frame:SetScript("OnHide", function() editPreview = false end)
    if frame.TitleText then frame.TitleText:SetText(L["AHPANEL_TITLE"]) end
    tinsert(UISpecialFrames, "DWMAHPlanPanel")   -- Escape closes it

    -- Top: summary, two checkboxes, hint. Each sits under the one above, so
    -- text that wraps pushes the rest down.
    summaryText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    summaryText:SetPoint("TOPLEFT", 16, -32)
    summaryText:SetPoint("RIGHT", -16, 0)
    summaryText:SetJustifyH("LEFT")

    enableCheck = MakeCheck(L["OPT_AHPLAN_NAME"], L["OPT_AHPLAN_DESC"], summaryText, -4, -6, function(v)
        P().ahPlanEnabled = v
        Panel:Refresh()
    end)
    autoCheck = MakeCheck(L["AHPANEL_AUTO"], L["AHPANEL_AUTO_TIP"], enableCheck, 0, -2, function(v)
        P().ahPlanConfirmed = v
        Panel:Refresh()
    end)

    hintText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hintText:SetPoint("TOPLEFT", autoCheck, "BOTTOMLEFT", 4, -6)
    hintText:SetPoint("RIGHT", -18, 0)
    hintText:SetJustifyH("LEFT")

    -- Bottom: buttons, progress bar, status line.
    moveBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    moveBtn:SetSize(140, 24)
    moveBtn:SetPoint("BOTTOMLEFT", 12, 12)
    moveBtn:SetText(L["AHPANEL_MOVE"])
    moveBtn:SetScript("OnClick", function()
        local e, kind = Engine(), CurrentKind()
        lastResult = nil
        if e and kind then e:Run("panel", kind) end
        Panel:Refresh()
    end)

    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetSize(100, 24)
    refresh:SetPoint("BOTTOMRIGHT", -12, 12)
    refresh:SetText(L["AHPANEL_REFRESH"])
    refresh:SetScript("OnClick", function()
        if CurrentKind() == "guild" then
            for tab = 1, (GetNumGuildBankTabs() or 0) do QueryGuildBankTab(tab) end
        end
        Panel:ScheduleTimer("Refresh", 1)
    end)

    bar = CreateFrame("StatusBar", nil, frame)
    bar:SetPoint("BOTTOMLEFT", 16, 44)
    bar:SetPoint("BOTTOMRIGHT", -16, 44)
    bar:SetHeight(12)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.2, 0.75, 0.3)
    bar:SetMinMaxValues(0, 1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)

    statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 4)
    statusText:SetPoint("RIGHT", -16, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(false)

    -- Middle: the list fills whatever is left between hint and status line.
    scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", hintText, "BOTTOMLEFT", -6, -8)
    scrollBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 80)
    local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_H)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    ApplyPosition(frame)
    frame:Hide()
    AddToEditMode()
end

--============================================================================
-- Refresh
--============================================================================

-- Which bank the window works on now: "guild" at the guild bank this
-- character's role uses, "warband" at an open bank, nil anywhere else.
function CurrentKind()
    if ns.guildBankOpen then
        return (ns.AHPlan and ns.AHPlan:GuildRole()) and "guild" or nil
    end
    if ns.bankState == "ready" and DWM:IsWarbandUsable() then return "warband" end
    return nil
end

-- The AH plan's moves at a bank: BuildPlan without purpose items (vellum).
function AHMoves(kind)
    local e = Engine()
    if not e then return {}, {} end
    local plan, warns = e:BuildPlan(kind)
    local out = {}
    for _, m in ipairs(plan) do if m.ah then out[#out + 1] = m end end
    return out, warns
end

-- The moves to list, and the line above the list.
local function Moves()
    local AHPlan = ns.AHPlan
    local s = AHPlan and AHPlan:Summary()
    if not s then return {}, L["MSG_AHPLAN_NODATA"] end
    if not s.role then return {}, L["AHPANEL_NOT_POSTER"] end
    if not P().ahPlanEnabled then return {}, L["AHPANEL_OFF"] end
    local kind = CurrentKind()
    if ns.guildBankOpen and not kind then return {}, L["AHPANEL_WRONG_GUILD"]:format(s.guild or "?") end
    if not kind then return {}, L["AHPANEL_OPEN_GB"]:format(s.guild or "?") end
    local plan, warns = AHMoves(kind)
    local hint
    if Running() then
        hint = L["AHPANEL_MOVING"]
    else
        hint = (#plan == 0) and L["AHPANEL_NOTHING"] or L["AHPANEL_COUNT"]:format(#plan)
    end
    if warns and warns[1] then hint = hint .. "  |cFFFFCC00" .. warns[1] .. "|r" end
    return plan, hint
end

local STOP_REASON = {
    stuck = "AHPANEL_WHY_STUCK", locked = "AHPANEL_WHY_LOCKED", blocked = "AHPANEL_WHY_BLOCKED", cap = "AHPANEL_WHY_CAP",
    cursor = "AHPANEL_WHY_CURSOR", combat = "AHPANEL_WHY_COMBAT",
}

-- Progress bar and status line: the run in progress, else the last result.
local function ShowProgress()
    local e = Engine()
    local s = e and e.session
    if s then
        local total = math.max(s.total or 0, 1)
        bar:SetValue(math.min((s.done or 0) / total, 1))
        bar:Show()
        statusText:SetText(L["AHPANEL_PROGRESS"]:format(s.done or 0, s.total or 0, s.current or "..."))
    elseif lastResult then
        local total = math.max(lastResult.total, 1)
        bar:SetValue(math.min(lastResult.done / total, 1))
        bar:Show()
        if lastResult.reason == "done" then
            statusText:SetText("|cFF33FF66" .. L["AHPANEL_DONE"]:format(lastResult.done, lastResult.total) .. "|r")
        else
            local why = L[STOP_REASON[lastResult.reason] or "AHPANEL_WHY_CLOSED"]
            statusText:SetText("|cFFFFCC00" .. L["AHPANEL_STOPPED"]:format(lastResult.done, lastResult.total, why) .. "|r")
        end
    else
        bar:Hide()
        statusText:SetText("")
    end
end

function Panel:Refresh()
    if not frame or not frame:IsShown() then return end
    local s = ns.AHPlan and ns.AHPlan:Summary()
    if s and s.me and s.role == "feeder" then
        summaryText:SetText(L["AHPANEL_SUMMARY_FEED"]:format(
            s.me:match("^[^-]+") or s.me, s.copies, s.guild or "?", s.pulled, tostring(s.generated or "?")))
    elseif s and s.me then
        summaryText:SetText(L["AHPANEL_SUMMARY"]:format(
            s.me:match("^[^-]+") or s.me, s.copies, s.items, tostring(s.generated or "?")))
    else
        summaryText:SetText("")
    end
    enableCheck:SetChecked(P().ahPlanEnabled)
    autoCheck:SetChecked(P().ahPlanConfirmed)
    autoCheck:SetEnabled(P().ahPlanEnabled and true or false)

    local plan, hint = Moves()
    hintText:SetText(hint or "")
    scrollBox:SetDataProvider(CreateDataProvider(plan), ScrollBoxConstants.RetainScrollPosition)
    moveBtn:SetEnabled(#plan > 0 and not Running())
    ShowProgress()
end

function Panel:Show()
    if not frame then Build() end
    if not frame:IsShown() then lastResult = nil end
    ApplyPosition(frame)
    frame:Show()
    self:Refresh()
end

function Panel:Hide()
    if frame then frame:Hide() end
end

function Panel:Toggle()
    if frame and frame:IsShown() then self:Hide() else self:Show() end
end

--============================================================================
-- Hooks called by Core and the ItemEngine
--============================================================================

-- Core, once the guild bank's tabs have had time to answer.
function Panel:OnGuildBankReady()
    if ns.AHPlan and ns.AHPlan:GuildRole() then self:Show() end
end

function Panel:OnGuildBankClosed()
    if frame and frame:IsShown() and not editPreview then frame:Hide() end
end

-- Core, when the bank is open and the warband bank usable. Opens only when the
-- AH plan has moves here, so an ordinary bank visit stays quiet.
function Panel:OnBankReady()
    if not (ns.AHPlan and ns.AHPlan:IsEnabled() and ns.AHPlan:Role()) then return end
    if P().ahPlanConfirmed then return end   -- the bank-open run moves them itself
    if #AHMoves("warband") > 0 then self:Show() end
end

function Panel:OnBankClosed()
    if frame and frame:IsShown() and not editPreview and not ns.guildBankOpen then frame:Hide() end
end

-- ItemEngine: a session moved items. Counts settle a moment after a move,
-- so the list is rebuilt a little later, at most a few times a second.
function Panel:OnEngineChanged()
    if not frame or not frame:IsShown() then return end
    if self._pending then return end
    self._pending = self:ScheduleTimer(function()
        self._pending = nil
        self:Refresh()
    end, 0.3)
end

-- ItemEngine: a session ended. Keep the result on screen until the next run.
function Panel:OnEngineFinished(reason, done, total)
    lastResult = { reason = reason, done = done, total = total }
    if reason == "done" and frame and frame:IsShown() then PlaySound(SOUNDKIT.UI_BAG_SORTING_01) end
    self:OnEngineChanged()
end

function Panel:GET_ITEM_INFO_RECEIVED() self:OnEngineChanged() end
function Panel:GUILDBANKBAGSLOTS_CHANGED()
    if not Running() then self:OnEngineChanged() end
end
Panel.BAG_UPDATE_DELAYED = Panel.GUILDBANKBAGSLOTS_CHANGED

function Panel:OnEnable()
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    self:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
    self:RegisterEvent("BAG_UPDATE_DELAYED")
end

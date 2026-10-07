--[[
    Djinni's Warband Manager - AHPlanPanel (card 0002)

    The AH plan's window, so nobody has to remember /dwm commands. It opens by
    itself when an AH character opens the plan's guild bank, and closes with it.

      * Two checkboxes: "Use the AH plan" (ahPlanEnabled) and "Move items by
        themselves" (ahPlanConfirmed). With the second one off, nothing moves
        until "Move items" is pressed; the list IS the dry run.
      * A list of the moves the item engine would make now, from
        ItemEngine:BuildPlan("guild"), with item tooltips.
      * "Move items" runs the engine once. Progress shows in the window.

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
local editPreview = false   -- shown only because Edit Mode is open

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
    row.text:SetText(("%s %d x %s  |cFFAAAAAA(%d -> %d)|r"):format(
        verb, e.amount, ItemText(e.itemID), e.have, after))
end

local function MakeCheck(label, tip, y, onClick)
    local c = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    c:SetPoint("TOPLEFT", 14, y)
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
    frame:SetSize(400, 460)
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

    summaryText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    summaryText:SetPoint("TOPLEFT", 16, -32)
    summaryText:SetPoint("RIGHT", -16, 0)
    summaryText:SetJustifyH("LEFT")

    enableCheck = MakeCheck(L["OPT_AHPLAN_NAME"], L["OPT_AHPLAN_DESC"], -54, function(v)
        P().ahPlanEnabled = v
        Panel:Refresh()
    end)
    autoCheck = MakeCheck(L["AHPANEL_AUTO"], L["AHPANEL_AUTO_TIP"], -80, function(v)
        P().ahPlanConfirmed = v
        Panel:Refresh()
    end)

    hintText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hintText:SetPoint("TOPLEFT", 18, -112)
    hintText:SetPoint("RIGHT", -18, 0)
    hintText:SetJustifyH("LEFT")

    scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", 12, -136)
    scrollBox:SetPoint("BOTTOMRIGHT", -30, 42)
    local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_H)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    moveBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    moveBtn:SetSize(140, 24)
    moveBtn:SetPoint("BOTTOMLEFT", 12, 12)
    moveBtn:SetText(L["AHPANEL_MOVE"])
    moveBtn:SetScript("OnClick", function()
        local e = Engine()
        if e then e:Run("panel", "guild") end
        Panel:Refresh()
    end)

    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetSize(100, 24)
    refresh:SetPoint("BOTTOMRIGHT", -12, 12)
    refresh:SetText(L["AHPANEL_REFRESH"])
    refresh:SetScript("OnClick", function()
        if ns.guildBankOpen then
            for tab = 1, (GetNumGuildBankTabs() or 0) do QueryGuildBankTab(tab) end
        end
        Panel:ScheduleTimer("Refresh", 1)
    end)

    ApplyPosition(frame)
    frame:Hide()
    AddToEditMode()
end

--============================================================================
-- Refresh
--============================================================================

-- The moves to list, and the line above the list.
local function Moves()
    local AHPlan = ns.AHPlan
    local s = AHPlan and AHPlan:Summary()
    if not s then return {}, L["MSG_AHPLAN_NODATA"] end
    if not s.poster then return {}, L["AHPANEL_NOT_POSTER"] end
    if not P().ahPlanEnabled then return {}, L["AHPANEL_OFF"] end
    if not ns.guildBankOpen then return {}, L["AHPANEL_OPEN_GB"]:format(s.guild or "?") end
    if not AHPlan:InTransportGuild() then return {}, L["AHPANEL_WRONG_GUILD"]:format(s.guild or "?") end
    local e = Engine()
    if not e then return {}, "" end
    if e.session then return {}, L["AHPANEL_MOVING"]:format(e.session.moves or 0) end
    local plan, warns = e:BuildPlan("guild")
    local hint = (#plan == 0) and L["AHPANEL_NOTHING"] or L["AHPANEL_COUNT"]:format(#plan)
    if warns and warns[1] then hint = hint .. "  |cFFFFCC00" .. warns[1] .. "|r" end
    return plan, hint
end

function Panel:Refresh()
    if not frame or not frame:IsShown() then return end
    local s = ns.AHPlan and ns.AHPlan:Summary()
    if s and s.me then
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
end

function Panel:Show()
    if not frame then Build() end
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
    if ns.AHPlan and ns.AHPlan:InTransportGuild() then self:Show() end
end

function Panel:OnGuildBankClosed()
    if frame and frame:IsShown() and not editPreview then frame:Hide() end
end

-- ItemEngine: a session moved an item, finished, or stopped. Counts settle a
-- moment after the last move, so the list is rebuilt a little later.
function Panel:OnEngineChanged()
    if not frame or not frame:IsShown() then return end
    if self._pending then return end
    self._pending = self:ScheduleTimer(function()
        self._pending = nil
        self:Refresh()
    end, 0.6)
end

function Panel:GET_ITEM_INFO_RECEIVED() self:OnEngineChanged() end
function Panel:GUILDBANKBAGSLOTS_CHANGED()
    if not Running() then self:OnEngineChanged() end
end

function Panel:OnEnable()
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    self:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
end

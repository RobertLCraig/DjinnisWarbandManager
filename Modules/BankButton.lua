--[[
    Djinni's Warband Manager - BankButton (Phase 6, DESIGN §15.6)

    A small standalone, draggable button that appears while the bank window is
    open and opens the options panel. Deliberately NOT anchored to BankFrame,
    AccountBankPanel, or any 3rd-party frame - it is driven only by the game's
    BANKFRAME_OPENED/CLOSED events and positioned in screen coords, so it is
    inherently compatible with Baganator / Bagnon / ArkInventory / OneBag /
    the default UI (all of which hide or replace Blizzard's bank frame).
    Plain (non-secure) frame -> no combat-lockdown concerns.
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local BankButton = DWM:NewModule("BankButton", "AceEvent-3.0")
ns.BankButton = BankButton

local btn  -- created lazily on first bank open

local function SavePosition(self)
    local point, _, relPoint, x, y = self:GetPoint()
    local cfg = DWM.db.profile.bankButton
    cfg.point, cfg.relPoint, cfg.x, cfg.y = point, relPoint, x, y
end

local function ApplyPosition(self)
    local cfg = DWM.db.profile.bankButton
    self:ClearAllPoints()
    self:SetPoint(cfg.point or "CENTER", UIParent,
        cfg.relPoint or "CENTER", cfg.x or 0, cfg.y or 220)
end

function BankButton:_Ensure()
    if btn then return btn end

    btn = CreateFrame("Button", "DWMBankButton", UIParent)
    btn:SetSize(36, 36)
    btn:SetFrameStrata("HIGH")
    btn:SetClampedToScreen(true)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture("Interface\\Icons\\achievement_guildperk_mobilebanking")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon = icon

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetTexCoord(0.2, 0.8, 0.2, 0.8)
    border:SetVertexColor(0.31, 0.76, 0.97)

    btn:SetScript("OnDragStart", function(self) self:StartMoving() end)
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    btn:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            ns.sessionPaused = not ns.sessionPaused
            DWM:Print(L["STATUS_PAUSED"]:format(ns.sessionPaused and L["YES"] or L["NO"]))
        else
            LibStub("AceConfigDialog-3.0"):Open(ADDON_NAME)
        end
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["ADDON_NAME"])
        GameTooltip:AddLine("|cFFAAAAAA" .. L["BANKBTN_TIP_OPEN"] .. "|r")
        GameTooltip:AddLine("|cFFAAAAAA" .. L["BANKBTN_TIP_PAUSE"] .. "|r")
        GameTooltip:AddLine("|cFFAAAAAA" .. L["BANKBTN_TIP_DRAG"] .. "|r")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:Hide()
    return btn
end

function BankButton:Refresh()
    -- Called when the toggle changes while the bank is open.
    if not btn then return end
    if DWM.db.profile.bankButton.hide then
        btn:Hide()
    elseif ns.bankState ~= "closed" then
        ApplyPosition(btn); btn:Show()
    end
end

function BankButton:BANKFRAME_OPENED()
    if DWM.db.profile.bankButton.hide then return end
    local b = self:_Ensure()
    ApplyPosition(b)
    b:Show()
end

function BankButton:BANKFRAME_CLOSED()
    if btn then btn:Hide() end
end

function BankButton:OnEnable()
    self:RegisterEvent("BANKFRAME_OPENED")
    self:RegisterEvent("BANKFRAME_CLOSED")
end

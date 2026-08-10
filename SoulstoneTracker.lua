-- SoulstoneTracker
-- Tracks soulstones cast by warlocks on raid members
-- Author: Waylock

SoulstoneTracker = {}
local m = SoulstoneTracker

local SOULSTONE_DURATION = 30 * 60
local FONT      = "Fonts\\FRIZQT__.TTF"
local BASE_W    = 380
local ROW_H     = 18
local TITLE_H   = 22
local HEADER_H  = 16
local MAX_ROWS  = 10
local MIN_W     = 250
local ADDON_MSG_PREFIX = "SSTracker"

-- Column proportions (as fraction of frame width)
local COL_CASTER_END  = 0.38  -- caster takes 0-38%
local COL_ARROW       = 0.40  -- arrow at 40%
local COL_TARGET_END  = 0.72  -- target takes 40-72%
-- expires takes 72-100%

m.stones  = {}
m.frame   = nil
m.locked  = false

-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

local function timeLeft(expires)
    return math.max(0, expires - time())
end

local function formatTime(secs)
    if secs <= 0 then
        return "|cffff3333EXPIRED|r"
    elseif secs <= 300 then
        return "|cffff7c0a"..string.format("%dm %02ds", math.floor(secs/60), math.mod(secs,60)).."|r"
    else
        return "|cff00ff98"..string.format("%dm %02ds", math.floor(secs/60), math.mod(secs,60)).."|r"
    end
end

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffa050ff[SS]|r " .. msg)
end

local function hasActiveStones()
    for _ in pairs(m.stones) do return true end
    return false
end

local function getWarlocksMissingStones()
    local missing = {}
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            local name, _, _, _, class = GetRaidRosterInfo(i)
            if name and class == "Warlock" then
                local hasCast = false
                for _, data in pairs(m.stones) do
                    if data.caster == name then hasCast = true break end
                end
                if not hasCast then table.insert(missing, name) end
            end
        end
    else
        for i = 1, GetNumPartyMembers() do
            local name = UnitName("party"..i)
            local class = UnitClass("party"..i)
            if name and class == "Warlock" then
                local hasCast = false
                for _, data in pairs(m.stones) do
                    if data.caster == name then hasCast = true break end
                end
                if not hasCast then table.insert(missing, name) end
            end
        end
    end
    return missing
end

-------------------------------------------------------------------------------
-- Raid Sync
-------------------------------------------------------------------------------

local function broadcastStone(target, caster, expires)
    local msg = "ADD:"..target..":"..caster..":"..expires
    if GetNumRaidMembers() > 0 then
        SendAddonMessage(ADDON_MSG_PREFIX, msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage(ADDON_MSG_PREFIX, msg, "PARTY")
    end
end

local function broadcastRemove(target)
    local msg = "REM:"..target
    if GetNumRaidMembers() > 0 then
        SendAddonMessage(ADDON_MSG_PREFIX, msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage(ADDON_MSG_PREFIX, msg, "PARTY")
    end
end

-------------------------------------------------------------------------------
-- Tracking
-------------------------------------------------------------------------------

function m.addStone(target, caster, expires, silent)
    local exp = expires or (time() + SOULSTONE_DURATION)
    m.stones[target] = { caster = caster, expires = exp, castTime = time() }
    if not silent then
        say("|cffa050ff"..caster.."|r soulstoned |cffffffff"..target.."|r")
        PlaySound("SPELLBOOKCLOSE")
        broadcastStone(target, caster, exp)
    end
    m.refresh()
end

function m.removeStone(target, silent)
    if m.stones[target] then
        m.stones[target] = nil
        if not silent then broadcastRemove(target) end
        m.refresh()
    end
end

function m.clearExpired()
    local now = time()
    local changed = false
    for target, data in pairs(m.stones) do
        if now >= data.expires then
            say("|cffff3333[WARNING]|r Soulstone expired on |cffffffff"..target.."|r")
            PlaySound("LOOTCLOSE")
            m.stones[target] = nil
            changed = true
        end
    end
    if changed then
        m.refresh()
        if not hasActiveStones() then
            say("|cffff3333[WARNING]|r No active soulstones in the raid!")
            PlaySound("RAID_WARNING")
            local missing = getWarlocksMissingStones()
            if table.getn(missing) > 0 then
                say("|cffff7c0aWarlocks without soulstone: |cffffffff"..table.concat(missing, ", ").."|r")
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Buff Scan
-------------------------------------------------------------------------------

function m.scanForSoulstones()
    local units = {}
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do table.insert(units, "raid"..i) end
    else
        table.insert(units, "player")
        for i = 1, GetNumPartyMembers() do table.insert(units, "party"..i) end
    end
    local found = 0
    for _, unit in ipairs(units) do
        local name = UnitName(unit)
        if name then
            local i = 1
            while true do
                local buffName = UnitBuff(unit, i)
                if not buffName then break end
                if string.find(buffName, "Soulstone") then
                    if not m.stones[name] then
                        m.addStone(name, "Unknown", nil, true)
                        found = found + 1
                    end
                end
                i = i + 1
            end
        end
    end
    if found > 0 then
        say("Found "..found.." existing soulstone(s) on group members.")
        m.refresh()
    end
end

-------------------------------------------------------------------------------
-- Minimap Button
-------------------------------------------------------------------------------

function m.createMinimapButton()
    local radius = 80
    local btn = CreateFrame("Button", "SoulstoneTrackerMinimap", Minimap)
    btn:SetWidth(20)
    btn:SetHeight(20)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetClampedToScreen(true)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Background")
    bg:SetAllPoints(btn)

    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
    icon:SetWidth(16)
    icon:SetHeight(16)
    icon:SetPoint("Center", btn, "Center", 0, 0)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(56)
    border:SetHeight(56)
    border:SetPoint("TopLeft", btn, "TopLeft", -17, 17)

    local angle = SoulstoneTrackerDB.minimapAngle or 195
    local function updatePos()
        btn:SetPoint("Center", Minimap, "Center", math.cos(math.rad(angle))*radius, math.sin(math.rad(angle))*radius)
    end
    updatePos()

    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function()
        btn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            angle = math.deg(math.atan2(py/s - my, px/s - mx))
            SoulstoneTrackerDB.minimapAngle = angle
            updatePos()
        end)
    end)
    btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnClick", function()
        if m.frame:IsVisible() then
            m.frame:Hide() SoulstoneTrackerDB.hidden = true
        else
            m.frame:Show() SoulstoneTrackerDB.hidden = false
        end
    end)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        GameTooltip:SetText("|cffa050ffSoulstone Tracker|r")
        GameTooltip:AddLine("Click to toggle", 1,1,1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    m.minimap = btn
end

-------------------------------------------------------------------------------
-- UI helpers - reposition columns based on current frame width
-------------------------------------------------------------------------------

function m.repositionColumns()
    local f = m.frame
    if not f or not f.cols then return end
    local w = f:GetWidth()

    local cx  = math.floor(w * COL_CASTER_END)
    local ax  = math.floor(w * COL_ARROW)
    local tx  = ax + 14
    local tw  = math.floor(w * COL_TARGET_END) - tx - 4
    local ew  = w - math.floor(w * COL_TARGET_END) - 8

    -- Headers
    f.cols.hTarget:ClearAllPoints()
    f.cols.hTarget:SetPoint("TopLeft", f, "TopLeft", tx, -(TITLE_H + HEADER_H/2))

    -- Rows
    for i = 1, MAX_ROWS do
        local row = f.rows[i]
        if row then
            row.caster:SetWidth(cx - 8)
            row.arrow:ClearAllPoints()
            row.arrow:SetPoint("TopLeft", f, "TopLeft", ax, -(TITLE_H + HEADER_H + 2 + (i-1)*ROW_H))
            row.target:ClearAllPoints()
            row.target:SetPoint("TopLeft", f, "TopLeft", tx, -(TITLE_H + HEADER_H + 2 + (i-1)*ROW_H))
            row.target:SetWidth(tw)
            row.timer:SetWidth(ew)
        end
    end
end

-------------------------------------------------------------------------------
-- UI
-------------------------------------------------------------------------------

function m.createFrame()
    local savedW = SoulstoneTrackerDB.size and SoulstoneTrackerDB.size.w or BASE_W
    local savedH = SoulstoneTrackerDB.size and SoulstoneTrackerDB.size.h or TITLE_H + HEADER_H + ROW_H + 6

    local f = CreateFrame("Frame", "SoulstoneTrackerFrame", UIParent)
    f:SetWidth(savedW)
    f:SetHeight(savedH)
    f:SetFrameStrata("MEDIUM")
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets   = { left=1, right=1, top=1, bottom=1 }
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
    f:SetBackdropBorderColor(0.25, 0.25, 0.35, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if not m.locked then this:StartMoving() end
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local point, _, rpoint, x, y = this:GetPoint()
        SoulstoneTrackerDB.position = { point=point, rpoint=rpoint, x=x, y=y }
    end)
    f:SetScript("OnSizeChanged", function()
        local w = math.max(MIN_W, this:GetWidth())
        this:SetWidth(w)
        SoulstoneTrackerDB.size = { w = w, h = this:GetHeight() }
        m.repositionColumns()
    end)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TopLeft",  f, "TopLeft",  1, -1)
    titleBar:SetPoint("TopRight", f, "TopRight", -1, -1)
    titleBar:SetHeight(TITLE_H)
    titleBar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    titleBar:SetBackdropColor(0.22, 0.08, 0.38, 1)

    local grad = titleBar:CreateTexture(nil, "OVERLAY")
    grad:SetAllPoints(titleBar)
    grad:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    grad:SetBlendMode("ADD")
    grad:SetVertexColor(0.2, 0.05, 0.4, 0.4)

    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 11, "OUTLINE")
    title:SetPoint("Left", titleBar, "Left", 6, 0)
    title:SetText("|cffffd700Soulstone Tracker v1.0|r")
    f.title = title

    -- Lock button using SetNormalTexture (same method as Threatmeter)
    local lockBtn = CreateFrame("Button", nil, titleBar)
    lockBtn:SetWidth(16)
    lockBtn:SetHeight(16)
    lockBtn:SetPoint("Right", titleBar, "Right", -24, 0)
    lockBtn:SetNormalTexture("Interface\\addons\\SoulstoneTracker\\images\\icon_unlocked.tga")
    lockBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    local function updateLock()
        if m.locked then
            lockBtn:SetNormalTexture("Interface\\addons\\SoulstoneTracker\\images\\icon_locked.tga")
        else
            lockBtn:SetNormalTexture("Interface\\addons\\SoulstoneTracker\\images\\icon_unlocked.tga")
        end
    end
    f.updateLock = updateLock

    lockBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(lockBtn, "ANCHOR_BOTTOM")
        GameTooltip:SetText(m.locked and "Unlock frame" or "Lock frame", 1,1,1)
        GameTooltip:Show()
    end)
    lockBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    lockBtn:SetScript("OnClick", function()
        m.locked = not m.locked
        SoulstoneTrackerDB.locked = m.locked
        updateLock()
        say(m.locked and "Frame locked." or "Frame unlocked.")
    end)

    -- X close button
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("Right", titleBar, "Right", -4, 0)
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY")
    closeTxt:SetFont(FONT, 13, "OUTLINE")
    closeTxt:SetAllPoints(closeBtn)
    closeTxt:SetJustifyH("Center")
    closeTxt:SetJustifyV("Middle")
    closeTxt:SetText("|cffaaaaaaX|r")
    closeBtn:SetScript("OnEnter", function() closeTxt:SetText("|cffffffffX|r") end)
    closeBtn:SetScript("OnLeave", function() closeTxt:SetText("|cffaaaaaaX|r") end)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        SoulstoneTrackerDB.hidden = true
    end)

    -- Column headers
    local hY = -(TITLE_H + HEADER_H/2)

    local hCaster = f:CreateFontString(nil, "OVERLAY")
    hCaster:SetFont(FONT, 10, "OUTLINE")
    hCaster:SetTextColor(0.85, 0.85, 0.85, 1)
    hCaster:SetPoint("TopLeft", f, "TopLeft", 8, hY)
    hCaster:SetText("Caster")

    local hTarget = f:CreateFontString(nil, "OVERLAY")
    hTarget:SetFont(FONT, 10, "OUTLINE")
    hTarget:SetTextColor(0.85, 0.85, 0.85, 1)
    hTarget:SetPoint("TopLeft", f, "TopLeft", math.floor(savedW * COL_ARROW) + 14, hY)
    hTarget:SetText("Target")

    local hExpires = f:CreateFontString(nil, "OVERLAY")
    hExpires:SetFont(FONT, 10, "OUTLINE")
    hExpires:SetTextColor(0.85, 0.85, 0.85, 1)
    hExpires:SetPoint("TopRight", f, "TopRight", -8, hY)
    hExpires:SetJustifyH("Right")
    hExpires:SetText("Expires")

    -- Divider
    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TopLeft",  f, "TopLeft",  1, -(TITLE_H + HEADER_H))
    div:SetPoint("TopRight", f, "TopRight", -1, -(TITLE_H + HEADER_H))
    div:SetTexture(0.3, 0.15, 0.5, 0.8)

    -- Empty label
    local empty = f:CreateFontString(nil, "OVERLAY")
    empty:SetFont(FONT, 10, "OUTLINE")
    empty:SetTextColor(0.4, 0.4, 0.4, 1)
    empty:SetPoint("TopLeft", f, "TopLeft", 8, -(TITLE_H + HEADER_H + 3))
    empty:SetText("No active soulstones")
    f.empty = empty

    -- Store column header refs for repositioning
    f.cols = { hTarget = hTarget }

    -- Rows
    f.rows = {}
    for i = 1, MAX_ROWS do
        local rowY = -(TITLE_H + HEADER_H + 2 + (i-1)*ROW_H)
        local w = savedW

        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetPoint("TopLeft",  f, "TopLeft",  1, rowY)
        bg:SetPoint("TopRight", f, "TopRight", -1, rowY)
        bg:SetHeight(ROW_H)
        if math.mod(i, 2) == 0 then bg:SetTexture(1,1,1,0.04) else bg:SetTexture(0,0,0,0) end
        bg:Hide()

        local caster = f:CreateFontString(nil, "OVERLAY")
        caster:SetFont(FONT, 11, "OUTLINE")
        caster:SetPoint("TopLeft", f, "TopLeft", 8, rowY)
        caster:SetWidth(math.floor(w * COL_CASTER_END) - 8)
        caster:SetJustifyH("Left")

        local arrow = f:CreateFontString(nil, "OVERLAY")
        arrow:SetFont(FONT, 11, "OUTLINE")
        arrow:SetTextColor(0.4, 0.4, 0.4, 1)
        arrow:SetPoint("TopLeft", f, "TopLeft", math.floor(w * COL_ARROW), rowY)
        arrow:SetText("->")

        local target = f:CreateFontString(nil, "OVERLAY")
        target:SetFont(FONT, 11, "OUTLINE")
        target:SetPoint("TopLeft", f, "TopLeft", math.floor(w * COL_ARROW) + 14, rowY)
        target:SetWidth(math.floor(w * COL_TARGET_END) - math.floor(w * COL_ARROW) - 18)
        target:SetJustifyH("Left")

        local timer = f:CreateFontString(nil, "OVERLAY")
        timer:SetFont(FONT, 11, "OUTLINE")
        timer:SetPoint("TopRight", f, "TopRight", -8, rowY)
        timer:SetWidth(w - math.floor(w * COL_TARGET_END) - 8)
        timer:SetJustifyH("Right")

        -- Tooltip hitbox
        local hitbox = CreateFrame("Frame", nil, f)
        hitbox:SetHeight(ROW_H)
        hitbox:SetPoint("TopLeft",  f, "TopLeft",  1, rowY)
        hitbox:SetPoint("TopRight", f, "TopRight", -1, rowY)
        hitbox:EnableMouse(true)
        hitbox.rowIndex = i
        hitbox:SetScript("OnEnter", function()
            local row = f.rows[this.rowIndex]
            if not row or not row.data then return end
            local d = row.data
            GameTooltip:SetOwner(this, "ANCHOR_CURSOR")
            GameTooltip:SetText("|cffa050ff"..d.caster.."|r -> |cffffffff"..d.target.."|r")
            GameTooltip:AddLine("Cast: "..date("%H:%M:%S", d.castTime), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Expires: "..date("%H:%M:%S", d.expires), 0.8, 0.8, 0.8)
            local s = timeLeft(d.expires)
            GameTooltip:AddLine(string.format("Time left: %dm %02ds", math.floor(s/60), math.mod(s,60)), 1,1,0)
            GameTooltip:Show()
        end)
        hitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

        f.rows[i] = { caster=caster, arrow=arrow, target=target, timer=timer, bg=bg, hitbox=hitbox, data=nil }
    end

    -- Resize grip using SetNormalTexture
    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BottomRight", f, "BottomRight", 0, 0)
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\addons\\SoulstoneTracker\\ResizeGrip")
    grip:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    grip:SetScript("OnEnter", function()
        GameTooltip:SetOwner(grip, "ANCHOR_LEFT")
        GameTooltip:SetText("Drag to resize", 1,1,1)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)

    -- Ticker
    local tick = 0
    f:SetScript("OnUpdate", function()
        tick = tick + arg1
        if tick >= 1 then
            tick = 0
            m.clearExpired()
            m.refresh()
        end
    end)

    -- Restore position
    if SoulstoneTrackerDB.position then
        local p = SoulstoneTrackerDB.position
        f:ClearAllPoints()
        f:SetPoint(p.point, UIParent, p.rpoint, p.x, p.y)
    else
        f:SetPoint("Center", UIParent, "Center", 300, 0)
    end

    -- Restore lock
    if SoulstoneTrackerDB.locked then
        m.locked = true
        updateLock()
    end

    m.frame = f
    m.repositionColumns()
    m.refresh()
end

function m.refresh()
    if not m.frame then return end
    local f = m.frame

    local list = {}
    for target, data in pairs(m.stones) do
        table.insert(list, { target=target, caster=data.caster, expires=data.expires, castTime=data.castTime or 0 })
    end
    table.sort(list, function(a,b) return a.expires < b.expires end)
    local count = table.getn(list)

    local missing = getWarlocksMissingStones()
    if table.getn(missing) > 0 and (GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0) then
        f.title:SetText("|cffffd700Soulstone Tracker|r |cffff7c0a["..table.getn(missing).." missing]|r")
    else
        f.title:SetText("|cffffd700Soulstone Tracker v1.0|r")
    end

    if count == 0 then f.empty:Show() else f.empty:Hide() end

    for i = 1, MAX_ROWS do
        local row  = f.rows[i]
        local data = list[i]
        if data then
            row.caster:SetText("|cffa050ff"..data.caster.."|r")
            row.arrow:SetText("->")
            row.target:SetText("|cffffffff"..data.target.."|r")
            row.timer:SetText(formatTime(timeLeft(data.expires)))
            row.bg:Show()
            row.data = data
        else
            row.caster:SetText("")
            row.arrow:SetText("")
            row.target:SetText("")
            row.timer:SetText("")
            row.bg:Hide()
            row.data = nil
        end
    end

    local rows = math.max(1, count)
    f:SetHeight(TITLE_H + HEADER_H + (rows * ROW_H) + 6)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local lastCaster = nil
local eFrame = CreateFrame("Frame")
eFrame:RegisterEvent("PLAYER_LOGIN")
eFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eFrame:RegisterEvent("SPELLCAST_START")
eFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")
eFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS")
eFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS")
eFrame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_SELF")
eFrame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_OTHER")
eFrame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")
eFrame:RegisterEvent("CHAT_MSG_ADDON")

eFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        SoulstoneTrackerDB = SoulstoneTrackerDB or {}
        m.createFrame()
        m.createMinimapButton()
        if SoulstoneTrackerDB.hidden then m.frame:Hide() else m.frame:Show() end
        say("Loaded. |cffffd700/ss|r toggle  |cffffd700/ss test|r  |cffffd700/ss help|r")
        local t = CreateFrame("Frame") local e = 0
        t:SetScript("OnUpdate", function()
            e = e + arg1
            if e >= 2 then t:SetScript("OnUpdate", nil) m.scanForSoulstones() end
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        local t = CreateFrame("Frame") local e = 0
        t:SetScript("OnUpdate", function()
            e = e + arg1
            if e >= 3 then t:SetScript("OnUpdate", nil) m.scanForSoulstones() end
        end)

    elseif event == "SPELLCAST_START" then
        if arg1 and string.find(arg1, "Soulstone Resurrection") then
            lastCaster = UnitName("player")
        end

    elseif event == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" then
        if arg1 and string.find(arg1, "Soulstone Resurrection") then
            m.addStone(UnitName("player"), lastCaster or UnitName("player"))
            lastCaster = nil
        end

    elseif event == "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS"
        or event == "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS" then
        if arg1 then
            local target = string.match(arg1, "(.+) gains Soulstone Resurrection")
            if target then
                m.addStone(target, lastCaster or "Unknown")
                lastCaster = nil
            end
        end

    elseif event == "CHAT_MSG_SPELL_AURA_GONE_SELF" then
        if arg1 and string.find(arg1, "Soulstone Resurrection") then
            m.removeStone(UnitName("player"))
        end

    elseif event == "CHAT_MSG_SPELL_AURA_GONE_OTHER" then
        if arg1 then
            local target = string.match(arg1, "Soulstone Resurrection fades from (.+)%.")
            if target then m.removeStone(target) end
        end

    elseif event == "CHAT_MSG_COMBAT_FRIENDLY_DEATH" then
        if arg1 then
            local dead = string.match(arg1, "(.+) dies%.")
            if dead and m.stones[dead] then m.removeStone(dead) end
        end

    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == ADDON_MSG_PREFIX and arg4 ~= UnitName("player") then
            if string.find(arg2, "^ADD:") then
                local target, caster, expires = string.match(arg2, "^ADD:(.+):(.+):(%d+)$")
                if target and caster and expires then
                    m.addStone(target, caster, tonumber(expires), true)
                end
            elseif string.find(arg2, "^REM:") then
                local target = string.match(arg2, "^REM:(.+)$")
                if target then m.removeStone(target, true) end
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- Slash
-------------------------------------------------------------------------------

SLASH_SOULSTONETRACKER1 = "/ss"
SLASH_SOULSTONETRACKER2 = "/soulstone"
SlashCmdList["SOULSTONETRACKER"] = function(args)
    args = args or ""
    local cmd = string.lower(string.gsub(args, "^%s*(.-)%s*$", "%1"))

    if cmd == "clear" then
        m.stones = {} m.refresh() say("Cleared.")
    elseif cmd == "test" then
        m.addStone(UnitName("player"), UnitName("player"))
        say("Test stone added.")
    elseif cmd == "list" then
        local n = 0
        for target, data in pairs(m.stones) do
            local s = timeLeft(data.expires)
            say(data.caster.." -> "..target.." ("..math.floor(s/60).."m "..math.mod(s,60).."s)")
            n = n + 1
        end
        if n == 0 then say("No active soulstones.") end
    elseif cmd == "warlocks" then
        local missing = getWarlocksMissingStones()
        if table.getn(missing) == 0 then
            say("All warlocks have active soulstones!")
        else
            say("|cffff7c0aMissing: |cffffffff"..table.concat(missing, ", ").."|r")
        end
    elseif cmd == "lock" then
        m.locked = not m.locked
        SoulstoneTrackerDB.locked = m.locked
        m.frame.updateLock()
        say(m.locked and "Frame locked." or "Frame unlocked.")
    elseif cmd == "scan" then
        m.scanForSoulstones()
    elseif cmd == "reset" then
        SoulstoneTrackerDB.position = nil
        SoulstoneTrackerDB.size = nil
        say("Position and size reset. /reload to apply.")
    elseif cmd == "help" then
        say("|cffffd700/ss|r toggle  |cffffd700/ss test|r  |cffffd700/ss clear|r  |cffffd700/ss list|r")
        say("|cffffd700/ss warlocks|r  |cffffd700/ss lock|r  |cffffd700/ss scan|r  |cffffd700/ss reset|r")
    else
        if m.frame and m.frame:IsVisible() then
            m.frame:Hide() SoulstoneTrackerDB.hidden = true say("Hidden.")
        else
            if not m.frame then m.createFrame() end
            m.frame:Show() SoulstoneTrackerDB.hidden = false say("Shown.")
        end
    end
end

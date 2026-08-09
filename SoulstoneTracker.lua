-- SoulstoneTracker
-- Tracks soulstones cast by warlocks on raid members
-- Author: Waylock

SoulstoneTracker = {}
local m = SoulstoneTracker

local SOULSTONE_DURATION = 30 * 60
local FONT     = "Fonts\\FRIZQT__.TTF"
local FRAME_W  = 380
local ROW_H    = 16
local TITLE_H  = 22
local MAX_ROWS = 10
local ADDON_MSG_PREFIX = "SSTracker"

m.stones   = {}
m.frame    = nil
m.locked   = false
m.minimap  = nil

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

local function playSound(sound)
    PlaySound(sound)
end

-- Check if any soulstones are active
local function hasActiveStones()
    for _ in pairs(m.stones) do return true end
    return false
end

-- Get all warlocks in raid without active soulstones
local function getWarlocksMissingStones()
    local missing = {}
    local numRaid = GetNumRaidMembers()
    if numRaid == 0 then
        -- Check party
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
    else
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
        playSound("SPELLBOOKCLOSE")
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
            playSound("LOOTCLOSE")
            m.stones[target] = nil
            changed = true
        end
    end
    if changed then
        m.refresh()
        -- Warn if no stones remain
        if not hasActiveStones() then
            say("|cffff3333[WARNING]|r No active soulstones in the raid!")
            playSound("RAID_WARNING")
            local missing = getWarlocksMissingStones()
            if table.getn(missing) > 0 then
                say("|cffff7c0aWarlocks without soulstone: |cffffffff"..table.concat(missing, ", ").."|r")
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Minimap Button
-------------------------------------------------------------------------------

function m.createMinimapButton()
    local radius = 80
    local button = CreateFrame("Button", "SoulstoneTrackerMinimap", Minimap)
    button:SetWidth(20)
    button:SetHeight(20)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:SetClampedToScreen(true)

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
    icon:SetWidth(18)
    icon:SetHeight(18)
    icon:SetPoint("Center", button, "Center", 0, 0)

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Background")
    bg:SetWidth(20)
    bg:SetHeight(20)
    bg:SetAllPoints(button)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(56)
    border:SetHeight(56)
    border:SetPoint("TopLeft", button, "TopLeft", -17, 17)

    -- Position on minimap
    local angle = SoulstoneTrackerDB.minimapAngle or 195
    local function updatePos()
        local x = math.cos(math.rad(angle)) * radius
        local y = math.sin(math.rad(angle)) * radius
        button:SetPoint("Center", Minimap, "Center", x, y)
    end
    updatePos()

    -- Drag to reposition
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function()
        button:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px/scale, py/scale
            angle = math.deg(math.atan2(py-my, px-mx))
            SoulstoneTrackerDB.minimapAngle = angle
            updatePos()
        end)
    end)
    button:SetScript("OnDragStop", function()
        button:SetScript("OnUpdate", nil)
    end)

    button:SetScript("OnClick", function()
        if m.frame:IsVisible() then
            m.frame:Hide()
            SoulstoneTrackerDB.hidden = true
        else
            m.frame:Show()
            SoulstoneTrackerDB.hidden = false
        end
    end)

    button:SetScript("OnEnter", function()
        GameTooltip:SetOwner(button, "ANCHOR_LEFT")
        GameTooltip:SetText("|cffa050ffSoulstone Tracker|r")
        GameTooltip:AddLine("Click to toggle", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    m.minimap = button
end

-------------------------------------------------------------------------------
-- UI
-------------------------------------------------------------------------------

function m.createFrame()
    local f = CreateFrame("Frame", "SoulstoneTrackerFrame", UIParent)
    f:SetWidth(FRAME_W)
    f:SetHeight(TITLE_H + 20 + ROW_H)
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

    -- Title text
    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 11, "OUTLINE")
    title:SetPoint("Left", titleBar, "Left", 6, 0)
    title:SetText("|cffffd700Soulstone Tracker v1.0|r")
    f.title = title

    -- Lock button (padlock using WoW action bar lock textures)
    local lockBtn = CreateFrame("Button", nil, titleBar)
    lockBtn:SetWidth(14)
    lockBtn:SetHeight(14)
    lockBtn:SetPoint("Right", titleBar, "Right", -22, 0)
    local lockTex = lockBtn:CreateTexture(nil, "OVERLAY")
    lockTex:SetAllPoints(lockBtn)
    lockTex:SetTexture("Interface\\ActionBar\\UI-ActionBar-Padlock")
    lockTex:SetVertexColor(0.6, 0.6, 0.6, 1)
    local function updateLock()
        if m.locked then
            lockTex:SetVertexColor(0.2, 1, 0.2, 1)
        else
            lockTex:SetVertexColor(0.6, 0.6, 0.6, 1)
        end
    end
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
    f.updateLock = updateLock

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
    local hY = -(TITLE_H + 3)

    local hCaster = f:CreateFontString(nil, "OVERLAY")
    hCaster:SetFont(FONT, 9, "OUTLINE")
    hCaster:SetTextColor(0.8, 0.8, 0.8, 1)
    hCaster:SetPoint("TopLeft", f, "TopLeft", 8, hY)
    hCaster:SetText("Caster")

    local hTarget = f:CreateFontString(nil, "OVERLAY")
    hTarget:SetFont(FONT, 9, "OUTLINE")
    hTarget:SetTextColor(0.8, 0.8, 0.8, 1)
    hTarget:SetPoint("TopLeft", f, "TopLeft", 175, hY)
    hTarget:SetText("Target")

    local hExpires = f:CreateFontString(nil, "OVERLAY")
    hExpires:SetFont(FONT, 9, "OUTLINE")
    hExpires:SetTextColor(0.8, 0.8, 0.8, 1)
    hExpires:SetPoint("TopRight", f, "TopRight", -8, hY)
    hExpires:SetJustifyH("Right")
    hExpires:SetText("Expires")

    -- Divider
    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TopLeft",  f, "TopLeft",  1, -(TITLE_H + 14))
    div:SetPoint("TopRight", f, "TopRight", -1, -(TITLE_H + 14))
    div:SetTexture(0.3, 0.15, 0.5, 0.8)

    -- Empty label
    local empty = f:CreateFontString(nil, "OVERLAY")
    empty:SetFont(FONT, 10, "OUTLINE")
    empty:SetTextColor(0.4, 0.4, 0.4, 1)
    empty:SetPoint("TopLeft", f, "TopLeft", 8, -(TITLE_H + 17))
    empty:SetText("No active soulstones")
    f.empty = empty

    -- Rows
    f.rows = {}
    for i = 1, MAX_ROWS do
        local rowY = -(TITLE_H + 15 + (i-1) * ROW_H)

        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetPoint("TopLeft",  f, "TopLeft",  1, rowY)
        bg:SetPoint("TopRight", f, "TopRight", -1, rowY)
        bg:SetHeight(ROW_H)
        if math.mod(i, 2) == 0 then
            bg:SetTexture(1, 1, 1, 0.04)
        else
            bg:SetTexture(0, 0, 0, 0)
        end
        bg:Hide()

        local caster = f:CreateFontString(nil, "OVERLAY")
        caster:SetFont(FONT, 11, "OUTLINE")
        caster:SetPoint("TopLeft", f, "TopLeft", 8, rowY)
        caster:SetWidth(155)
        caster:SetJustifyH("Left")

        local arrow = f:CreateFontString(nil, "OVERLAY")
        arrow:SetFont(FONT, 11, "OUTLINE")
        arrow:SetTextColor(0.4, 0.4, 0.4, 1)
        arrow:SetPoint("TopLeft", f, "TopLeft", 163, rowY)
        arrow:SetText("->")

        local target = f:CreateFontString(nil, "OVERLAY")
        target:SetFont(FONT, 11, "OUTLINE")
        target:SetPoint("TopLeft", f, "TopLeft", 177, rowY)
        target:SetPoint("TopRight", f, "TopRight", -85, rowY)
        target:SetJustifyH("Left")

        local timer = f:CreateFontString(nil, "OVERLAY")
        timer:SetFont(FONT, 11, "OUTLINE")
        timer:SetPoint("TopRight", f, "TopRight", -8, rowY)
        timer:SetWidth(75)
        timer:SetJustifyH("Right")

        -- Hover tooltip
        local hitbox = CreateFrame("Frame", nil, f)
        hitbox:SetPoint("TopLeft",  f, "TopLeft",  1, rowY)
        hitbox:SetPoint("TopRight", f, "TopRight", -1, rowY)
        hitbox:SetHeight(ROW_H)
        hitbox:EnableMouse(true)
        hitbox.index = i
        hitbox:SetScript("OnEnter", function()
            local row = f.rows[this.index]
            if not row or not row.data then return end
            local data = row.data
            GameTooltip:SetOwner(this, "ANCHOR_CURSOR")
            GameTooltip:SetText("|cffa050ff"..data.caster.."|r → |cffffffff"..data.target.."|r")
            GameTooltip:AddLine("Cast: "..date("%H:%M:%S", data.castTime), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Expires: "..date("%H:%M:%S", data.expires), 0.8, 0.8, 0.8)
            local secs = timeLeft(data.expires)
            GameTooltip:AddLine("Time left: "..string.format("%dm %02ds", math.floor(secs/60), math.mod(secs,60)), 1, 1, 0)
            GameTooltip:Show()
        end)
        hitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

        f.rows[i] = { caster=caster, arrow=arrow, target=target, timer=timer, bg=bg, hitbox=hitbox, data=nil }
    end

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
    if SoulstoneTrackerDB and SoulstoneTrackerDB.position then
        local p = SoulstoneTrackerDB.position
        f:ClearAllPoints()
        f:SetPoint(p.point, UIParent, p.rpoint, p.x, p.y)
    else
        f:SetPoint("Center", UIParent, "Center", 300, 0)
    end

    -- Restore scale
    if SoulstoneTrackerDB and SoulstoneTrackerDB.scale then
        f:SetScale(SoulstoneTrackerDB.scale)
    end

    -- Restore lock
    if SoulstoneTrackerDB and SoulstoneTrackerDB.locked then
        m.locked = true
        f.updateLock()
    end

    m.frame = f
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

    if count == 0 then f.empty:Show() else f.empty:Hide() end

    -- Warlock warning in title
    local missing = getWarlocksMissingStones()
    if table.getn(missing) > 0 and (GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0) then
        f.title:SetText("|cffffd700Soulstone Tracker|r |cffff7c0a["..table.getn(missing).." warlock(s) missing]|r")
    else
        f.title:SetText("|cffffd700Soulstone Tracker v1.0|r")
    end

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
    f:SetHeight(TITLE_H + 16 + (rows * ROW_H) + 4)
end

-------------------------------------------------------------------------------
-- Buff Scan - check existing soulstones on login/reload
-------------------------------------------------------------------------------

function m.scanForSoulstones()
    local units = {}
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            table.insert(units, "raid"..i)
        end
    else
        table.insert(units, "player")
        for i = 1, GetNumPartyMembers() do
            table.insert(units, "party"..i)
        end
    end

    local found = 0
    for _, unit in ipairs(units) do
        local name = UnitName(unit)
        if name then
            local i = 1
            while true do
                local buffName, buffRank, buffIcon, buffCount = UnitBuff(unit, i)
                if not buffName then break end
                if string.find(buffName, "Soulstone") then
                    -- vanilla WoW doesn't give expiry time from UnitBuff
                    -- so we just add it with full duration
                    if not m.stones[name] then
                        m.addStone(name, "Unknown", nil, true)
                    end
                    found = found + 1
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
        say("Loaded. |cffffd700/ss|r toggle  |cffffd700/ss test|r  |cffffd700/ss scale 0.8|r  |cffffd700/ss warlocks|r")
        -- Scan for existing soulstones after a short delay
        local scanTimer = CreateFrame("Frame")
        local scanElapsed = 0
        scanTimer:SetScript("OnUpdate", function()
            scanElapsed = scanElapsed + arg1
            if scanElapsed >= 2 then
                scanTimer:SetScript("OnUpdate", nil)
                m.scanForSoulstones()
            end
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Re-scan after zone changes/reloads
        local scanTimer = CreateFrame("Frame")
        local scanElapsed = 0
        scanTimer:SetScript("OnUpdate", function()
            scanElapsed = scanElapsed + arg1
            if scanElapsed >= 3 then
                scanTimer:SetScript("OnUpdate", nil)
                m.scanForSoulstones()
            end
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
        -- arg1=prefix, arg2=message, arg3=channel, arg4=sender
        if arg1 == ADDON_MSG_PREFIX and arg4 ~= UnitName("player") then
            if string.find(arg2, "^ADD:") then
                local _, target, caster, expires = string.match(arg2, "^(ADD):(.+):(.+):(%d+)$")
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
        m.stones = {}
        m.refresh()
        say("Cleared.")

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
            say("|cffff7c0aWarlocks without soulstone:|r |cffffffff"..table.concat(missing, ", ").."|r")
        end

    elseif cmd == "lock" then
        m.locked = not m.locked
        SoulstoneTrackerDB.locked = m.locked
        m.frame.updateLock()
        say(m.locked and "Frame locked." or "Frame unlocked.")

    elseif string.find(cmd, "^scale") then
        local val = string.match(cmd, "scale%s+([%d%.]+)")
        local scale = tonumber(val)
        if scale and scale >= 0.5 and scale <= 2.0 then
            m.frame:SetScale(scale)
            SoulstoneTrackerDB.scale = scale
            say("Scale set to "..scale)
        else
            say("Usage: /ss scale 0.5-2.0")
        end

    elseif cmd == "help" then
        say("|cffffd700Commands:|r")
        say("/ss — toggle window")
        say("/ss test — add test stone")
        say("/ss clear — clear all stones")
        say("/ss list — list active stones")
        say("/ss warlocks — show warlocks without stones")
        say("/ss lock — toggle frame lock")
        say("/ss scale 0.8 — resize (0.5-2.0)")

    else
        if m.frame and m.frame:IsVisible() then
            m.frame:Hide()
            SoulstoneTrackerDB.hidden = true
            say("Hidden.")
        else
            if not m.frame then m.createFrame() end
            m.frame:Show()
            SoulstoneTrackerDB.hidden = false
            say("Shown.")
        end
    end
end

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

local COL_CASTER_END = 0.38
local COL_ARROW      = 0.40
local COL_TARGET_END = 0.72

-- Curse tracking
local CURSES = {
    ["Curse of the Elements"]    = "CoE",
    ["Curse of Shadow"]          = "CoS",
    ["Curse of Recklessness"]    = "CoR",
    ["Curse of Weakness"]        = "CoW",
}
local CURSE_COLORS = {
    ["CoE"] = "|cffaa00ff",  -- Purple
    ["CoS"] = "|cff0099ff",  -- Blue
    ["CoR"] = "|cffff3333",  -- Red
    ["CoW"] = "|cff00cc44",  -- Green
}
local CURSE_DIVIDER_H = 14
local CURSE_ROW_H     = 16

-- Raid target icons (texture coords in UI-RaidTargetingIcons)
local RAID_ICONS = {
    { name = "Star",     coords = {0,    0.25, 0,    0.25} },
    { name = "Circle",   coords = {0.25, 0.5,  0,    0.25} },
    { name = "Diamond",  coords = {0.5,  0.75, 0,    0.25} },
    { name = "Triangle", coords = {0.75, 1,    0,    0.25} },
    { name = "Moon",     coords = {0,    0.25, 0.25, 0.5 } },
    { name = "Square",   coords = {0.25, 0.5,  0.25, 0.5 } },
    { name = "Cross",    coords = {0.5,  0.75, 0.25, 0.5 } },
    { name = "Skull",    coords = {0.75, 1,    0.25, 0.5 } },
}

m.stones   = {}
m.curses   = {}  -- { shortName = { caster } }
m.banish   = {}  -- { warlockName = raidIconIndex }
m.frame    = nil
m.settings = nil  -- settings panel frame
m.locked   = false
m.muted    = false

-- Default settings
local DEFAULTS = {
    -- Notifications
    muteChat         = false,
    muteSounds       = false,
    warnOnCast       = true,
    warnFiveMin      = true,
    warnOneMin       = true,
    warnExpired      = true,
    warnNoStones     = true,
    warnWarlocks     = true,
    -- Display
    showCurseSection  = true,
    showBanishSection = true,
    frameAlpha        = 0.95,
    -- Timing
    warnMinutes       = 5,   -- first warning threshold in minutes
    warnSeconds       = 60,  -- second warning threshold in seconds
    -- Announce
    announceOnCast   = true,
    announceExpired  = true,
    announceWarnings = true,
    announceCurse    = true,
    announceBanish   = true,
}

m.cfg = {}

-------------------------------------------------------------------------------
-- Config helpers
-------------------------------------------------------------------------------

local function cfg(key)
    if m.cfg[key] == nil then return DEFAULTS[key] end
    return m.cfg[key]
end

local function setCfg(key, val)
    m.cfg[key] = val
    if SoulstoneTrackerDB then
        SoulstoneTrackerDB.cfg = m.cfg
    end
end

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

local function sendGroup(msg)
    if cfg("muteChat") then return end
    if GetNumRaidMembers() > 0 then
        SendChatMessage(msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendChatMessage(msg, "PARTY")
    end
end

local function playSound(sound)
    if not cfg("muteSounds") then PlaySound(sound) end
end

local function hasActiveStones()
    for _ in pairs(m.stones) do return true end
    return false
end

local function getWarlocksMissingStones()
    local missing = {}
    -- Build set of targets who have a stone
    local coveredTargets = {}
    for target in pairs(m.stones) do
        coveredTargets[target] = true
    end
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            local name, _, _, _, class = GetRaidRosterInfo(i)
            if name and class == "Warlock" and not coveredTargets[name] then
                -- Check if they've cast on anyone
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
            if name and class == "Warlock" and not coveredTargets[name] then
                local hasCast = false
                for _, data in pairs(m.stones) do
                    if data.caster == name then hasCast = true break end
                end
                if not hasCast then table.insert(missing, name) end
            end
        end
        -- Check self
        local myClass = UnitClass("player")
        local myName = UnitName("player")
        if myClass == "Warlock" and not coveredTargets[myName] then
            local hasCast = false
            for _, data in pairs(m.stones) do
                if data.caster == myName then hasCast = true break end
            end
            if not hasCast then table.insert(missing, myName) end
        end
    end
    return missing
end

-------------------------------------------------------------------------------
-- Persistence
-------------------------------------------------------------------------------

local function saveAll()
    if not SoulstoneTrackerDB then return end
    local now = time()
    -- Save stones
    local saved = {}
    for target, data in pairs(m.stones) do
        if data.expires > now then
            saved[target] = { caster=data.caster, expires=data.expires, castTime=data.castTime or now, warnedFiveMin=data.warnedFiveMin, warnedOneMin=data.warnedOneMin }
        end
    end
    SoulstoneTrackerDB.stones = saved
    -- Save curses
    SoulstoneTrackerDB.curses = m.curses
    -- Save banish
    SoulstoneTrackerDB.banish = m.banish
end

local function loadAll()
    if not SoulstoneTrackerDB then return end
    -- Load stones
    if SoulstoneTrackerDB.stones then
        local now = time()
        for target, data in pairs(SoulstoneTrackerDB.stones) do
            if data.expires > now then
                m.stones[target] = { caster=data.caster, expires=data.expires, castTime=data.castTime or now, warnedFiveMin=data.warnedFiveMin or false, warnedOneMin=data.warnedOneMin or false }
            end
        end
        SoulstoneTrackerDB.stones = nil
    end
    -- Load curses
    if SoulstoneTrackerDB.curses then
        m.curses = SoulstoneTrackerDB.curses
        SoulstoneTrackerDB.curses = nil
    end
    -- Load banish
    if SoulstoneTrackerDB.banish then
        m.banish = SoulstoneTrackerDB.banish
        SoulstoneTrackerDB.banish = nil
    end
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

function m.addStone(target, caster, expires, silent, unknownExpiry)
    local exp = expires or (time() + SOULSTONE_DURATION)
    m.stones[target] = { caster=caster, expires=exp, castTime=time(), warnedFiveMin=false, warnedOneMin=false, unknownExpiry=unknownExpiry or false }
    if not silent then
        say("|cffa050ff"..caster.."|r soulstoned |cffffffff"..target.."|r")
        if cfg("warnOnCast") then playSound("SPELLBOOKCLOSE") end
        broadcastStone(target, caster, exp)
        if cfg("announceOnCast") then
            sendGroup("[Soulstone] "..caster.." -> "..target.." (30 min)")
        end
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
        local secs = data.expires - now
        -- First warning (configurable, default 5 min)
        local firstWarnSecs = cfg("warnMinutes") * 60
        if not data.warnedFiveMin and secs <= firstWarnSecs and secs > 0 then
            data.warnedFiveMin = true
            if cfg("warnFiveMin") then
                say("|cffff7c0a[WARNING]|r Soulstone on |cffffffff"..target.."|r expires in "..cfg("warnMinutes").." minutes!")
                playSound("RAID_WARNING")
                if cfg("announceWarnings") then
                    sendGroup("[Soulstone] WARNING: "..target.."'s soulstone expires in "..cfg("warnMinutes").." minutes!")
                end
            end
            m.refresh()
        end
        -- Second warning (configurable, default 60 sec)
        local secondWarnSecs = cfg("warnSeconds")
        if not data.warnedOneMin and secs <= secondWarnSecs and secs > 0 then
            data.warnedOneMin = true
            if cfg("warnOneMin") then
                say("|cffff3333[WARNING]|r Soulstone on |cffffffff"..target.."|r expires in "..cfg("warnSeconds").." seconds!")
                playSound("RAID_WARNING")
                if cfg("announceWarnings") then
                    sendGroup("[Soulstone] WARNING: "..target.."'s soulstone expires in "..cfg("warnSeconds").." seconds!")
                end
            end
            m.refresh()
        end
        -- Expired
        if now >= data.expires then
            if cfg("warnExpired") then
                say("|cffff3333[WARNING]|r Soulstone expired on |cffffffff"..target.."|r")
                playSound("LOOTCLOSE")
                if cfg("announceExpired") then
                    sendGroup("[Soulstone] "..target.."'s soulstone has expired!")
                end
            end
            m.stones[target] = nil
            changed = true
        end
    end
    if changed then
        m.refresh()
        if not hasActiveStones() and cfg("warnNoStones") then
            say("|cffff3333[WARNING]|r No active soulstones in the raid!")
            playSound("RAID_WARNING")
            if cfg("warnWarlocks") then
                local missing = getWarlocksMissingStones()
                if table.getn(missing) > 0 then
                    say("|cffff7c0aWarlocks with available SS: |cffffffff"..table.concat(missing, ", ").."|r")
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Buff Scan
-------------------------------------------------------------------------------

function m.scanForSoulstones(silent)
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
                local tex = UnitBuff(unit, i)
                if not tex then break end
                if string.find(tex, "Spell_Shadow_SoulGem") then
                    if not m.stones[name] then
                        m.addStone(name, "Unknown", nil, true, true)
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
    elseif not silent then
        say("No soulstones found on group members.")
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

    -- Background circle
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Background")
    bg:SetAllPoints(btn)

    -- Use a soulstone-themed icon that's guaranteed to exist
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\Spell_Shadow_SoulGem")
    icon:SetWidth(18)
    icon:SetHeight(18)
    icon:SetPoint("Center", btn, "Center", 0, 0)

    -- Highlight on hover
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetAllPoints(btn)
    highlight:SetBlendMode("ADD")

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
        local n = 0
        for _ in pairs(m.stones) do n = n + 1 end
        if n > 0 then
            GameTooltip:AddLine(n.." active soulstone(s)", 0, 1, 0)
        else
            GameTooltip:AddLine("No active soulstones", 0.5, 0.5, 0.5)
        end
        GameTooltip:AddLine("Click to toggle", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    m.minimap = btn
end

-------------------------------------------------------------------------------
-- Column repositioning on resize
-------------------------------------------------------------------------------

function m.repositionColumns()
    local f = m.frame
    if not f or not f.cols then return end
    local w = f:GetWidth()

    local tx = math.floor(w * COL_ARROW) + 14
    f.cols.hTarget:ClearAllPoints()
    f.cols.hTarget:SetPoint("TopLeft", f, "TopLeft", tx, -(TITLE_H + HEADER_H/2))

    for i = 1, MAX_ROWS do
        local row = f.rows[i]
        if row then
            local rowY = -(TITLE_H + HEADER_H + 2 + (i-1)*ROW_H)
            row.caster:SetWidth(math.floor(w * COL_CASTER_END) - 8)
            row.arrow:ClearAllPoints()
            row.arrow:SetPoint("TopLeft", f, "TopLeft", math.floor(w * COL_ARROW), rowY)
            row.target:ClearAllPoints()
            row.target:SetPoint("TopLeft", f, "TopLeft", tx, rowY)
            row.target:SetWidth(math.floor(w * COL_TARGET_END) - tx - 4)
            row.timer:SetWidth(w - math.floor(w * COL_TARGET_END) - 8)
        end
    end
end

-------------------------------------------------------------------------------
-- UI
-------------------------------------------------------------------------------

StaticPopupDialogs["SOULSTONETRACKER_RELOAD"] = {
    text = "SoulstoneTracker: some changes need a UI reload to fully apply. Reload now?",
    button1 = "Reload Now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Call this instead of m.settings:Hide() directly whenever the settings
-- panel is closed, so a pending reload-required change gets flagged.
function m.closeSettings()
    if not m.settings then return end
    m.settings:Hide()
    if m.settings.needsReload then
        m.settings.needsReload = false
        StaticPopup_Show("SOULSTONETRACKER_RELOAD")
    end
end

function m.onClose()
    if m.frame then
        m.frame:Hide()
        SoulstoneTrackerDB.hidden = true
    end
end

function m.onLockClick()
    m.locked = not m.locked
    SoulstoneTrackerDB.locked = m.locked
    m.frame.updateLock()
    say(m.locked and "Frame locked." or "Frame unlocked.")
end

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
        SoulstoneTrackerDB.size = { w=w, h=this:GetHeight() }
        m.repositionColumns()
    end)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TopLeft",  f, "TopLeft",  1, -1)
    titleBar:SetPoint("TopRight", f, "TopRight", -1, -1)
    titleBar:SetHeight(TITLE_H)
    titleBar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    titleBar:SetBackdropColor(0.22, 0.08, 0.38, 1)
    f.titleBar = titleBar

    local grad = titleBar:CreateTexture(nil, "OVERLAY")
    grad:SetAllPoints(titleBar)
    grad:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    grad:SetBlendMode("ADD")
    grad:SetVertexColor(0.2, 0.05, 0.4, 0.4)

    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 11, "OUTLINE")
    title:SetPoint("Left", titleBar, "Left", 6, 0)
    title:SetText("|cffffd700Soulstone Tracker v1.2|r")
    f.title = title

    -- Settings button (defined in XML with BLP texture)
    local settingsBtn = _G["SSTSettingsButton"]
    settingsBtn:SetParent(titleBar)
    settingsBtn:SetPoint("Right", titleBar, "Right", -42, 0)
    settingsBtn:Show()

    -- Scan button (pure Lua, not XML -- avoids the reload/staleness issues
    -- we hit with the XML-defined buttons).
    local scanBtn = CreateFrame("Button", nil, titleBar)
    scanBtn:SetWidth(16) scanBtn:SetHeight(16)
    scanBtn:SetPoint("Right", titleBar, "Right", -60, 0)
    local scanTex = scanBtn:CreateTexture(nil, "ARTWORK")
    scanTex:SetAllPoints(scanBtn)
    scanTex:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
    scanTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    scanBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(scanBtn, "ANCHOR_LEFT")
        GameTooltip:SetText("Scan for existing soulstones")
        GameTooltip:Show()
        scanTex:SetVertexColor(1, 1, 0.6)
    end)
    scanBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
        scanTex:SetVertexColor(1, 1, 1)
    end)
    scanBtn:SetScript("OnClick", function()
        m.scanForSoulstones()
    end)

    -- Lock button (defined in XML with BLP texture)
    local lockBtn = _G["SSTLockButton"]
    lockBtn:SetParent(titleBar)
    lockBtn:SetPoint("Right", titleBar, "Right", -24, 0)
    lockBtn:Show()

    local lockTex = _G["SSTLockButtonNT"]
    f.lockTex = lockTex

    local function updateLock()
        if m.locked then
            lockTex:SetTexture("Interface\\addons\\SoulstoneTracker\\images\\icon_locked")
        else
            lockTex:SetTexture("Interface\\addons\\SoulstoneTracker\\images\\icon_unlocked")
        end
    end
    updateLock()
    f.updateLock = updateLock

    -- X close button (defined in XML with BLP texture)
    local closeBtn = _G["SSTCloseButton"]
    closeBtn:SetParent(titleBar)
    closeBtn:SetPoint("Right", titleBar, "Right", -4, 0)
    closeBtn:Show()

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

    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TopLeft",  f, "TopLeft",  1, -(TITLE_H + HEADER_H))
    div:SetPoint("TopRight", f, "TopRight", -1, -(TITLE_H + HEADER_H))
    div:SetTexture(0.3, 0.15, 0.5, 0.8)

    local empty = f:CreateFontString(nil, "OVERLAY")
    empty:SetFont(FONT, 10, "OUTLINE")
    empty:SetTextColor(0.4, 0.4, 0.4, 1)
    empty:SetPoint("TopLeft", f, "TopLeft", 8, -(TITLE_H + HEADER_H + 3))
    empty:SetText("No active soulstones")
    f.empty = empty

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

        local tx = math.floor(w * COL_ARROW) + 14
        local target = f:CreateFontString(nil, "OVERLAY")
        target:SetFont(FONT, 11, "OUTLINE")
        target:SetPoint("TopLeft", f, "TopLeft", tx, rowY)
        target:SetWidth(math.floor(w * COL_TARGET_END) - tx - 4)
        target:SetJustifyH("Left")

        local timer = f:CreateFontString(nil, "OVERLAY")
        timer:SetFont(FONT, 11, "OUTLINE")
        timer:SetPoint("TopRight", f, "TopRight", -8, rowY)
        timer:SetWidth(w - math.floor(w * COL_TARGET_END) - 8)
        timer:SetJustifyH("Right")

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

    local SEC_ROW_H = 18

    -- Combined Warlock section (curse + banish on same row)
    local warlockDivTex = f:CreateTexture(nil, "ARTWORK")
    warlockDivTex:SetHeight(1)
    warlockDivTex:SetTexture(0.3, 0.15, 0.5, 0.8)
    f.curseDivider = warlockDivTex

    local warlockHdr = f:CreateFontString(nil, "OVERLAY")
    warlockHdr:SetFont(FONT, 8, "OUTLINE")
    warlockHdr:SetTextColor(0.6, 0.6, 0.6, 1)
    warlockHdr:SetText("CURSE AND BANISH ASSIGNMENT")
    f.curseHeader = warlockHdr

    -- One row per warlock (up to 5), shows: Name | CurseIcon | BanishIcon
    f.warlockRows = {}
    for i = 1, 5 do
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetHeight(SEC_ROW_H)
        if math.mod(i,2)==0 then bg:SetTexture(1,1,1,0.04) else bg:SetTexture(0,0,0,0) end
        bg:Hide()

        -- Warlock name
        local nameTxt = f:CreateFontString(nil, "OVERLAY")
        nameTxt:SetFont(FONT, 11, "OUTLINE")
        nameTxt:SetJustifyH("Left")
        nameTxt:Hide()

        -- Curse icon (auto-detected)
        local curseIcon = f:CreateTexture(nil, "ARTWORK")
        curseIcon:SetWidth(14)
        curseIcon:SetHeight(14)
        curseIcon:Hide()

        -- Curse label
        local curseLbl = f:CreateFontString(nil, "OVERLAY")
        curseLbl:SetFont(FONT, 10, "OUTLINE")
        curseLbl:SetJustifyH("Left")
        curseLbl:Hide()

        -- Curse override button (manual assign/correct, mirrors banish button below)
        local curseBtn = CreateFrame("Button", "SSWarlockCurse_"..i, f)
        curseBtn:SetHeight(SEC_ROW_H)
        curseBtn:SetFrameLevel(f:GetFrameLevel() + 5)
        curseBtn.rowIndex = i

        curseBtn:SetScript("OnEnter", function()
            local row = f.warlockRows[this.rowIndex]
            if not row or not row.warlockName then return end
            GameTooltip:SetOwner(curseBtn, "ANCHOR_LEFT")
            GameTooltip:SetText(row.warlockName, 0.6, 0.3, 1)
            local shortName = nil
            for sn, data in pairs(m.curses) do
                if data.caster == row.warlockName then shortName = sn break end
            end
            GameTooltip:AddLine(shortName and ("Curse: "..shortName) or "No curse detected", 1,1,0)
            GameTooltip:AddLine("Click to manually set/correct", 0.7,0.7,0.7)
            GameTooltip:Show()
        end)
        curseBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        curseBtn:SetScript("OnClick", function()
            local row = f.warlockRows[this.rowIndex]
            if not row or not row.warlockName then return end
            local wName = row.warlockName
            local menu = CreateFrame("Frame", "SSWarlockCurseMenu_"..this.rowIndex, UIParent, "UIDropDownMenuTemplate")
            UIDropDownMenu_Initialize(menu, function()
                local none = { text="-- None --", notCheckable=true }
                none.func = function()
                    for sn, data in pairs(m.curses) do
                        if data.caster == wName then m.curses[sn] = nil end
                    end
                    m.refresh()
                    say("Cleared curse assignment for "..wName..".")
                end
                UIDropDownMenu_AddButton(none)
                for fullName, shortName in pairs(CURSES) do
                    local ci = { text=fullName.." ("..shortName..")", notCheckable=true, arg1=shortName }
                    ci.func = function(sn)
                        -- Remove wName from any other curse slot first
                        for sn2, data in pairs(m.curses) do
                            if data.caster == wName and sn2 ~= sn then m.curses[sn2] = nil end
                        end
                        m.curses[sn] = { caster = wName }
                        m.refresh()
                        local msg = "[Curse] "..wName.." -> "..sn.." (manual override)"
                        say(msg)
                        local ch = GetNumRaidMembers()>0 and "RAID" or (GetNumPartyMembers()>0 and "PARTY" or nil)
                        if ch then SendAddonMessage(ADDON_MSG_PREFIX, "CURSE:"..sn..":"..wName, ch) end
                    end
                    UIDropDownMenu_AddButton(ci)
                end
            end, "MENU")
            ToggleDropDownMenu(1, nil, menu, "cursor", 0, 0)
        end)
        curseBtn:Hide()

        -- Banish icon button
        local banishBtn = CreateFrame("Button", "SSWarlockBanish_"..i, f)
        banishBtn:SetWidth(16)
        banishBtn:SetHeight(16)
        banishBtn:SetFrameLevel(f:GetFrameLevel() + 5)
        banishBtn.rowIndex = i

        local banishTex = banishBtn:CreateTexture(nil, "ARTWORK")
        banishTex:SetAllPoints(banishBtn)
        banishTex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
        banishTex:SetTexCoord(0,0,0,0)
        banishBtn.iconTex = banishTex

        local banishLbl = banishBtn:CreateFontString(nil, "OVERLAY")
        banishLbl:SetFont(FONT, 10, "OUTLINE")
        banishLbl:SetAllPoints(banishBtn)
        banishLbl:SetJustifyH("Center")
        banishLbl:SetJustifyV("Middle")
        banishLbl:SetTextColor(0.4, 0.4, 0.4, 1)
        banishLbl:SetText("-")
        banishBtn.lbl = banishLbl

        banishBtn:SetScript("OnEnter", function()
            local row = f.warlockRows[this.rowIndex]
            if not row or not row.warlockName then return end
            GameTooltip:SetOwner(banishBtn, "ANCHOR_LEFT")
            GameTooltip:SetText(row.warlockName, 0.6, 0.3, 1)
            local idx = m.banish[row.warlockName]
            GameTooltip:AddLine(idx and ("Banish: "..RAID_ICONS[idx].name) or "Click to assign banish target", 1,1,0)
            GameTooltip:Show()
        end)
        banishBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        banishBtn:SetScript("OnClick", function()
            local row = f.warlockRows[this.rowIndex]
            if not row or not row.warlockName then return end
            local wName = row.warlockName
            local menu = CreateFrame("Frame", "SSWarlockMenu_"..this.rowIndex, UIParent, "UIDropDownMenuTemplate")
            UIDropDownMenu_Initialize(menu, function()
                local none = { text="-- None --", notCheckable=true }
                none.func = function()
                    m.banish[wName] = nil
                    m.refreshBanish()
                    local ch = GetNumRaidMembers()>0 and "RAID" or (GetNumPartyMembers()>0 and "PARTY" or nil)
                    if ch then SendAddonMessage(ADDON_MSG_PREFIX, "BANISH:"..wName..":0", ch) end
                end
                UIDropDownMenu_AddButton(none)
                for idx, iconData in ipairs(RAID_ICONS) do
                    local ii = { text=iconData.name, notCheckable=true, arg1=idx }
                    ii.func = function(iconIdx)
                        m.banish[wName] = iconIdx
                        m.refreshBanish()
                        local msg = "[Banish] "..wName.." -> "..RAID_ICONS[iconIdx].name
                        say(msg)
                        local ch = GetNumRaidMembers()>0 and "RAID" or (GetNumPartyMembers()>0 and "PARTY" or nil)
                        if ch then sendGroup(msg) SendAddonMessage(ADDON_MSG_PREFIX, "BANISH:"..wName..":"..iconIdx, ch) end
                    end
                    UIDropDownMenu_AddButton(ii)
                end
            end, "MENU")
            ToggleDropDownMenu(1, nil, menu, "cursor", 0, 0)
        end)
        banishBtn:Hide()

        f.warlockRows[i] = {
            bg=bg, nameTxt=nameTxt, curseIcon=curseIcon, curseLbl=curseLbl, curseBtn=curseBtn,
            banishBtn=banishBtn, banishTex=banishTex, banishLbl=banishLbl,
            warlockName=nil
        }
    end

    -- Keep these for compatibility
    f.curseRows  = {}
    f.banishRows = {}
    f.banishDivider = f:CreateTexture(nil, "ARTWORK") -- unused but referenced
    f.banishHeader  = f:CreateFontString(nil, "OVERLAY") -- unused but referenced


    -- Resize grip
    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BottomRight", f, "BottomRight", 0, 0)
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\AddOns\\SoulstoneTracker\\ResizeGrip")
    grip:SetScript("OnEnter", function()
        GameTooltip:SetOwner(grip, "ANCHOR_LEFT")
        GameTooltip:SetText("Drag to resize", 1,1,1)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)

    -- Ticker
    local tick = 0
    local flashTime = 0
    local flashDir = 1
    f:SetScript("OnUpdate", function()
        tick = tick + arg1
        if tick >= 1 then
            tick = 0
            m.clearExpired()
            m.refresh()
        end
        local shouldFlash = false
        local now = time()
        for _, data in pairs(m.stones) do
            if data.expires - now <= 60 and data.expires - now > 0 then
                shouldFlash = true
                break
            end
        end

        if shouldFlash then
            flashTime = flashTime + arg1 * flashDir
            if flashTime >= 1 then flashDir = -1
            elseif flashTime <= 0 then flashDir = 1 end
            local r = 0.22 + (0.5 * flashTime)
            local g = 0.08 * (1 - flashTime)
            local b = 0.38 * (1 - flashTime)
            f.titleBar:SetBackdropColor(r, g, b, 1)
        else
            flashTime = 0
            flashDir = 1
            f.titleBar:SetBackdropColor(0.22, 0.08, 0.38, 1)
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

    -- Restore scale
    if SoulstoneTrackerDB.scale then
        f:SetScale(SoulstoneTrackerDB.scale)
    end

    -- Restore lock state
    if SoulstoneTrackerDB.locked then
        m.locked = true
    end

    m.frame = f
    m.repositionColumns()
    -- Apply lock state after m.frame is set
    f.updateLock()
    m.refresh()
end

function m.refresh()
    if not m.frame then return end
    local f = m.frame

    local list = {}
    for target, data in pairs(m.stones) do
        table.insert(list, { target=target, caster=data.caster, expires=data.expires, castTime=data.castTime or 0, unknownExpiry=data.unknownExpiry })
    end
    table.sort(list, function(a,b) return a.expires < b.expires end)
    local count = table.getn(list)

    local missing = getWarlocksMissingStones()
    if table.getn(missing) > 0 and (GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0) then
        f.title:SetText("|cffffd700Soulstone Tracker|r |cffff7c0a["..table.getn(missing).." available]|r")
    else
        f.title:SetText("|cffffd700Soulstone Tracker v1.2|r")
    end

    if count == 0 then f.empty:Show() else f.empty:Hide() end

    for i = 1, MAX_ROWS do
        local row  = f.rows[i]
        local data = list[i]
        if data then
            row.caster:SetText("|cffa050ff"..data.caster.."|r")
            row.arrow:SetText("->")
            row.target:SetText("|cffffffff"..data.target.."|r")
            if data.unknownExpiry then
                row.timer:SetText("|cff888888~"..formatTime(timeLeft(data.expires)).." ?|r")
            else
                row.timer:SetText(formatTime(timeLeft(data.expires)))
            end
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
    -- Height is managed by refreshBanish which accounts for all sections
    m.refreshBanish()
end

function m.refreshBanish()
    if not m.frame then return end
    local f = m.frame
    local SEC_ROW_H = 18
    local HEADER_H2 = 10

    -- Curse icons - exact paths verified from GetSpellTexture in-game
    local CURSE_ICONS = {
        ["CoE"] = "Interface\\Icons\\Spell_Shadow_ChillTouch",        -- Curse of the Elements
        ["CoS"] = "Interface\\Icons\\Spell_Shadow_CurseOfAchimonde",  -- Curse of Shadow
        ["CoR"] = "Interface\\Icons\\Spell_Shadow_UnholyStrength",    -- Curse of Recklessness
        ["CoW"] = "Interface\\Icons\\Spell_Shadow_CurseOfMannoroth",  -- Curse of Weakness
    }
    local FALLBACK_ICON = "Interface\\Icons\\Spell_Shadow_UnholyStrength"

    -- Build warlock list
    local warlocks = {}
    local playerName = UnitName("player")
    if playerName then table.insert(warlocks, playerName) end
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            local name, _, _, _, class = GetRaidRosterInfo(i)
            if name and name ~= playerName and class == "Warlock" then
                table.insert(warlocks, name)
            end
        end
    else
        for i = 1, GetNumPartyMembers() do
            local name = UnitName("party"..i)
            if name and UnitClass("party"..i) == "Warlock" then
                table.insert(warlocks, name)
            end
        end
    end

    -- Build reverse curse lookup: warlock name -> shortName
    local warlockCurse = {}
    for shortName, data in pairs(m.curses) do
        if data.caster then
            warlockCurse[data.caster] = shortName
        end
    end

    -- Count stones for base Y
    local stoneCount = 0
    for _ in pairs(m.stones) do stoneCount = stoneCount + 1 end
    local stoneRows = math.max(1, stoneCount)
    local baseY = -(TITLE_H + HEADER_H + stoneRows * ROW_H + 6)
    local curY = baseY

    local warlockCount = table.getn(warlocks)

    if not f.warlockRows then
        -- Frame height only
        f:SetHeight(TITLE_H + HEADER_H + stoneRows * ROW_H + 6)
        return
    end

    if warlockCount > 0 and cfg("showCurseSection") then
        -- Divider
        f.curseDivider:ClearAllPoints()
        f.curseDivider:SetPoint("TopLeft",  f, "TopLeft",  1, curY)
        f.curseDivider:SetPoint("TopRight", f, "TopRight", -1, curY)
        f.curseDivider:Show()
        -- Header inline on divider
        f.curseHeader:ClearAllPoints()
        f.curseHeader:SetPoint("TopLeft", f, "TopLeft", 8, curY + 5)
        f.curseHeader:Show()
        curY = curY - 2

        for i = 1, 5 do
            local row = f.warlockRows[i]
            local wName = warlocks[i]
            if row then
                row.warlockName = wName
                if wName then
                    -- Bg
                    row.bg:ClearAllPoints()
                    row.bg:SetPoint("TopLeft",  f, "TopLeft",  1, curY)
                    row.bg:SetPoint("TopRight", f, "TopRight", -1, curY)
                    row.bg:SetHeight(SEC_ROW_H)
                    row.bg:Show()

                    -- Name
                    row.nameTxt:ClearAllPoints()
                    row.nameTxt:SetPoint("TopLeft", f, "TopLeft", 8, curY - 2)
                    row.nameTxt:SetWidth(f:GetWidth() * 0.5)
                    row.nameTxt:SetText("|cffa050ff"..wName.."|r")
                    row.nameTxt:Show()

                    -- Curse info (centered in row)
                    local shortName = warlockCurse[wName]
                    if shortName then
                        row.curseIcon:ClearAllPoints()
                        row.curseIcon:SetPoint("TopLeft", f, "TopLeft", math.floor(f:GetWidth() * 0.45), curY - 2)
                        row.curseIcon:SetTexture(CURSE_ICONS[shortName] or "Interface\\Icons\\Spell_Shadow_Curse")
                        row.curseIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        row.curseIcon:Show()
                        row.curseLbl:ClearAllPoints()
                        row.curseLbl:SetPoint("TopLeft", f, "TopLeft", math.floor(f:GetWidth() * 0.45) + 18, curY - 2)
                        row.curseLbl:SetText((CURSE_COLORS[shortName] or "|cffffffff")..shortName.."|r")
                        row.curseLbl:Show()
                    else
                        row.curseIcon:Hide()
                        row.curseLbl:ClearAllPoints()
                        row.curseLbl:SetPoint("TopLeft", f, "TopLeft", math.floor(f:GetWidth() * 0.45), curY - 2)
                        row.curseLbl:SetText("|cff666666-|r")
                        row.curseLbl:Show()
                    end

                    -- Curse override hitbox (covers icon+label area, click to manually set)
                    row.curseBtn:ClearAllPoints()
                    row.curseBtn:SetPoint("TopLeft", f, "TopLeft", math.floor(f:GetWidth() * 0.45) - 2, curY - 2)
                    row.curseBtn:SetWidth(48)
                    row.curseBtn:Show()

                    -- Banish icon button (right side, moved in from edge)
                    row.banishBtn:ClearAllPoints()
                    row.banishBtn:SetPoint("TopRight", f, "TopRight", -24, curY - 1)
                    row.banishBtn:Show()
                    local iconIdx = m.banish[wName]
                    if iconIdx and RAID_ICONS[iconIdx] then
                        local c = RAID_ICONS[iconIdx].coords
                        row.banishTex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
                        row.banishTex:SetTexCoord(c[1], c[2], c[3], c[4])
                        row.banishLbl:SetText("")
                    else
                        row.banishTex:SetTexCoord(0,0,0,0)
                        row.banishLbl:SetText("|cffaaaaaa-|r")
                    end

                    curY = curY - SEC_ROW_H
                else
                    row.warlockName = nil
                    row.bg:Hide() row.nameTxt:Hide()
                    row.curseIcon:Hide() row.curseLbl:Hide() row.curseBtn:Hide()
                    row.banishBtn:Hide()
                end
            end
        end
    else
        f.curseDivider:Hide()
        f.curseHeader:Hide()
        for i = 1, 5 do
            local row = f.warlockRows[i]
            if row then
                row.bg:Hide() row.nameTxt:Hide()
                row.curseIcon:Hide() row.curseLbl:Hide() row.curseBtn:Hide()
                row.banishBtn:Hide()
            end
        end
    end

    -- Resize
    local totalH = TITLE_H + HEADER_H + (stoneRows * ROW_H) + 6 + math.abs(curY - baseY)
    f:SetHeight(totalH)
end

-------------------------------------------------------------------------------
-- Curse tracking
-------------------------------------------------------------------------------

local lastCurseCaster = nil

local SHORT_NAMES = {
    ["Curse of the Elements"]  = "CoE",
    ["Curse of Shadow"]        = "CoS",
    ["Curse of Recklessness"]  = "CoR",
    ["Curse of Weakness"]      = "CoW",
}

-- Reverse lookup: shortName -> fullName, so SPELL_GO_SELF (which gives us a
-- spellID, not text) can still feed detectCurse()'s existing message-based
-- logic unchanged.
local FULL_NAMES = {}
for full, short in pairs(SHORT_NAMES) do FULL_NAMES[short] = full end

-- Curse spellIDs confirmed live via SPELL_GO_SELF on this server (Turtle/
-- OctoWow's client lacks GetSpellInfo, so these can't be looked up
-- generically -- only whichever ranks are actually reported get added).
-- If a warlock with an untracked rank casts a curse, add their reported ID
-- here rather than falling back to guessing.
local CURSE_SPELL_IDS = {
    [702]   = "CoW", -- Curse of Weakness
    [17937] = "CoS", -- Curse of Shadow
    [11722] = "CoE", -- Curse of the Elements
    [11717] = "CoR", -- Curse of Recklessness
}

function m.detectCurse(msg, caster)
    for fullName, shortName in pairs(SHORT_NAMES) do
        if string.find(msg, fullName) then
            local casterName = caster or UnitName("player")
            -- Only update if:
            -- 1. This curse has no caster yet, OR
            -- 2. The same warlock is casting it (already assigned to them), OR
            -- 3. The caster previously had a different curse (they switched)
            local existing = m.curses[shortName]
            local casterPrevCurse = nil
            for sn, data in pairs(m.curses) do
                if data.caster == casterName then
                    casterPrevCurse = sn
                    break
                end
            end

            local shouldUpdate = false
            if not existing then
                -- New curse not yet tracked
                shouldUpdate = true
            elseif existing.caster == casterName then
                -- Same warlock recasting the same curse -- nothing actually
                -- changed (no timestamp is tracked per-curse), so skip the
                -- announce/broadcast entirely to avoid repeat noise.
                shouldUpdate = false
            end
            -- If another warlock already has this curse slot, don't overwrite

            -- Clear the caster's previous curse whenever they're switching to
            -- a different one, regardless of whether the new curse is
            -- already tracked -- this used to only run in one of the three
            -- branches above, so switching to an untracked curse left the
            -- old assignment stuck forever and never told other clients.
            if casterPrevCurse and casterPrevCurse ~= shortName then
                m.curses[casterPrevCurse] = nil
                shouldUpdate = true
                local channel = GetNumRaidMembers() > 0 and "RAID" or (GetNumPartyMembers() > 0 and "PARTY" or nil)
                if channel then
                    SendAddonMessage(ADDON_MSG_PREFIX, "CURSEREM:"..casterPrevCurse, channel)
                end
            end

            if shouldUpdate then
                m.curses[shortName] = { caster = casterName }
                say((CURSE_COLORS[shortName] or "|cffffffff")..shortName.."|r detected — cast by |cffa050ff"..casterName.."|r")
                if cfg("announceCurse") then
                    sendGroup("[Curse] "..casterName.." is on "..shortName.." ("..fullName..")")
                end
                local channel = GetNumRaidMembers() > 0 and "RAID" or (GetNumPartyMembers() > 0 and "PARTY" or nil)
                if channel then
                    SendAddonMessage(ADDON_MSG_PREFIX, "CURSE:"..shortName..":"..casterName, channel)
                    -- Addon messages over RAID scope can occasionally get
                    -- dropped (a known vanilla-era limitation, not something
                    -- fixable in code) -- send a redundant follow-up after a
                    -- short delay so a single lost packet doesn't leave
                    -- other clients out of sync. Idempotent to repeat.
                    local resendTimer = CreateFrame("Frame")
                    local elapsed = 0
                    resendTimer:SetScript("OnUpdate", function()
                        elapsed = elapsed + arg1
                        if elapsed >= 1.5 then
                            resendTimer:SetScript("OnUpdate", nil)
                            local ch = GetNumRaidMembers() > 0 and "RAID" or (GetNumPartyMembers() > 0 and "PARTY" or nil)
                            if ch and m.curses[shortName] and m.curses[shortName].caster == casterName then
                                SendAddonMessage(ADDON_MSG_PREFIX, "CURSE:"..shortName..":"..casterName, ch)
                            end
                        end
                    end)
                end
                m.refreshBanish()
            end
            return true
        end
    end
    return false
end

function m.removeCurse(msg)
    for fullName, shortName in pairs(SHORT_NAMES) do
        if string.find(msg, fullName) then
            -- Only remove locally if THIS client's own player is the one
            -- who cast it. AURA_GONE events aren't reliably self-scoped --
            -- they can fire from fade/replace text visible near a shared
            -- target regardless of who's tracking it, which was wiping out
            -- another warlock's correctly-synced curse entry. Removal for
            -- another warlock's curse should come from their own client's
            -- sync instead, not from ambient combat text here.
            local existing = m.curses[shortName]
            if existing and existing.caster == UnitName("player") then
                m.curses[shortName] = nil
                m.refresh()
            end
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Settings Panel
-------------------------------------------------------------------------------

function m.toggleSettings()
    if m.settings and m.settings:IsVisible() then
        m.closeSettings()
        return
    end
    if not m.settings then
        m.createSettings()
    end
    m.settings:Show()
    m.refreshSettings()
end

function m.createSettings()
    local SW, SH = 320, 420
    local s = CreateFrame("Frame", "SoulstoneTrackerSettings", UIParent)
    s:SetWidth(SW)
    s:SetHeight(SH)
    s:SetFrameStrata("HIGH")
    s:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets   = { left=1, right=1, top=1, bottom=1 }
    })
    s:SetBackdropColor(0.05, 0.05, 0.08, 0.98)
    s:SetBackdropBorderColor(0.4, 0.2, 0.6, 1)
    s:SetMovable(true)
    s:EnableMouse(true)
    s:RegisterForDrag("LeftButton")
    s:SetScript("OnDragStart", function() this:StartMoving() end)
    s:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    s:SetClampedToScreen(true)

    -- Position next to main frame
    if m.frame then
        s:SetPoint("TopLeft", m.frame, "TopRight", 4, 0)
    else
        s:SetPoint("Center", UIParent, "Center", 0, 0)
    end

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, s)
    titleBar:SetPoint("TopLeft",  s, "TopLeft",  1, -1)
    titleBar:SetPoint("TopRight", s, "TopRight", -1, -1)
    titleBar:SetHeight(22)
    titleBar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    titleBar:SetBackdropColor(0.22, 0.08, 0.38, 1)

    local grad = titleBar:CreateTexture(nil, "OVERLAY")
    grad:SetAllPoints(titleBar)
    grad:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    grad:SetBlendMode("ADD")
    grad:SetVertexColor(0.2, 0.05, 0.4, 0.4)

    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    title:SetPoint("Left", titleBar, "Left", 6, 0)
    title:SetText("|cffffd700Soulstone Tracker — Settings|r")

    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetWidth(18) closeBtn:SetHeight(18)
    closeBtn:SetPoint("Right", titleBar, "Right", -4, 0)
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY")
    closeTxt:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    closeTxt:SetAllPoints(closeBtn) closeTxt:SetJustifyH("Center") closeTxt:SetJustifyV("Middle")
    closeTxt:SetText("|cffaaaaaaX|r")
    closeBtn:SetScript("OnEnter", function() closeTxt:SetText("|cffffffffX|r") end)
    closeBtn:SetScript("OnLeave", function() closeTxt:SetText("|cffaaaaaaX|r") end)
    closeBtn:SetScript("OnClick", function() m.closeSettings() end)

    -- Helper to create a toggle checkbox row
    local function makeToggle(parent, label, key, yOff)
        local cb = CreateFrame("Button", nil, parent)
        cb:SetWidth(14) cb:SetHeight(14)
        cb:SetPoint("TopLeft", parent, "TopLeft", 10, yOff)

        local box = cb:CreateTexture(nil, "ARTWORK")
        box:SetAllPoints(cb)
        box:SetTexture("Interface\\Buttons\\WHITE8X8")
        box:SetVertexColor(0.15, 0.15, 0.2, 1)

        local check = cb:CreateTexture(nil, "OVERLAY")
        check:SetAllPoints(cb)
        check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        check:SetVertexColor(0.6, 0.3, 1, 1)

        local lbl = parent:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        lbl:SetPoint("Left", cb, "Right", 6, 0)
        lbl:SetText(label)
        lbl:SetTextColor(0.85, 0.85, 0.85, 1)

        cb.check = check
        cb.key   = key
        cb:SetScript("OnClick", function()
            local cur = cfg(this.key)
            setCfg(this.key, not cur)
            if not cur then this.check:Show() else this.check:Hide() end
            if m.frame then m.refreshBanish() end
        end)
        cb:SetScript("OnEnter", function() box:SetVertexColor(0.25, 0.15, 0.35, 1) end)
        cb:SetScript("OnLeave", function() box:SetVertexColor(0.15, 0.15, 0.2, 1) end)

        return cb
    end

    -- Helper for section header
    local function makeHeader(parent, text, yOff)
        local div = parent:CreateTexture(nil, "ARTWORK")
        div:SetHeight(1)
        div:SetPoint("TopLeft",  parent, "TopLeft",  6, yOff)
        div:SetPoint("TopRight", parent, "TopRight", -6, yOff)
        div:SetTexture(0.3, 0.15, 0.5, 0.8)

        local hdr = parent:CreateFontString(nil, "OVERLAY")
        hdr:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        hdr:SetTextColor(0.7, 0.5, 1, 1)
        hdr:SetPoint("TopLeft", parent, "TopLeft", 10, yOff + 5)
        hdr:SetText(text)
        return hdr
    end

    -- Helper for number input
    local function makeSlider(parent, label, key, minV, maxV, step, yOff)
        local lbl = parent:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        lbl:SetTextColor(0.85, 0.85, 0.85, 1)
        lbl:SetPoint("TopLeft", parent, "TopLeft", 10, yOff)
        lbl:SetText(label)

        local valLbl = parent:CreateFontString(nil, "OVERLAY")
        valLbl:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        valLbl:SetTextColor(0.6, 0.3, 1, 1)
        valLbl:SetPoint("TopRight", parent, "TopRight", -10, yOff)
        valLbl:SetJustifyH("Right")

        local sliderName = "SSTracker_Slider_"..key
        local slider = CreateFrame("Slider", sliderName, parent, "OptionsSliderTemplate")
        slider:SetWidth(SW - 30)
        slider:SetHeight(16)
        slider:SetPoint("TopLeft", parent, "TopLeft", 10, yOff - 14)
        slider:SetMinMaxValues(minV, maxV)
        slider:SetValueStep(step)
        slider:SetValue(cfg(key))
        getglobal(sliderName.."Low"):SetText(tostring(minV))
        getglobal(sliderName.."High"):SetText(tostring(maxV))
        local sliderText = getglobal(sliderName.."Text")
        sliderText:SetText(tostring(cfg(key)))
        sliderText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        slider.key = key
        slider.valLbl = valLbl
        slider:SetScript("OnValueChanged", function()
            local v = math.floor(this:GetValue() / step + 0.5) * step
            setCfg(this.key, v)
            getglobal(this:GetName().."Text"):SetText(tostring(v))
            this.valLbl:SetText(tostring(v))
        end)
        valLbl:SetText(tostring(cfg(key)))
        return slider
    end

    -- Helper for action button
    local function makeButton(parent, label, onClick, yOff)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetWidth(SW - 20) btn:SetHeight(20)
        btn:SetPoint("TopLeft", parent, "TopLeft", 10, yOff)
        btn:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Buttons\\WHITE8X8", edgeSize=1, insets={left=1,right=1,top=1,bottom=1} })
        btn:SetBackdropColor(0.15, 0.08, 0.25, 1)
        btn:SetBackdropBorderColor(0.4, 0.2, 0.6, 0.8)
        local txt = btn:CreateFontString(nil, "OVERLAY")
        txt:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        txt:SetAllPoints(btn) txt:SetJustifyH("Center") txt:SetJustifyV("Middle")
        txt:SetText(label)
        txt:SetTextColor(0.85, 0.85, 0.85, 1)
        btn:SetScript("OnEnter", function() btn:SetBackdropColor(0.25, 0.12, 0.4, 1) end)
        btn:SetScript("OnLeave", function() btn:SetBackdropColor(0.15, 0.08, 0.25, 1) end)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    -- Store checkboxes for refresh
    s.checks = {}
    s.needsReload = false
    local y = -28

    -- NOTIFICATIONS section
    makeHeader(s, "NOTIFICATIONS", y) y = y - 14
    s.checks["warnOnCast"]    = makeToggle(s, "Play sound on soulstone cast",       "warnOnCast",    y) y = y - 18
    s.checks["warnFiveMin"]   = makeToggle(s, "Warn when soulstone nears expiry",    "warnFiveMin",   y) y = y - 18
    s.checks["warnOneMin"]    = makeToggle(s, "Warn at final countdown",             "warnOneMin",    y) y = y - 18
    s.checks["warnExpired"]   = makeToggle(s, "Alert when soulstone expires",        "warnExpired",   y) y = y - 18
    s.checks["warnNoStones"]  = makeToggle(s, "Alert when no stones remain",         "warnNoStones",  y) y = y - 18
    s.checks["warnWarlocks"]  = makeToggle(s, "List warlocks with available SS",     "warnWarlocks",  y) y = y - 24

    -- SOUNDS section
    makeHeader(s, "SOUNDS", y) y = y - 14
    s.checks["muteSounds"]    = makeToggle(s, "Mute all sounds",                     "muteSounds",    y) y = y - 24

    -- RAID CHAT section
    makeHeader(s, "RAID CHAT ANNOUNCEMENTS", y) y = y - 14
    s.checks["muteChat"]         = makeToggle(s, "Mute all raid chat",               "muteChat",         y) y = y - 18
    s.checks["announceOnCast"]   = makeToggle(s, "Announce soulstone casts",         "announceOnCast",   y) y = y - 18
    s.checks["announceWarnings"] = makeToggle(s, "Announce expiry warnings",         "announceWarnings", y) y = y - 18
    s.checks["announceExpired"]  = makeToggle(s, "Announce when stone expires",      "announceExpired",  y) y = y - 18
    s.checks["announceCurse"]    = makeToggle(s, "Announce curse assignments",       "announceCurse",    y) y = y - 18
    s.checks["announceBanish"]   = makeToggle(s, "Announce banish assignments",      "announceBanish",   y) y = y - 24

    -- DISPLAY section
    makeHeader(s, "DISPLAY", y) y = y - 14
    s.checks["showCurseSection"]  = makeToggle(s, "Show curse & banish section",     "showCurseSection",  y) y = y - 24

    -- TIMING section
    makeHeader(s, "WARNING THRESHOLDS", y) y = y - 14
    s.warnMinSlider = makeSlider(s, "First warning (minutes):", "warnMinutes", 1, 15, 1, y) y = y - 36
    s.warnSecSlider = makeSlider(s, "Final warning (seconds):", "warnSeconds", 15, 120, 5, y) y = y - 40

    -- ACTION BUTTONS
    makeHeader(s, "ACTIONS", y) y = y - 14
    makeButton(s, "Clear all soulstones", function()
        m.stones = {} m.refresh() say("Cleared all soulstones.")
    end, y) y = y - 26
    makeButton(s, "Clear curse assignments", function()
        m.curses = {} m.refreshBanish() say("Cleared curse assignments.")
    end, y) y = y - 26
    makeButton(s, "Clear banish assignments", function()
        m.banish = {} m.refreshBanish() say("Cleared banish assignments.")
    end, y) y = y - 26
    makeButton(s, "Scan group for soulstones", function()
        m.scanForSoulstones()
    end, y) y = y - 26
    makeButton(s, "Reset position & size", function()
        SoulstoneTrackerDB.position = nil
        SoulstoneTrackerDB.size = nil
        s.needsReload = true
        say("Position reset. Reload to apply.")
    end, y)

    s:SetHeight(math.abs(y) + 30)
    s:Hide()
    m.settings = s
end

function m.refreshSettings()
    if not m.settings then return end
    local s = m.settings
    for key, cb in pairs(s.checks) do
        if cb.check then
            if cfg(key) then cb.check:Show() else cb.check:Hide() end
        end
    end
    if s.warnMinSlider then
        s.warnMinSlider:SetValue(cfg("warnMinutes"))
        getglobal(s.warnMinSlider:GetName().."Text"):SetText(tostring(cfg("warnMinutes")))
    end
    if s.warnSecSlider then
        s.warnSecSlider:SetValue(cfg("warnSeconds"))
        getglobal(s.warnSecSlider:GetName().."Text"):SetText(tostring(cfg("warnSeconds")))
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

-- Track last caster per target using addon messages
-- When YOU cast soulstone, SPELLCAST_START fires, then CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS
-- When OTHERS cast, we only get the buff gain message with no caster info
-- Solution: broadcast via addon message with caster info, and use target unit scanning

local lastCaster = nil

local eFrame = CreateFrame("Frame")
eFrame:RegisterEvent("PLAYER_LOGIN")
eFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
eFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eFrame:RegisterEvent("SPELLCAST_START")
eFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")
eFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS")
eFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS")
eFrame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_SELF")
eFrame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_OTHER")
eFrame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")
eFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF")
eFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
eFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE")
eFrame:RegisterEvent("CHAT_MSG_SPELL_DAMAGESHIELDS_SELF")
eFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
eFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
eFrame:RegisterEvent("CHAT_MSG_ADDON")
-- Reliable curse self-detection via nampower, if available. SPELL_GO_SELF
-- is guaranteed to only ever fire for spells the local player casts -- no
-- ambiguous chat-text parsing, unlike the CHAT_MSG_SPELL_* fallback below.
local hasNampower = (GetNampowerVersion ~= nil)
if hasNampower then
    eFrame:RegisterEvent("SPELL_GO_SELF")
end

eFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        SoulstoneTrackerDB = SoulstoneTrackerDB or {}
        -- Load config
        if SoulstoneTrackerDB.cfg then
            m.cfg = SoulstoneTrackerDB.cfg
        end
        loadAll()
        m.createFrame()
        m.createMinimapButton()
        if SoulstoneTrackerDB.hidden then m.frame:Hide() else m.frame:Show() end
        if SoulstoneTrackerDB.locked then m.locked = true m.frame.updateLock() end
        m.refreshBanish()
        say("Loaded. Type |cffffd700/ss help|r for commands.")
        local t = CreateFrame("Frame") local e = 0
        t:SetScript("OnUpdate", function()
            e = e + arg1
            if e >= 2 then
                t:SetScript("OnUpdate", nil)
                m.scanForSoulstones()
                -- Request sync from others with the addon
                local channel = GetNumRaidMembers() > 0 and "RAID" or (GetNumPartyMembers() > 0 and "PARTY" or nil)
                if channel then
                    SendAddonMessage(ADDON_MSG_PREFIX, "SYNCREQ", channel)
                end
            end
        end)

    elseif event == "PLAYER_LEAVING_WORLD" then
        saveAll()

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        m.refreshBanish()
        -- Debounced scan for existing soulstones on newly-joined members --
        -- without this, a stone already active on someone who just joined
        -- your group wouldn't be picked up until next login/zone change.
        -- Silent unless it actually finds something, and coalesces rapid
        -- roster churn (e.g. several people joining a raid in quick
        -- succession) into a single scan instead of one per event.
        if m.__rosterScanTimer then
            m.__rosterScanTimer:SetScript("OnUpdate", nil)
        end
        local t = CreateFrame("Frame")
        m.__rosterScanTimer = t
        local e = 0
        t:SetScript("OnUpdate", function()
            e = e + arg1
            if e >= 2 then
                t:SetScript("OnUpdate", nil)
                m.scanForSoulstones(true)
                -- Ask others with the addon to resend their accurate data --
                -- this is what lets a scanned "Unknown"/estimated stone get
                -- corrected once the real caster's client responds. Without
                -- this, joining a raid mid-session (unlike login, which
                -- already does this) would leave scanned entries permanently
                -- estimated.
                local channel = GetNumRaidMembers() > 0 and "RAID" or (GetNumPartyMembers() > 0 and "PARTY" or nil)
                if channel then
                    SendAddonMessage(ADDON_MSG_PREFIX, "SYNCREQ", channel)
                end
            end
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        if m.frame then
            local t = CreateFrame("Frame") local e = 0
            t:SetScript("OnUpdate", function()
                e = e + arg1
                if e >= 3 then t:SetScript("OnUpdate", nil) m.scanForSoulstones() end
            end)
        end

    elseif event == "SPELLCAST_START" then
        -- Only fires for player's own casts
        if arg1 and string.find(arg1, "Soulstone Resurrection") then
            lastCaster = UnitName("player")
            -- Broadcast that we're casting so others know the caster
            if GetNumRaidMembers() > 0 then
                SendAddonMessage(ADDON_MSG_PREFIX, "CASTING:"..UnitName("player")..">"..UnitName("target"), "RAID")
            elseif GetNumPartyMembers() > 0 then
                SendAddonMessage(ADDON_MSG_PREFIX, "CASTING:"..UnitName("player")..">"..UnitName("target"), "PARTY")
            end
        end
        -- Track curse caster (you casting)
        for fullName in pairs(SHORT_NAMES) do
            if arg1 and string.find(arg1, fullName) then
                lastCurseCaster = UnitName("player")
                break
            end
        end

    elseif event == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" then
        -- "You gain Soulstone Resurrection (1)." - you received a soulstone
        -- Only apply locally if we're confident who cast it (lastCaster set
        -- via our own SPELLCAST_START, or received via the CASTING: sync).
        -- Otherwise skip rather than guessing "Unknown" and broadcasting a
        -- wrong/premature attribution that could race the real caster's own.
        if arg1 and string.find(arg1, "Soulstone Resurrection") and lastCaster then
            m.addStone(UnitName("player"), lastCaster)
            lastCaster = nil
        end

    elseif event == "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS"
        or event == "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS" then
        -- "Playername gains Soulstone Resurrection (1)."
        if arg1 then
            local target = string.match(arg1, "(.+) gains Soulstone Resurrection")
            if target and lastCaster then
                m.addStone(target, lastCaster)
                lastCaster = nil
            end
        end

    elseif event == "CHAT_MSG_SPELL_AURA_GONE_SELF" then
        if arg1 and string.find(arg1, "Soulstone Resurrection") then
            m.removeStone(UnitName("player"))
        end
        m.removeCurse(arg1 or "")

    elseif event == "CHAT_MSG_SPELL_AURA_GONE_OTHER" then
        if arg1 then
            local target = string.match(arg1, "Soulstone Resurrection fades from (.+)%.")
            if target then m.removeStone(target) end
            m.removeCurse(arg1)
        end

    elseif event == "SPELL_GO_SELF" then
        -- itemId, spellID, casterGuid, targetGuid, castFlags, numTargetsHit, numTargetsMissed
        local spellID = arg2
        local shortName = spellID and CURSE_SPELL_IDS[spellID]
        if shortName then
            -- Guaranteed self-scoped by nampower, so always safe to
            -- attribute directly to the local player.
            m.detectCurse(FULL_NAMES[shortName], UnitName("player"))
        end

    elseif event == "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF"
        or event == "CHAT_MSG_SPELL_SELF_DAMAGE"
        or event == "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE"
        or event == "CHAT_MSG_SPELL_DAMAGESHIELDS_SELF"
        or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE"
        or event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE" then
        -- When nampower is available, SPELL_GO_SELF above is the reliable
        -- source of truth for local curse casts, so this ambiguous
        -- chat-text fallback is skipped entirely to avoid the cross-warlock
        -- misattribution these shared-visibility channels can cause. This
        -- does mean a curse rank not yet in CURSE_SPELL_IDS above simply
        -- won't register -- add its spellID there rather than re-enabling
        -- this fallback. Without nampower at all, use best-effort behavior.
        if arg1 and not hasNampower then
            m.detectCurse(arg1, lastCurseCaster or UnitName("player"))
            lastCurseCaster = nil
        end

    elseif event == "CHAT_MSG_COMBAT_FRIENDLY_DEATH" then
        if arg1 then
            local dead = string.match(arg1, "(.+) dies%.")
            if dead and m.stones[dead] then m.removeStone(dead) end
        end

    elseif event == "CHAT_MSG_ADDON" then
        -- arg1=prefix arg2=message arg3=channel arg4=sender
        if arg1 == ADDON_MSG_PREFIX then
            if string.find(arg2, "^CASTING:") then
                local rest = string.sub(arg2, 9) -- strip leading "CASTING:" (8 chars)
                local gtPos = string.find(rest, ">", 1, true)
                local caster = gtPos and string.sub(rest, 1, gtPos - 1)
                local target = gtPos and string.sub(rest, gtPos + 1)
                if caster and target and caster ~= "" and target ~= "" and arg4 ~= UnitName("player") then
                    lastCaster = caster
                end
            elseif string.find(arg2, "^ADD:") then
                local rest = string.sub(arg2, 5) -- strip leading "ADD:" (4 chars)
                local p1 = string.find(rest, ":", 1, true)
                local target = p1 and string.sub(rest, 1, p1 - 1)
                local rest2 = p1 and string.sub(rest, p1 + 1)
                local p2 = rest2 and string.find(rest2, ":", 1, true)
                local caster = p2 and string.sub(rest2, 1, p2 - 1)
                local expires = p2 and string.sub(rest2, p2 + 1)
                if target and caster and expires and target ~= "" and caster ~= "" and expires ~= "" and arg4 ~= UnitName("player") then
                    m.addStone(target, caster, tonumber(expires), true)
                end
            elseif string.find(arg2, "^REM:") then
                local target = string.sub(arg2, 5) -- strip leading "REM:" (4 chars)
                if target and target ~= "" then m.removeStone(target, true) end
            elseif string.find(arg2, "^BANISH:") then
                local rest = string.sub(arg2, 8) -- strip leading "BANISH:" (7 chars)
                local colonPos = string.find(rest, ":", 1, true)
                local wName = colonPos and string.sub(rest, 1, colonPos - 1)
                local iconIdx = colonPos and string.sub(rest, colonPos + 1)
                if wName and iconIdx and wName ~= "" and iconIdx ~= "" and arg4 ~= UnitName("player") then
                    local idx = tonumber(iconIdx)
                    if idx == 0 then
                        m.banish[wName] = nil
                    else
                        m.banish[wName] = idx
                    end
                    m.refreshBanish()
                end
            elseif string.find(arg2, "^CURSE:") then
                local rest = string.sub(arg2, 7) -- strip leading "CURSE:" (6 chars)
                local colonPos = string.find(rest, ":", 1, true)
                local shortName = colonPos and string.sub(rest, 1, colonPos - 1)
                local caster = colonPos and string.sub(rest, colonPos + 1)
                if shortName and caster and shortName ~= "" and caster ~= "" and arg4 ~= UnitName("player") then
                    m.curses[shortName] = { caster=caster }
                    m.refresh()
                end
            elseif string.find(arg2, "^CURSEREM:") then
                local shortName = string.sub(arg2, 10) -- strip leading "CURSEREM:" (9 chars)
                if shortName and shortName ~= "" and arg4 ~= UnitName("player") then
                    m.curses[shortName] = nil
                    m.refresh()
                end
            elseif arg2 == "SYNCREQ" and arg4 ~= UnitName("player") then
                -- Someone is requesting our stone data - send all our stones
                -- (except our own uncertain scanned entries -- those
                -- shouldn't propagate and risk overwriting someone else's
                -- accurate value with a guess)
                local channel = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
                for target, data in pairs(m.stones) do
                    if data.expires > time() and not data.unknownExpiry then
                        SendAddonMessage(ADDON_MSG_PREFIX, "ADD:"..target..":"..data.caster..":"..data.expires, channel)
                    end
                end
                -- Also sync banish assignments
                for wName, iconIdx in pairs(m.banish) do
                    SendAddonMessage(ADDON_MSG_PREFIX, "BANISH:"..wName..":"..iconIdx, channel)
                end
                -- Also sync curses
                for shortName, data in pairs(m.curses) do
                    SendAddonMessage(ADDON_MSG_PREFIX, "CURSE:"..shortName..":"..data.caster, channel)
                end
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
        m.stones = {} m.refresh() say("Cleared all soulstones.")

    elseif string.find(cmd, "^testcurse") then
        local sn, caster = string.match(args, "%a+%s+(%a+)%s*(%a*)")
        sn = sn or "CoE"
        local CURSE_LOOKUP = { coe="CoE", cos="CoS", cor="CoR", cow="CoW" }
        sn = CURSE_LOOKUP[string.lower(sn)] or sn
        if not CURSE_COLORS[sn] then
            say("Unknown curse short name |cffffffff"..sn.."|r. Use one of: |cffffd700CoE, CoS, CoR, CoW|r")
        else
            caster = (caster ~= "" and caster) or UnitName("player")
            -- Injects directly into m.curses exactly like the CHAT_MSG_ADDON
            -- "CURSE:" receive-branch does, to simulate a sync arriving from
            -- another player without needing a second client.
            m.curses[sn] = { caster = caster }
            m.refresh()
            say("Simulated sync: |cffa050ff"..caster.."|r -> "..(CURSE_COLORS[sn] or "|cffffffff")..sn.."|r (as if received from another player)")
            -- The curse/banish section only draws a row for your own name or
            -- an actual Warlock currently in your raid/party, so a made-up
            -- name won't visibly appear even though it's tracked internally.
            if caster ~= UnitName("player") then
                local isRealWarlock = false
                local numRaid = GetNumRaidMembers()
                if numRaid > 0 then
                    for i = 1, numRaid do
                        local n, _, _, _, class = GetRaidRosterInfo(i)
                        if n == caster and class == "Warlock" then isRealWarlock = true break end
                    end
                else
                    for i = 1, GetNumPartyMembers() do
                        if UnitName("party"..i) == caster and UnitClass("party"..i) == "Warlock" then
                            isRealWarlock = true break
                        end
                    end
                end
                if not isRealWarlock then
                    say("|cffff7c0aNote:|r "..caster.." isn't a Warlock in your current group, so no row will show for them. Use your own name or an actual grouped warlock to see it rendered.")
                end
            end
        end

    elseif string.find(cmd, "^testcast") then
        local target, caster, secs = string.match(args, "%a+%s+(%a+)%s*(%a*)%s*(%d*)")
        if not target then
            say("Usage: |cffffd700/ss testcast <target> [caster] [seconds]|r")
        else
            caster = (caster ~= "" and caster) or UnitName("player")
            local duration = (secs ~= "" and tonumber(secs)) or (30 * 60)
            m.addStone(target, caster, time() + duration)
            say("Test stone: |cffa050ff"..caster.."|r -> |cffffffff"..target.."|r ("..duration.."s)")
        end

    elseif string.find(cmd, "^test") then
        local secs = string.match(cmd, "test%s+(%d+)")
        local duration = tonumber(secs) or (30 * 60)
        m.addStone(UnitName("player"), UnitName("player"), time() + duration)
        if secs then
            say("Test stone added with "..secs.."s duration.")
        else
            say("Test stone added. Use |cffffd700/ss test 90|r to test with 90 seconds.")
        end

    elseif cmd == "scan" then
        m.scanForSoulstones()

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

    elseif cmd == "diag" then
        -- On-demand diagnostic: reveal exact string contents (including
        -- hidden whitespace or realm suffixes) of both the roster-derived
        -- warlock names and the synced curse caster names, since they can
        -- look identical on screen but fail an exact string match in code.
        local playerName = UnitName("player")
        say("|cff00ff00[DIAG]|r player = "..string.format("%q", playerName))
        local numRaid = GetNumRaidMembers()
        if numRaid > 0 then
            for i = 1, numRaid do
                local name, _, _, _, class = GetRaidRosterInfo(i)
                if name and class == "Warlock" then
                    say("|cff00ff00[DIAG]|r roster warlock = "..string.format("%q", name))
                end
            end
        else
            for i = 1, GetNumPartyMembers() do
                local name = UnitName("party"..i)
                if name and UnitClass("party"..i) == "Warlock" then
                    say("|cff00ff00[DIAG]|r roster warlock = "..string.format("%q", name))
                end
            end
        end
        local any = false
        for sn, data in pairs(m.curses) do
            any = true
            say("|cff00ff00[DIAG]|r m.curses["..sn.."].caster = "..string.format("%q", data.caster or "nil"))
        end
        if not any then say("|cff00ff00[DIAG]|r m.curses is empty") end

    elseif cmd == "lock" then
        m.locked = not m.locked
        SoulstoneTrackerDB.locked = m.locked
        m.frame.updateLock()
        say(m.locked and "Frame locked." or "Frame unlocked.")

    elseif cmd == "curses" then
        local n = 0
        for shortName, data in pairs(m.curses) do
            say((CURSE_COLORS[shortName] or "|cffffffff")..shortName.."|r — "..data.caster.." on "..data.target)
            n = n + 1
        end
        if n == 0 then say("No active curses tracked.") end

    elseif cmd == "clearcurses" then
        m.curses = {}
        m.refresh()
        say("Cleared all curse assignments.")

    elseif cmd == "clearbanish" then
        m.banish = {}
        m.refreshBanish()
        say("Cleared all banish assignments.")
        local channel = GetNumRaidMembers() > 0 and "RAID" or (GetNumPartyMembers() > 0 and "PARTY" or nil)
        if channel then
            SendAddonMessage(ADDON_MSG_PREFIX, "SYNCREQ", channel)
            say("Requesting sync from others with SoulstoneTracker...")
        end

    elseif cmd == "reset" then
        SoulstoneTrackerDB.position = nil
        SoulstoneTrackerDB.size = nil
        SoulstoneTrackerDB.scale = nil
        say("Position/size reset. /reload to apply.")

    elseif string.find(cmd, "^scale") then
        local val = string.match(cmd, "scale%s+([%d%.]+)")
        local scale = tonumber(val)
        if scale and scale >= 0.5 and scale <= 2.0 then
            m.frame:SetScale(scale)
            SoulstoneTrackerDB.scale = scale
            say("Scale set to "..scale)
        else
            say("Usage: /ss scale 0.5-2.0  (e.g. /ss scale 0.8)")
        end

    elseif cmd == "help" then
        say("|cffffd700Commands:|r")
        say("|cffffd700/ss|r — toggle window")
        say("|cffffd700/ss test|r — add test stone (30 min)")
        say("|cffffd700/ss test 90|r — add test stone with 90 second duration")
        say("|cffffd700/ss clear|r — clear all stones")
        say("|cffffd700/ss list|r — list active stones in chat")
        say("|cffffd700/ss curses|r — list active curse assignments")
        say("|cffffd700/ss testcurse CoE Bob|r — simulate a curse sync from 'Bob' (CoE/CoS/CoR/CoW)")
        say("|cffffd700/ss testcast Bob Waylock 90|r — simulate Waylock soulstoning Bob, 90s")
        say("|cffffd700/ss clearcurses|r — clear curse assignments")
        say("|cffffd700/ss lock|r — toggle frame lock")
        say("|cffffd700/ss scale 0.8|r — resize (0.5-2.0)")
        say("|cffffd700/ss scan|r — scan group for existing stones")
        say("|cffffd700/ss reset|r — reset position and size")

    else
        if m.frame and m.frame:IsVisible() then
            m.frame:Hide() SoulstoneTrackerDB.hidden = true say("Hidden.")
        else
            if not m.frame then m.createFrame() end
            m.frame:Show() SoulstoneTrackerDB.hidden = false say("Shown.")
        end
    end
end

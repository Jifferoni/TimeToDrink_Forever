--[[--------------------------------------------------------------------
  Time To Drink (Forever)  -  WoW Forever addon   v1.0.0-beta
  By Jifferoni / Deedee Megadoodu

  Live healer mana bar, threshold sliders, on-screen warnings and
  party alerts, built for WoW Forever's modern API.

  WoW Forever restricts what addons can do:
    * some unit values (possibly party mana in combat) come back as
      "secret" values the addon may display but not compare;
    * addons may be blocked from sending chat inside instances.
  This build handles both safely and includes /ttd probe so you can
  check exactly what your client allows.

  Slash commands:
    /ttd              open / close the window
    /ttd probe        report what this client allows (mana, chat)
    /ttd probe chat   same, plus a real party chat + addon message test
    /ttd test         show a sample on-screen warning
    /ttd bar          show / hide the mini mana bar
    /ttd lock         lock / unlock the mini mana bar
    /ttd scale 0.9    resize the window (0.6 to 1.4)
    /ttd reset        recenter the window and mini bar
    /ttd status       print current settings
----------------------------------------------------------------------]]

local addonName, ns = ...
local TTD = {}
ns.TTD = TTD
_G.TimeToDrinkForever = TTD

local VERSION = "1.0.0-beta"
local MANA    = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0
local PREFIX  = "TTDF"
local GAP     = 5            -- Low always stays at least this far above OOM
local MIN_CD, MAX_CD, CD_STEP = 10, 120, 5
local MAX_MSG = 200
local TICK    = 0.25

local FONT       = "Fonts\\FRIZQT__.TTF"
-- Title font: Pirata One (SIL Open Font License, bundled in Fonts\ with its
-- license). If it fails to load, Text() falls back to the standard game font.
local TITLE_FONT = "Interface\\AddOns\\" .. addonName .. "\\Fonts\\PirataOne-Regular.ttf"
local TITLE_SIZE = 32
local BAR_TEX    = "Interface\\TargetingFrame\\UI-StatusBar"
local WHITE      = "Interface\\Buttons\\WHITE8x8"

local C = {
    bg      = { 0.06, 0.07, 0.09, 0.97 },
    panel2  = { 0.10, 0.11, 0.14, 1 },
    field   = { 0.04, 0.05, 0.07, 1 },
    border  = { 0.33, 0.27, 0.13, 1 },
    line    = { 0.17, 0.18, 0.22, 1 },
    gold    = { 1.00, 0.83, 0.36 },
    text    = { 0.93, 0.91, 0.86 },
    muted   = { 0.66, 0.64, 0.57 },
    blue    = { 0.27, 0.58, 1.00 },
    amber   = { 1.00, 0.70, 0.22 },
    red     = { 0.95, 0.30, 0.32 },
    green   = { 0.40, 0.80, 0.40 },
    chat    = { 0.56, 0.79, 1.00 },
}

local DEFAULTS = {
    low = 40, oom = 15, cooldown = 15,
    chat = true, screen = true, sound = true, miniBar = false, barLocked = false,
    scale = 1.0, tab = "low",
    lowMsg = "{healer} is below {threshold}% mana ({mana}%)",
    oomMsg = "{healer} is OOM ({mana}% mana)!",
    setMsg = "{healer} is the healer. The party will be warned below {threshold}% mana.",
}
local DEFAULT_MSG = { low = DEFAULTS.lowMsg, oom = DEFAULTS.oomMsg, set = DEFAULTS.setMsg }

TTD.roster       = {}
TTD.healer       = nil      -- name
TTD.healerUnit   = nil      -- unit token (player / party1-4)
TTD.wasInParty   = false
TTD.lastChat     = { LOW = 0, OOM = 0 }
TTD.lastScreen   = { LOW = 0, OOM = 0 }
TTD.manaHidden   = false

-- =====================================================================
-- Helpers
-- =====================================================================
local function isSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

local function say(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TTD:|r " .. text)
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function InParty()
    return IsInGroup() and not IsInRaid()
end

local function ChatChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
       and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "INSTANCE_CHAT"
    end
    return "PARTY"
end

-- true when the client says addons can't send chat right now
local function ChatLocked()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and not isSecret(locked) and locked then return true end
    end
    return false
end

local function SendChat(text)
    local fn = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if not fn then return false end
    return (pcall(fn, text, ChatChannel()))
end

local function SendAddon(text)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false, "no API" end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, ChatChannel())
    return ok, res
end

local function CleanMessage(s, default)
    if type(s) ~= "string" then return default end
    s = s:gsub("|", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return default end
    if #s > MAX_MSG then s = s:sub(1, MAX_MSG) end
    return s
end

local function Sub(s, token, value)
    local v = tostring(value):gsub("%%", "%%%%")
    return (s:gsub(token, v))
end

function TTD:Format(template, pct)
    local db = self.db
    local s = template or ""
    s = Sub(s, "{healer}", self.healer or "The healer")
    s = Sub(s, "{mana}", pct and math.floor(pct) or "?")
    s = Sub(s, "{threshold}", db.low)
    s = Sub(s, "{oom}", db.oom)
    s = s:gsub("|", "")
    if #s > 255 then s = s:sub(1, 255) end
    return s
end

-- Name of a unit, or nil when the client hides it (secret)
local function SafeName(unit)
    local n = UnitName(unit)
    if n == nil or isSecret(n) then return nil end
    return n
end

local function ClassColorName(unit, name)
    local ok, _, class = pcall(UnitClass, unit)
    if ok and class and not isSecret(class) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
       and RAID_CLASS_COLORS[class].colorStr then
        return "|c" .. RAID_CLASS_COLORS[class].colorStr .. name .. "|r"
    end
    return name
end

-- Returns pct (0-100 number, or nil if unknown/hidden), plus raw cur/max
-- (which may be secret; only ever handed to a StatusBar).
function TTD:ReadMana(unit)
    if not unit then return nil end
    local cur = UnitPower(unit, MANA)
    local max = UnitPowerMax(unit, MANA)
    if not isSecret(cur) and not isSecret(max) then
        if max and max > 0 then return (cur / max) * 100, cur, max, false end
        return nil, cur, max, false          -- no mana bar (e.g. warrior)
    end
    -- Values are secret: try the percent API, which some sources say stays readable.
    if UnitPowerPercent then
        local scale = CurveConstants and CurveConstants.ScaleTo100
        local ok, p = pcall(UnitPowerPercent, unit, MANA, false, scale)
        if ok and p ~= nil and not isSecret(p) and type(p) == "number" then
            if not scale then p = p * 100 end
            return p, cur, max, false
        end
    end
    return nil, cur, max, true               -- hidden
end

-- =====================================================================
-- Roster / healer
-- =====================================================================
function TTD:RefreshRoster()
    local list, incomplete = {}, false
    local me = SafeName("player")
    if me then list[#list + 1] = { name = me, unit = "player" } else incomplete = true end
    if InParty() then
        for i = 1, GetNumSubgroupMembers() do
            local u = "party" .. i
            local n = SafeName(u)
            if n then list[#list + 1] = { name = n, unit = u } else incomplete = true end
        end
    end
    self.roster = list

    if self.healer then
        local found
        for _, r in ipairs(list) do if r.name == self.healer then found = r end end
        if found then
            self.healerUnit = found.unit
        elseif not incomplete then
            self.healer, self.healerUnit = nil, nil
        end
    end
    if not self.healer and not InParty() and me then
        self.healer, self.healerUnit = me, "player"
    end
end

function TTD:SetHealer(name, unit, announce)
    self.healer, self.healerUnit = name, unit
    if announce then
        if InParty() and self.db.chat and not ChatLocked() then
            SendChat(self:Format(self.db.setMsg, (self:ReadMana(unit))))
        else
            say("healer set to " .. name .. ".")
        end
    end
    self:RefreshPanel()
end

-- =====================================================================
-- On-screen warning
-- =====================================================================
function TTD:CreateAlert()
    if self.alert then return end
    local a = CreateFrame("Frame", "TimeToDrinkForeverAlert", UIParent)
    a:SetFrameStrata("HIGH")
    a:SetSize(900, 60)
    a:SetPoint("TOP", UIParent, "TOP", 0, -180)
    a:Hide()
    local fs = a:CreateFontString(nil, "OVERLAY")
    if not fs:SetFont(TITLE_FONT, 40, "THICKOUTLINE") then fs:SetFont(FONT, 32, "THICKOUTLINE") end
    fs:SetPoint("CENTER")
    fs:SetShadowOffset(0, -2)
    a.text = fs
    a.elapsed = 0
    a:SetScript("OnUpdate", function(f, elapsed)
        f.elapsed = f.elapsed + elapsed
        if f.elapsed > 4 then f:Hide()
        elseif f.elapsed > 3 then f:SetAlpha(4 - f.elapsed) end
    end)
    self.alert = a
end

function TTD:ShowAlert(text, kind)
    self:CreateAlert()
    local col = (kind == "OOM") and C.red or C.amber
    self.alert.text:SetText(text)
    self.alert.text:SetTextColor(col[1], col[2], col[3])
    self.alert.elapsed = 0
    self.alert:SetAlpha(1)
    self.alert:Show()
    if self.db.sound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
        PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    end
end

-- =====================================================================
-- Alert check (runs every TICK seconds)
-- =====================================================================
function TTD:CheckHealer()
    local db = self.db
    if not self.healer or not self.healerUnit then return end
    if IsInRaid() then return end
    local unit = self.healerUnit
    local exists = UnitExists(unit)
    if isSecret(exists) or not exists then return end
    local dead = UnitIsDeadOrGhost(unit)
    if not isSecret(dead) and dead then return end

    local pct = self:ReadMana(unit)
    if not pct then return end

    local kind, tmpl
    if pct < db.oom then kind, tmpl = "OOM", db.oomMsg
    elseif pct < db.low then kind, tmpl = "LOW", db.lowMsg
    else return end

    local now  = GetTime()
    local text = self:Format(tmpl, pct)

    if InParty() and db.chat and not ChatLocked()
       and (now - self.lastChat[kind]) >= db.cooldown then
        if SendChat(text) then
            SendAddon(kind)
            self.lastChat[kind] = now
            if kind == "OOM" then self.lastChat.LOW = now end
        end
    end

    if db.screen and (now - self.lastScreen[kind]) >= db.cooldown then
        self:ShowAlert(text, kind)
        self.lastScreen[kind] = now
        if kind == "OOM" then self.lastScreen.LOW = now end
    end
end

-- =====================================================================
-- UI building blocks
-- =====================================================================
local FLAT = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }

local function Skin(f, bg, border)
    f:SetBackdrop(FLAT)
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

local function Text(parent, size, color, flags, font)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    if not fs:SetFont(font or FONT, size, flags or "") then
        fs:SetFont(FONT, size, flags or "")      -- fall back if a font file is missing
    end
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetJustifyH("LEFT")
    return fs
end

-- Mana bar with OOM/Low zones and marker lines. cur/max may be secret.
local function CreateManaBar(parent, w, h, withLabels)
    local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bar:SetSize(w, h)
    Skin(bar, C.field, { 0, 0, 0, 1 })
    local inner = w - 2

    local oomZone = bar:CreateTexture(nil, "BACKGROUND", nil, 2)
    oomZone:SetColorTexture(C.red[1], C.red[2], C.red[3], 0.22)
    oomZone:SetPoint("TOPLEFT", 1, -1); oomZone:SetPoint("BOTTOMLEFT", 1, 1)
    local lowZone = bar:CreateTexture(nil, "BACKGROUND", nil, 2)
    lowZone:SetColorTexture(C.amber[1], C.amber[2], C.amber[3], 0.15)

    local sb = CreateFrame("StatusBar", nil, bar)
    sb:SetPoint("TOPLEFT", 1, -1); sb:SetPoint("BOTTOMRIGHT", -1, 1)
    sb:SetStatusBarTexture(BAR_TEX)
    sb:SetMinMaxValues(0, 100); sb:SetValue(0)
    sb:SetStatusBarColor(C.blue[1], C.blue[2], C.blue[3])

    local over = CreateFrame("Frame", nil, bar)
    over:SetAllPoints(bar)
    over:SetFrameLevel(sb:GetFrameLevel() + 2)
    local shine = over:CreateTexture(nil, "ARTWORK")
    shine:SetColorTexture(1, 1, 1, 0.10)
    shine:SetPoint("TOPLEFT", 1, -1); shine:SetPoint("TOPRIGHT", -1, -1); shine:SetHeight(h / 2 - 1)
    local oomLine = over:CreateTexture(nil, "OVERLAY")
    oomLine:SetColorTexture(C.red[1], C.red[2], C.red[3], 1); oomLine:SetWidth(2)
    local lowLine = over:CreateTexture(nil, "OVERLAY")
    lowLine:SetColorTexture(C.amber[1], C.amber[2], C.amber[3], 1); lowLine:SetWidth(2)

    local oomLabel, lowLabel
    if withLabels then
        oomLabel = Text(bar, 11, C.red, "OUTLINE")
        lowLabel = Text(bar, 11, C.amber, "OUTLINE")
    end

    function bar:SetThresholds(low, oom)
        local xo = math.max(0.01, inner * oom / 100)
        local xl = math.max(0.01, inner * low / 100)
        oomZone:SetWidth(xo)
        lowZone:ClearAllPoints()
        lowZone:SetPoint("TOPLEFT", bar, "TOPLEFT", 1 + xo, -1)
        lowZone:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1 + xo, 1)
        lowZone:SetWidth(math.max(0.01, xl - xo))
        oomLine:ClearAllPoints()
        oomLine:SetPoint("TOP", bar, "TOPLEFT", 1 + xo, 2); oomLine:SetPoint("BOTTOM", bar, "BOTTOMLEFT", 1 + xo, -2)
        lowLine:ClearAllPoints()
        lowLine:SetPoint("TOP", bar, "TOPLEFT", 1 + xl, 2); lowLine:SetPoint("BOTTOM", bar, "BOTTOMLEFT", 1 + xl, -2)
        if oomLabel then
            -- OOM label sits left of its line, Low label right of its line: they never overlap
            oomLabel:ClearAllPoints(); oomLabel:SetPoint("TOPRIGHT", bar, "BOTTOMLEFT", xo - 2, -3)
            oomLabel:SetText("OOM " .. oom .. "%")
            lowLabel:ClearAllPoints(); lowLabel:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", xl + 4, -3)
            lowLabel:SetText("Low " .. low .. "%")
        end
    end

    -- pct: readable percent or nil; cur/max: raw (maybe secret)
    function bar:SetMana(pct, cur, max, low, oom)
        -- check isSecret first: comparing a secret value (even to nil) is not allowed
        local haveRaw = isSecret(cur) or isSecret(max) or (cur ~= nil and max ~= nil)
        if haveRaw then
            if not pcall(sb.SetMinMaxValues, sb, 0, max) or not pcall(sb.SetValue, sb, cur) then
                sb:SetMinMaxValues(0, 100); sb:SetValue(pct or 0)
            end
        else
            sb:SetMinMaxValues(0, 100); sb:SetValue(pct or 0)
        end
        local col = C.blue
        if pct then
            if pct < oom then col = C.red elseif pct < low then col = C.amber end
        end
        sb:SetStatusBarColor(col[1], col[2], col[3])
    end

    return bar
end

-- Flat slider. onChange(value) returns the value it actually accepted.
local function CreateSlider(parent, w, color, minV, maxV, onChange)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(w, 20)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(true)
    s:EnableMouseWheel(true)
    s:SetHitRectInsets(0, 0, -4, -4)

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(C.line[1], C.line[2], C.line[3], 1)
    track:SetPoint("LEFT"); track:SetPoint("RIGHT"); track:SetHeight(6)
    local fill = s:CreateTexture(nil, "ARTWORK")
    fill:SetColorTexture(color[1], color[2], color[3], 1)
    fill:SetPoint("LEFT", track, "LEFT"); fill:SetHeight(6)
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.96, 0.95, 0.91, 1)
    thumb:SetSize(10, 20)
    s:SetThumbTexture(thumb)

    local function paint(v)
        fill:SetWidth(math.max(0.01, w * (v - minV) / (maxV - minV)))
    end
    function s:SetQuiet(v)
        self.quiet = true
        self:SetValue(v)
        self.quiet = false
        paint(v)
    end
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        paint(v)
        if self.quiet then return end
        local accepted = onChange(v)
        if accepted and accepted ~= v then self:SetQuiet(accepted) end
    end)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(Clamp(self:GetValue() + delta, minV, maxV))
    end)
    return s
end

local function CreateBadge(parent, color, bg)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(52, 20)
    Skin(f, bg, { color[1] * 0.5, color[2] * 0.5, color[3] * 0.5, 1 })
    f.text = Text(f, 12, color, nil)
    f.text:SetPoint("CENTER")
    return f
end

local function CreateToggle(parent, w, label, hint, get, set)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, 26)
    local l = Text(b, 13, C.text)
    l:SetPoint("LEFT", 0, 0)
    l:SetText(label .. (hint and ("  |cffa8a392" .. hint .. "|r") or ""))
    local track = CreateFrame("Frame", nil, b, "BackdropTemplate")
    track:SetSize(40, 20)
    track:SetPoint("RIGHT", 0, 0)
    local knob = track:CreateTexture(nil, "OVERLAY")
    knob:SetSize(16, 16)
    knob:SetColorTexture(0.96, 0.95, 0.91, 1)
    function b:Refresh()
        local on = get()
        if on then Skin(track, { 0.22, 0.45, 0.22, 1 }, { 0.37, 0.68, 0.35, 1 })
        else Skin(track, C.line, { 0.23, 0.24, 0.28, 1 }) end
        knob:ClearAllPoints()
        knob:SetPoint(on and "RIGHT" or "LEFT", track, on and "RIGHT" or "LEFT", on and -2 or 2, 0)
    end
    b:SetScript("OnClick", function(self) set(not get()); self:Refresh() end)
    b:Refresh()
    return b
end

local function CreateFlatButton(parent, w, h, label, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, h)
    Skin(b, C.panel2, C.border)
    b.text = Text(b, 12, C.gold)
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1) end)
    b:SetScript("OnLeave", function(self)
        if self.selected then self:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1)
        else self:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1) end
    end)
    function b:SetSelected(sel)
        self.selected = sel
        if sel then
            self:SetBackdropColor(0.23, 0.20, 0.13, 1)
            self:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1)
            self.text:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        else
            self:SetBackdropColor(C.panel2[1], C.panel2[2], C.panel2[3], 1)
            self:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
            self.text:SetTextColor(C.text[1], C.text[2], C.text[3])
        end
    end
    return b
end

local function HeaderIcon(parent, texture)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(40, 40)
    Skin(f, { 0, 0, 0, 1 }, { 0.66, 0.53, 0.18, 1 })
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOPLEFT", 2, -2); t:SetPoint("BOTTOMRIGHT", -2, 2)
    t:SetTexture(texture)
    t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return f
end

-- =====================================================================
-- Main panel
-- =====================================================================
local W, PAD = 440, 24
local CW = W - PAD * 2

function TTD:CreatePanel()
    if self.panel then return end
    local db = self.db
    local p = CreateFrame("Frame", "TimeToDrinkForeverPanel", UIParent, "BackdropTemplate")
    p:SetSize(W, 736)
    Skin(p, C.bg, C.border)
    p:SetFrameStrata("DIALOG")
    p:SetClampedToScreen(true)
    p:SetMovable(true)
    p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local point, _, rel, x, y = f:GetPoint()
        db.pos = { point, rel, x, y }
    end)
    p:SetScale(db.scale or 1)
    if db.pos then p:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
    else p:SetPoint("CENTER", UIParent, "CENTER", 0, 20) end
    p:Hide()
    tinsert(UISpecialFrames, "TimeToDrinkForeverPanel")
    self.panel = p

    -- Header -----------------------------------------------------------
    local head = CreateFrame("Frame", nil, p, "BackdropTemplate")
    head:SetPoint("TOPLEFT", 1, -1); head:SetPoint("TOPRIGHT", -1, -1); head:SetHeight(76)
    Skin(head, C.panel2, { 0, 0, 0, 0 })
    local headLine = p:CreateTexture(nil, "ARTWORK")
    headLine:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
    headLine:SetPoint("TOPLEFT", head, "BOTTOMLEFT"); headLine:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT"); headLine:SetHeight(1)

    -- Title + tagline form one centered block. The icons sit outside the WIDER
    -- of the two lines with a fixed buffer, so they never cover any text.
    local ICON, BUFFER, CORNER = 40, 18, 44     -- CORNER = room kept for the close button
    local maxHalf = W / 2 - ICON - CORNER
    local titleSize, tagSize = TITLE_SIZE, 11
    local title = Text(head, titleSize, C.gold, "OUTLINE", TITLE_FONT)
    title:SetShadowColor(0, 0, 0, 0.8)
    title:SetShadowOffset(0, -2)
    title:SetText("Time To Drink")
    local tag = Text(head, tagSize, C.muted)
    tag:SetText("Keep your healer hydrated")
    -- shrink the tagline, then the title, until the block fits between the icons
    while tagSize > 8 and (tag:GetStringWidth() or 0) / 2 + BUFFER > maxHalf do
        tagSize = tagSize - 1
        tag:SetFont(FONT, tagSize, "")
    end
    while titleSize > 20 and (title:GetStringWidth() or 0) / 2 + BUFFER > maxHalf do
        titleSize = titleSize - 2
        if not title:SetFont(TITLE_FONT, titleSize, "OUTLINE") then title:SetFont(FONT, titleSize, "OUTLINE") end
    end
    local textHalf = math.max(title:GetStringWidth() or 120, tag:GetStringWidth() or 120) / 2
    local TAG_GAP = 1
    local blockH = (title:GetStringHeight() or titleSize) + TAG_GAP + (tag:GetStringHeight() or tagSize)
    title:SetPoint("TOP", head, "CENTER", 0, blockH / 2)
    tag:SetPoint("TOP", title, "BOTTOM", 0, -TAG_GAP)
    local offset = textHalf + BUFFER + ICON / 2
    HeaderIcon(head, "Interface\\Icons\\INV_Drink_18"):SetPoint("CENTER", head, "CENTER", -offset, 0)
    HeaderIcon(head, "Interface\\Icons\\INV_Drink_10"):SetPoint("CENTER", head, "CENTER", offset, 0)

    local close = CreateFrame("Button", nil, head, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", head, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() TTD:TogglePanel() end)   -- default would hide only the header

    local y = -94

    -- Healer picker ------------------------------------------------------
    local hl = Text(p, 11, C.muted)
    hl:SetPoint("TOPLEFT", PAD, y - 7)
    hl:SetText("HEALER")
    local dd
    local ddOK = MenuUtil and pcall(function()
        dd = CreateFrame("DropdownButton", nil, p, "WowStyle1DropdownTemplate")
        dd:SetPoint("TOPLEFT", PAD + 70, y)
        dd:SetWidth(CW - 70)
        dd:SetDefaultText("Select healer")
        dd:SetupMenu(function(_, root)
            TTD:RefreshRoster()
            if #TTD.roster == 0 then root:CreateTitle("No one to pick") end
            for _, r in ipairs(TTD.roster) do
                root:CreateRadio(ClassColorName(r.unit, r.name),
                    function() return TTD.healer == r.name end,
                    function() TTD:SetHealer(r.name, r.unit, true) end)
            end
        end)
    end)
    if ddOK then
        self.dropdown = dd
    else
        if dd then dd:Hide() end
        -- Fallback: a button that cycles through the group
        local cyc = CreateFlatButton(p, CW - 70, 26, "Select healer", function()
            TTD:RefreshRoster()
            local n = #TTD.roster
            if n == 0 then return end
            local idx = 0
            for i, r in ipairs(TTD.roster) do if r.name == TTD.healer then idx = i end end
            local r = TTD.roster[(idx % n) + 1]
            TTD:SetHealer(r.name, r.unit, true)
        end)
        cyc:SetPoint("TOPLEFT", PAD + 70, y)
        self.cycleButton = cyc
    end
    y = y - 40

    -- Live mana bar ------------------------------------------------------
    local nameText = Text(p, 14, C.text, nil)
    nameText:SetPoint("TOPLEFT", PAD, y)
    local pctText = Text(p, 14, C.blue, nil)
    pctText:SetPoint("TOPRIGHT", -PAD, y)
    pctText:SetJustifyH("RIGHT")
    self.nameText, self.pctText = nameText, pctText
    y = y - 22
    local bar = CreateManaBar(p, CW, 26, true)
    bar:SetPoint("TOPLEFT", PAD, y)
    self.bigBar = bar
    y = y - 50

    -- Threshold card -----------------------------------------------------
    local card = CreateFrame("Frame", nil, p, "BackdropTemplate")
    card:SetPoint("TOPLEFT", PAD, y)
    card:SetSize(CW, 130)
    Skin(card, C.panel2, C.line)
    local IW = CW - 32

    local lowLabel = Text(card, 13, C.text)
    lowLabel:SetPoint("TOPLEFT", 16, -14)
    lowLabel:SetText("Low mana alert below")
    local lowBadge = CreateBadge(card, C.amber, { 0.23, 0.17, 0.05, 1 })
    lowBadge:SetPoint("TOPRIGHT", -16, -11)

    local oomLabel = Text(card, 13, C.text)
    oomLabel:SetPoint("TOPLEFT", 16, -66)
    oomLabel:SetText("OOM alert below")
    local oomBadge = CreateBadge(card, C.red, { 0.23, 0.07, 0.08, 1 })
    oomBadge:SetPoint("TOPRIGHT", -16, -63)

    local lowSlider, oomSlider
    lowSlider = CreateSlider(card, IW, C.amber, 1, 100, function(v)
        if v < db.oom + GAP then v = db.oom + GAP end
        db.low = Clamp(v, 1, 100)
        TTD:RefreshThresholds()
        return db.low
    end)
    lowSlider:SetPoint("TOPLEFT", 16, -36)

    oomSlider = CreateSlider(card, IW, C.red, 1, 100 - GAP, function(v)
        db.oom = Clamp(v, 1, 100 - GAP)
        if db.low < db.oom + GAP then db.low = db.oom + GAP end   -- push Low up
        TTD:RefreshThresholds()
        return db.oom
    end)
    oomSlider:SetPoint("TOPLEFT", 16, -88)

    local note = Text(card, 11, C.muted)
    note:SetPoint("BOTTOMLEFT", 16, 8)
    note:SetText("Low always stays " .. GAP .. "% above OOM. Raising OOM pushes Low up.")
    self.lowSlider, self.oomSlider, self.lowBadge, self.oomBadge = lowSlider, oomSlider, lowBadge, oomBadge
    y = y - 144

    -- Repeat stepper -----------------------------------------------------
    local rl = Text(p, 13, C.text)
    rl:SetPoint("TOPLEFT", PAD, y - 6)
    rl:SetText("Repeat alerts every")
    local plus = CreateFlatButton(p, 30, 26, "+", function()
        db.cooldown = Clamp(db.cooldown + CD_STEP, MIN_CD, MAX_CD); TTD:RefreshPanel()
    end)
    plus:SetPoint("TOPRIGHT", -PAD, y)
    local cdText = Text(p, 13, C.text)
    cdText:SetPoint("RIGHT", plus, "LEFT", -10, 0)
    cdText:SetWidth(56); cdText:SetJustifyH("CENTER")
    local minus = CreateFlatButton(p, 30, 26, "-", function()
        db.cooldown = Clamp(db.cooldown - CD_STEP, MIN_CD, MAX_CD); TTD:RefreshPanel()
    end)
    minus:SetPoint("RIGHT", cdText, "LEFT", -10, 0)
    self.cdText = cdText
    y = y - 38

    -- Toggles --------------------------------------------------------------
    local toggles = {
        { "Party chat alerts", "(blocked where Forever disallows)", "chat" },
        { "On-screen warning", "(only you)", "screen" },
        { "Play sound", nil, "sound" },
        { "Mini mana bar", "(movable overlay)", "miniBar" },
    }
    self.toggles = {}
    for _, t in ipairs(toggles) do
        local key = t[3]
        local tg = CreateToggle(p, CW, t[1], t[2],
            function() return db[key] end,
            function(v) db[key] = v; TTD:UpdateMiniBarVisibility(); TTD:UpdateStatus() end)
        tg:SetPoint("TOPLEFT", PAD, y)
        self.toggles[#self.toggles + 1] = tg
        y = y - 28
    end
    y = y - 8

    -- Messages ---------------------------------------------------------------
    local div = p:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(C.line[1], C.line[2], C.line[3], 1)
    div:SetPoint("TOPLEFT", PAD, y); div:SetSize(CW, 1)
    y = y - 12

    self.tabs = {}
    local tabDefs = { { "low", "Low mana" }, { "oom", "OOM" }, { "set", "Healer picked" } }
    local tx = PAD
    for _, td in ipairs(tabDefs) do
        local key = td[1]
        local w = (key == "set") and 110 or 90
        local b = CreateFlatButton(p, w, 26, td[2], function()
            TTD:CommitMessage(); db.tab = key; TTD:RefreshPanel()
        end)
        b:SetPoint("TOPLEFT", tx, y)
        b.key = key
        tx = tx + w + 6
        self.tabs[#self.tabs + 1] = b
    end
    y = y - 36

    local ml = Text(p, 11, C.muted)
    ml:SetPoint("TOPLEFT", PAD, y)
    ml:SetText("Message sent to party")
    y = y - 16

    local eb = CreateFrame("EditBox", nil, p, "BackdropTemplate")
    eb:SetSize(CW, 28)
    eb:SetPoint("TOPLEFT", PAD, y)
    Skin(eb, C.field, C.border)
    eb:SetFont(FONT, 13, "")
    eb:SetTextColor(C.text[1], C.text[2], C.text[3])
    eb:SetTextInsets(8, 8, 0, 0)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(MAX_MSG)
    local busy = false
    eb:SetScript("OnEnterPressed", function(self) TTD:CommitMessage(); self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self)
        busy = true; TTD:RefreshMessageBox(); self:ClearFocus(); busy = false
    end)
    eb:SetScript("OnEditFocusLost", function() if not busy then TTD:CommitMessage() end end)
    eb:SetScript("OnTextChanged", function(_, user) if user then TTD:UpdatePreview(true) end end)
    self.msgBox = eb
    y = y - 36

    local il = Text(p, 11, C.muted)
    il:SetPoint("TOPLEFT", PAD, y - 5)
    il:SetText("Insert:")
    local cx = PAD + 44
    for _, tk in ipairs({ "{healer}", "{mana}", "{threshold}", "{oom}" }) do
        local token = tk
        local w = 18 + #token * 6
        local chip = CreateFlatButton(p, w, 22, token, function()
            eb:SetFocus(); eb:Insert(token); TTD:UpdatePreview(true)
        end)
        chip.text:SetFont(FONT, 11, "")
        chip:SetPoint("TOPLEFT", cx, y)
        cx = cx + w + 6
    end
    y = y - 32

    local pv = CreateFrame("Frame", nil, p, "BackdropTemplate")
    pv:SetPoint("TOPLEFT", PAD, y)
    pv:SetSize(CW, 40)
    Skin(pv, C.field, C.line)
    local pvText = Text(pv, 12, C.chat)
    pvText:SetPoint("TOPLEFT", 10, -6); pvText:SetPoint("BOTTOMRIGHT", -10, 6)
    pvText:SetJustifyV("MIDDLE"); pvText:SetWordWrap(true)
    self.previewText = pvText

    -- Footer ------------------------------------------------------------------
    local foot = CreateFrame("Frame", nil, p, "BackdropTemplate")
    foot:SetPoint("BOTTOMLEFT", 1, 1); foot:SetPoint("BOTTOMRIGHT", -1, 1); foot:SetHeight(44)
    Skin(foot, C.panel2, { 0, 0, 0, 0 })
    local footLine = p:CreateTexture(nil, "ARTWORK")
    footLine:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
    footLine:SetPoint("BOTTOMLEFT", foot, "TOPLEFT"); footLine:SetPoint("BOTTOMRIGHT", foot, "TOPRIGHT"); footLine:SetHeight(1)
    -- status on top, credits underneath, both centered
    local status = Text(foot, 11, C.green)
    status:SetPoint("TOP", foot, "TOP", 0, -8)
    status:SetJustifyH("CENTER")
    self.statusText = status
    local by = Text(foot, 11, { 0.72, 0.60, 0.35 })
    by:SetPoint("BOTTOM", foot, "BOTTOM", 0, 8)
    by:SetJustifyH("CENTER")
    by:SetText("By Jifferoni / Deedee Megadoodu")
end

function TTD:CommitMessage()
    if not self.msgBox then return end
    local key = self.db.tab
    self.db[key .. "Msg"] = CleanMessage(self.msgBox:GetText(), DEFAULT_MSG[key])
    self:RefreshMessageBox()
end

function TTD:RefreshMessageBox()
    if self.msgBox then self.msgBox:SetText(self.db[self.db.tab .. "Msg"]) end
    self:UpdatePreview(false)
end

function TTD:UpdatePreview(fromBox)
    if not self.previewText then return end
    local tmpl = fromBox and self.msgBox:GetText() or self.db[self.db.tab .. "Msg"]
    local pct = self:ReadMana(self.healerUnit)
    self.previewText:SetText("[Party] " .. self:Format(tmpl, pct))
end

function TTD:RefreshThresholds()
    local db = self.db
    if self.lowSlider then
        self.lowSlider:SetQuiet(db.low)
        self.oomSlider:SetQuiet(db.oom)
        self.lowBadge.text:SetText(db.low .. "%")
        self.oomBadge.text:SetText(db.oom .. "%")
        self.bigBar:SetThresholds(db.low, db.oom)
    end
    if self.miniBar then self.miniBar.bar:SetThresholds(db.low, db.oom) end
    self:UpdateReadout()
    self:UpdatePreview(false)
end

function TTD:UpdateStatus()
    local st = self.statusText
    if not st then return end
    local db = self.db
    local msg, col
    if not self.healer then
        msg, col = "Pick a healer", C.muted
    elseif IsInRaid() then
        msg, col = "In a raid: alerts off", C.muted
    elseif not InParty() then
        if db.screen then msg, col = "Solo: on-screen warnings only", C.green
        else msg, col = "Solo: alerts start in a group", C.muted end
    elseif self.manaHidden then
        msg, col = "Mana hidden by the game right now", C.amber
    elseif db.chat and ChatLocked() then
        msg, col = db.screen and "Chat blocked here: on-screen only" or "Chat blocked here", C.amber
    elseif db.chat and db.screen then
        msg, col = "Party + on-screen alerts active", C.green
    elseif db.chat then
        msg, col = "Party alerts active", C.green
    elseif db.screen then
        msg, col = "On-screen warnings only", C.green
    else
        msg, col = "All alerts off", C.muted
    end
    st:SetText(msg)
    st:SetTextColor(col[1], col[2], col[3])
end

function TTD:UpdateReadout()
    local db = self.db
    local unit = self.healerUnit
    local pct, cur, max, hidden
    if self.healer and unit then pct, cur, max, hidden = self:ReadMana(unit) end
    self.manaHidden = hidden and true or false

    if self.nameText then
        if not self.healer then
            self.nameText:SetText("No healer selected")
            self.pctText:SetText("")
        else
            self.nameText:SetText(ClassColorName(unit or "player", self.healer))
            if pct then
                local col = (pct < db.oom and C.red) or (pct < db.low and C.amber) or C.blue
                self.pctText:SetText(math.floor(pct) .. "% mana")
                self.pctText:SetTextColor(col[1], col[2], col[3])
            elseif hidden then
                self.pctText:SetText("hidden in combat")
                self.pctText:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
            else
                self.pctText:SetText("no mana")
                self.pctText:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
            end
        end
        self.bigBar:SetMana(pct, cur, max, db.low, db.oom)
    end
    if self.miniBar and self.miniBar:IsShown() then
        local m = self.miniBar
        m.name:SetText(self.healer and ClassColorName(unit or "player", self.healer) or "No healer")
        if pct then
            local col = (pct < db.oom and C.red) or (pct < db.low and C.amber) or C.blue
            m.pct:SetText(math.floor(pct) .. "%"); m.pct:SetTextColor(col[1], col[2], col[3])
        else
            m.pct:SetText(hidden and "hidden" or "--"); m.pct:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
        end
        m.bar:SetMana(pct, cur, max, db.low, db.oom)
    end
    self:UpdateStatus()
end

function TTD:RefreshPanel()
    if not self.panel then return end
    local db = self.db
    self:RefreshRoster()
    if self.dropdown then pcall(self.dropdown.GenerateMenu, self.dropdown) end
    if self.cycleButton then self.cycleButton.text:SetText(self.healer or "Select healer") end
    self.cdText:SetText(db.cooldown .. " sec")
    for _, tg in ipairs(self.toggles) do tg:Refresh() end
    for _, b in ipairs(self.tabs) do b:SetSelected(b.key == db.tab) end
    self:RefreshMessageBox()
    self:RefreshThresholds()
end

function TTD:TogglePanel(forceShow)
    self:CreatePanel()
    if self.panel:IsShown() and not forceShow then
        self:CommitMessage()
        self.panel:Hide()
    else
        self:RefreshPanel()
        self.panel:Show()
    end
end

-- =====================================================================
-- Mini mana bar overlay
-- =====================================================================
function TTD:CreateMiniBar()
    if self.miniBar then return end
    local db = self.db
    local m = CreateFrame("Frame", "TimeToDrinkForeverMiniBar", UIParent, "BackdropTemplate")
    m:SetSize(220, 46)
    Skin(m, { 0.06, 0.07, 0.09, 0.85 }, C.border)
    m:SetClampedToScreen(true)
    m:SetMovable(true)
    m:EnableMouse(true)
    m:RegisterForDrag("LeftButton")
    m:SetScript("OnDragStart", function(f) if not db.barLocked then f:StartMoving() end end)
    m:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local point, _, rel, x, y = f:GetPoint()
        db.barPos = { point, rel, x, y }
    end)
    if db.barPos then m:SetPoint(db.barPos[1], UIParent, db.barPos[2], db.barPos[3], db.barPos[4])
    else m:SetPoint("CENTER", UIParent, "CENTER", -300, -150) end
    m.name = Text(m, 12, C.text)
    m.name:SetPoint("TOPLEFT", 8, -6)
    m.pct = Text(m, 12, C.blue)
    m.pct:SetPoint("TOPRIGHT", -8, -6)
    m.pct:SetJustifyH("RIGHT")
    m.bar = CreateManaBar(m, 204, 14, false)
    m.bar:SetPoint("BOTTOMLEFT", 8, 7)
    m.bar:SetThresholds(db.low, db.oom)
    m:Hide()
    self.miniBar = m
end

function TTD:UpdateMiniBarVisibility()
    local db = self.db
    if db.miniBar and not IsInRaid() then
        self:CreateMiniBar()
        self.miniBar:Show()
        self:UpdateReadout()
    elseif self.miniBar then
        self.miniBar:Hide()
    end
end

-- =====================================================================
-- Probe: what does this client allow?
-- =====================================================================
local function Describe(v)
    if isSecret(v) then return "|cffffb347SECRET|r" end
    if v == nil then return "nil" end
    return tostring(v)
end

function TTD:Probe(withChat)
    local lines = {}
    local function add(k, v)
        lines[#lines + 1] = k .. ": " .. v
        DEFAULT_CHAT_FRAME:AddMessage("|cff7fc4ffTTD probe|r  " .. k .. ": " .. v)
    end
    local version, build, _, toc = GetBuildInfo()
    add("Client", Describe(version) .. "  build " .. Describe(build) .. "  interface " .. Describe(toc))
    add("Project", "WOW_PROJECT_ID=" .. Describe(WOW_PROJECT_ID) .. "  CAMELOT=" .. Describe(WOW_PROJECT_CAMELOT))
    add("Secret value system", issecretvalue and "present" or "not present")
    local inInst, instType = IsInInstance()
    add("Location", (not isSecret(inInst) and inInst) and ("instance (" .. Describe(instType) .. ")") or "open world")
    add("Group", IsInRaid() and "raid" or (IsInGroup() and ("party, chat channel " .. ChatChannel()) or "solo"))
    add("In combat", Describe(InCombatLockdown()))
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked, reason = pcall(C_ChatInfo.InChatMessagingLockdown)
        add("Chat lockdown", ok and (Describe(locked) .. "  reason " .. Describe(reason)) or "call failed")
    else
        add("Chat lockdown", "API not present")
    end

    local units = { "player" }
    if self.healerUnit and self.healerUnit ~= "player" then units[#units + 1] = self.healerUnit end
    for _, u in ipairs(units) do
        local label = (u == "player") and "You" or ("Healer (" .. u .. ")")
        add(label .. " name", Describe(UnitName(u)))
        add(label .. " UnitPower/Max", Describe(UnitPower(u, MANA)) .. " / " .. Describe(UnitPowerMax(u, MANA)))
        if UnitPowerPercent then
            local scale = CurveConstants and CurveConstants.ScaleTo100
            local ok, pv = pcall(UnitPowerPercent, u, MANA, false, scale)
            add(label .. " UnitPowerPercent", ok and Describe(pv) or "call failed")
        else
            add(label .. " UnitPowerPercent", "API not present")
        end
        local pct, _, _, hidden = self:ReadMana(u)
        add(label .. " => addon can compare thresholds", pct and "YES" or (hidden and "NO (hidden)" or "no mana"))
    end

    if type(TimeToDrinkForeverDB) == "table" then
        TimeToDrinkForeverDB.lastProbe = { when = date and date("%Y-%m-%d %H:%M:%S") or "?", lines = lines }
    end

    if withChat then
        if not IsInGroup() then
            add("Chat test", "skipped (join a party first)")
            return
        end
        local token = tostring(math.random(10000, 99999))
        self.probeWait = { token = token, chat = false, addon = false }
        local sent = SendChat("Time To Drink probe " .. token .. " (testing addon chat, please ignore)")
        local aok, ares = SendAddon("PROBE" .. token)
        add("Chat send call", sent and "no error" or "error")
        add("Addon message send", (aok and "no error" or "error") .. "  result " .. Describe(ares))
        C_Timer.After(3, function()
            local w = TTD.probeWait
            if not w then return end
            add("Party chat delivered", w.chat and "YES" or "NO (blocked or not echoed)")
            add("Addon message delivered", w.addon and "YES" or "NO (blocked or not echoed)")
            TTD.probeWait = nil
        end)
    end
end

-- =====================================================================
-- Events
-- =====================================================================
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("CHAT_MSG_ADDON")
for _, e in ipairs({ "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER" }) do
    ev:RegisterEvent(e)
end

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= addonName then return end
    if type(TimeToDrinkForeverDB) ~= "table" then TimeToDrinkForeverDB = {} end
    local db = TimeToDrinkForeverDB
    for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
    db.oom = Clamp(math.floor(tonumber(db.oom) or 15), 1, 100 - GAP)
    db.low = Clamp(math.floor(tonumber(db.low) or 40), db.oom + GAP, 100)
    db.cooldown = Clamp(math.floor(tonumber(db.cooldown) or 15), MIN_CD, MAX_CD)
    db.lowMsg = CleanMessage(db.lowMsg, DEFAULTS.lowMsg)
    db.oomMsg = CleanMessage(db.oomMsg, DEFAULTS.oomMsg)
    db.setMsg = CleanMessage(db.setMsg, DEFAULTS.setMsg)
    if not DEFAULT_MSG[db.tab] then db.tab = "low" end
    TTD.db = db
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    end
    TTD:RegisterSettings()
    ev:UnregisterEvent("ADDON_LOADED")
end

function handlers.PLAYER_ENTERING_WORLD()
    if not TTD.db then return end
    if not TTD.ticker then
        TTD.wasInParty = InParty()
        TTD:RefreshRoster()
        TTD.ticker = C_Timer.NewTicker(TICK, function() TTD:OnTick() end)
        say("v" .. VERSION .. " loaded. /ttd to open, /ttd probe to test what WoW Forever allows.")
    end
    TTD:UpdateMiniBarVisibility()
end

function handlers.GROUP_ROSTER_UPDATE()
    if not TTD.db then return end
    local inParty = InParty()
    if inParty and not TTD.wasInParty then
        -- Fresh party: make the player pick the healer again
        TTD.healer, TTD.healerUnit = nil, nil
        TTD:RefreshRoster()
        TTD:TogglePanel(true)
    else
        local had = TTD.healer
        TTD:RefreshRoster()
        if had and not TTD.healer and inParty and TTD.db.chat and not ChatLocked() then
            SendChat("The healer has left the party, please pick a new healer in Time To Drink.")
        end
        if TTD.panel and TTD.panel:IsShown() then TTD:RefreshPanel() end
    end
    TTD.wasInParty = inParty
    TTD:UpdateMiniBarVisibility()
end

function handlers.CHAT_MSG_ADDON(prefix, text, _, sender)
    if isSecret(prefix) or prefix ~= PREFIX or isSecret(text) then return end
    local now = GetTime()
    if text == "OOM" then
        TTD.lastChat.OOM, TTD.lastChat.LOW = now, now
    elseif text == "LOW" then
        TTD.lastChat.LOW = now
    elseif TTD.probeWait and text == ("PROBE" .. TTD.probeWait.token) then
        TTD.probeWait.addon = true
    end
end

local function OnGroupChat(text)
    if isSecret(text) or not TTD.probeWait then return end
    if text:find(TTD.probeWait.token, 1, true) then TTD.probeWait.chat = true end
end
handlers.CHAT_MSG_PARTY = OnGroupChat
handlers.CHAT_MSG_PARTY_LEADER = OnGroupChat
handlers.CHAT_MSG_INSTANCE_CHAT = OnGroupChat
handlers.CHAT_MSG_INSTANCE_CHAT_LEADER = OnGroupChat

ev:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h then h(...) end
end)

function TTD:OnTick()
    if (self.panel and self.panel:IsShown()) or (self.miniBar and self.miniBar:IsShown()) then
        self:UpdateReadout()
    end
    self:CheckHealer()
end

-- =====================================================================
-- Settings page + addon compartment
-- =====================================================================
function TTD:RegisterSettings()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    pcall(function()
        local canvas = CreateFrame("Frame")
        local t = Text(canvas, 22, C.gold, nil, TITLE_FONT)
        t:SetPoint("TOPLEFT", 16, -16)
        t:SetText("Time To Drink")
        local d = Text(canvas, 13, C.text)
        d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -8)
        d:SetText("All settings live in the Time To Drink window.")
        local b = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
        b:SetSize(180, 26)
        b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -12)
        b:SetText("Open Time To Drink")
        b:SetScript("OnClick", function()
            if SettingsPanel and SettingsPanel:IsShown() and HideUIPanel then HideUIPanel(SettingsPanel) end
            TTD:TogglePanel(true)
        end)
        local cat = Settings.RegisterCanvasLayoutCategory(canvas, "Time To Drink")
        Settings.RegisterAddOnCategory(cat)
    end)
end

function TimeToDrinkForever_OnAddonCompartmentClick()
    TTD:TogglePanel()
end

function TimeToDrinkForever_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button or UIParent, "ANCHOR_LEFT")
    GameTooltip:AddLine("Time To Drink")
    GameTooltip:AddLine("Click to open.", 1, 1, 1)
    GameTooltip:Show()
end

function TimeToDrinkForever_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-- =====================================================================
-- Slash commands
-- =====================================================================
SLASH_TIMETODRINKFOREVER1 = "/ttd"
SLASH_TIMETODRINKFOREVER2 = "/timetodrink"
SlashCmdList.TIMETODRINKFOREVER = function(msg)
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    local db = TTD.db
    if not db then return end

    if cmd == "probe" then
        TTD:Probe(arg == "chat")
    elseif cmd == "test" then
        TTD:ShowAlert(TTD:Format(db.oomMsg, 8), "OOM")
    elseif cmd == "bar" then
        db.miniBar = not db.miniBar
        TTD:UpdateMiniBarVisibility()
        if TTD.panel then TTD:RefreshPanel() end
        say("mini mana bar " .. (db.miniBar and "shown" or "hidden"))
    elseif cmd == "lock" then
        db.barLocked = not db.barLocked
        say("mini mana bar " .. (db.barLocked and "locked" or "unlocked"))
    elseif cmd == "scale" then
        local s = tonumber(arg)
        if s then
            db.scale = Clamp(s, 0.6, 1.4)
            if TTD.panel then TTD.panel:SetScale(db.scale) end
            say("window scale " .. db.scale)
        else
            say("usage: /ttd scale 0.9")
        end
    elseif cmd == "reset" then
        db.pos, db.barPos = nil, nil
        if TTD.panel then TTD.panel:ClearAllPoints(); TTD.panel:SetPoint("CENTER", UIParent, "CENTER", 0, 20) end
        if TTD.miniBar then TTD.miniBar:ClearAllPoints(); TTD.miniBar:SetPoint("CENTER", UIParent, "CENTER", -300, -150) end
        TTD:TogglePanel(true)
        say("window and mini bar recentered.")
    elseif cmd == "status" then
        say(("healer=%s  low=%d%%  oom=%d%%  repeat=%ds  chat=%s  screen=%s  group=%s"):format(
            TTD.healer or "none", db.low, db.oom, db.cooldown, tostring(db.chat), tostring(db.screen),
            IsInRaid() and "raid" or (IsInGroup() and "party" or "solo")))
    else
        TTD:TogglePanel()
    end
end

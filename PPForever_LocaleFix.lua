-- PP Forever Locale Fix
-- PPForever detects camp buffs (which make blessings bounce) only by their
-- English aura names. On deDE and other clients those never match, so the
-- addon keeps re-casting a blessing the server rejects with
-- "A more powerful spell is already active".
--
-- This addon patches PPForever from the outside without editing its files:
--  1. Every time a blessing is rejected with that error, the recipient plus
--     blessing family is treated as covered for 15 minutes, so PPForever picks
--     an alternative blessing or moves on to the next player. Works with every
--     client language, since it compares against the client's own error text.
--  2. Optional localized camp buff names (see CAMP_NAMES below) let PPForever
--     skip covered players without the first failed cast.
--
-- /ppfix          status
-- /ppfix buffs    show target's buffs in a copy window + save to SavedVariables
-- /ppfix clear    forget all remembered rejections

local _, ns = ...
local D = DSPBuffData
if not D then return end
-- The camp-buff fix only matters for blessings; the slash command works for all classes.
local FIX = D.PlayerClass == "PALADIN" and type(D.CampConflict) == "function"

local BOUNCE_SECONDS = 900

-- Localized camp buff names, by covered blessing family (first rank spell ID).
-- English names are already handled by PPForever itself. Add the names shown
-- in the buff tooltip for your client language, e.g. found via /ppfix buffs.
local CAMP_NAMES = {
    [19740] = {}, -- Blessing of Might   <- "Boosted Attack Power"
    [19742] = {}, -- Blessing of Wisdom  <- "Boosted Mana Regeneration"
    -- Kings is left out on purpose: its English name is shared with the
    -- Enchanted Lute buff and PPForever also checks the icon for it.
}

local bounced, pending = {}, nil
local hits = 0

local function Now() return GetTime() end

local function Key(guid, spell)
    local family = spell and (spell.key or spell.id)
    if type(guid) == "string" and family then return guid .. ":" .. tostring(family) end
end

local function Prune()
    local now = Now()
    for key, expiry in pairs(bounced) do
        if expiry <= now then bounced[key] = nil end
    end
end

local function IsBounced(guid, spell)
    local key = Key(guid, spell)
    return key and bounced[key] and bounced[key] > Now()
end

local function Remember(spell, guid)
    if spell and guid then pending = {guid = guid, key = spell.key or spell.id, time = Now()} end
end

local function LocalizedCampConflict(unit, spell)
    if not D.BlessingAuraIDs then return end
    local family = D.BlessingAuraIDs(spell)
    for familyKey, names in pairs(CAMP_NAMES) do
        if family[familyKey] then
            for _, name in ipairs(names) do
                if D.BuffInfo(unit, {campName = name}) == true then return true end
            end
        end
    end
end

-- 1) CampConflict: report a conflict for remembered rejections and for
--    localized camp names, otherwise defer to PPForever's own check.
if FIX then
    local originalCampConflict = D.CampConflict
    D.CampConflict = function(unit, spell, ...)
        if spell and not D.Combat() then
            local guid = D.Call(UnitGUID, unit)
            if IsBounced(guid, spell) then return true end
            if LocalizedCampConflict(unit, spell) then return true end
        end
        return originalCampConflict(unit, spell, ...)
    end
end

-- 2) Remember which blessing was just sent to whom.
if FIX and D.SocialBuffs and type(D.SocialBuffs.Record) == "function" then
    local originalRecord = D.SocialBuffs.Record
    D.SocialBuffs.Record = function(spell, guid, ...)
        Remember(spell, guid)
        return originalRecord(spell, guid, ...)
    end
end

local function HookAllInOne()
    if not FIX then return false end
    local button = _G.PPForeverTargetBuff
    if not button then return false end
    if button.ppLocaleFixHooked then return true end
    button:HookScript("PreClick", function(self, _, down)
        if D.Combat() or not self.spell then return end
        if D.SocialBuffs and D.SocialBuffs.IsCastEdge and not D.SocialBuffs.IsCastEdge(down) then return end
        local guid = self.groupGUID or D.Call(UnitGUID, self.recipient or "target")
        Remember(self.spell, guid)
    end)
    button.ppLocaleFixHooked = true
    return true
end

local function Refresh()
    if D.Combat() then return end
    if D.TargetBuff and D.TargetBuff.Update then pcall(D.TargetBuff.Update) end
    if D.SocialBuffs and D.SocialBuffs.Refresh then pcall(D.SocialBuffs.Refresh) end
end

local function IsBounceMessage(message)
    return type(message) == "string" and (
        (SPELL_FAILED_AURA_BOUNCED and message == SPELL_FAILED_AURA_BOUNCED) or
        (ERR_SPELL_FAILED_AURA_BOUNCED and message == ERR_SPELL_FAILED_AURA_BOUNCED))
end

local events = CreateFrame("Frame")
events:RegisterEvent("UI_ERROR_MESSAGE")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "UI_ERROR_MESSAGE" then
        -- Classic passes (messageType, message); accept either position.
        local message = IsBounceMessage(arg2) and arg2 or IsBounceMessage(arg1) and arg1
        if message and pending and Now() - pending.time < 3 then
            local key = Key(pending.guid, pending)
            if key then
                Prune()
                bounced[key] = Now() + BOUNCE_SECONDS
                hits = hits + 1
            end
            pending = nil
            Refresh()
        end
    else
        HookAllInOne()
    end
end)
HookAllInOne()

-- 3) PPForever bug (all classes): social buffing waits while any group/self buff
--    "needs refresh", using the refresh threshold (default 10 min). A buff whose
--    full duration is not longer than that (Thorns: 10 min) needs refresh right
--    after casting, so social buffing never starts. For this gate only, a buff is
--    pending when missing or below GATE_MINUTES; normal refresh rules are unchanged.
local GATE_MINUTES = 2
if D.TargetBuff and type(D.TargetBuff.GroupPending) == "function" and D.Config and type(D.Config.Settings) == "function" then
    local originalGroupPending = D.TargetBuff.GroupPending
    D.TargetBuff.GroupPending = function(...)
        local s = D.Config.Settings()
        if type(s) ~= "table" then return originalGroupPending(...) end
        local minutes, limit = s.buffRefreshMinutes, s.limitBuffRefresh
        s.buffRefreshMinutes = math.min(minutes or 10, GATE_MINUTES)
        s.limitBuffRefresh = true
        local ok, result = pcall(originalGroupPending, ...)
        s.buffRefreshMinutes, s.limitBuffRefresh = minutes, limit
        if not ok then return true end
        return result
    end
end

local function Print(text) print("|cff66ccffPP Forever Locale Fix:|r " .. text) end

-- WoW chat text cannot be selected. Show results in a copyable edit box and
-- keep the last capture in SavedVariables (written on /reload or logout).
local copyWindow
local function ShowCopy(text)
    if not copyWindow then
        local w = CreateFrame("Frame", "PPForeverLocaleFixCopy", UIParent, "BackdropTemplate")
        w:SetSize(460, 300); w:SetPoint("CENTER"); w:SetFrameStrata("DIALOG")
        w:SetMovable(true); w:EnableMouse(true); w:RegisterForDrag("LeftButton")
        w:SetScript("OnDragStart", w.StartMoving); w:SetScript("OnDragStop", w.StopMovingOrSizing)
        if w.SetBackdrop then
            w:SetBackdrop({bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 24, insets = {left = 6, right = 6, top = 6, bottom = 6}})
        end
        local title = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -12); title:SetText("PP Forever Locale Fix - Ctrl+A, Ctrl+C")
        local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)
        local scroll = CreateFrame("ScrollFrame", nil, w, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -34); scroll:SetPoint("BOTTOMRIGHT", -32, 14)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true); edit:SetAutoFocus(false); edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(400)
        edit:SetScript("OnEscapePressed", function() w:Hide() end)
        scroll:SetScrollChild(edit)
        w.edit = edit
        tinsert(UISpecialFrames, "PPForeverLocaleFixCopy")
        copyWindow = w
    end
    copyWindow.edit:SetText(text)
    copyWindow:Show()
    copyWindow.edit:SetFocus()
    copyWindow.edit:HighlightText()
end

SLASH_PPFOREVERLOCALEFIX1 = "/ppfix"
SlashCmdList.PPFOREVERLOCALEFIX = function(input)
    input = (input or ""):lower():match("^%s*(.-)%s*$")
    local tr = ns.Translation
    if input == "lang" or input == "lang on" or input == "lang off" then
        if not tr then Print("No translation available for client language " .. tostring(GetLocale and GetLocale()) .. ".") return end
        local on = tr.Status()
        if input == "lang on" then on = true elseif input == "lang off" then on = false else on = not on end
        tr.SetEnabled(on)
        if on then
            tr.Scan()
            Print("Übersetzung aktiv.")
        else
            Print("Translation disabled. /reload to restore all English text.")
        end
    elseif input == "clear" then
        wipe(bounced); pending = nil; Refresh()
        Print("Remembered rejections cleared.")
    elseif input == "buffs" then
        local Log = ns.BuffLog
        local unit = D.Call(UnitExists, "target") == true and "target" or "player"
        local who = D.Call(UnitName, unit) or unit
        local lines = {"Buffs on " .. who .. " (" .. (GetLocale and GetLocale() or "?") .. "):"}
        local buffs = Log and Log.ReadBuffs(unit) or {}
        for _, b in ipairs(buffs) do
            lines[#lines + 1] = string.format("%s | ID %s | icon %s", tostring(b.name), tostring(b.id), tostring(b.icon))
        end
        if Log then Log.Collect(unit) end
        ShowCopy(table.concat(lines, "\n"))
        Print(#buffs .. " buffs (also added to the buff log).")
    elseif input == "log" then
        local Log = ns.BuffLog
        if not Log then return end
        local text, n = Log.Report()
        ShowCopy(text)
        Print(string.format("Buff log: %d buffs, collecting %s. Saved on /reload or logout.", n, Log.Enabled() and "on" or "off"))
    elseif input == "log on" or input == "log off" then
        if ns.BuffLog then ns.BuffLog.SetEnabled(input == "log on") end
        Print("Buff log " .. (input == "log on" and "on." or "off."))
    elseif input == "log clear" then
        if ns.BuffLog then ns.BuffLog.Clear() end
        Print("Buff log cleared.")
    elseif input == "log quiet" or input == "log notify" then
        PPForeverLocaleFixDB = PPForeverLocaleFixDB or {}
        PPForeverLocaleFixDB.collectNotify = input == "log notify"
        Print("New-buff chat notices " .. (input == "log notify" and "on." or "off."))
    else
        Prune()
        local active = 0
        for _ in pairs(bounced) do active = active + 1 end
        if FIX then
            Print(string.format("active. All-in-One hooked: %s. Rejections seen: %d, currently skipped: %d.",
                tostring(HookAllInOne()), hits, active))
        else
            Print("camp-buff fix inactive (Paladins only).")
        end
        if tr then
            local on, locale, count, hookCount = tr.Status()
            Print(string.format("translation %s (%s, %d strings, %d text hooks).", on and "on" or "off", locale, count, hookCount))
        end
        if ns.BuffLog then
            Print(string.format("buff log %s, %d buffs collected.", ns.BuffLog.Enabled() and "on" or "off", ns.BuffLog.Count()))
        end
        Print("/ppfix buffs - target buffs, /ppfix log - collected buffs (log on|off|clear|quiet|notify),")
        Print("/ppfix clear - reset rejections, /ppfix lang - toggle translation.")
    end
end

-- Passive buff log: while you play, record every buff seen on players you
-- target or mouse over (and your own), keyed by spell ID. Used to find the
-- localized names/IDs of Forever camp buffs. Stored in PPForeverLocaleFixDB.buffLog.
local _, ns = ...
local D = DSPBuffData
if not D then return end

local Log = {}
ns.BuffLog = Log

local MAX_ENTRIES = 3000
local FOREVER_ID = 1000000 -- Forever-specific spells (camp buffs etc.) use IDs above this
local enabled = false      -- becomes true after SavedVariables are loaded
local lastGUID, lastTime = {}, {}
local playerDirty = false

local function Secret(v) return issecretvalue and issecretvalue(v) end
local function Now() return date and date("%Y-%m-%d %H:%M") or "?" end

-- Returns a list of {name=, id=, icon=} for the unit's helpful auras.
function Log.ReadBuffs(unit)
    local list = {}
    for i = 1, 40 do
        local name, id, icon
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local aura = D.Call(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
            if type(aura) ~= "table" then break end
            name, id, icon = aura.name, aura.spellId, aura.icon
        else
            local a, tex, _, _, _, _, _, _, _, spellID = D.Call(UnitBuff, unit, i)
            if not a then break end
            name, id, icon = a, spellID, tex
        end
        if not Secret(name) and not Secret(id) and not Secret(icon) and type(id) == "number" then
            list[#list + 1] = {name = name, id = id, icon = icon}
        end
    end
    return list
end

local function DB()
    PPForeverLocaleFixDB = PPForeverLocaleFixDB or {}
    PPForeverLocaleFixDB.buffLog = PPForeverLocaleFixDB.buffLog or {}
    return PPForeverLocaleFixDB.buffLog
end

local count = 0
local function Record(buff, who, quiet)
    local log = DB()
    local entry = log[buff.id]
    local stamp = Now()
    if not entry then
        if count >= MAX_ENTRIES then return end
        entry = {name = buff.name, icon = buff.icon, seen = 0, first = stamp,
            locale = GetLocale and GetLocale()}
        log[buff.id] = entry
        count = count + 1
        if not quiet and buff.id >= FOREVER_ID and PPForeverLocaleFixDB.collectNotify ~= false then
            print(string.format("|cff66ccffPP Forever Locale Fix:|r Neuer Forever-Buff: %s (ID %d) bei %s",
                tostring(buff.name), buff.id, tostring(who)))
        end
    end
    entry.seen = entry.seen + 1
    entry.last = stamp
    entry.sample = who
    if type(buff.name) == "string" then entry.name = buff.name end
end

function Log.Collect(unit, quiet)
    if not enabled then return 0 end
    if D.Call(UnitExists, unit) ~= true or D.Call(UnitIsPlayer, unit) ~= true then return 0 end
    local guid = D.Call(UnitGUID, unit)
    -- Mouseover fires constantly; count the same player at most every 30 s.
    if unit == "mouseover" and guid and lastGUID[unit] == guid and GetTime() - (lastTime[unit] or 0) < 30 then return 0 end
    lastGUID[unit], lastTime[unit] = guid, GetTime()
    local who = D.Call(UnitName, unit) or unit
    if Secret(who) then who = unit end
    local buffs = Log.ReadBuffs(unit)
    for _, buff in ipairs(buffs) do Record(buff, who, quiet) end
    return #buffs
end

-- Copyable report, Forever-specific IDs first.
function Log.Report()
    local log = DB()
    local ids = {}
    for id in pairs(log) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        local fa, fb = a >= FOREVER_ID, b >= FOREVER_ID
        if fa ~= fb then return fa end
        return a < b
    end)
    local lines = {string.format("Buff log: %d buffs (%s). ID | Name | gesehen | zuletzt | bei", #ids, GetLocale and GetLocale() or "?")}
    local header = false
    for _, id in ipairs(ids) do
        local e = log[id]
        if not header and id < FOREVER_ID then lines[#lines + 1] = "--- Standard-Buffs ---"; header = true end
        lines[#lines + 1] = string.format("%d | %s | %dx | %s | %s", id, tostring(e.name), e.seen or 0, tostring(e.last), tostring(e.sample))
    end
    return table.concat(lines, "\n"), #ids
end

function Log.Count() return count end
function Log.Enabled() return enabled end
function Log.SetEnabled(on)
    PPForeverLocaleFixDB = PPForeverLocaleFixDB or {}
    PPForeverLocaleFixDB.collect = on and true or false
    enabled = on and true or false
end
function Log.Clear()
    if PPForeverLocaleFixDB then PPForeverLocaleFixDB.buffLog = {} end
    count = 0
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
events:RegisterEvent("UNIT_AURA")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "PPForever_LocaleFix" then return end
        local db = PPForeverLocaleFixDB or {}
        PPForeverLocaleFixDB = db
        enabled = db.collect ~= false
        local log = DB()
        count = 0
        for _ in pairs(log) do count = count + 1 end
        -- Seed from earlier manual /ppfix buffs captures (quietly).
        if not db.buffLogSeeded and type(db.captures) == "table" then
            for _, capture in ipairs(db.captures) do
                for _, buff in ipairs(capture.buffs or {}) do
                    if type(buff.id) == "number" then Record(buff, capture.target, true) end
                end
            end
            db.buffLogSeeded = true
        end
    elseif not enabled then
        return
    elseif event == "PLAYER_TARGET_CHANGED" then
        Log.Collect("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        Log.Collect("mouseover")
    elseif event == "UNIT_AURA" then
        if arg1 == "player" then playerDirty = true end
    elseif event == "PLAYER_ENTERING_WORLD" then
        playerDirty = true
    end
end)
-- Own buffs: at most once every 2 seconds after they change.
local elapsed = 0
events:SetScript("OnUpdate", function(_, delta)
    if not playerDirty then return end
    elapsed = elapsed + delta
    if elapsed < 2 then return end
    elapsed, playerDirty = 0, false
    lastGUID.player = nil
    Log.Collect("player")
end)

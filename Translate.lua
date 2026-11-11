-- PP Forever Locale Fix - UI translation engine
-- PPForever has no localization system; all UI text is hard-coded English.
-- This translates it from the outside, without touching PPForever's files:
--  * FontString/Button SetText on frames owned by PPForever (names DSP*/PPForever*)
--  * GameTooltip lines while the tooltip is owned by a PPForever frame
--  * print() messages starting with "PP Forever"
-- Only display text is changed; secure attributes and macros are never touched.
-- Untranslated strings simply stay English.

local _, ns = ...
local D = DSPBuffData
if not D then return end
local locale = GetLocale and GetLocale()
local L = ns.locales and ns.locales[locale]
if not L then return end

local enabled = true
ns.Translation = {locale = locale}

local function Secret(v) return issecretvalue and issecretvalue(v) end

-- Resolve spell-name placeholders from the client (e.g. Forever-only spells).
local function SpellName(id, fallback)
    local name
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" and type(info.name) == "string" and not Secret(info.name) then name = info.name end
    end
    if not name and GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, id)
        if ok and type(n) == "string" and not Secret(n) then name = n end
    end
    return name or fallback
end
local placeholders = {REVOKE = SpellName(1325499, "Revoke")}
for key, value in pairs(L.strings) do
    if value:find("{", 1, true) then
        L.strings[key] = value:gsub("{(%u+)}", function(p) return placeholders[p] or p end)
    end
end

local S = L.strings
-- Long known sentences double as fragments, so concatenations of them translate too.
local fragments = {}
for en, de in pairs(S) do
    if #en >= 20 and en:find(" ", 1, true) and not en:find("\n", 1, true) then fragments[#fragments + 1] = {en, de} end
end
for _, f in ipairs(L.fragments or {}) do fragments[#fragments + 1] = f end
table.sort(fragments, function(a, b) return #a[1] > #b[1] end)

local cache, cacheSize = {}, 0
local T

local function Exact(s)
    local hit = S[s]
    if hit then return hit end
    local lead, core, trail = s:match("^(%s*)(.-)(%s*)$")
    if core ~= s and core ~= "" then
        hit = S[core]
        if hit then return lead .. hit .. trail end
    end
end

local function Translate(s)
    local hit = Exact(s)
    if hit then return hit end
    if s:find("\n", 1, true) then
        local out, changed = {}, false
        for line in (s .. "\n"):gmatch("(.-)\n") do
            local t = T(line)
            if t ~= line then changed = true end
            out[#out + 1] = t
        end
        return changed and table.concat(out, "\n") or s
    end
    for _, p in ipairs(L.patterns or {}) do
        local caps = {s:match(p[1])}
        if caps[1] ~= nil then
            local flags = p[3] or {}
            return (p[2]:gsub("%%(%d)", function(i)
                i = tonumber(i)
                local v = caps[i] or ""
                if flags[i] then return T(v) end
                return v
            end))
        end
    end
    -- "Label: value" where either side is a known string.
    local a, b = s:match("^(.-): (.+)$")
    if a and a ~= "" and (Exact(a) or Exact(b)) then
        return T(a) .. ": " .. T(b)
    end
    -- "Section / Label" (settings search results).
    if s:find(" / ", 1, true) then
        local x, y = s:match("^(.-) / (.+)$")
        if x and (Exact(x) or Exact(y)) then return T(x) .. " / " .. T(y) end
    end
    -- "Shift + Left-click", "Aura + Righteous Fury".
    if s:find(" + ", 1, true) then
        local out, changed = {}, false
        for token in (s .. " + "):gmatch("(.-) %+ ") do
            local t = Exact(token) or token
            if t ~= token then changed = true end
            out[#out + 1] = t
        end
        if changed then return table.concat(out, " + ") end
    end
    -- Known sentences/phrases inside composed text.
    local r, changed = s, false
    for _, f in ipairs(fragments) do
        local i, j = r:find(f[1], 1, true)
        while i do
            r = r:sub(1, i - 1) .. f[2] .. r:sub(j + 1)
            changed = true
            i, j = r:find(f[1], i + #f[2], true)
        end
    end
    if changed then return r end
    return s
end

function T(s)
    if type(s) ~= "string" or s == "" or Secret(s) then return s end
    local hit = cache[s]
    if hit then return hit end
    local ok, r = pcall(Translate, s)
    if not ok or type(r) ~= "string" then r = s end
    if cacheSize > 4000 then wipe(cache); cacheSize = 0 end
    cache[s] = r; cacheSize = cacheSize + 1
    return r
end
ns.Translation.T = T

-- Ownership: anything below a frame named DSP*/PPForever* (not our own windows).
local owned = setmetatable({}, {__mode = "k"})
local function CheckOwned(obj)
    local f = obj
    for _ = 1, 40 do
        if not f then return false end
        if f.IsForbidden and f:IsForbidden() then return false end
        local name = f.GetName and f:GetName()
        if type(name) == "string" and not Secret(name) then
            if name:find("^PPForeverLocaleFix") then return false end
            if name:find("^DSP") or name:find("^PPForever") then return true end
        end
        f = f.GetParent and f:GetParent()
    end
    return false
end
local function IsOwned(obj)
    local v = owned[obj]
    if v ~= nil then return v end
    local ok, res = pcall(CheckOwned, obj)
    v = ok and res == true
    owned[obj] = v
    return v
end

local busy = false
local function Apply(obj, text)
    local t = T(text)
    if t ~= text then
        busy = true
        pcall(obj.SetText, obj, t)
        busy = false
    end
end
local function OnSetText(obj, text)
    if busy or not enabled or type(text) ~= "string" or Secret(text) then return end
    if IsOwned(obj) then Apply(obj, text) end
end

local hooked = 0
local function HookMethods(object)
    local mt = object and getmetatable(object)
    local index = mt and mt.__index
    if type(index) == "table" and type(index.SetText) == "function" and not index.ppLocaleFixHooked then
        if pcall(hooksecurefunc, index, "SetText", OnSetText) then
            pcall(function() index.ppLocaleFixHooked = true end)
            hooked = hooked + 1
        end
    end
end
HookMethods(UIParent:CreateFontString())
HookMethods(CreateFrame("Button"))
HookMethods(CreateFrame("CheckButton"))

-- Text set before our hooks existed (PPForever builds frames at load).
local function TranslateExisting(obj)
    if not obj.GetText then return end
    local ok, text = pcall(obj.GetText, obj)
    if ok and type(text) == "string" and not Secret(text) then Apply(obj, text) end
end
local function Walk(frame, depth)
    if depth > 15 or not frame then return end
    if frame.IsForbidden and frame:IsForbidden() then return end
    local kind = frame.GetObjectType and frame:GetObjectType()
    if kind == "Button" or kind == "CheckButton" then TranslateExisting(frame) end
    if frame.GetRegions then
        for _, region in ipairs({frame:GetRegions()}) do
            if region.GetObjectType and region:GetObjectType() == "FontString" then TranslateExisting(region) end
        end
    end
    if frame.GetChildren then
        for _, child in ipairs({frame:GetChildren()}) do Walk(child, depth + 1) end
    end
end

local roots = {"DSPPaladinBuffsTable", "DSPBuffsConfigWindow", "DSPRaidAssignmentsWindow", "DSPBuffsMinimapButton",
    "PPForeverWhatsNew", "PPForeverSocialCombatGate", "PPForeverUnlockRequest", "PPForeverBlessingMenu",
    "PPForeverDragMenuBackdrop"}
local rootHooked = {}

-- Make the settings search find German labels too.
local function AugmentSearch()
    local design = D.ConfigDesign and D.ConfigDesign.current
    if not design or type(design.entries) ~= "table" then return end
    for _, e in ipairs(design.entries) do
        local frame = e.frame
        if frame and not frame.ppLocaleFixTerms and type(frame.ppSearchTerms) == "string" then
            local terms = {T(e.label)}
            local function Collect(f, depth)
                if depth > 8 or not f then return end
                if f.GetRegions then
                    for _, region in ipairs({f:GetRegions()}) do
                        if region.GetObjectType and region:GetObjectType() == "FontString" then
                            local ok, text = pcall(region.GetText, region)
                            if ok and type(text) == "string" and not Secret(text) and #text < 80 then terms[#terms + 1] = text end
                        end
                    end
                end
                if f.GetChildren then for _, child in ipairs({f:GetChildren()}) do Collect(child, depth + 1) end end
            end
            pcall(Collect, frame, 0)
            frame.ppSearchTerms = frame.ppSearchTerms .. " " .. table.concat(terms, " ")
            frame.ppLocaleFixTerms = true
        end
    end
end

-- Settings sub-tabs: PPForever sizes them from the English label length
-- (#label*7+20), so longer translations overflow. Re-lay them out from the
-- rendered text width after every Select().
local TAB_LEFT, TAB_SPACE = 220, 860
local function RelayoutTabs(design)
    if not enabled or type(design) ~= "table" or not design.active or type(design.entries) ~= "table" then return end
    local group = design.active.group
    local links, total = {}, 0
    for _, e in ipairs(design.entries) do
        if e.group == group and not e.retired and e.link and e.link.label then
            local ok, width = pcall(e.link.label.GetStringWidth, e.link.label)
            width = ok and type(width) == "number" and not Secret(width) and width or 0
            links[#links + 1] = {entry = e, width = width}
            total = total + width
        end
    end
    if #links == 0 then return end
    local pad = 20
    if total + pad * #links > TAB_SPACE then pad = math.max(8, math.floor((TAB_SPACE - total) / #links)) end
    local x = TAB_LEFT
    for _, link in ipairs(links) do
        local w = math.max(62, math.ceil(link.width) + pad)
        local e = link.entry
        e.link:ClearAllPoints(); e.link:SetPoint("TOPLEFT", x, -159); e.link:SetWidth(w)
        if e.underline then e.underline:SetWidth(w - 8) end
        x = x + w
    end
end
if D.ConfigDesign and type(D.ConfigDesign.Select) == "function" then
    hooksecurefunc(D.ConfigDesign, "Select", function(design) pcall(RelayoutTabs, design) end)
end

local function ScanAll()
    if not enabled then return end
    for _, name in ipairs(roots) do
        local root = _G[name]
        if root then
            pcall(Walk, root, 0)
            if not rootHooked[name] and root.HookScript then
                rootHooked[name] = true
                root:HookScript("OnShow", function(self)
                    pcall(Walk, self, 0)
                    if name == "DSPBuffsConfigWindow" then
                        pcall(AugmentSearch)
                        pcall(RelayoutTabs, D.ConfigDesign and D.ConfigDesign.current)
                    end
                end)
            end
        end
    end
    pcall(AugmentSearch)
    pcall(RelayoutTabs, D.ConfigDesign and D.ConfigDesign.current)
end
ns.Translation.Scan = ScanAll

-- Tooltips: translate lines after PPForever filled them, then re-layout.
local tipBusy = false
local function TranslateTooltip(tip)
    if tipBusy or not enabled then return end
    local owner = tip.GetOwner and tip:GetOwner()
    if not owner or not IsOwned(owner) then return end
    local name = tip:GetName()
    local changed = false
    for i = 1, tip:NumLines() do
        for _, side in ipairs({"Left", "Right"}) do
            local fs = _G[name .. "Text" .. side .. i]
            if fs then
                local ok, text = pcall(fs.GetText, fs)
                if ok and type(text) == "string" and not Secret(text) then
                    local t = T(text)
                    if t ~= text then
                        busy = true; fs:SetText(t); busy = false
                        changed = true
                    end
                end
            end
        end
    end
    if changed then
        tipBusy = true
        pcall(tip.Show, tip)
        tipBusy = false
    end
end
hooksecurefunc(GameTooltip, "Show", TranslateTooltip)

-- Chat: only messages printed by PP Forever.
if getprinthandler and setprinthandler then
    local original = getprinthandler()
    if original then
        setprinthandler(function(...)
            if enabled and select("#", ...) == 1 then
                local message = ...
                if type(message) == "string" and not Secret(message) and message:find("PP Forever", 1, true) then
                    return original(T(message))
                end
            end
            return original(...)
        end)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, addon)
    if event == "ADDON_LOADED" and addon == "PPForever_LocaleFix" then
        PPForeverLocaleFixDB = PPForeverLocaleFixDB or {}
        enabled = PPForeverLocaleFixDB.translate ~= false
        ScanAll()
    elseif event == "PLAYER_LOGIN" then
        ScanAll()
        if C_Timer and C_Timer.After then
            C_Timer.After(2, ScanAll)
            C_Timer.After(8, ScanAll)
        end
    end
end)

function ns.Translation.Status()
    local count = 0
    for _ in pairs(S) do count = count + 1 end
    return enabled, locale, count, hooked
end
function ns.Translation.SetEnabled(on)
    PPForeverLocaleFixDB = PPForeverLocaleFixDB or {}
    PPForeverLocaleFixDB.translate = on and true or false
    enabled = on and true or false
end

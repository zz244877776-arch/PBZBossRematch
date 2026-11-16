local U = require("util")
local Config = require("config")
local Data = require("gamedata")
local Toast = require("toast")

local M = {}

local VIS_VISIBLE = 0
local VIS_COLLAPSED = 1
local VIS_HIDDEN = 2
local NAV_UP = 2
local NAV_DOWN = 3
local BUTTON_CLASS = "W_DialogueButton_C"

-- Per-instance settings the menu designer filled in on the original buttons; new buttons start empty.
local COPIED_BUTTON_FIELDS = { "ClickSound", "OnHoverSound", "bCanPlaySound" }
local TEMPLATE_BUTTON_FIELDS = { "ShopButton", "ManualSave", "AbilityCultivation", "CloseBtn" }

M.OnBossChosen = nil

-- Only addresses are kept between frames. A Lua wrapper outliving its object crashes UE4SS as
-- soon as it is touched (even IsValid), and the engine frees removed widgets on its next GC.
local menuKey = nil
local entryKey = nil
local poolKeys = {}      -- our list buttons, kept in MainBox and reused
local hiddenKeys = {}    -- { key = address, vis = visibility } of original entries hidden by the list
local buttonActions = {}

local function isActivated(m)
    local ok, v = pcall(function() return m:IsActivated() end)
    return ok and v == true
end

local function liveMenu(activeOnly)
    local m = U.live("W_BellMenu_C", menuKey)
    if m and activeOnly and not isActivated(m) then return nil end
    return m
end

-- Drops every reference without touching the objects behind them.
function M.reset()
    menuKey, entryKey = nil, nil
    poolKeys, hiddenKeys, buttonActions = {}, {}, {}
end

local function childrenOf(box)
    local list = {}
    local n = 0
    pcall(function() n = box:GetChildrenCount() end)
    for i = 0, n - 1 do
        local ok, c = pcall(function() return box:GetChildAt(i) end)
        if ok and U.valid(c) then table.insert(list, c) end
    end
    return list
end

-- Fresh wrappers for MainBox children, by address.
local function childMap(m)
    local map = {}
    for _, c in ipairs(childrenOf(m.MainBox)) do
        local a = U.address(c)
        if a then map[a] = c end
    end
    return map
end

-- ===== Localized map names =====

local locCache = {}

-- Resolves a localization key by letting one of the game's rich text blocks look it up. The helper
-- widget has no parent and is collected by the engine soon after, so it is never reused.
local function resolveLocKey(ns, key)
    local cacheKey = ns .. "/" .. key
    if locCache[cacheKey] ~= nil then return locCache[cacheKey] or nil end
    if not U.valid(Toast.ButtonClass) then return nil end
    local pc = U.playerController()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ok, scratch = pcall(function() return wbl:Create(pc, Toast.ButtonClass, pc) end)
    if not ok or not U.valid(scratch) then return nil end
    local rt = scratch.PBZCommonLocRichText_39
    if not U.valid(rt) then return nil end
    local result = false
    for _, k in ipairs({ key, ns .. "/" .. key, ns .. "." .. key }) do
        pcall(function() rt:SetText(FText("")) end)
        pcall(function() rt:SetTextByLocKey(k) end)
        local s = ""
        pcall(function() s = rt:GetText():ToString() end)
        if s ~= "" and s ~= k and s ~= key then
            result = s
            break
        end
    end
    locCache[cacheKey] = result
    return result or nil
end

Data.LocResolver = resolveLocKey

-- ===== Buttons =====

local loggedLabel = false

local function setLabel(btn, text)
    Toast.setLabel(btn, text, not loggedLabel)
    loggedLabel = true
end

local loggedCopy = false

local function copyButtonSettings(m, btn)
    local template = nil
    for _, field in ipairs(TEMPLATE_BUTTON_FIELDS) do
        local ok, w = pcall(function() return m[field] end)
        if ok and U.valid(w) then
            template = w
            break
        end
    end
    if not template then return end
    for _, field in ipairs(COPIED_BUTTON_FIELDS) do
        local ok, err = pcall(function()
            local v = template[field]
            -- An empty object slot must not be written back: it would store an invalid pointer.
            if type(v) ~= "boolean" and not U.valid(v) then error("template value is empty, skipped") end
            btn[field] = v
        end)
        if not loggedCopy then
            U.log("button setting %s ok=%s %s", field, tostring(ok), ok and "" or tostring(err))
        end
    end
    loggedCopy = true
end

local function newButton(m)
    local pc = U.playerController()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ok, btn = pcall(function() return wbl:Create(m, Toast.ButtonClass, pc) end)
    if not ok or not U.valid(btn) then return nil end
    copyButtonSettings(m, btn)
    return btn
end

local function addBeforeClose(m, btn)
    local box = m.MainBox
    local close = m.CloseBtn
    local closeInBox = false
    pcall(function() closeInBox = U.valid(close) and box:GetChildIndex(close) >= 0 end)
    if closeInBox then box:RemoveChild(close) end
    box:AddChildToVerticalBox(btn)
    if closeInBox then box:AddChildToVerticalBox(close) end
end

local function isShown(w)
    local ok, vis = pcall(function() return w:GetVisibility() end)
    return ok and vis ~= VIS_COLLAPSED and vis ~= VIS_HIDDEN
end

-- Some menu entries sit inside a border or overlay; dig out the button itself.
local function buttonIn(w, depth)
    if not U.valid(w) or not isShown(w) then return nil end
    if U.className(w) == BUTTON_CLASS then return w end
    if (depth or 0) >= 2 then return nil end
    local ok, content = pcall(function() return w:GetContent() end)
    if ok and U.valid(content) then return buttonIn(content, (depth or 0) + 1) end
    for _, c in ipairs(childrenOf(w)) do
        local b = buttonIn(c, (depth or 0) + 1)
        if b then return b end
    end
    return nil
end

-- The designer wired explicit up/down links between the original buttons, so gamepad focus
-- jumps over anything inserted later. Re-chain every visible button, wrapping at both ends.
local function relinkNavigation()
    local m = liveMenu(false)
    if not m then return end
    local buttons = {}
    for _, c in ipairs(childrenOf(m.MainBox)) do
        local b = buttonIn(c)
        if b then table.insert(buttons, b) end
    end
    local n = #buttons
    if n == 0 then return end
    for i, b in ipairs(buttons) do
        local up = buttons[i > 1 and i - 1 or n]
        local down = buttons[i < n and i + 1 or 1]
        pcall(function() b:SetNavigationRuleExplicit(NAV_UP, up) end)
        pcall(function() b:SetNavigationRuleExplicit(NAV_DOWN, down) end)
    end
    U.log("bell menu: navigation linked over %d buttons", n)
end

-- The game's own menu logic only manages its own buttons, so keep exactly one dialogue button
-- in the menu showing the selected appearance whenever one is hovered or focused.
function M.onButtonFocused(btn)
    local m = liveMenu(true)
    if not m or not U.valid(btn) then return end
    local box = m.MainBox
    local ok, parent = pcall(function() return btn:GetParent() end)
    if not ok or U.address(parent) ~= U.address(box) then return end
    local target = U.address(btn)
    for _, c in ipairs(childrenOf(box)) do
        if U.className(c) == BUTTON_CLASS then
            local selected = U.address(c) == target
            pcall(function() c:DoSelectedAppearance(selected) end)
        end
    end
end

local hoverHooked = false

local function ensureHoverHook()
    if hoverHooked or not U.valid(Toast.ButtonClass) then return end
    hoverHooked = true
    local path = U.fullName(Toast.ButtonClass):gsub("^%S+%s+", "") .. ":BP_OnHovered"
    local ok, err = pcall(RegisterHook, path, function(self) M.onButtonFocused(self:get()) end)
    U.log("hook %s: %s", path, ok and "ok" or tostring(err))
end

local function focusKey(key)
    local m = liveMenu(true)
    local btn = m and childMap(m)[key]
    if not btn then return end
    pcall(function() btn:SetFocus() end)
    pcall(function() btn:SetUserFocus(U.playerController()) end)
    M.onButtonFocused(btn)
end

-- ===== List mode =====

local function collapsePool(m)
    local children = childMap(m)
    for _, key in ipairs(poolKeys) do
        buttonActions[key] = nil
        local b = children[key]
        if b then pcall(function() b:SetVisibility(VIS_COLLAPSED) end) end
    end
end

local function hideOriginals(m)
    if #hiddenKeys > 0 then return end
    local pool = {}
    for _, key in ipairs(poolKeys) do pool[key] = true end
    for _, c in ipairs(childrenOf(m.MainBox)) do
        local key = U.address(c)
        local ok, vis = pcall(function() return c:GetVisibility() end)
        if ok and vis ~= VIS_COLLAPSED and not pool[key] then
            table.insert(hiddenKeys, { key = key, vis = vis })
            pcall(function() c:SetVisibility(VIS_COLLAPSED) end)
        end
    end
end

local function showOriginals(m)
    local children = childMap(m)
    for _, h in ipairs(hiddenKeys) do
        local c = children[h.key]
        if c then pcall(function() c:SetVisibility(h.vis) end) end
    end
    hiddenKeys = {}
end

local function buildList(entries)
    local m = liveMenu(true)
    if not m then return end
    hideOriginals(m)
    collapsePool(m)
    local children = childMap(m)
    for i, e in ipairs(entries) do
        local key = poolKeys[i]
        local b = key and children[key]
        if not b then
            b = newButton(m)
            if not b then break end
            m.MainBox:AddChildToVerticalBox(b)
            key = U.address(b)
            poolKeys[i] = key
        end
        buttonActions[key] = e.action
        pcall(function() b:SetVisibility(VIS_VISIBLE) end)
        setLabel(b, e.label)
    end
    local keys = {}
    for i = 1, #entries do keys[i] = poolKeys[i] end
    local function applyLabels()
        local mm = liveMenu(true)
        if not mm then return end
        local now = childMap(mm)
        for i, key in ipairs(keys) do
            local b = now[key]
            if b then setLabel(b, entries[i].label) end
        end
    end
    U.delay(50, "bellui.labels", function()
        applyLabels()
        relinkNavigation()
        focusKey(keys[1])
    end)
    U.delay(400, "bellui.labels2", applyLabels)
end

local function leaveList(m)
    collapsePool(m)
    showOriginals(m)
end

local showMapList

local function backToMenu()
    local m = liveMenu(false)
    if not m then return end
    leaveList(m)
    relinkNavigation()
    focusKey(entryKey)
end

local function showBossList(mapId, bosses)
    local entries = {}
    for _, b in ipairs(bosses) do
        local arena = Data.arena(b.id)
        local suffix = ""
        if not arena then suffix = "（未勘察）"
        elseif arena.unsupported then suffix = "（暂不支持）" end
        table.insert(entries, {
            label = b.name .. suffix,
            action = function()
                backToMenu()
                local m = liveMenu(false)
                if m then pcall(function() m:DeactivateWidget() end) end
                if M.OnBossChosen then M.OnBossChosen(b) end
            end,
        })
    end
    table.insert(entries, { label = "返回", action = function() showMapList() end })
    buildList(entries)
end

showMapList = function()
    local byMap, order = Data.availableBossesByMap()
    local entries = {}
    for _, mapId in ipairs(order) do
        local bosses = byMap[mapId]
        table.insert(entries, {
            label = string.format("%s（%d）", Data.mapDisplayName(mapId), #bosses),
            action = function() showBossList(mapId, bosses) end,
        })
    end
    if #entries == 0 then
        Toast.show("没有可再战的 Boss", 3000)
        return
    end
    table.insert(entries, { label = "返回", action = backToMenu })
    buildList(entries)
end

-- ===== Injection =====

local MENU_BUTTON_FIELDS = { "TeleportBtn_BrokenBell", "TeleportBtn", "ShopButton", "ManualSave", "JhsyButton", "ItemUpgradeButton", "CloseBtn", "AbilityCultivation" }

-- Removes buttons left behind by a previous load of this mod (e.g. after a hot reload or a world change).
local function removeStaleButtons(m)
    local own = {}
    for _, field in ipairs(MENU_BUTTON_FIELDS) do
        local ok, w = pcall(function() return m[field] end)
        if ok and U.valid(w) then own[U.address(w)] = true end
    end
    for _, c in ipairs(childrenOf(m.MainBox)) do
        if U.className(c) == BUTTON_CLASS and not own[U.address(c)] then
            pcall(function() c:RemoveFromParent() end)
            U.log("bell menu: removed stale button")
        end
    end
end

local function inject(m)
    M.reset()
    menuKey = U.address(m)
    removeStaleButtons(m)
    local ok, cls = pcall(function() return m.ShopButton:GetClass() end)
    if not ok or not U.valid(cls) then
        U.log("bell menu: cannot get button class")
        return
    end
    Toast.ButtonClass = cls
    ensureHoverHook()
    local entry = newButton(m)
    if not entry then
        U.log("bell menu: failed to create entry button")
        return
    end
    addBeforeClose(m, entry)
    entryKey = U.address(entry)
    buttonActions[entryKey] = function() showMapList() end
    setLabel(entry, Config.EntryLabel)
    local function refresh()
        local mm = liveMenu(false)
        local e = mm and childMap(mm)[entryKey]
        if e then setLabel(e, Config.EntryLabel) end
        relinkNavigation()
    end
    U.delay(50, "bellui.entryLabel", refresh)
    -- The menu shows or hides some of its own entries while it animates in.
    U.delay(400, "bellui.entryLabel2", refresh)
    U.log("bell menu: entry button injected")
end

function M.menuOpen()
    for _, m in ipairs(FindAllOf("W_BellMenu_C") or {}) do
        if isActivated(m) then return true end
    end
    return false
end

function M.tick(enabled)
    if not enabled then return end
    if menuKey then
        local alive = liveMenu(false)
        if not alive then
            M.reset()
        elseif not isActivated(alive) and #hiddenKeys > 0 then
            leaveList(alive)
        end
    end
    for _, m in ipairs(FindAllOf("W_BellMenu_C") or {}) do
        if isActivated(m) then
            if U.address(m) == menuKey and childMap(m)[entryKey] then return end
            local ok, err = pcall(inject, m)
            if not ok then U.log("bell menu inject error: %s", tostring(err)) end
            return
        end
    end
end

function M.handleClick(btn)
    local action = buttonActions[U.address(btn)]
    if not action or not liveMenu(true) then return false end
    U.gameThread("bellui.click", action)
    return true
end

return M

local U = require("util")
local Config = require("config")
local Data = require("gamedata")
local Toast = require("toast")
local L = require("locale")

local M = {}

local VIS_VISIBLE = 0
local VIS_COLLAPSED = 1
local VIS_HIDDEN = 2
local NAV_UP = 2
local NAV_DOWN = 3
local BUTTON_CLASS = "W_DialogueButton_C"

-- Per-instance settings the menu designer filled in on the original buttons; new buttons start empty.
local COPIED_BUTTON_FIELDS = { "ClickSound", "OnHoverSound", "bCanPlaySound" }
local TEMPLATE_BUTTON_FIELDS = { "ShopButton", "ManualSave", "AbilityCultivation", "CloseBtn", "TeleportBtn", "JhsyButton" }

M.OnBossChosen = nil

local showMapList -- defined later; entry button / leaveList restore this action

-- Only addresses are kept between frames. A Lua wrapper outliving its object crashes UE4SS as
-- soon as it is touched (even IsValid), and the engine frees removed widgets on its next GC.
local menuKey = nil
local entryKey = nil
local poolKeys = {}      -- our list buttons, kept in MainBox and reused
local hiddenKeys = {}    -- { key = address, vis = visibility } of original entries hidden by the list
local buttonActions = {}
local listKeys = {}      -- ordered keys for map / boss list
local locScratchKey = nil -- single hidden DialogueButton reused by LocResolver

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
    listKeys = {}
    locScratchKey = nil
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
-- One hidden scratch button reused for every loc lookup. Creating a fresh W_DialogueButton
-- per boss/map key (~75+) while the bell menu is open hard-crashes CommonUI.

local function liveLocScratch()
    return locScratchKey and U.live(BUTTON_CLASS, locScratchKey) or nil
end

local function ensureLocScratch()
    local scratch = liveLocScratch()
    if scratch then return scratch end
    locScratchKey = nil
    if not U.valid(Toast.ButtonClass) then return nil end
    local pc = U.playerController()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local menu = liveMenu(false)
    local outer = menu or pc
    local ok, w = pcall(function() return wbl:Create(outer, Toast.ButtonClass, pc) end)
    if not ok or not U.valid(w) then return nil end
    -- Keep it out of layout / input; do not AddChild to MainBox.
    pcall(function() w:SetVisibility(VIS_COLLAPSED) end)
    pcall(function() w:UnbindTriggeringInputActionToClick() end)
    locScratchKey = U.address(w)
    return w
end

-- Resolves a localization key by letting one of the game's rich text blocks look it up.
local function resolveLocKey(ns, key)
    local cacheKey = tostring(ns or "") .. "/" .. tostring(key or "")
    if locCache[cacheKey] ~= nil then return locCache[cacheKey] or nil end
    local scratch = ensureLocScratch()
    if not scratch then return nil end
    local rt = scratch.PBZCommonLocRichText_39
    if not U.valid(rt) then return nil end
    local result = false
    local tries = { key }
    if ns and ns ~= "" then
        table.insert(tries, ns .. "/" .. key)
        table.insert(tries, ns .. "." .. key)
    end
    for _, k in ipairs(tries) do
        if k and k ~= "" then
            pcall(function() rt:SetText(FText("")) end)
            pcall(function() rt:SetTextByLocKey(k) end)
            local s = ""
            pcall(function() s = rt:GetText():ToString() end)
            if s ~= "" and s ~= k and s ~= key and s ~= (ns .. "/" .. key) and s ~= (ns .. "." .. key) then
                result = s
                break
            end
        end
    end
    locCache[cacheKey] = result
    return result or nil
end

function M.clearLocCache()
    locCache = {}
    -- Keep the scratch widget; only drop the address if the object is already gone.
    if locScratchKey and not liveLocScratch() then locScratchKey = nil end
end

Data.LocResolver = resolveLocKey

-- ===== Buttons =====

local loggedLabel = false

local function setLabel(btn, text)
    Toast.setLabel(btn, text, not loggedLabel)
    loggedLabel = true
end

local loggedCopy = false

local function findTemplateButton(m)
    for _, field in ipairs(TEMPLATE_BUTTON_FIELDS) do
        local ok, w = pcall(function() return m[field] end)
        if ok and U.valid(w) then return w end
    end
    return nil
end

-- Only unbind Confirm; do not disable interaction — that broke mouse/gamepad on list rows.
local function unbindConfirm(btn)
    if not U.valid(btn) then return end
    pcall(function() btn:UnbindTriggeringInputActionToClick() end)
end

-- Copy the template's TriggeringInputAction so gamepad A / Confirm clicks our rows
-- (entry, map list, and boss list) the same way as the vanilla bell buttons.
local function bindConfirm(btn, template)
    if not U.valid(btn) then return end
    pcall(function() btn.bIsFocusable = true end)
    pcall(function() btn:SetIsFocusable(true) end)
    pcall(function() btn:SetIsButtonEnabled(true) end)
    pcall(function() btn:SetIsInteractionEnabled(true) end)
    if U.valid(template) then
        local copied = false
        pcall(function()
            local action = template.TriggeringInputAction
            if action ~= nil then
                btn:SetTriggeringInputAction(action)
                copied = true
            end
        end)
        if not copied then
            pcall(function() btn.TriggeringInputAction = template.TriggeringInputAction end)
        end
        if not loggedCopy then
            U.log("gamepad confirm action copied from template=%s", tostring(copied))
        end
    end
    pcall(function() btn:BindTriggeringInputActionToClick() end)
end

local function copyButtonSettings(m, btn)
    local template = findTemplateButton(m)
    if not template then
        bindConfirm(btn, nil)
        return
    end
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
    bindConfirm(btn, template)
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
    bindConfirm(btn, findTemplateButton(m))
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
        if b then
            unbindConfirm(b)
            pcall(function() b:SetVisibility(VIS_COLLAPSED) end)
        end
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
            if key == entryKey then unbindConfirm(c) end
            pcall(function() c:SetVisibility(VIS_COLLAPSED) end)
        end
    end
    -- Entry must not keep Confirm while the map/boss list is open.
    if entryKey then
        local entry = childMap(m)[entryKey]
        if entry then unbindConfirm(entry) end
        buttonActions[entryKey] = nil
    end
end

local function showOriginals(m)
    local children = childMap(m)
    for _, h in ipairs(hiddenKeys) do
        local c = children[h.key]
        if c then pcall(function() c:SetVisibility(h.vis) end) end
    end
    hiddenKeys = {}
    if entryKey then
        local entry = children[entryKey]
        if entry then
            bindConfirm(entry, findTemplateButton(m))
            buttonActions[entryKey] = function() showMapList() end
        end
    end
end

local function buildList(entries)
    local m = liveMenu(true)
    if not m then return end
    hideOriginals(m)
    collapsePool(m)
    local children = childMap(m)
    local template = findTemplateButton(m)
    listKeys = {}
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
        listKeys[i] = key
        pcall(function() b:SetVisibility(VIS_VISIBLE) end)
        setLabel(b, e.label)
        bindConfirm(b, template)
    end
    -- Focus the first row immediately so Confirm cannot land on a stale "返回" row
    -- left over from the previous list (map → boss transition).
    relinkNavigation()
    if listKeys[1] then focusKey(listKeys[1]) end
    local keys = {}
    for i = 1, #listKeys do keys[i] = listKeys[i] end
    local function applyLabels()
        local mm = liveMenu(true)
        if not mm then return end
        local now = childMap(mm)
        local tmpl = findTemplateButton(mm)
        for i, key in ipairs(keys) do
            local b = now[key]
            if b and entries[i] then
                setLabel(b, entries[i].label)
                bindConfirm(b, tmpl)
            end
        end
        relinkNavigation()
    end
    U.delay(50, "bellui.labels", applyLabels)
    U.delay(400, "bellui.labels2", applyLabels)
end

local function leaveList(m)
    listKeys = {}
    collapsePool(m)
    showOriginals(m)
end

local function backToMenu()
    local m = liveMenu(false)
    if not m then return end
    leaveList(m)
    relinkNavigation()
    focusKey(entryKey)
end

local function showBossList(mapId, bosses)
    -- Challengeable first; proven-unsupported last so （暂不支持） is easy to spot.
    local ordered = {}
    for _, b in ipairs(bosses) do table.insert(ordered, b) end
    table.sort(ordered, function(a, b)
        local ua = Data.arena(a.id)
        local ub = Data.arena(b.id)
        local aBad = ua and ua.unsupported and true or false
        local bBad = ub and ub.unsupported and true or false
        if aBad ~= bBad then return not aBad end
        return tostring(a.name) < tostring(b.name)
    end)

    local entries = {}
    for _, b in ipairs(ordered) do
        local arena = Data.arena(b.id)
        -- Do not show "未勘察": missing arena cache only means first trip uses the map
        -- bell (slower). Keep "暂不支持" for bosses that already failed a full scan.
        local suffix = (arena and arena.unsupported) and L.T("unsupported_tag") or ""
        table.insert(entries, {
            label = b.name .. suffix,
            action = function()
                backToMenu()
                local mm = liveMenu(false)
                if mm then pcall(function() mm:DeactivateWidget() end) end
                if M.OnBossChosen then M.OnBossChosen(b) end
            end,
        })
    end
    table.insert(entries, { label = L.T("back"), action = function() showMapList() end })
    buildList(entries)
end

showMapList = function()
    -- Rebuild boss rows so lockey names refresh; keep locCache / single scratch widget
    -- (wiping the cache forced ~75 DialogueButton Creates and crashed CommonUI).
    Data.clearBossRows()
    local byMap, order = Data.availableBossesByMap()
    local sampleLogged = false
    local entries = {}
    for _, mapId in ipairs(order) do
        local bosses = byMap[mapId]
        if not sampleLogged and bosses and bosses[1] then
            local b = bosses[1]
            U.log("boss name sample %s -> %s via %s (key %s/%s)",
                b.id, tostring(b.name), tostring(b.nameSource),
                tostring(b.nameNs), tostring(b.nameKey))
            -- Only lockey text is a safe language signal (ValueCache/Hans are often Chinese).
            if b.nameSource == "lockey" then
                pcall(function() require("locale").observeText(b.name) end)
            end
            sampleLogged = true
        end
        local mapName = Data.mapDisplayName(mapId)
        table.insert(entries, {
            label = L.T("map_count", mapName, #bosses),
            action = function() showBossList(mapId, bosses) end,
        })
    end
    if #entries == 0 then
        Toast.show(L.T("no_challengable"), 3000)
        return
    end
    table.insert(entries, { label = L.T("back"), action = backToMenu })
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
    -- Read already-localized vanilla button labels (no scratch-widget Create — that crashes).
    pcall(function()
        local samples = {}
        for _, field in ipairs(MENU_BUTTON_FIELDS) do
            local ok, w = pcall(function() return m[field] end)
            if ok and U.valid(w) then
                for _, tw in ipairs({ "PBZCommonLocRichText_39", "Selected" }) do
                    local text = ""
                    pcall(function() text = w[tw]:GetText():ToString() end)
                    if text and text ~= "" then
                        table.insert(samples, text)
                        break
                    end
                end
            end
        end
        local code = require("locale").observeMenuTexts(samples)
        U.log("bell menu: locale from menu labels -> %s (%s) samples=%d",
            tostring(code), tostring(require("locale").culture()), #samples)
    end)
    ensureHoverHook()
    local entry = newButton(m)
    if not entry then
        U.log("bell menu: failed to create entry button")
        return
    end
    addBeforeClose(m, entry)
    entryKey = U.address(entry)
    buttonActions[entryKey] = function() showMapList() end
    setLabel(entry, L.entryLabel())
    local function refresh()
        local mm = liveMenu(false)
        local e = mm and childMap(mm)[entryKey]
        if e then
            setLabel(e, L.entryLabel())
            bindConfirm(e, findTemplateButton(mm))
        end
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
    if not U.valid(btn) then return false end
    local action = buttonActions[U.address(btn)]
    if not action or not liveMenu(true) then return false end
    U.log("bellui click key=%s listRows=%d", tostring(U.address(btn)), #listKeys)
    U.gameThread("bellui.click", action)
    return true
end

return M

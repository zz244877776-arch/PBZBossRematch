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

-- Per-instance settings the menu designer filled in on the original buttons; new buttons start empty.
local COPIED_BUTTON_FIELDS = { "ClickSound", "OnHoverSound", "bCanPlaySound" }
local TEMPLATE_BUTTON_FIELDS = { "ShopButton", "ManualSave", "AbilityCultivation", "CloseBtn" }

M.OnBossChosen = nil

local menu = nil
local menuKey = nil
local entryButton = nil
local listButtons = {}
local hiddenChildren = {}
local buttonActions = {}

local scratch = nil

-- Resolves a localization key by letting one of the game's rich text blocks look it up.
local function resolveLocKey(ns, key)
    if not U.valid(Toast.ButtonClass) then return nil end
    if not U.valid(scratch) then
        local pc = U.playerController()
        local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        scratch = wbl:Create(pc, Toast.ButtonClass, pc)
    end
    local rt = U.valid(scratch) and scratch.PBZCommonLocRichText_39
    if not U.valid(rt) then return nil end
    for _, k in ipairs({ key, ns .. "/" .. key, ns .. "." .. key }) do
        pcall(function() rt:SetText(FText("")) end)
        pcall(function() rt:SetTextByLocKey(k) end)
        local s = ""
        pcall(function() s = rt:GetText():ToString() end)
        if s ~= "" and s ~= k and s ~= key then return s end
    end
    return nil
end

Data.LocResolver = resolveLocKey

local loggedLabel = false

local function setLabel(btn, text)
    Toast.setLabel(btn, text, not loggedLabel)
    loggedLabel = true
end

local loggedCopy = false

local function copyButtonSettings(btn)
    local template = nil
    for _, field in ipairs(TEMPLATE_BUTTON_FIELDS) do
        local ok, w = pcall(function() return menu[field] end)
        if ok and U.valid(w) then
            template = w
            break
        end
    end
    if not template then return end
    for _, field in ipairs(COPIED_BUTTON_FIELDS) do
        local ok, err = pcall(function() btn[field] = template[field] end)
        if not loggedCopy then
            local back = nil
            pcall(function() back = btn[field] end)
            U.log("button setting %s ok=%s now=%s %s", field, tostring(ok),
                tostring(back ~= nil and (type(back) == "boolean" and tostring(back) or U.fullName(back)) or nil),
                ok and "" or tostring(err))
        end
    end
    loggedCopy = true
end

local function newButton(label, action)
    local pc = U.playerController()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local btn = wbl:Create(menu, Toast.ButtonClass, pc)
    if not U.valid(btn) then return nil end
    copyButtonSettings(btn)
    buttonActions[U.address(btn)] = action
    return btn
end

local function addToMainBox(btn)
    local box = menu.MainBox
    local close = menu.CloseBtn
    local closeInBox = false
    pcall(function() closeInBox = U.valid(close) and box:GetChildIndex(close) >= 0 end)
    if closeInBox then box:RemoveChild(close) end
    box:AddChildToVerticalBox(btn)
    if closeInBox then box:AddChildToVerticalBox(close) end
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

local function isShown(w)
    local ok, vis = pcall(function() return w:GetVisibility() end)
    return ok and vis ~= VIS_COLLAPSED and vis ~= VIS_HIDDEN
end

-- Some menu entries sit inside a border or overlay; dig out the button itself.
local function buttonIn(w, depth)
    if not U.valid(w) or not isShown(w) then return nil end
    if U.className(w) == "W_DialogueButton_C" then return w end
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
    if not U.valid(menu) then return end
    local buttons = {}
    for _, c in ipairs(childrenOf(menu.MainBox)) do
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

local function clearList()
    for _, b in ipairs(listButtons) do
        buttonActions[U.address(b)] = nil
        pcall(function() b:RemoveFromParent() end)
    end
    listButtons = {}
end

local function hideOriginals()
    if #hiddenChildren > 0 then return end
    for _, c in ipairs(childrenOf(menu.MainBox)) do
        local ok, vis = pcall(function() return c:GetVisibility() end)
        if ok and vis ~= VIS_COLLAPSED then
            table.insert(hiddenChildren, { widget = c, vis = vis })
            pcall(function() c:SetVisibility(VIS_COLLAPSED) end)
        end
    end
end

local function showOriginals()
    for _, h in ipairs(hiddenChildren) do
        if U.valid(h.widget) then pcall(function() h.widget:SetVisibility(h.vis) end) end
    end
    hiddenChildren = {}
end

local function isActivated(m)
    local ok, v = pcall(function() return m:IsActivated() end)
    return ok and v == true
end

-- The game's own menu logic only manages its own buttons, so keep exactly one dialogue button
-- in the menu showing the selected appearance whenever one is hovered or focused.
function M.onButtonFocused(btn)
    if not U.valid(menu) or not isActivated(menu) or not U.valid(btn) then return end
    local box = menu.MainBox
    local ok, parent = pcall(function() return btn:GetParent() end)
    if not ok or U.address(parent) ~= U.address(box) then return end
    local target = U.address(btn)
    for _, c in ipairs(childrenOf(box)) do
        if U.className(c) == "W_DialogueButton_C" then
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

local function focus(btn)
    if not U.valid(btn) then return end
    pcall(function() btn:SetFocus() end)
    pcall(function() btn:SetUserFocus(U.playerController()) end)
    M.onButtonFocused(btn)
end

local function buildList(entries)
    clearList()
    hideOriginals()
    for _, e in ipairs(entries) do
        local b = newButton(e.label, e.action)
        if b then
            menu.MainBox:AddChildToVerticalBox(b)
            table.insert(listButtons, b)
        end
    end
    local buttons = listButtons
    local function applyLabels()
        for i, b in ipairs(buttons) do
            if U.valid(b) then setLabel(b, entries[i].label) end
        end
    end
    U.delay(50, "bellui.labels", function()
        applyLabels()
        relinkNavigation()
        focus(buttons[1])
    end)
    U.delay(400, "bellui.labels2", applyLabels)
end

local showMapList

local function backToMenu()
    clearList()
    showOriginals()
    relinkNavigation()
    focus(entryButton)
end

local function showBossList(mapId, bosses)
    local entries = {}
    for _, b in ipairs(bosses) do
        local arena = Data.arena(b.id)
        local suffix = ""
        if not arena then suffix = "（未勘察）"
        elseif arena.unsupported then suffix = "（暂不支持）" end
        local label = b.name .. suffix
        table.insert(entries, {
            label = label,
            action = function()
                local m = menu
                backToMenu()
                pcall(function() m:DeactivateWidget() end)
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

local MENU_BUTTON_FIELDS = { "TeleportBtn_BrokenBell", "TeleportBtn", "ShopButton", "ManualSave", "JhsyButton", "ItemUpgradeButton", "CloseBtn", "AbilityCultivation" }

-- Removes buttons left behind by a previous load of this mod (e.g. after a hot reload).
local function removeStaleButtons(m)
    local own = {}
    for _, field in ipairs(MENU_BUTTON_FIELDS) do
        local ok, w = pcall(function() return m[field] end)
        if ok and U.valid(w) then own[U.address(w)] = true end
    end
    for _, c in ipairs(childrenOf(m.MainBox)) do
        if U.className(c) == "W_DialogueButton_C" and not own[U.address(c)] then
            pcall(function() c:RemoveFromParent() end)
            U.log("bell menu: removed stale button")
        end
    end
end

local function inject(m)
    menu = m
    menuKey = U.address(m)
    listButtons = {}
    hiddenChildren = {}
    removeStaleButtons(m)
    local ok, cls = pcall(function() return m.ShopButton:GetClass() end)
    if not ok or not U.valid(cls) then
        U.log("bell menu: cannot get button class")
        return
    end
    Toast.ButtonClass = cls
    ensureHoverHook()
    entryButton = newButton(Config.EntryLabel, function() showMapList() end)
    if not entryButton then
        U.log("bell menu: failed to create entry button")
        return
    end
    addToMainBox(entryButton)
    local entry = entryButton
    U.delay(50, "bellui.entryLabel", function()
        if U.valid(entry) then setLabel(entry, Config.EntryLabel) end
        relinkNavigation()
    end)
    -- The menu shows or hides some of its own entries while it animates in.
    U.delay(400, "bellui.entryLabel2", function()
        if U.valid(entry) then setLabel(entry, Config.EntryLabel) end
        relinkNavigation()
    end)
    U.log("bell menu: entry button injected")
end

function M.menuOpen()
    for _, m in ipairs(FindAllOf("W_BellMenu_C") or {}) do
        if U.valid(m) and isActivated(m) then return true end
    end
    return false
end

function M.tick(enabled)
    if not enabled then return end
    if U.valid(menu) and not isActivated(menu) and #hiddenChildren > 0 then
        clearList()
        showOriginals()
    end
    for _, m in ipairs(FindAllOf("W_BellMenu_C") or {}) do
        if U.valid(m) and isActivated(m) then
            if U.address(m) == menuKey and U.valid(entryButton) then return end
            local ok, err = pcall(inject, m)
            if not ok then U.log("bell menu inject error: %s", tostring(err)) end
            return
        end
    end
end

function M.handleClick(btn)
    local action = buttonActions[U.address(btn)]
    if action then
        U.gameThread("bellui.click", action)
        return true
    end
    return false
end

return M

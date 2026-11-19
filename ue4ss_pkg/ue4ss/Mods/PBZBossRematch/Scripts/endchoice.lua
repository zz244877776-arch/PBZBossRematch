-- After a rematch victory (optional): two viewport buttons — 再战 / 退出.
-- Off by default; toggled with Config.PostFightChoiceToggleKey (F8).
-- Mouse + gamepad: left/right navigate, A / Confirm activates (same CommonUI path as bell menu).
local U = require("util")
local Config = require("config")
local Toast = require("toast")
local L = require("locale")

local M = {}

local VIS_VISIBLE = 0
local VIS_HIT_TEST_INVISIBLE = 3
local BUTTON_CLASS = "W_DialogueButton_C"
local BUTTON_ZORDER = 200000
local PREFS_PATH = U.DataDir .. "/prefs.lua"

local NAV_LEFT = 0
local NAV_RIGHT = 1
local NAV_UP = 2
local NAV_DOWN = 3
local MOUSE_LOCK_DO_NOT_LOCK = 0

local rematchKey = nil
local quitKey = nil
local titleKey = nil
local onRematch = nil
local onQuit = nil
local visible = false
local inputTaken = false
-- 1 = 再战, 2 = 退出
local focusIndex = 1
local appearanceIndex = nil -- last index we applied DoSelectedAppearance for
local padLatch = {}
local lastInputRefresh = nil

-- Runtime override; nil means "use Config + prefs".
local enabledOverride = nil

local TEMPLATE_BUTTON_FIELDS = {
    "ShopButton", "ManualSave", "AbilityCultivation", "CloseBtn", "TeleportBtn", "JhsyButton",
}

local PAD_LEFT = { "Gamepad_DPad_Left", "Gamepad_Left" }
local PAD_RIGHT = { "Gamepad_DPad_Right", "Gamepad_Right" }
local PAD_CONFIRM = {
    "Gamepad_FaceButton_Bottom",
    "Enter",
    "SpaceBar",
}

local function liveBtn(key)
    return key and U.live(BUTTON_CLASS, key) or nil
end

local function removeKey(key)
    local w = liveBtn(key)
    if w then
        pcall(function() w:UnbindTriggeringInputActionToClick() end)
        pcall(function() w:RemoveFromParent() end)
    end
    return nil
end

local function widgetLib()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
end

local function setMouseVisible(on)
    local pc = U.playerController()
    if not U.valid(pc) then return end
    pcall(function() pc.bShowMouseCursor = on and true or false end)
end

local function enableClickable(btn)
    if not U.valid(btn) then return end
    pcall(function() btn.bIsFocusable = true end)
    pcall(function() btn:SetIsFocusable(true) end)
    pcall(function() btn:SetIsButtonEnabled(true) end)
    pcall(function() btn:SetIsInteractionEnabled(true) end)
end

-- Steal Confirm from any living dialogue button (bell menu / HUD) so gamepad A fires our click.
local function findConfirmTemplate()
    for _, menu in ipairs(FindAllOf("W_BellMenu_C") or {}) do
        if U.valid(menu) then
            for _, field in ipairs(TEMPLATE_BUTTON_FIELDS) do
                local ok, w = pcall(function() return menu[field] end)
                if ok and U.valid(w) then return w end
            end
        end
    end
    for _, w in ipairs(FindAllOf(BUTTON_CLASS) or {}) do
        if U.valid(w) then
            local a = U.address(w)
            if a ~= rematchKey and a ~= quitKey and a ~= titleKey then
                local has = false
                pcall(function()
                    local action = w.TriggeringInputAction
                    if action ~= nil then has = true end
                end)
                if has then return w end
            end
        end
    end
    return nil
end

local function bindConfirm(btn, template)
    if not U.valid(btn) then return end
    enableClickable(btn)
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
    end
    pcall(function() btn:BindTriggeringInputActionToClick() end)
end

local function linkNavigation(a, b)
    if not (U.valid(a) and U.valid(b)) then return end
    -- Side-by-side: stick / D-pad left-right. Up/down also swap so any direction works.
    pcall(function() a:SetNavigationRuleExplicit(NAV_RIGHT, b) end)
    pcall(function() a:SetNavigationRuleExplicit(NAV_LEFT, b) end)
    pcall(function() a:SetNavigationRuleExplicit(NAV_UP, b) end)
    pcall(function() a:SetNavigationRuleExplicit(NAV_DOWN, b) end)
    pcall(function() b:SetNavigationRuleExplicit(NAV_LEFT, a) end)
    pcall(function() b:SetNavigationRuleExplicit(NAV_RIGHT, a) end)
    pcall(function() b:SetNavigationRuleExplicit(NAV_UP, a) end)
    pcall(function() b:SetNavigationRuleExplicit(NAV_DOWN, a) end)
    U.log("endchoice: navigation linked 再战 <-> 退出")
end

-- Only push selected look when the focused button actually changes.
-- Calling DoSelectedAppearance every tick / hover restarts the button anim → flicker.
local function applySelectedAppearance(force)
    if not force and appearanceIndex == focusIndex then return end
    appearanceIndex = focusIndex
    local rematch = liveBtn(rematchKey)
    local quit = liveBtn(quitKey)
    if rematch then pcall(function() rematch:DoSelectedAppearance(focusIndex == 1) end) end
    if quit then pcall(function() quit:DoSelectedAppearance(focusIndex == 2) end) end
end

local function focusButton(index, opts)
    opts = opts or {}
    local next = (index == 2) and 2 or 1
    local changed = next ~= focusIndex
    focusIndex = next
    if changed or opts.forceFocus then
        local btn = liveBtn(focusIndex == 1 and rematchKey or quitKey)
        local pc = U.playerController()
        if U.valid(btn) then
            pcall(function() btn:SetFocus() end)
            pcall(function() btn:SetUserFocus(pc) end)
        end
    end
    -- W_DialogueButton's "hover" look is DoSelectedAppearance (same as bell menu), not a
    -- separate hover skin. Only apply when the focused button changes — never every tick.
    if changed or appearanceIndex == nil then
        applySelectedAppearance(true)
    end
end

local function takeUiInput(focusWidget)
    local pc = U.playerController()
    local wbl = widgetLib()
    if not U.valid(pc) or not U.valid(wbl) then return end
    setMouseVisible(true)
    -- UIOnly: D-pad / stick navigate widgets; GameAndUI fallback keeps HOME working.
    local ok = pcall(function()
        wbl:SetInputMode_UIOnlyEx(pc, focusWidget, MOUSE_LOCK_DO_NOT_LOCK, true)
    end)
    if not ok then
        pcall(function()
            wbl:SetInputMode_GameAndUIEx(pc, focusWidget, MOUSE_LOCK_DO_NOT_LOCK, false, true)
        end)
    end
    if U.valid(focusWidget) then
        pcall(function() focusWidget:SetFocus() end)
        pcall(function() focusWidget:SetUserFocus(pc) end)
    end
    inputTaken = true
end

local function releaseUiInput()
    if not inputTaken then
        setMouseVisible(false)
        return
    end
    inputTaken = false
    local pc = U.playerController()
    local wbl = widgetLib()
    setMouseVisible(false)
    if U.valid(pc) and U.valid(wbl) then
        pcall(function() wbl:SetInputMode_GameOnly(pc, true) end)
        pcall(function() wbl:SetFocusToGameViewport() end)
    end
    U.log("endchoice: game input restored")
end

function M.reset()
    rematchKey = removeKey(rematchKey)
    quitKey = removeKey(quitKey)
    titleKey = removeKey(titleKey)
    onRematch, onQuit, visible = nil, nil, false
    focusIndex = 1
    appearanceIndex = nil
    padLatch = {}
    lastInputRefresh = nil
    releaseUiInput()
end

function M.isVisible()
    return visible
end

local function loadPrefs()
    local t = U.loadTable(PREFS_PATH)
    return type(t) == "table" and t or {}
end

local function savePrefs(t)
    U.saveTable(PREFS_PATH, t)
end

function M.isEnabled()
    if enabledOverride ~= nil then return enabledOverride == true end
    local prefs = loadPrefs()
    if prefs.PostFightChoiceEnabled ~= nil then
        return prefs.PostFightChoiceEnabled == true
    end
    return Config.PostFightChoiceEnabled == true
end

function M.setEnabled(on)
    enabledOverride = on == true
    local prefs = loadPrefs()
    prefs.PostFightChoiceEnabled = enabledOverride
    savePrefs(prefs)
    U.log("post-fight choice %s", enabledOverride and "ON" or "OFF")
    return enabledOverride
end

function M.toggle()
    local on = M.setEnabled(not M.isEnabled())
    local key = Config.PostFightChoiceToggleKey or "F8"
    Toast.show(on and L.T("choice_enabled", key) or L.T("choice_disabled", key), 3500)
    return on
end

local function placeButton(w, xFrac, yFrac, hitTest)
    pcall(function() w:AddToViewport(BUTTON_ZORDER) end)
    pcall(function() w:SetVisibility(hitTest == false and VIS_HIT_TEST_INVISIBLE or VIS_VISIBLE) end)
    pcall(function() w:SetAlignmentInViewport({ X = 0.5, Y = 0.5 }) end)
    pcall(function()
        local pc = U.playerController()
        local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size = wll:GetViewportSize(pc)
        w:SetPositionInViewport({ X = size.X * xFrac, Y = size.Y * yFrac }, true)
    end)
end

local function makeButton(label, xFrac, yFrac, hitTest)
    if not U.valid(Toast.ButtonClass) then
        U.log("endchoice: Toast.ButtonClass missing")
        return nil
    end
    local pc = U.playerController()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ok, w = pcall(function() return wbl:Create(pc, Toast.ButtonClass, pc) end)
    if not ok or not U.valid(w) then
        U.log("endchoice: create failed: %s", tostring(w))
        return nil
    end
    placeButton(w, xFrac, yFrac, hitTest ~= false)
    if hitTest ~= false then enableClickable(w) end
    Toast.setLabel(w, label)
    local key = U.address(w)
    U.delay(50, "endchoice.label", function()
        local live = liveBtn(key)
        if live then
            Toast.setLabel(live, label)
            if hitTest ~= false then enableClickable(live) end
        end
    end)
    return key
end

local function activateFocused()
    if not visible then return end
    local fn = (focusIndex == 1) and onRematch or onQuit
    local label = focusIndex == 1 and "rematch" or "quit"
    U.log("endchoice: activate %s (gamepad/keyboard)", label)
    M.hide()
    if fn then fn() end
end

function M.hide()
    M.reset()
end

function M.show(opts)
    opts = opts or {}
    M.reset()
    local name = opts.bossName or "Boss"
    onRematch = opts.onRematch
    onQuit = opts.onQuit
    focusIndex = 1
    padLatch = {}

    titleKey = makeButton(L.T("victory_title", name), 0.5, 0.32, false)
    rematchKey = makeButton(L.T("rematch"), 0.38, 0.48, true)
    quitKey = makeButton(L.T("quit"), 0.62, 0.48, true)
    if not rematchKey or not quitKey then
        U.log("endchoice: buttons missing, falling back to quit")
        M.reset()
        if onQuit then onQuit() end
        return false
    end

    local rematch = liveBtn(rematchKey)
    local quit = liveBtn(quitKey)
    local template = findConfirmTemplate()
    bindConfirm(rematch, template)
    bindConfirm(quit, template)
    linkNavigation(rematch, quit)
    visible = true
    takeUiInput(rematch)
    focusButton(1, { forceFocus = true })
    U.delay(100, "endchoice.input", function()
        if not visible then return end
        local r, q = liveBtn(rematchKey), liveBtn(quitKey)
        local tmpl = findConfirmTemplate()
        bindConfirm(r, tmpl)
        bindConfirm(q, tmpl)
        linkNavigation(r, q)
        takeUiInput(liveBtn(focusIndex == 1 and rematchKey or quitKey))
        -- Don't re-apply appearance unless focus moved; avoids a second flash.
        focusButton(focusIndex, { forceFocus = true })
    end)
    U.log("endchoice: shown for %s (gamepad nav ready, template=%s)",
        name, tostring(U.valid(template)))
    return true
end

function M.handleClick(widget)
    if not visible or not U.valid(widget) then return false end
    local a = U.address(widget)
    if a and rematchKey and a == rematchKey then
        U.log("endchoice: rematch clicked")
        local fn = onRematch
        M.hide()
        if fn then fn() end
        return true
    end
    if a and quitKey and a == quitKey then
        U.log("endchoice: quit clicked")
        local fn = onQuit
        M.hide()
        if fn then fn() end
        return true
    end
    if a and titleKey and a == titleKey then return true end
    return false
end

function M.onButtonFocused(btn)
    if not visible or not U.valid(btn) then return false end
    local a = U.address(btn)
    if a and rematchKey and a == rematchKey then
        focusButton(1, { fromHover = true })
        return true
    end
    if a and quitKey and a == quitKey then
        focusButton(2, { fromHover = true })
        return true
    end
    return false
end

local function keyJustPressed(names)
    local pc = U.playerController()
    if not U.valid(pc) or not Key then return false end
    for _, name in ipairs(names) do
        local k = Key[name]
        if k then
            local pressed = false
            local okJust = pcall(function()
                pressed = pc:WasInputKeyJustPressed(k) == true
            end)
            if okJust and pressed then return true end
            -- Fallback: edge-detect IsInputKeyDown when WasInputKeyJustPressed is missing.
            if not okJust then
                local okDown, down = pcall(function() return pc:IsInputKeyDown(k) == true end)
                if okDown and down then
                    if not padLatch[name] then
                        padLatch[name] = true
                        return true
                    end
                else
                    padLatch[name] = nil
                end
            end
        end
    end
    return false
end

local function pollGamepadNav()
    if keyJustPressed(PAD_LEFT) then
        focusButton(focusIndex == 1 and 2 or 1)
        return
    end
    if keyJustPressed(PAD_RIGHT) then
        focusButton(focusIndex == 1 and 2 or 1)
        return
    end
    -- Up / Down also toggle (same two-button row).
    if keyJustPressed({ "Gamepad_DPad_Up", "Gamepad_DPad_Down" }) then
        focusButton(focusIndex == 1 and 2 or 1)
        return
    end
    if keyJustPressed(PAD_CONFIRM) then
        activateFocused()
    end
end

function M.tick()
    if not visible then return end
    local rematch = liveBtn(rematchKey)
    local quit = liveBtn(quitKey)
    if not rematch or not quit then
        U.log("endchoice: buttons gone, hiding")
        M.hide()
        return
    end
    -- Alt-tab / focus loss drops the cursor and UI-only input; only re-assert when lost
    -- (not every tick — that steals focus and fights mouse hover).
    local pc = U.playerController()
    local cursorOn = false
    pcall(function() cursorOn = pc and pc.bShowMouseCursor == true end)
    local now = os.clock()
    if (not cursorOn) and ((not lastInputRefresh) or (now - lastInputRefresh) > 0.35) then
        lastInputRefresh = now
        local focus = focusIndex == 1 and rematch or quit
        takeUiInput(focus)
        U.log("endchoice: reassert mouse/UI input after focus loss")
    end
    -- Do NOT rewrite labels / DoSelectedAppearance / enableClickable every tick:
    -- that fights the button's hover anim and makes 再战/退出 flash.
    pollGamepadNav()
end

return M

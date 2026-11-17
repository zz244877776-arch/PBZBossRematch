-- "退出挑战" on the System menu's 退出游戏 page.
--
-- The rows of that page (载入游戏 / 返回至开始界面 / 返回至桌面) are W_SettingsListEntry_Action
-- entries of a settings ListView, built from GameSettingAction items whose captions and actions
-- live in native fields Lua cannot set, so no real list item can be added. Instead one more
-- entry of the same class is created and laid over the list, right under its last row:
--   ListView < SizeBox < Overlay   ->   Overlay also gets  SizeBox(copy of the list's width) < entry
-- It is only there while that page is shown (the same list view also shows the other settings
-- pages). If that fails, a plain button is put on the viewport instead.
--
-- None of the menu's blueprint classes are in the class dump, so the page is recognised by
-- what is displayed rather than by class names, and the first few results are written to the
-- log in full ("quitui dump") to show what the menu is really made of.
local U = require("util")
local Config = require("config")
local Toast = require("toast")

local M = {}

local VIS_VISIBLE = 0
local VIS_COLLAPSED = 1
local VIS_HIDDEN = 2

local SYSTEM_MENU_CLASS = "W_Systembase_C"
local BUTTON_CLASS = "W_DialogueButton_C"
-- Above the System menu, whatever layer the game puts it on.
local BUTTON_ZORDER = 100000
-- Fourth-row position measured on a 16:9 screenshot of the page, as fractions of the viewport
-- height (the menu scales with height). Overridable from config.lua.
local DEFAULT_X = 0.087
local DEFAULT_Y = 0.49

-- Only the Simplified Chinese strings are confirmed (from screenshots); the rest are guesses.
local MARKERS = {
    load = { "载入游戏", "載入遊戲", "load game" },
    title = { "返回至开始界面", "返回至開始介面", "return to title", "back to title", "return to main menu" },
    desktop = { "返回至桌面", "return to desktop", "quit to desktop", "exit to desktop" },
}
local MARKERS_NEEDED = 2
local MARKER_EXTRA_BYTES = 24

local TEXT_CLASSES = { "TextBlock", "RichTextBlock" }
local TEXT_SCAN_INTERVAL_S = 1.0
local MAX_DUMPS = 6
local MAX_DUMP_TEXTS = 40

local H_FILL, V_TOP = 0, 1

local buttonKey = nil
-- The injected list row: its SizeBox wrapper, the entry, and the entry's Button_Action
-- (that is what CommonButtonBase:HandleButtonClicked reports).
local row = nil
local rowFailed = false
local textScanAt = 0
local textFound = false
local dumps = 0
local lastDumpSig = nil
local warnedNoClass = false

local function liveBtn()
    return buttonKey and U.live(BUTTON_CLASS, buttonKey) or nil
end

local function removeButton()
    local w = liveBtn()
    if w then
        pcall(function() w:RemoveFromParent() end)
        U.log("quitui: button removed")
    end
    buttonKey = nil
end

local function liveRow()
    if not row then return nil end
    return U.live("SizeBox", row.wrapKey)
end

local function removeRow()
    local w = liveRow()
    if w then
        pcall(function() w:RemoveFromParent() end)
        U.log("quitui: list row removed")
    end
    row = nil
end

function M.reset()
    removeButton()
    row = nil
    rowFailed = false
    textScanAt, textFound = 0, false
end

-- Function results come back as Lua tables, array properties as TArray wrappers.
local function listOf(arr)
    local out = {}
    if type(arr) == "table" then
        for _, v in pairs(arr) do
            if U.valid(v) then table.insert(out, v) end
        end
        return out
    end
    pcall(function()
        arr:ForEach(function(_, elem)
            local v = elem:get()
            if U.valid(v) then table.insert(out, v) end
        end)
    end)
    return out
end

local function textOf(widget)
    local s = ""
    pcall(function() s = widget:GetText():ToString() end)
    return s or ""
end

local function markerOf(text)
    if not text or text == "" then return nil end
    local s = string.lower(text)
    for id, names in pairs(MARKERS) do
        for _, name in ipairs(names) do
            if #s <= #name + MARKER_EXTRA_BYTES and string.find(s, name, 1, true) then return id end
        end
    end
    return nil
end

local function isTrue(obj, method)
    local ok, v = pcall(function() return obj[method](obj) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- The user widget that owns the tree this widget is the root of.
local function treeOwner(w)
    local okT, tree = pcall(function() return w:GetOuter() end)
    if not okT or not U.valid(tree) or U.className(tree) ~= "WidgetTree" then return nil end
    local okO, owner = pcall(function() return tree:GetOuter() end)
    if okO and U.valid(owner) then return owner end
    return nil
end

-- False only on proof that the widget is not displayed: a collapsed or hidden ancestor, a
-- switcher showing another child, or a list row that is back in its list's pool. `rowOwners`
-- maps row widgets to their list view (false for pooled rows): rows have no parent panel, and
-- a pooled row keeps its Slate widget and its old caption. `chain` collects the ancestor
-- class names.
local function shownInTree(w, rowOwners, chain)
    local function note(s)
        if chain then table.insert(chain, s) end
    end
    local cur = w
    for _ = 1, 48 do
        local ok, vis = pcall(function() return cur:GetVisibility() end)
        if ok and (vis == VIS_COLLAPSED or vis == VIS_HIDDEN) then
            note("(hidden)")
            return false
        end
        local okP, parent = pcall(function() return cur:GetParent() end)
        if not okP or not U.valid(parent) then
            local owner = rowOwners[U.address(cur)]
            if owner == false then
                note("(pooled row)")
                return false
            end
            if owner and isTrue(owner, "IsVisible") == false then
                note("(list not on screen)")
                return false
            end
            parent = owner or treeOwner(cur)
            if not parent then return true end
        end
        local cn = U.className(parent)
        note(cn)
        if string.find(cn, "Switcher", 1, true) then
            local okA, active = pcall(function() return parent:GetActiveWidget() end)
            if okA and U.valid(active) and U.address(active) ~= U.address(cur) then
                note("(inactive tab)")
                return false
            end
        end
        cur = parent
    end
    return true
end

-- A closed menu can stay in memory, so being there is not enough: it has to be activated and
-- still have its Slate widget (IsVisible is false once that is released).
local function menuOpen()
    for _, w in ipairs(FindAllOf(SYSTEM_MENU_CLASS) or {}) do
        local activated = isTrue(w, "IsActivated")
        local visible = isTrue(w, "IsVisible")
        if activated == true and visible ~= false then return true end
        if activated == nil and visible == true then return true end
    end
    return false
end

-- Every list view with the rows it is displaying, and the row -> list map for shownInTree.
local function collectLists()
    local lists, rowOwners = {}, {}
    for _, lv in ipairs(FindAllOf("ListView") or {}) do
        local rows, pooled = {}, {}
        pcall(function() rows = listOf(lv.EntryWidgetPool.ActiveWidgets) end)
        pcall(function() pooled = listOf(lv.EntryWidgetPool.InactiveWidgets) end)
        if #rows == 0 then
            pcall(function() rows = listOf(lv:GetDisplayedEntryWidgets()) end)
        end
        for _, e in ipairs(pooled) do
            local a = U.address(e)
            if a then rowOwners[a] = false end
        end
        for _, e in ipairs(rows) do
            local a = U.address(e)
            if a then rowOwners[a] = lv end
        end
        table.insert(lists, { widget = lv, rows = rows })
    end
    return lists, rowOwners
end

local function settingOf(entry)
    local setting = nil
    pcall(function() setting = entry.Setting end)
    if U.valid(setting) then return setting end
    return nil
end

local function entryLabel(entry)
    local s = ""
    pcall(function()
        local tb = entry.Text_SettingName
        if U.valid(tb) then s = textOf(tb) end
    end)
    if s ~= "" then return s end
    local setting = settingOf(entry)
    if setting then pcall(function() s = setting:GetDisplayName():ToString() end) end
    return s or ""
end

-- The list views that are on screen, with what their rows say. `rule` is set on the one that
-- is the quit page.
local function inspectLists(lists, rowOwners)
    local out = {}
    for _, l in ipairs(lists) do
        local lv, entries = l.widget, l.rows
        if isTrue(lv, "IsVisible") == true then
            if #entries > 0 then
                local info = { widget = lv, entries = entries, class = U.className(lv), labels = {},
                               entryClasses = {}, items = {} }
                local seen, distinct = {}, 0
                for _, e in ipairs(entries) do
                    local label = entryLabel(e)
                    table.insert(info.labels, label)
                    table.insert(info.entryClasses, U.className(e))
                    local id = markerOf(label)
                    if id and not seen[id] then
                        seen[id] = true
                        distinct = distinct + 1
                    end
                end
                local buttons = 0
                pcall(function()
                    for _, item in ipairs(listOf(lv.ListItems)) do
                        local cn = U.className(item)
                        table.insert(info.items, cn)
                        if cn == "GameSettingAction" or string.find(cn, "SettingValue_Button", 1, true) then
                            buttons = buttons + 1
                        end
                    end
                end)
                local rule = nil
                if distinct >= MARKERS_NEEDED then
                    rule = "row text"
                elseif #info.items >= 2 and #info.items <= 6 and buttons == #info.items then
                    -- Other languages: a short page made only of button rows.
                    rule = "button rows"
                end
                if rule and not shownInTree(lv, rowOwners) then
                    info.hidden = rule
                    rule = nil
                end
                info.rule = rule
                table.insert(out, info)
            end
        end
    end
    return out
end

-- Fallback that does not depend on how the page is built: the row captions themselves.
local function scanTexts(rowOwners)
    local hits, seen, distinct = {}, {}, 0
    local sample, sampled = {}, {}
    for _, cls in ipairs(TEXT_CLASSES) do
        for _, tb in ipairs(FindAllOf(cls) or {}) do
            if isTrue(tb, "IsVisible") == true then
                local s = textOf(tb)
                local id = markerOf(s)
                if id then
                    local chain = {}
                    local shown = shownInTree(tb, rowOwners, chain)
                    table.insert(hits, { text = s, class = U.className(tb), shown = shown, chain = chain })
                    if shown and not seen[id] then
                        seen[id] = true
                        distinct = distinct + 1
                    end
                elseif s ~= "" and #s <= 48 and not sampled[s] and #sample < MAX_DUMP_TEXTS then
                    sampled[s] = true
                    table.insert(sample, s)
                end
            end
        end
    end
    return distinct >= MARKERS_NEEDED, hits, sample
end

local function dump(result, lists, rowOwners, hits, sample)
    local parts = { result }
    for _, l in ipairs(lists) do
        table.insert(parts, l.class .. ":" .. table.concat(l.labels, ","))
    end
    table.insert(parts, hits and tostring(#hits) or "-")
    local sig = table.concat(parts, "|")
    if sig == lastDumpSig or dumps >= MAX_DUMPS then return end
    lastDumpSig = sig
    dumps = dumps + 1

    U.log("quitui dump %d/%d: %s, %d visible list(s)", dumps, MAX_DUMPS, result, #lists)
    for _, l in ipairs(lists) do
        local chain = {}
        shownInTree(l.widget, rowOwners, chain)
        U.log("quitui dump: list %s rule=%s hidden=%s rows=[%s]", l.class, tostring(l.rule), tostring(l.hidden),
            table.concat(l.labels, " | "))
        U.log("quitui dump:   entries=[%s] items=[%s]", table.concat(l.entryClasses, ","), table.concat(l.items, ","))
        U.log("quitui dump:   in %s", table.concat(chain, " < "))
    end
    for _, h in ipairs(hits or {}) do
        U.log("quitui dump: text [%s] %s shown=%s in %s", h.text, h.class, tostring(h.shown), table.concat(h.chain, " < "))
    end
    if sample and #sample > 0 then
        U.log("quitui dump: other texts on screen: %s", table.concat(sample, " / "))
    end
end

local function quitPageShown()
    local allLists, rowOwners = collectLists()
    local lists = inspectLists(allLists, rowOwners)
    for _, l in ipairs(lists) do
        if l.rule then
            dump("quit page by " .. l.rule, lists, rowOwners)
            return true, l
        end
    end
    local now = os.clock()
    if now - textScanAt >= TEXT_SCAN_INTERVAL_S then
        textScanAt = now
        local found, hits, sample = scanTexts(rowOwners)
        textFound = found
        dump(found and "quit page by captions" or "quit page not found", lists, rowOwners, hits, sample)
    end
    return textFound, nil
end

local function parentPanel(w)
    local ok, p = pcall(function() return w:GetParent() end)
    if ok and U.valid(p) then return p end
    return nil
end

local function num(v, fallback)
    v = tonumber(v)
    if v == nil or v ~= v then return fallback end
    return v
end

local function setRowLabel(entry, label)
    local ftext = FText(label)
    pcall(function() entry.Text_SettingName:SetText(ftext) end)
end

-- Builds the extra row next to the list in `info`. Returns true when it is on screen.
local function injectRow(info)
    local lv = info.widget
    local box = parentPanel(lv)
    local overlay = box and parentPanel(box)
    if not box or not overlay or U.className(box) ~= "SizeBox" then
        U.log("quitui row: unexpected layout list<%s<%s", box and U.className(box) or "-",
            overlay and U.className(overlay) or "-")
        return false
    end
    local template = info.entries[#info.entries]
    local entryClass, actionClass, sizeBoxClass = nil, nil, nil
    pcall(function() entryClass = template:GetClass() end)
    actionClass = StaticFindObject("/Script/GameSettings.GameSettingAction")
    sizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    local okTree, tree = pcall(function() return overlay:GetOuter() end)
    if not U.valid(entryClass) or not U.valid(actionClass) or not U.valid(sizeBoxClass)
        or not okTree or not U.valid(tree) then
        U.log("quitui row: missing class or widget tree")
        return false
    end

    local pc = U.playerController()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local okE, entry = pcall(function() return wbl:Create(pc, entryClass, pc) end)
    if not okE or not U.valid(entry) then
        U.log("quitui row: create entry failed: %s", tostring(entry))
        return false
    end
    -- Clicking an action row runs ActionSetting->Execute(). A fresh GameSettingAction has neither
    -- a custom nor a named action, so that call does nothing; the click is handled through the
    -- button hook instead. The row must not be left without a setting: the entry dereferences it.
    local okA, action = pcall(function() return StaticConstructObject(actionClass, entry) end)
    if not okA or not U.valid(action) then
        U.log("quitui row: GameSettingAction construct failed: %s", tostring(action))
        return false
    end
    pcall(function() entry.Setting = action end)
    pcall(function() entry.ActionSetting = action end)
    local okSet = false
    pcall(function() okSet = U.address(entry.ActionSetting) == U.address(action) end)
    if not okSet then
        U.log("quitui row: could not assign the action setting; not using the row")
        return false
    end
    local label = Config.ExitLabel or "退出挑战"
    pcall(function() entry:OnSettingAssigned(FText(label)) end)
    setRowLabel(entry, label)

    local okW, wrap = pcall(function() return StaticConstructObject(sizeBoxClass, tree) end)
    if not okW or not U.valid(wrap) then
        U.log("quitui row: SizeBox construct failed: %s", tostring(wrap))
        return false
    end
    pcall(function()
        if box.bOverride_WidthOverride ~= 0 and box.bOverride_WidthOverride ~= false then
            wrap:SetWidthOverride(box.WidthOverride)
        end
    end)
    pcall(function()
        if box.bOverride_MaxDesiredWidth ~= 0 and box.bOverride_MaxDesiredWidth ~= false then
            wrap:SetMaxDesiredWidth(box.MaxDesiredWidth)
        end
    end)
    local okAdd = pcall(function() wrap:AddChild(entry) end)
    if not okAdd then
        U.log("quitui row: SizeBox AddChild failed")
        return false
    end

    -- Row offset: every displayed row has the same height; spacing sits between rows.
    local rowH = 0
    pcall(function() rowH = num(template:GetDesiredSize().Y, 0) end)
    local spacing = 0
    pcall(function() spacing = num(lv:GetVerticalEntrySpacing(), 0) end)
    local count = #info.entries
    pcall(function() count = num(lv:GetNumItems(), count) end)
    if rowH <= 0 then
        U.log("quitui row: row height unknown; not using the row")
        return false
    end
    local pad = { Left = 0, Top = 0, Right = 0, Bottom = 0 }
    local hAlign, vAlign = H_FILL, V_TOP
    pcall(function()
        local s = box.Slot
        pad = { Left = num(s.Padding.Left, 0), Top = num(s.Padding.Top, 0),
                Right = num(s.Padding.Right, 0), Bottom = 0 }
        hAlign = s.HorizontalAlignment
        vAlign = s.VerticalAlignment
    end)
    local top = pad.Top + count * (rowH + spacing)

    local okSlot, slot = pcall(function() return overlay:AddChildToOverlay(wrap) end)
    if not okSlot or not U.valid(slot) then
        U.log("quitui row: AddChildToOverlay failed: %s", tostring(slot))
        pcall(function() wrap:RemoveFromParent() end)
        return false
    end
    pcall(function() slot:SetHorizontalAlignment(hAlign) end)
    pcall(function() slot:SetVerticalAlignment(V_TOP) end)
    pcall(function() slot:SetPadding({ Left = pad.Left, Top = top, Right = pad.Right, Bottom = 0 }) end)
    pcall(function() wrap:SetVisibility(VIS_VISIBLE) end)

    local btn = nil
    pcall(function() btn = entry.Button_Action end)
    row = {
        wrapKey = U.address(wrap),
        entryKey = U.address(entry), entryClass = U.className(entry),
        buttonKey = U.valid(btn) and U.address(btn) or nil,
    }
    local width = "?"
    pcall(function() width = tostring(box.bOverride_WidthOverride) .. "/" .. tostring(box.WidthOverride) end)
    U.log("quitui row: added under %d row(s): rowH=%.1f spacing=%.1f top=%.1f hAlign=%s vAlign(list)=%s width=%s button=%s",
        count, rowH, spacing, top, tostring(hAlign), tostring(vAlign), width,
        U.valid(btn) and U.className(btn) or "none")
    U.delay(100, "quitui.rowLabel", function()
        local live = row and U.live(row.entryClass, row.entryKey)
        if live then setRowLabel(live, label) end
    end)
    return true
end

local function place(btn)
    local pc = U.playerController()
    local x = tonumber(Config.ExitButtonX) or DEFAULT_X
    local y = tonumber(Config.ExitButtonY) or DEFAULT_Y
    pcall(function() btn:AddToViewport(BUTTON_ZORDER) end)
    pcall(function() btn:SetVisibility(VIS_VISIBLE) end)
    pcall(function() btn:SetAlignmentInViewport({ X = 0.0, Y = 0.5 }) end)
    local ok, err = pcall(function()
        local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size = wll:GetViewportSize(pc)
        btn:SetPositionInViewport({ X = size.Y * x, Y = size.Y * y }, true)
        U.log("quitui: button at %.0f,%.0f in a %.0fx%.0f viewport", size.Y * x, size.Y * y, size.X, size.Y)
    end)
    if not ok then U.log("quitui: positioning failed: %s", tostring(err)) end
    pcall(function() btn.bIsFocusable = true end)
    pcall(function() btn:SetIsButtonEnabled(true) end)
    pcall(function() btn:SetIsInteractionEnabled(true) end)
end

local function ensureButton()
    if liveBtn() then return end
    buttonKey = nil
    if not U.valid(Toast.ButtonClass) then
        if not warnedNoClass then
            warnedNoClass = true
            U.log("quitui: no button class yet (the bell menu has not been opened this session)")
        end
        return
    end
    local pc = U.playerController()
    if not pc then return end
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ok, btn = pcall(function() return wbl:Create(pc, Toast.ButtonClass, pc) end)
    if not ok or not U.valid(btn) then
        U.log("quitui: create failed: %s", tostring(btn))
        return
    end
    buttonKey = U.address(btn)
    place(btn)
    local label = Config.ExitLabel or "退出挑战"
    Toast.setLabel(btn, label)
    U.delay(50, "quitui.label", function()
        local live = liveBtn()
        if live then Toast.setLabel(live, label) end
    end)
    U.log("quitui: button shown on the quit page (%s)", label)
end

local function keepRow()
    if not liveRow() then
        row = nil
        return false
    end
    -- The entry's blueprint may refill the caption from its (empty) setting.
    local entry = U.live(row.entryClass, row.entryKey)
    local label = Config.ExitLabel or "退出挑战"
    if entry then
        local s = ""
        pcall(function() s = entry.Text_SettingName:GetText():ToString() end)
        if s ~= label then setRowLabel(entry, label) end
    end
    return true
end

function M.tick(active)
    if not active or not menuOpen() then
        if buttonKey then removeButton() end
        if row then removeRow() end
        textScanAt, textFound = 0, false
        return
    end
    local shown, info = quitPageShown()
    if not shown then
        if buttonKey then removeButton() end
        if row then removeRow() end
        return
    end
    if keepRow() then return end
    if info and not rowFailed then
        local ok, res = pcall(injectRow, info)
        if ok and res then
            removeButton()
            return
        end
        rowFailed = true
        U.log("quitui row: injection failed (%s); using the viewport button", ok and "see above" or tostring(res))
    end
    ensureButton()
end

local function closeSystemMenu()
    for _, w in ipairs(FindAllOf(SYSTEM_MENU_CLASS) or {}) do
        if isTrue(w, "IsActivated") == true then
            local ok, err = pcall(function() w:DeactivateWidget() end)
            U.log("quitui: closing the System menu: %s", ok and "ok" or tostring(err))
        end
    end
end

function M.handleClick(widget)
    if not U.valid(widget) then return false end
    local addr = U.address(widget)
    local fromRow = row and row.buttonKey and addr == row.buttonKey
    if not fromRow and not (buttonKey and addr == buttonKey) then return false end
    U.log("quitui: exit challenge clicked (%s)", fromRow and "list row" or "viewport button")
    -- The click is still being dispatched by the widget; tear the menu down afterwards.
    U.delay(50, "quitui.quit", function()
        removeButton()
        removeRow()
        closeSystemMenu()
        require("challenge").quit()
    end)
    return true
end

return M

local U = require("util")

local M = {}

local VIS_HIT_TEST_INVISIBLE = 3

M.ButtonClass = nil

local current = nil

-- W_DialogueButton draws its label with two rich text blocks (normal and selected state),
-- so the label has to be written into both of them.
local TEXT_WIDGETS = { "PBZCommonLocRichText_39", "Selected" }

function M.setLabel(btn, text, verbose)
    local ftext = FText(text)
    pcall(function() btn:SetWidgetText({ ChoiceText = ftext, ChoiceIndex = 0, Last = false }) end)
    pcall(function() btn:UpdateButtonText(ftext) end)
    for _, name in ipairs(TEXT_WIDGETS) do
        local ok, err = pcall(function()
            local rt = btn[name]
            if U.valid(rt) then rt:SetText(ftext) end
        end)
        if verbose then
            local back = ""
            pcall(function() back = btn[name]:GetText():ToString() end)
            U.log("label %s.%s ok=%s readback=%s %s", text, name, tostring(ok), back, ok and "" or tostring(err))
        end
    end
end

-- Called when the world changes: the old toast widget may already be freed, so just forget it.
function M.reset()
    current = nil
end

local function liveToast(key)
    return U.live("W_DialogueButton_C", key)
end

-- `current` is an address, never a wrapper: removed toasts are freed by the engine's next GC.
local function removeCurrent()
    local w = liveToast(current)
    if w then pcall(function() w:RemoveFromParent() end) end
    current = nil
end

function M.show(text, durationMs)
    U.log("toast: %s", text)
    if not U.valid(M.ButtonClass) then return end
    removeCurrent()
    local pc = U.playerController()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ok, w = pcall(function() return wbl:Create(pc, M.ButtonClass, pc) end)
    if not ok or not U.valid(w) then
        U.log("toast create failed: %s", tostring(w))
        return
    end
    local key = U.address(w)
    current = key
    pcall(function() w:AddToViewport(500) end)
    pcall(function() w:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)
    pcall(function() w:SetAlignmentInViewport({ X = 0.5, Y = 0.5 }) end)
    pcall(function()
        local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size = wll:GetViewportSize(pc)
        w:SetPositionInViewport({ X = size.X * 0.5, Y = size.Y * 0.2 }, true)
    end)
    M.setLabel(w, text)
    U.delay(50, "toast.label", function()
        local live = liveToast(key)
        if live then M.setLabel(live, text) end
    end)

    U.delay(durationMs or 3000, "toast.hide", function()
        if current == key then removeCurrent() end
    end)
end

return M

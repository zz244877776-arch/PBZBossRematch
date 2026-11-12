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

local function removeCurrent()
    if U.valid(current) then pcall(function() current:RemoveFromParent() end) end
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
    current = w
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
        if U.valid(w) then M.setLabel(w, text) end
    end)

    local mine = w
    U.delay(durationMs or 3000, "toast.hide", function()
        if current == mine then removeCurrent() end
    end)
end

return M

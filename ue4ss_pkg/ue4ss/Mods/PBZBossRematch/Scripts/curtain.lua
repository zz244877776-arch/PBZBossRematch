-- Black screen over the travel / boss loading, using the player camera's own fade.
-- UMG widgets (toasts) still draw on top of it.
local U = require("util")

local M = {}

local BLACK = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }

-- nil = no curtain, "fading" = animating to black, "covered" = held black
local state = nil
local ownCall = false

local function cameraManager()
    local pc = U.playerController()
    if not U.valid(pc) then return nil end
    local ok, cm = pcall(function() return pc.PlayerCameraManager end)
    if ok and U.valid(cm) then return cm end
    return nil
end

local function withCamera(fn)
    local cm = cameraManager()
    if not cm then return false end
    ownCall = true
    local ok = pcall(fn, cm)
    ownCall = false
    return ok
end

function M.isCovered() return state ~= nil end

function M.cover()
    state = "covered"
    U.log("curtain: cover")
    M.hold()
end

-- Animated fade to black; the hard hold only starts once the fade has finished.
function M.fadeOut(seconds)
    if state then return end
    state = "fading"
    U.log("curtain: fade out")
    withCamera(function(cm) cm:StartCameraFade(0.0, 1.0, seconds, BLACK, false, true) end)
    U.delay(math.floor(seconds * 1000) + 50, "curtain.fadeDone", function()
        if state == "fading" then
            state = "covered"
            M.hold()
        end
    end)
end

-- Map loads, new camera managers and the game's own travel fades all reset the camera fade,
-- so this runs every frame while covered and right after any fade the game starts itself.
function M.hold(camera)
    if state ~= "covered" then return end
    if U.valid(camera) then
        ownCall = true
        pcall(function() camera:SetManualCameraFade(1.0, BLACK, false) end)
        ownCall = false
        return
    end
    withCamera(function(cm) cm:SetManualCameraFade(1.0, BLACK, false) end)
end

function M.onExternalFade()
    if ownCall then return end
    M.hold()
end

function M.reveal(seconds)
    if not state then return end
    state = nil
    U.log("curtain: reveal")
    local ok = withCamera(function(cm) cm:StartCameraFade(1.0, 0.0, seconds or 0.8, BLACK, false, false) end)
    if not ok then withCamera(function(cm) cm:StopCameraFade() end) end
end

return M

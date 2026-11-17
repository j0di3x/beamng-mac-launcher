-- PedalBox force feedback bridge (installed by BeamNG Launcher for Mac).
--
-- On a Mac the game can't talk to the wheel's motor (Wine has no force feedback driver for it).
-- This mod takes the steering force BeamNG already computes and sends it over UDP to
-- PedalBox (127.0.0.1:47290), which plays it on the wheel.
--
-- It uses hydros.enableVirtualWheel, BeamNG's own hook for wheels it doesn't drive itself:
-- the steering angle still comes straight from the input, only the force goes out to PedalBox.

local M = {}

local PORT = 47290
local FFMAX = 10            -- hydros.lua scales forces to -FFmax..FFmax
local udp = nil

-- hydros' torque pushes the wheel towards negative steering; PedalBox wants + = push right
local function sendForce(_, _, torque)
  if not udp then return end
  local f = -(torque or 0) / FFMAX
  if f ~= f then f = 0 end  -- NaN
  -- steering position and speed ride along: PedalBox adds a speed-based return-to-centre push
  local speed = electrics.values.wheelspeed or electrics.values.airspeed or 0
  udp:sendto(string.format("PBF1 %.4f %.3f %.2f", f, input.steering or 0, speed), "127.0.0.1", PORT)
end

local function steeringAngle()
  return input.steering or 0
end

local function hook()
  hydros.enableVirtualWheel(true, steeringAngle, sendForce)
end

local function onExtensionLoaded()
  if not hydros or not hydros.enableVirtualWheel or not socket then
    log("W", "pedalboxFFB", "force feedback bridge not started: game API missing")
    return false
  end
  udp = socket.udp()
  udp:settimeout(0)
  hook()
  -- the game sends its own FFB setup later (e.g. gamepad vibration), which would switch the
  -- bridge off again; the game calls hydros.onFFBConfigChanged by name, so wrap it and re-hook after
  if not hydros.pedalboxWrapped then
    local original = hydros.onFFBConfigChanged
    hydros.onFFBConfigChanged = function(...)
      original(...)
      if udp then hook() end
    end
    hydros.pedalboxWrapped = true
  end
  log("I", "pedalboxFFB", "force feedback goes to PedalBox on 127.0.0.1:" .. PORT)
end

local function onExtensionUnloaded()
  if udp then
    sendForce(nil, nil, 0)
    udp:close()
    udp = nil
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M

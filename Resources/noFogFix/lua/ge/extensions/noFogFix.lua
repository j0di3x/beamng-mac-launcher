-- Keeps fog off. Workaround for the D3DMetal (GameHub/GPTK) fog bug on macOS,
-- where the fog post-effect covers everything below the horizon.
local M = {}

local function killFog()
  if core_environment and core_environment.getFogDensity then
    local fog = core_environment.getFogDensity()
    if fog and fog > 0 then
      core_environment.setFogDensity(0)
      log('I', 'noFogFix', 'fog density ' .. tostring(fog) .. ' -> 0')
    end
  end
end

local pending = 0
M.onClientPostStartMission = function() pending = 30 end -- run again after the map finishes setting its environment
M.onEnvironmentChanged = function(changes)
  if changes and changes.fogDensity and changes.fogDensity > 0 then pending = 1 end
end
M.onUpdate = function()
  if pending > 0 then
    pending = pending - 1
    if pending == 0 then killFog() end
  end
end
M.onExtensionLoaded = function() killFog() end

return M

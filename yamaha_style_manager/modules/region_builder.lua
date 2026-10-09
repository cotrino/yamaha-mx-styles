-- @noindex
local reaper = reaper
local Regions = {}

local COLORS = {
  ["Intro"] = 0x00A5FFFF, ["Main"] = 0x00CC44FF, ["Fill In"] = 0xFF8800FF,
  ["Ending"] = 0xEE3333FF, ["Break"] = 0xAA55FFFF,
}

local function color_for(name)
  for prefix, color in pairs(COLORS) do
    if name:find(prefix, 1, true) == 1 then return color | 0x1000000 end
  end
  return 0
end

function Regions.create(markers, end_tick, ppq)
  if reaper.SNM_SetIntConfigVar then
    reaper.SNM_SetIntConfigVar("seekplay", 1)
    reaper.SNM_SetIntConfigVar("smoothseek", 1)
    reaper.SNM_SetIntConfigVar("smoothseek_mode", 2)
  end
  local count = 0
  for index, marker in ipairs(markers) do
    local next_marker = markers[index + 1]
    local finish_tick = next_marker and next_marker.tick or end_tick
    if finish_tick > marker.tick then
      local start_time = reaper.TimeMap2_QNToTime(0, marker.tick / ppq)
      local end_time = reaper.TimeMap2_QNToTime(0, finish_tick / ppq)
      reaper.AddProjectMarker2(0, true, start_time, end_time, marker.name, -1, color_for(marker.name))
      count = count + 1
    end
  end
  return count
end

return Regions

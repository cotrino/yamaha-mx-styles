-- @noindex
local reaper = reaper
local Regions = {}

-- One table drives both the REAPER region colours and the Launchpad pad colours (pad = Launchpad palette index).
Regions.SECTIONS = {
  { kind = "Intro", prefix = "Intro", rgb = { 60, 120, 255 }, pad = 45 },
  { kind = "Main", prefix = "Main", rgb = { 32, 208, 64 }, pad = 21 },
  { kind = "Fill", prefix = "Fill", rgb = { 255, 128, 0 }, pad = 9 },
  { kind = "Break", prefix = "Break", rgb = { 255, 80, 176 }, pad = 53 },
  { kind = "Ending", prefix = "Ending", rgb = { 224, 32, 32 }, pad = 5 },
}

function Regions.section_for(name)
  for _, section in ipairs(Regions.SECTIONS) do
    if name:find(section.prefix, 1, true) == 1 then return section end
  end
end

local function color_for(name)
  local section = Regions.section_for(name)
  if not section then return 0 end
  return reaper.ColorToNative(section.rgb[1], section.rgb[2], section.rgb[3]) | 0x1000000
end
function Regions.create(markers, end_tick, ppq)
  if reaper.SNM_SetIntConfigVar then
    reaper.SNM_SetIntConfigVar("seekplay", 1)
    reaper.SNM_SetIntConfigVar("smoothseek", 0)
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

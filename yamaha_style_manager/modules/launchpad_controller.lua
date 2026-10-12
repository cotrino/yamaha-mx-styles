-- @noindex
-- Launchpad Mini MK3 control through its "LPMiniMK3 MIDI" port in Custom mode 3 ("User"), whose factory
-- layout is a Drum Rack: the left 4x8 block sends/receives notes 36 (bottom-left) .. 67 (top-right of
-- the block). The top row of that block (64-67) is region 1-4, the next row down region 5-8, etc.
-- Pads light with the section colour; the playing section turns white.
local reaper = reaper
local Launchpad = { last_event = 0, regions = {}, output = nil, input = nil, active = false,
  lit = nil, parts = {}, nano_input = nil, voices = nil, yamaha_output = nil, mapper = nil }

local COLORS = { Intro = 45, Main = 21, Fill = 9, Ending = 5, Break = 53 }
local COLOR_ACTIVE, COLOR_OFF = 3, 0
local MAX_PADS = 32

local function color_for(name)
  for prefix, color in pairs(COLORS) do
    if name:find(prefix, 1, true) == 1 then return color end
  end
  return 37
end

local function pad_note(index) -- region index (1 = top-left pad) -> note
  local row, col = (index - 1) // 4, (index - 1) % 4
  return 36 + (7 - row) * 4 + col
end

local function note_to_index(note)
  if note < 36 or note > 67 then return nil end
  local offset = note - 36
  return (7 - offset // 4) * 4 + offset % 4 + 1
end

local function output_named(name)
  for index = 0, 63 do
    local ok, device_name = reaper.GetMIDIOutputName(index, "")
    if ok and device_name:lower():find(name:lower(), 1, true) then return index end
  end
end

local function input_named(name)
  for index = 0, 63 do
    local ok, device_name = reaper.GetMIDIInputName(index, "")
    if ok and device_name:lower():find(name:lower(), 1, true) then return index end
  end
end

local function set_pad(index, color)
  if Launchpad.output then reaper.StuffMIDIMessage(16 + Launchpad.output, 0x90, pad_note(index), color) end
end

local function collect_regions()
  local regions = {}
  local _, markers, region_total = reaper.CountProjectMarkers(0)
  for index = 0, markers + region_total - 1 do
    local _, is_region, start_pos, end_pos, name = reaper.EnumProjectMarkers3(0, index)
    if is_region then regions[#regions + 1] = { start = start_pos, finish = end_pos, name = name } end
  end
  return regions
end

function Launchpad.setup(folder, region_count, devices, rig, mapper)
  devices = devices or {}
  local index = math.floor(reaper.GetMediaTrackInfo_Value(folder, "IP_TRACKNUMBER")) - 1
  reaper.InsertTrackAtIndex(index, true)
  local track = reaper.GetTrack(0, index)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "[MIDI] Launchpad Controller", true)
  Launchpad.output = devices.launchpad_output or output_named("Launchpad") or output_named("LPMini")
  Launchpad.input = devices.launchpad_input or input_named("Launchpad") or input_named("LPMini")
  Launchpad.regions = collect_regions()
  Launchpad.voices = rig and rig.voices
  Launchpad.parts = rig and rig.children or {}
  Launchpad.nano_input = devices.nano_input or input_named("nanoKONTROL")
  Launchpad.yamaha_output = rig and rig.output
  Launchpad.mapper = mapper
  Launchpad.lit = nil
  for pad = 1, MAX_PADS do set_pad(pad, COLOR_OFF) end
  for i, region in ipairs(Launchpad.regions) do
    if i <= MAX_PADS then set_pad(i, color_for(region.name)) end
  end
  Launchpad.active = (Launchpad.input ~= nil or Launchpad.nano_input ~= nil) and #Launchpad.regions > 0
  if Launchpad.mapper then Launchpad.mapper.send_voices(Launchpad.yamaha_output, Launchpad.voices) end
  return {
    message = (Launchpad.output and Launchpad.input) and
      "Launchpad ready: press its USER button; pads = sections." or
      "Launchpad input/output not detected; MIDI region controls remain inactive.",
  }
end

function Launchpad.shutdown()
  for pad = 1, MAX_PADS do set_pad(pad, COLOR_OFF) end
  Launchpad.active = false
end

local function jump_to(index)
  local region = Launchpad.regions[index]
  if not region then return end
  reaper.SetEditCurPos2(0, region.start, true, true)
  if reaper.GetPlayState() & 1 == 0 then reaper.OnPlayButton() end
  if Launchpad.mapper then Launchpad.mapper.send_voices(Launchpad.yamaha_output, Launchpad.voices) end
end

function Launchpad.step(direction)
  local current = Launchpad.lit or 1
  jump_to(math.max(1, math.min(#Launchpad.regions, current + direction)))
end

local function update_active_lights()
  if not Launchpad.output or reaper.GetPlayState() & 1 == 0 then return end
  local position = reaper.GetPlayPosition()
  local current
  for i, region in ipairs(Launchpad.regions) do
    if position >= region.start and position < region.finish then current = i break end
  end
  if current ~= Launchpad.lit then
    if Launchpad.lit and Launchpad.lit <= MAX_PADS then
      set_pad(Launchpad.lit, color_for(Launchpad.regions[Launchpad.lit].name))
    end
    if current and current <= MAX_PADS then set_pad(current, COLOR_ACTIVE) end
    Launchpad.lit = current
  end
end

-- Korg nanoKONTROL2 (CC mode defaults): sliders CC 0-7 = part volume, knobs 16-23 = part pan,
-- S 32-39 = solo, M 48-55 = mute, R 64-71 = re-send that part's voice. Transport: Play 41, Stop 42,
-- Track < / > (58 / 59) or Marker < / > (61 / 62) = previous / next section.
local function nano_message(cc, value)
  local lane, base = cc % 8, cc - cc % 8
  local track = Launchpad.parts[lane + 1]
  if base == 0 and cc < 8 and track then
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", (value / 100) ^ 2)
  elseif base == 16 and track then
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", (value - 63.5) / 63.5)
  elseif base == 32 and track and value > 0 then
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", reaper.GetMediaTrackInfo_Value(track, "I_SOLO") == 0 and 1 or 0)
  elseif base == 48 and track and value > 0 then
    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 0 and 1 or 0)
  elseif base == 64 and track and value > 0 and Launchpad.mapper and Launchpad.voices then
    Launchpad.mapper.send_voices(Launchpad.yamaha_output, { Launchpad.voices[lane + 1] })
  elseif value > 0 and cc == 41 then reaper.OnPlayButton()
  elseif value > 0 and cc == 42 then reaper.OnStopButton()
  elseif value > 0 and (cc == 59 or cc == 62) then Launchpad.step(1)
  elseif value > 0 and (cc == 58 or cc == 61) then Launchpad.step(-1)
  end
end

function Launchpad.poll()  if not Launchpad.active then return end
  for event_index = 0, 127 do
    local event_id, message, _, flags = reaper.MIDI_GetRecentInputEvent(event_index)
    if not event_id or event_id == 0 then break end
    if event_id == Launchpad.last_event then break end
    if event_index == 0 then Launchpad.last_event = event_id end
    local input_id = flags and (flags & 0xFFFF)
    if input_id == Launchpad.nano_input and message and #message >= 3 and (message:byte(1) & 0xF0) == 0xB0 then
      nano_message(message:byte(2), message:byte(3))
    end
    if input_id == Launchpad.input and message and #message >= 3
      and (message:byte(1) & 0xF0) == 0x90 and message:byte(3) > 0 then
      local index = note_to_index(message:byte(2))
      if index then jump_to(index) end
    end
  end
  update_active_lights()
end

return Launchpad

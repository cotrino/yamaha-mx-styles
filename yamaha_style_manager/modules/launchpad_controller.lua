-- @noindex
local reaper = reaper
local Launchpad = { last_event = 0, actions = {}, output = nil }

local PAD_MAP = {
  [0] = { 1, 63 }, [1] = { 2, 63 }, [2] = { 3, 63 }, [3] = { 4, 63 },
  [16] = { 5, 60 }, [17] = { 6, 60 }, [18] = { 7, 60 }, [19] = { 8, 60 },
  [32] = { 9, 47 }, [33] = { 10, 47 }, [34] = { 11, 47 }, [35] = { 12, 47 },
  [48] = { 13, 15 }, [49] = { 14, 15 }, [50] = { 15, 15 }, [51] = { 16, 15 },
}

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

function Launchpad.setup(folder, region_count)
  local index = math.floor(reaper.GetMediaTrackInfo_Value(folder, "IP_TRACKNUMBER")) - 1
  reaper.InsertTrackAtIndex(index, true)
  local track = reaper.GetTrack(0, index)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "[MIDI] Launchpad Controller", true)
  Launchpad.output = output_named("Launchpad")
  Launchpad.input = input_named("Launchpad")
  for pad, map in pairs(PAD_MAP) do
    if Launchpad.output then reaper.StuffMIDIMessage(16 + Launchpad.output, 0x90, pad, map[2]) end
    Launchpad.actions[pad] = reaper.NamedCommandLookup(string.format("_SWS_SM_GOTO_REG%d", map[1]))
  end
  return {
    message = (Launchpad.output and Launchpad.input) and "Launchpad LEDs initialized." or
      "Launchpad input/output not detected; MIDI region controls remain inactive.",
  }
end

function Launchpad.poll()
  for event_index = 0, 127 do
    local event_id, message, _, flags = reaper.MIDI_GetRecentInputEvent(event_index)
    if not event_id or event_id == 0 then break end
    if event_id == Launchpad.last_event then break end
    if event_index == 0 then Launchpad.last_event = event_id end
    local input_id = flags and (flags & 0xFFFF)
    if Launchpad.input ~= nil and input_id == Launchpad.input and message and #message >= 3
      and (message:byte(1) & 0xF0) == 0x90 and message:byte(3) > 0 then
      local action = Launchpad.actions[message:byte(2)]
      if action and action ~= 0 then reaper.Main_OnCommand(action, 0) end
    end
  end
end

return Launchpad

-- @noindex
-- Launchpad Mini MK3 control. The script switches the pad to PROGRAMMER mode by SysEx (no need to press USER), so
-- the 8x8 grid reports notes 11-88 (bottom-left = 11, top-right = 88) and accepts RGB colours by SysEx.
-- Rows 2-8 from the bottom hold the style sections (top row first); the bottom row holds the arranger controls.
-- LEDs are sent to every Launchpad output port and pad presses are read from every Launchpad input port.
local reaper = reaper
local Launchpad = { last_event = 0, regions = {}, output = nil, input = nil, active = false,
  lit = nil, parts = {}, nano_input = nil, voices = nil, yamaha_output = nil, mapper = nil }

local Regions = require("region_builder")
local MAX_PADS = 56
local LOOKAHEAD = 0.03 -- seconds before a section end at which the arranger jumps (defer jitter margin)
local HEADER = string.char(0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D)

local function rgb_for(name)
  local section = Regions.section_for(name)
  if not section then return 40, 40, 40 end
  return section.rgb[1] // 2, section.rgb[2] // 2, section.rgb[3] // 2
end

local function kind_of(name)
  local section = Regions.section_for(name)
  return section and section.kind or "Other"
end

local function pad_note(index) -- region index (1 = top-left pad) -> programmer-mode note
  local row, col = (index - 1) // 8, (index - 1) % 8
  return (8 - row) * 10 + col + 1
end

local function note_to_index(note)
  local row, col = note // 10, note % 10
  if row < 2 or row > 8 or col < 1 or col > 8 then return nil end
  return (8 - row) * 8 + col
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

-- The Launchpad exposes two ports ("... MIDI" and "MIDIIN2/MIDIOUT2 (...)"); LEDs are driven on all of them and
-- pad presses are read from all of them, because which one carries what depends on the mode and OS driver.
local function matching_ports(count, getter)
  local ports = {}
  for id = 0, count - 1 do
    local ok, name = getter(id, "")
    local lower = ok and name and name:lower() or ""
    if lower:find("launchpad", 1, true) or lower:find("lpmini", 1, true) then ports[#ports + 1] = id end
  end
  return ports
end

local function hardware(id, data) reaper.SendMIDIMessageToHardware(id, data) end

local function send_led(status, note, value)
  for _, id in ipairs(Launchpad.outputs or {}) do hardware(id, string.char(status, note, value)) end
end

-- LED updates are queued and sent as one SysEx per port: { [note] = spec bytes }.
local queue, queue_order = {}, {}
local function queue_led(note, ...)
  if not queue[note] then queue_order[#queue_order + 1] = note end
  queue[note] = string.char(...)
end

local function led_rgb(note, r, g, b) queue_led(note, 3, note, math.min(127, r), math.min(127, g), math.min(127, b)) end
local function led_off(note) queue_led(note, 0, note, 0) end
local function led_pulse(note, palette) queue_led(note, 2, note, palette) end

local function flush_leds()
  if #queue_order == 0 then return end
  local body = {}
  for _, note in ipairs(queue_order) do body[#body + 1] = queue[note] end
  local message = HEADER .. string.char(0x03) .. table.concat(body) .. string.char(0xF7)
  for _, id in ipairs(Launchpad.outputs or {}) do hardware(id, message) end
  queue, queue_order = {}, {}
end

local function set_pad(index, name)
  local note = pad_note(index)
  if name then led_rgb(note, rgb_for(name)) else led_off(note) end
end

local function set_programmer_mode(enabled)
  for _, id in ipairs(Launchpad.outputs or {}) do
    hardware(id, HEADER .. string.char(0x0E, enabled and 1 or 0, 0xF7))
  end
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
  Launchpad.outputs = matching_ports(reaper.GetNumMIDIOutputs(), reaper.GetMIDIOutputName)
  Launchpad.inputs = matching_ports(reaper.GetNumMIDIInputs(), reaper.GetMIDIInputName)
  if Launchpad.output then
    local known = false
    for _, id in ipairs(Launchpad.outputs) do if id == Launchpad.output then known = true end end
    if not known then Launchpad.outputs[#Launchpad.outputs + 1] = Launchpad.output end
  end
  if Launchpad.input then
    local known = false
    for _, id in ipairs(Launchpad.inputs) do if id == Launchpad.input then known = true end end
    if not known then Launchpad.inputs[#Launchpad.inputs + 1] = Launchpad.input end
  end
  Launchpad.input_set = {}
  for _, id in ipairs(Launchpad.inputs) do Launchpad.input_set[id] = true end
  Launchpad.regions = collect_regions()
  Launchpad.rig = rig
  Launchpad.voices = rig and rig.voices
  Launchpad.parts = rig and rig.children or {}
  Launchpad.nano_input = devices.nano_input or input_named("nanoKONTROL")
  Launchpad.yamaha_output = rig and rig.output
  Launchpad.mapper = mapper
  Launchpad.lit, Launchpad.cur, Launchpad.pending, Launchpad.after = nil, nil, nil, nil
  Launchpad.last_main = nil
  set_programmer_mode(true)
  for pad = 1, MAX_PADS do set_pad(pad, nil) end
  for i, region in ipairs(Launchpad.regions) do
    if i <= MAX_PADS then set_pad(i, region.name) end
  end
  Launchpad.draw_controls()
  flush_leds()
  Launchpad.active = (#Launchpad.inputs > 0 or Launchpad.nano_input ~= nil) and #Launchpad.regions > 0
  if Launchpad.mapper then Launchpad.mapper.send_voices(Launchpad.yamaha_output, Launchpad.voices) end
  return {
    message = (#Launchpad.inputs > 0 and #Launchpad.outputs > 0) and
      "Launchpad ready (Programmer mode): pads = sections, bottom row = controls." or
      "Launchpad input/output not detected; MIDI region controls remain inactive.",
  }
end

-- Re-enters Programmer mode and redraws every LED (use after replugging or if the pad shows its own layout).
function Launchpad.reinit()
  set_programmer_mode(true)
  for pad = 1, MAX_PADS do set_pad(pad, nil) end
  for i, region in ipairs(Launchpad.regions) do
    if i <= MAX_PADS then set_pad(i, region.name) end
  end
  Launchpad.lit = nil
  Launchpad.draw_controls()
  flush_leds()
end

function Launchpad.shutdown()
  for pad = 1, MAX_PADS do set_pad(pad, nil) end
  for note = 11, 18 do led_off(note) end
  flush_leds()
  set_programmer_mode(false)
  Launchpad.active = false
end
-- Bottom row of the grid: arranger controls.
local CONTROL = { [11] = "play", [12] = "autofill", [13] = "ending", [14] = "voices",
  [15] = "tempo_down", [16] = "tempo_up", [17] = "prev", [18] = "next" }
local CONTROL_RGB = { play = { 0, 127, 0 }, autofill = { 127, 100, 0 }, ending = { 127, 0, 0 }, voices = { 0, 60, 127 },
  tempo_down = { 0, 110, 110 }, tempo_up = { 0, 110, 110 }, prev = { 127, 30, 90 }, next = { 127, 30, 90 } }
Launchpad.auto_fill = true
Launchpad.cur, Launchpad.last_main, Launchpad.after, Launchpad.pending, Launchpad.holdoff = nil, nil, nil, nil, 0

function Launchpad.draw_controls()
  for note, name in pairs(CONTROL) do
    local c = CONTROL_RGB[name]
    if name == "autofill" and not Launchpad.auto_fill then c = { 20, 16, 0 } end
    if name == "play" and reaper.GetPlayState() & 1 == 1 then c = { 127, 127, 127 } end
    led_rgb(note, c[1], c[2], c[3])
  end
end
local function region_at(position)
  for i, region in ipairs(Launchpad.regions) do
    if position >= region.start and position < region.finish then return i end
  end
end

local function find_region(predicate)
  for i, region in ipairs(Launchpad.regions) do if predicate(region.name) then return i end end
end

local function letter_of(name) return name:match("(%a+)%s*$") end

local function set_loop(index)
  local region = index and Launchpad.regions[index]
  if region and kind_of(region.name) == "Main" then
    reaper.GetSet_LoopTimeRange2(0, true, true, region.start, region.finish, false)
    reaper.GetSetRepeat(1)
  else
    reaper.GetSetRepeat(0)
  end
end

-- Moves to a section immediately and keeps loop state, bookkeeping and voices consistent.
local function go(index, from_pending)
  local region = Launchpad.regions[index]
  if not region then return end
  Launchpad.cur = index
  if kind_of(region.name) == "Main" then Launchpad.last_main = index end
  set_loop(index)
  reaper.SetEditCurPos2(0, region.start, false, true)
  Launchpad.holdoff = reaper.time_precise() + 0.2
  if not from_pending then Launchpad.pending = nil end
end

local function next_bar(position)
  local _, measures = reaper.TimeMap2_timeToBeats(0, position)
  local at = reaper.TimeMap2_beatsToTime(0, 0, measures + 1)
  if at - position > 20 then return position end
  return at
end

local function after_section(index)
  local region = Launchpad.regions[index]
  local kind = kind_of(region.name)
  if kind == "Intro" then
    local letter = letter_of(region.name)
    return find_region(function(n) return kind_of(n) == "Main" and letter_of(n) == letter end)
      or find_region(function(n) return kind_of(n) == "Main" end)
  end
  if kind == "Fill" or kind == "Break" then return Launchpad.after or Launchpad.last_main end
end

local function fill_before(from_index, to_index)
  local from_letter = letter_of(Launchpad.regions[from_index].name)
  return find_region(function(n)
    return kind_of(n) == "Fill" and n:lower():find("fill in " .. (from_letter or "?"):lower() .. (from_letter or "?"):lower(), 1, true)
  end)
end

-- Requests a section: starts immediately when stopped, otherwise at the next bar line.
function Launchpad.trigger(index)
  local region = Launchpad.regions[index]
  if not region then return end
  if reaper.GetPlayState() & 1 == 0 then
    Launchpad.after = nil
    go(index)
    reaper.OnPlayButton()
    if Launchpad.mapper then Launchpad.mapper.send_voices(Launchpad.yamaha_output, Launchpad.voices) end
    return
  end
  if index == Launchpad.cur and kind_of(region.name) == "Main" then return end
  local kind, target, after = kind_of(region.name), index, nil
  local current = Launchpad.cur and kind_of(Launchpad.regions[Launchpad.cur].name)
  if Launchpad.auto_fill and kind == "Main" and current == "Main" then
    local fill = fill_before(Launchpad.cur, index)
    if fill then target, after = fill, index end
  end
  Launchpad.pending = { target = target, after = after, final = index, at = next_bar(reaper.GetPlayPosition()) }
  if index <= MAX_PADS then led_pulse(pad_note(index), 3) end
end

function Launchpad.step(direction)
  local base = (Launchpad.pending and Launchpad.pending.final) or Launchpad.cur or Launchpad.last_main or 1
  Launchpad.trigger(math.max(1, math.min(#Launchpad.regions, base + direction)))
end

function Launchpad.play_stop()
  if reaper.GetPlayState() & 1 == 1 then
    reaper.OnStopButton()
    Launchpad.pending = nil
    local main = Launchpad.last_main or Launchpad.cur
    if main then reaper.SetEditCurPos2(0, Launchpad.regions[main].start, true, false) end
  else
    Launchpad.trigger(Launchpad.last_main or Launchpad.cur or 1)
  end
end

function Launchpad.trigger_ending()
  local ending = find_region(function(n) return kind_of(n) == "Ending" end)
  if not ending then return end
  local letter = letter_of(Launchpad.regions[Launchpad.last_main or 1].name)
  ending = find_region(function(n) return kind_of(n) == "Ending" and letter_of(n) == letter end) or ending
  Launchpad.trigger(ending)
end

function Launchpad.nudge_tempo(delta)
  reaper.SetCurrentBPM(0, math.max(30, math.min(300, reaper.Master_GetTempo() + delta)), true)
end

function Launchpad.toggle_auto_fill()
  Launchpad.auto_fill = not Launchpad.auto_fill
  Launchpad.draw_controls()
end

local function resend()
  if Launchpad.mapper then Launchpad.mapper.send_voices(Launchpad.yamaha_output, Launchpad.voices) end
end

local function run_control(name)
  if name == "play" then Launchpad.play_stop()
  elseif name == "autofill" then Launchpad.toggle_auto_fill()
  elseif name == "ending" then Launchpad.trigger_ending()
  elseif name == "voices" then resend()
  elseif name == "tempo_down" then Launchpad.nudge_tempo(-2)
  elseif name == "tempo_up" then Launchpad.nudge_tempo(2)
  elseif name == "prev" then Launchpad.step(-1)
  elseif name == "next" then Launchpad.step(1) end
end

local function update_arranger()
  if reaper.GetPlayState() & 1 == 0 then
    if Launchpad.cur and Launchpad.lit then set_pad(Launchpad.lit, Launchpad.regions[Launchpad.lit].name) end
    Launchpad.lit, Launchpad.pending = nil, nil
    Launchpad.draw_controls()
    return
  end
  local position = reaper.GetPlayPosition()
  local now = reaper.time_precise()
  if now >= Launchpad.holdoff then
    local pending = Launchpad.pending
    if pending and position >= pending.at - LOOKAHEAD then
      Launchpad.after = pending.after
      Launchpad.pending = nil
      go(pending.target, true)
      resend()
    else
      -- Stick to the current section until just past its end so a late poll still triggers the jump.
      local region = Launchpad.cur and Launchpad.regions[Launchpad.cur]
      if not (region and position >= region.start - 0.05 and position < region.finish + 0.3) then
        Launchpad.cur = region_at(position)
        region = Launchpad.cur and Launchpad.regions[Launchpad.cur]
        if region and kind_of(region.name) == "Main" then Launchpad.last_main = Launchpad.cur; set_loop(Launchpad.cur) end
      end
      if region and position >= region.finish - LOOKAHEAD then
        local kind = kind_of(region.name)
        if kind == "Main" then
          -- REAPER's own loop repeats Mains; only re-seek if looping was lost.
          if reaper.GetSetRepeat(-1) == 0 then go(Launchpad.cur) end
        elseif kind == "Ending" then
          reaper.OnStopButton()
          local main = Launchpad.last_main
          if main then reaper.SetEditCurPos2(0, Launchpad.regions[main].start, true, false) end
          Launchpad.cur, Launchpad.after = nil, nil
        else
          local nxt = after_section(Launchpad.cur)
          Launchpad.after = nil
          if nxt then go(nxt) else reaper.OnStopButton() end
        end
      end
    end
  end
  local current = Launchpad.cur
  if current ~= Launchpad.lit then
    if Launchpad.lit and Launchpad.lit <= MAX_PADS then
      set_pad(Launchpad.lit, Launchpad.regions[Launchpad.lit].name)
    end
    if current and current <= MAX_PADS then led_rgb(pad_note(current), 127, 127, 127) end
    Launchpad.lit = current
    if not Launchpad.pending then Launchpad.draw_controls() end
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
  elseif value > 0 and cc == 41 then Launchpad.play_stop()
  elseif value > 0 and cc == 42 then if reaper.GetPlayState() & 1 == 1 then Launchpad.play_stop() end
  elseif value > 0 and cc == 45 then Launchpad.trigger_ending()
  elseif value > 0 and cc == 46 then Launchpad.toggle_auto_fill()
  elseif value > 0 and cc == 60 then resend()
  elseif value > 0 and cc == 43 then Launchpad.nudge_tempo(-2)
  elseif value > 0 and cc == 44 then Launchpad.nudge_tempo(2)
  elseif value > 0 and (cc == 59 or cc == 62) then Launchpad.step(1)
  elseif value > 0 and (cc == 58 or cc == 61) then Launchpad.step(-1)
  end
end

function Launchpad.poll()
  if not Launchpad.active then return end
  for event_index = 0, 127 do
    local event_id, message, _, flags = reaper.MIDI_GetRecentInputEvent(event_index)
    if not event_id or event_id == 0 then break end
    if event_id == Launchpad.last_event then break end
    if event_index == 0 then Launchpad.last_event = event_id end
    local input_id = flags and (flags & 0xFFFF)
    if input_id and Launchpad.input_set and Launchpad.input_set[input_id] and message and #message >= 3 then
      Launchpad.last_seen = string.format('port %d: %02X %02X %02X', input_id, message:byte(1), message:byte(2), message:byte(3))
    end
    if input_id == Launchpad.nano_input and message and #message >= 3 and (message:byte(1) & 0xF0) == 0xB0 then
      nano_message(message:byte(2), message:byte(3))
    end
    if input_id and Launchpad.input_set and Launchpad.input_set[input_id] and message and #message >= 3
      and (message:byte(1) & 0xF0) == 0x90 and message:byte(3) > 0 then
      local note = message:byte(2)
      local index = note_to_index(note)
      if index then Launchpad.trigger(index) elseif CONTROL[note] then run_control(CONTROL[note]) end
    end
  end
  update_arranger()
  flush_leds()
end

return Launchpad

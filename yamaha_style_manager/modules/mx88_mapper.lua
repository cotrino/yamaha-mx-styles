-- @noindex
local reaper = reaper
local Mapper = {}
local VoiceMap = require("voice_map")

function Mapper.configure(driver)
  VoiceMap.configure(driver.programs)
  Mapper.driver = driver
end

local PARTS = {
  { channel = 9, name = "Ch 9: Rhythm 2 (Percussion)", role = "drums" },
  { channel = 10, name = "Ch 10: Rhythm 1 (Drums)", role = "drums" },
  { channel = 11, name = "Ch 11: Bass", role = "bass" },
  { channel = 12, name = "Ch 12: Chord 1", role = "chord1" },
  { channel = 13, name = "Ch 13: Chord 2", role = "chord2" },
  { channel = 14, name = "Ch 14: Pad / Strings", role = "pad" },
  { channel = 15, name = "Ch 15: Phrase 1", role = "phrase1" },
  { channel = 16, name = "Ch 16: Phrase 2", role = "phrase2" },
}

local function basename(path)
  return path:match("([^\\/]+)%.%w+$") or path:match("([^\\/]+)$") or "Style"
end

local function midi_output_named(name)
  for index = 0, 63 do
    local ok, device_name = reaper.GetMIDIOutputName(index, "")
    if ok and device_name:lower():find(name:lower(), 1, true) then return index end
  end
end

local REAPER_PPQ = 960

local function insert_events(take, events, channel, ppq, role, markers)
  local chan = channel - 1
  local function scale(tick) return reaper.MIDI_GetPPQPosFromProjQN(take, tick / ppq) end
  -- Read the voice the style selects on this channel, then translate it to an MX88 voice for the part's role.
  local voice = {}
  for _, event in ipairs(events) do
    if (event.status & 0x0F) == chan then
      local kind = event.status & 0xF0
      if kind == 0xB0 and event.data1 == 0 and voice.msb == nil then voice.msb = event.data2
      elseif kind == 0xB0 and event.data1 == 32 and voice.lsb == nil then voice.lsb = event.data2
      elseif kind == 0xC0 and voice.prg == nil then voice.prg = event.data1 end
    end
  end
  local mx = VoiceMap.resolve(voice, role)
  local points, seen = { 0 }, { [0] = true }
  for _, marker in ipairs(markers or {}) do
    if not seen[marker.tick] then
      points[#points + 1], seen[marker.tick] = marker.tick, true
    end
  end
  table.sort(points)
  for _, point in ipairs(points) do
    local selected = { msb = voice.msb, lsb = voice.lsb, prg = voice.prg }
    for _, event in ipairs(events) do
      if event.tick <= point and (event.status & 0x0F) == chan then
        local kind = event.status & 0xF0
        if kind == 0xB0 and event.data1 == 0 then selected.msb = event.data2
        elseif kind == 0xB0 and event.data1 == 32 then selected.lsb = event.data2
        elseif kind == 0xC0 then selected.prg = event.data1 end
      end
    end
    local mapped, tick = VoiceMap.resolve(selected, role), scale(point)
    reaper.MIDI_InsertCC(take, false, false, tick, 0xB0, chan, 0, mapped.msb)
    reaper.MIDI_InsertCC(take, false, false, tick, 0xB0, chan, 32, mapped.lsb)
    reaper.MIDI_InsertCC(take, false, false, tick, 0xC0, chan, mapped.prg, 0)
    reaper.MIDI_InsertCC(take, false, false, tick, 0xB0, chan, 89, 0)
    for _, controller in ipairs({ {91, 40}, {93, 0}, {94, 0}, {74, 64}, {71, 64} }) do
      reaper.MIDI_InsertCC(take, false, false, tick, 0xB0, chan, controller[1], controller[2])
    end
    for _, body in ipairs(Mapper.driver.arp_messages(channel, nil, false)) do
      reaper.MIDI_InsertTextSysexEvt(take, false, false, tick, -1, body)
    end
    if point == 0 then mx = mapped end
  end
  local open_notes = {}
  for _, event in ipairs(events) do
    if (event.status & 0x0F) == chan then
      local event_type = event.status & 0xF0
      local tick = scale(event.tick)
      if event_type == 0x90 and event.data2 > 0 then
        open_notes[event.data1] = open_notes[event.data1] or {}
        table.insert(open_notes[event.data1], { tick = tick, velocity = event.data2 })
      elseif event_type == 0x80 or (event_type == 0x90 and event.data2 == 0) then
        local pending = open_notes[event.data1]
        local note = pending and table.remove(pending, 1)
        if note then
          reaper.MIDI_InsertNote(take, false, false, note.tick, math.max(note.tick + 1, tick),
            chan, event.data1, note.velocity, true)
        end
      elseif event_type == 0xB0 then
        -- Bank/program were sent at the start of the item; effect sends (91/93/94) are replaced by fixed levels
        -- because the style's values drive the MX88 variation effect (delay) and make parts echo.
        if event.data1 ~= 0 and event.data1 ~= 32 and event.data1 ~= 89 and event.data1 ~= 91 and event.data1 ~= 93 and event.data1 ~= 94 then
          reaper.MIDI_InsertCC(take, false, false, tick, 0xB0, chan, event.data1, event.data2)
        end
      elseif event_type == 0xC0 then
        -- Style program changes use GM/XG numbers that would override the mapped MX88 voice.
      elseif event_type == 0xE0 then
        reaper.MIDI_InsertCC(take, false, false, tick, 0xE0, chan, event.data1, event.data2)
      end
    end
  end
  for pitch, pending in pairs(open_notes) do
    for _, open in ipairs(pending) do
      reaper.MIDI_InsertNote(take, false, false, open.tick, open.tick + REAPER_PPQ // 16,
        chan, pitch, open.velocity, true)
    end
  end
  reaper.MIDI_Sort(take)
  return { chan = chan, msb = mx.msb, lsb = mx.lsb, prg = mx.prg, name = mx.name }
end
local FX_NAME = "Yamaha/sty_chord_transposer.jsfx"

-- JSFX can only be loaded from REAPER's Effects folder, so install it there on demand.
local function ensure_jsfx(source_path)
  local dir = reaper.GetResourcePath() .. "/Effects/Yamaha"
  reaper.RecursiveCreateDirectory(dir, 0)
  local input, input_error = io.open(source_path, "rb")
  if not input then error("Cannot read chord transposer: " .. tostring(input_error)) end
  local data = input:read("*a")
  input:close()
  local output, output_error = io.open(dir .. "/sty_chord_transposer.jsfx", "wb")
  if not output then error("Cannot install chord transposer: " .. tostring(output_error)) end
  local ok, write_error = output:write(data)
  output:close()
  if not ok then error("Cannot write chord transposer: " .. tostring(write_error)) end
end

function Mapper.refresh_voice(voice, position)
  local state
  if voice.track and reaper.ValidatePtr(voice.track, "MediaTrack*") then
    state = Mapper.driver.sections.read(voice.track, position)
    if state then voice.msb, voice.lsb, voice.prg = state.msb, state.lsb, state.prg end
  end
  voice.name = VoiceMap.name(voice)
  return state
end

function Mapper.solo_volume()
  return math.max(0, math.min(127,
    math.floor(tonumber(reaper.GetExtState("YamahaStyleManager", "SoloVolume")) or 120)))
end

function Mapper.send_solo_level(output)
  if output == nil then return end
  reaper.StuffMIDIMessage(16 + output, 0xB0, 7, Mapper.solo_volume())
  reaper.StuffMIDIMessage(16 + output, 0xB0, 11, 127)
end

-- Immediately selects the mapped voices on the keyboard (bank MSB/LSB then program change).
function Mapper.send_voices(output, voices, position)
  if not output then return end
  position = position or ((reaper.GetPlayState() & 1 ~= 0) and reaper.GetPlayPosition() or reaper.GetCursorPosition())
  for _, v in ipairs(voices or {}) do
    local state = Mapper.refresh_voice(v, position)
    local msb, lsb, prg = v.msb, v.lsb, v.prg
    if state then
      local arp
      for _, candidate in ipairs(Mapper.driver.arpeggios) do
        if candidate.nr == state.arp_nr then arp = candidate break end
      end
      local controllers = state.controllers
      Mapper.driver.send_full_state(output, v.chan + 1, {msb = msb, lsb = lsb, prg = prg},
        arp, state.enabled, controllers[91], controllers[93], controllers[74], controllers[71])
    elseif v.solo then
      reaper.StuffMIDIMessage(16 + output, 0xB0 | v.chan, 123, 0)
      Mapper.driver.send_full_state(output, v.chan + 1, v, nil, false, 40, 0, 64, 64)
      Mapper.send_solo_level(output)
    else
      reaper.StuffMIDIMessage(16 + output, 0xB0 | v.chan, 0, msb)
      reaper.StuffMIDIMessage(16 + output, 0xB0 | v.chan, 32, lsb)
      reaper.StuffMIDIMessage(16 + output, 0xC0 | v.chan, prg, 0)
    end
  end
end

-- Local Control off stops the keyboard from sounding by itself, so only the rig's MIDI reaches the voices.
function Mapper.set_local_control(output, on)
  if not output then return end
  reaper.SendMIDIMessageToHardware(output, string.char(0xF0, 0x43, 0x10, 0x7F, 0x1C, 0x00, 0x00, 0x0A, on and 1 or 0, 0xF7))
  reaper.StuffMIDIMessage(16 + output, 0xB0, 122, on and 127 or 0)
end

-- A previous import keeps playing to the same MX88 channels, which sounds like looping background notes
-- and a doubled arrangement, so every import replaces earlier rigs, controller tracks and regions.
function Mapper.remove_previous_rigs()
  local region_ids = {}
  for index = reaper.CountTracks(0) - 1, 0, -1 do
    local track = reaper.GetTrack(0, index)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name:find("[YAMAHA STY RIG]", 1, true) == 1 then
      local _, owned = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:MXStyleRegions", "", false)
      for id in owned:gmatch("%d+") do region_ids[tonumber(id)] = true end
      local depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
      local last = index
      if depth == 1 then
        local level = 1
        while level > 0 and last + 1 < reaper.CountTracks(0) do
          last = last + 1
          level = level + reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, last), "I_FOLDERDEPTH")
        end
      end
      for i = last, index, -1 do reaper.DeleteTrack(reaper.GetTrack(0, i)) end
    elseif name == "[MIDI] Yamaha MX88 Chord Input" or name == "[MIDI] Launchpad Controller" then
      reaper.DeleteTrack(track)
    end
  end
  for id in pairs(region_ids) do reaper.DeleteProjectMarker(0, id, true) end
end

function Mapper.create_rig(style, style_path, transposer_path, devices)
  assert(Mapper.driver, "Load the Genos Suite before importing")
  ensure_jsfx(transposer_path)
  Mapper.remove_previous_rigs()
  local tempo, meter = style.tempos and style.tempos[1], style.meters and style.meters[1]
  if tempo or meter then
    local marker = reaper.FindTempoTimeSigMarker(0, 0)
    assert(reaper.SetTempoTimeSigMarker(0, marker, 0, -1, -1, tempo and tempo.bpm or reaper.Master_GetTempo(),
      meter and meter.numerator or 0, meter and meter.denominator or 0, false), "Cannot set style tempo/meter")
  end
  local insert_at = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(insert_at, true)
  local folder = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", "[YAMAHA STY RIG] - " .. basename(style_path), true)
  reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)

  devices = devices or {}
  local output = devices.yamaha_output or midi_output_named("Yamaha MX88") or midi_output_named("Yamaha MX")
  local rig = { folder = folder, children = {}, voices = {}, output = output, output_found = output ~= nil }
  local length = reaper.TimeMap2_QNToTime(0, math.max(1, style.end_tick / style.ppq))
  for index, part in ipairs(PARTS) do
    reaper.InsertTrackAtIndex(insert_at + index, true)
    local track = reaper.GetTrack(0, insert_at + index)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", part.name, true)
    if output then reaper.SetMediaTrackInfo_Value(track, "I_MIDIHWOUT", (output << 5) | part.channel) end
    local item = reaper.CreateNewMIDIItemInProj(track, 0, length, false)
    local take = reaper.GetActiveTake(item)
    local voice = insert_events(take, style.events, part.channel, style.ppq, part.role, style.markers)
    voice.track = track
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:MXStyleChannel", tostring(part.channel), true)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", part.name .. " - " .. voice.name, true)
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "[MX Style] " .. voice.name, true)
    rig.voices[#rig.voices + 1] = voice
    rig.children[#rig.children + 1] = track
  end
  reaper.SetMediaTrackInfo_Value(rig.children[#rig.children], "I_FOLDERDEPTH", -1)

  reaper.InsertTrackAtIndex(insert_at, true)
  local input = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(input, "P_NAME", "[MIDI] Yamaha MX88 Chord Input", true)
  if devices.yamaha_input then
    reaper.SetMediaTrackInfo_Value(input, "I_RECINPUT", 4096 | (devices.yamaha_input << 5))
    reaper.SetMediaTrackInfo_Value(input, "I_RECMON", 1)
    reaper.SetMediaTrackInfo_Value(input, "I_RECARM", 1)
  end
  local split = tonumber(reaper.GetExtState("YamahaStyleManager", "Split")) or 60
  for _, track in ipairs(rig.children) do
    local send = reaper.CreateTrackSend(input, track)
    reaper.SetTrackSendInfo_Value(input, 0, send, "I_SENDMODE", 1) -- pre-FX: parts hear the whole keyboard
    local fx = reaper.TrackFX_AddByName(track, FX_NAME, false, -1)
    assert(fx >= 0, "Cannot load the Yamaha style chord transposer")
    reaper.TrackFX_SetParam(track, fx, 1, split)
  end
  -- The keyboard track keeps only the right hand (soloist) for the MX88; the left hand just picks chords.
  local input_fx = reaper.TrackFX_AddByName(input, FX_NAME, false, -1)
  assert(input_fx >= 0, "Cannot load the keyboard split chord transposer")
  reaper.TrackFX_SetParam(input, input_fx, 1, split)
  reaper.TrackFX_SetParam(input, input_fx, 2, 1)
  rig.input, rig.input_fx = input, input_fx
  if output then reaper.SetMediaTrackInfo_Value(input, "I_MIDIHWOUT", (output << 5) | 1) end
  local solo_program = tonumber(reaper.GetExtState("YamahaStyleManager", "SoloVoice")) or 65
  local preset = reaper.GetExtState("YamahaStyleManager", "SoloPreset")
  local solo = VoiceMap.solo(solo_program, preset)
  rig.voices[#rig.voices + 1] = { chan = 0, msb = solo.msb, lsb = solo.lsb, prg = solo.prg,
    name = solo.name, gm_prg = preset == "" and solo_program or nil, solo = true }
  return rig
end

return Mapper

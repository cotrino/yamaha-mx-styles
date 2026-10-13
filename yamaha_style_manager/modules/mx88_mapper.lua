-- @noindex
local reaper = reaper
local Mapper = {}
local VoiceMap = require("voice_map")

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
  local function scale(tick) return math.floor(tick * REAPER_PPQ / ppq + 0.5) end
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
  reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, chan, 0, mx.msb)
  reaper.MIDI_InsertCC(take, false, false, 1, 0xB0, chan, 32, mx.lsb)
  reaper.MIDI_InsertCC(take, false, false, 2, 0xC0, chan, mx.prg, 0)
  reaper.MIDI_InsertCC(take, false, false, 3, 0xB0, chan, 91, 40)
  reaper.MIDI_InsertCC(take, false, false, 3, 0xB0, chan, 93, 0)
  reaper.MIDI_InsertCC(take, false, false, 3, 0xB0, chan, 94, 0)
  -- Repeat the voice at every section start so jumping to a region still selects the right sound.
  for _, marker in ipairs(markers or {}) do
    local tick = scale(marker.tick)
    if tick > 2 then
      reaper.MIDI_InsertCC(take, false, false, tick, 0xB0, chan, 0, mx.msb)
      reaper.MIDI_InsertCC(take, false, false, tick, 0xB0, chan, 32, mx.lsb)
      reaper.MIDI_InsertCC(take, false, false, tick, 0xC0, chan, mx.prg, 0)
    end
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
        if event.data1 ~= 0 and event.data1 ~= 32 and event.data1 ~= 91 and event.data1 ~= 93 and event.data1 ~= 94 then
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
  return { chan = chan, msb = mx.msb, lsb = mx.lsb, prg = mx.prg }
end
local FX_NAME = "Yamaha/sty_chord_transposer.jsfx"

-- JSFX can only be loaded from REAPER's Effects folder, so install it there on demand.
local function ensure_jsfx(source_path)
  local dir = reaper.GetResourcePath() .. "/Effects/Yamaha"
  reaper.RecursiveCreateDirectory(dir, 0)
  local input = source_path and io.open(source_path, "rb")
  if not input then return end
  local data = input:read("*a")
  input:close()
  local output = io.open(dir .. "/sty_chord_transposer.jsfx", "wb")
  if output then output:write(data) output:close() end
end

-- Immediately selects the mapped voices on the keyboard (bank MSB/LSB then program change).
function Mapper.send_voices(output, voices)
  if not output then return end
  for _, v in ipairs(voices or {}) do
    reaper.StuffMIDIMessage(16 + output, 0xB0 | v.chan, 0, v.msb)
    reaper.StuffMIDIMessage(16 + output, 0xB0 | v.chan, 32, v.lsb)
    reaper.StuffMIDIMessage(16 + output, 0xC0 | v.chan, v.prg, 0)
    if v.solo then
      -- A live voice change must not leave hanging notes or a muted channel behind.
      reaper.StuffMIDIMessage(16 + output, 0xB0 | v.chan, 123, 0)
      reaper.StuffMIDIMessage(16 + output, 0xB0 | v.chan, 7, 100)
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
  local removed = false
  for index = reaper.CountTracks(0) - 1, 0, -1 do
    local track = reaper.GetTrack(0, index)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name:find("[YAMAHA STY RIG]", 1, true) == 1 then
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
      removed = true
    elseif name == "[MIDI] Yamaha MX88 Chord Input" or name == "[MIDI] Launchpad Controller" then
      reaper.DeleteTrack(track)
    end
  end
  if removed then
    for index = reaper.CountProjectMarkers(0) - 1, 0, -1 do reaper.DeleteProjectMarkerByIndex(0, index) end
  end
end

function Mapper.create_rig(style, style_path, transposer_path, devices)
  Mapper.remove_previous_rigs()  local insert_at = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(insert_at, true)
  local folder = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", "[YAMAHA STY RIG] - " .. basename(style_path), true)
  reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)

  devices = devices or {}
  local output = devices.yamaha_output or midi_output_named("Yamaha MX88") or midi_output_named("Yamaha MX")
  ensure_jsfx(transposer_path)
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
    if fx < 0 then rig.fx_missing = true else reaper.TrackFX_SetParam(track, fx, 1, split) end
  end
  -- The keyboard track keeps only the right hand (soloist) for the MX88; the left hand just picks chords.
  local input_fx = reaper.TrackFX_AddByName(input, FX_NAME, false, -1)
  if input_fx >= 0 then
    reaper.TrackFX_SetParam(input, input_fx, 1, split)
    reaper.TrackFX_SetParam(input, input_fx, 2, 1)
  end
  rig.input, rig.input_fx = input, input_fx
  if output then reaper.SetMediaTrackInfo_Value(input, "I_MIDIHWOUT", (output << 5) | 1) end
  rig.voices[#rig.voices + 1] = { chan = 0, msb = 0, lsb = 0, prg = tonumber(reaper.GetExtState("YamahaStyleManager", "SoloVoice")) or 65, solo = true }
  return rig
end

return Mapper

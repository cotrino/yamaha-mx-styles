-- @noindex
local reaper = reaper
local Mapper = {}
local VoiceMap = require("voice_map")

local PARTS = {
  { channel = 9, name = "Ch 9: Rhythm 2 (Percussion)", drum = true },
  { channel = 10, name = "Ch 10: Rhythm 1 (Drums)", drum = true },
  { channel = 11, name = "Ch 11: Bass" },
  { channel = 12, name = "Ch 12: Chord 1" },
  { channel = 13, name = "Ch 13: Chord 2" },
  { channel = 14, name = "Ch 14: Pad / Strings" },
  { channel = 15, name = "Ch 15: Phrase 1" },
  { channel = 16, name = "Ch 16: Phrase 2" },
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

local function insert_events(take, events, channel, ppq, drum)
  local chan = channel - 1
  local function scale(tick) return math.floor(tick * REAPER_PPQ / ppq + 0.5) end
  -- Use the voice (bank MSB/LSB + program) the style itself selects on this channel,
  -- so the MX88 plays the right sound; fall back to a generic bank only if absent.
  local voice = {}
  for _, event in ipairs(events) do
    if (event.status & 0x0F) == chan then
      local kind = event.status & 0xF0
      if kind == 0xB0 and event.data1 == 0 and voice.msb == nil then voice.msb = event.data2
      elseif kind == 0xB0 and event.data1 == 32 and voice.lsb == nil then voice.lsb = event.data2
      elseif kind == 0xC0 and voice.prg == nil then voice.prg = event.data1 end
    end
  end
  local mx = VoiceMap.resolve(voice, drum)
  reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, chan, 0, mx.msb)
  reaper.MIDI_InsertCC(take, false, false, 1, 0xB0, chan, 32, mx.lsb)
  reaper.MIDI_InsertCC(take, false, false, 2, 0xC0, chan, mx.prg, 0)
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
        -- Bank/program were already sent at the start of the item.
        if event.data1 ~= 0 and event.data1 ~= 32 then
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

function Mapper.create_rig(style, style_path, transposer_path, devices)
  local insert_at = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(insert_at, true)
  local folder = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", "[YAMAHA STY RIG] - " .. basename(style_path), true)
  reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)

  devices = devices or {}
  local output = devices.yamaha_output or midi_output_named("Yamaha MX88") or midi_output_named("Yamaha MX")
  ensure_jsfx(transposer_path)
  VoiceMap.init(((transposer_path or ''):gsub('[^/\\]+[/\\][^/\\]+$', '')) .. 'data/Yamaha_MX49.reabank')
  local rig = { folder = folder, children = {}, output_found = output ~= nil }
  local length = reaper.TimeMap2_QNToTime(0, math.max(1, style.end_tick / style.ppq))
  for index, part in ipairs(PARTS) do
    reaper.InsertTrackAtIndex(insert_at + index, true)
    local track = reaper.GetTrack(0, insert_at + index)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", part.name, true)
    if output then reaper.SetMediaTrackInfo_Value(track, "I_MIDIHWOUT", (output << 5) | part.channel) end
    local item = reaper.CreateNewMIDIItemInProj(track, 0, length, false)
    local take = reaper.GetActiveTake(item)
    insert_events(take, style.events, part.channel, style.ppq, part.drum)
    rig.children[#rig.children + 1] = track
  end
  reaper.SetMediaTrackInfo_Value(rig.children[#rig.children], "I_FOLDERDEPTH", -1)

  reaper.InsertTrackAtIndex(insert_at, true)
  local input = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(input, "P_NAME", "[MIDI] Yamaha MX88 Chord Input", true)
  for _, track in ipairs(rig.children) do
    reaper.CreateTrackSend(input, track)
    reaper.TrackFX_AddByName(track, FX_NAME, false, -1)
  end
  return rig
end

return Mapper

-- @noindex
local reaper = reaper
local Mapper = {}

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

local function insert_events(take, events, channel, ppq, drum)
  reaper.MIDI_InsertCC(take, false, false, 0, 0xB0 | (channel - 1), 0, 63)
  reaper.MIDI_InsertCC(take, false, false, 0, 0xB0 | (channel - 1), 32, drum and 32 or 0)
  local open_notes = {}
  local function note_key(note)
    return tostring(note)
  end
  for _, event in ipairs(events) do
    if (event.status & 0x0F) + 1 == channel then
      local event_type = event.status & 0xF0
      if event_type == 0x90 and event.data2 > 0 then
        local key = note_key(event.data1)
        open_notes[key] = open_notes[key] or {}
        open_notes[key][#open_notes[key] + 1] = { tick = event.tick, velocity = event.data2 }
      elseif event_type == 0x80 or (event_type == 0x90 and event.data2 == 0) then
        local notes = open_notes[note_key(event.data1)]
        local note = notes and table.remove(notes, 1)
        if note then
          reaper.MIDI_InsertNote(take, false, false, note.tick, math.max(note.tick + 1, event.tick),
            channel - 1, event.data1, note.velocity, true)
        end
      elseif event_type == 0xB0 then
        reaper.MIDI_InsertCC(take, false, false, event.tick, 0xB0 | (channel - 1), event.data1, event.data2)
      elseif event_type == 0xC0 then
        reaper.MIDI_InsertCC(take, false, false, event.tick, 0xC0 | (channel - 1), event.data1, 0)
      elseif event_type == 0xE0 then
        reaper.MIDI_InsertCC(take, false, false, event.tick, 0xE0 | (channel - 1), event.data1, event.data2)
      end
    end
  end
  for note, notes in pairs(open_notes) do
    for _, open in ipairs(notes) do
      reaper.MIDI_InsertNote(take, false, false, open.tick, open.tick + math.max(1, ppq / 16),
        channel - 1, tonumber(note), open.velocity, true)
    end
  end
  reaper.MIDI_Sort(take)
end

function Mapper.create_rig(style, style_path, transposer_path)
  local insert_at = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(insert_at, true)
  local folder = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", "[YAMAHA STY RIG] - " .. basename(style_path), true)
  reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)

  local output = midi_output_named("Yamaha MX88") or midi_output_named("Yamaha MX")
  local rig = { folder = folder, children = {}, output_found = output ~= nil }
  local length = reaper.TimeMap2_QNToTime(0, math.max(1, style.end_tick / style.ppq))
  for index, part in ipairs(PARTS) do
    reaper.InsertTrackAtIndex(insert_at + index, true)
    local track = reaper.GetTrack(0, insert_at + index)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", part.name, true)
    if output then reaper.SetMediaTrackInfo_Value(track, "I_MIDIHWOUT", (output << 5) | (part.channel - 1)) end
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
    if transposer_path then
      reaper.TrackFX_AddByName(track, transposer_path, false, 1)
    else
      reaper.TrackFX_AddByName(track, "sty_chord_transposer", false, 1)
    end
  end
  return rig
end

return Mapper

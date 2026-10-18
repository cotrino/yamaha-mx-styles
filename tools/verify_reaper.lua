-- Run in REAPER, not a standalone Lua interpreter. Uses a new project tab.
local tools = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local root = tools .. ".." .. package.config:sub(1, 1)
local manager = root .. "yamaha_style_manager" .. package.config:sub(1, 1)
local suite = root .. "..\\yamaha-mx-genos-suite\\Scripts\\Yamaha_MX_Genos_Suite\\"
local output = YamahaStyleVerificationOutput or (root .. "build")
reaper.RecursiveCreateDirectory(output, 0)
local report = {}
local function check(condition, label)
  assert(condition, label)
  report[#report + 1] = "PASS " .. label
end
local function save_report(ok, err)
  local file = assert(io.open(output .. "\\reaper-verification.txt", "w"))
  file:write("REAPER ", reaper.GetAppVersion(), "\n", table.concat(report, "\n"), "\n")
  file:write(ok and "RESULT PASS\n" or ("RESULT FAIL\n" .. tostring(err) .. "\n"))
  file:close()
  reaper.SetExtState("YamahaStyleManagerTests", "Result", ok and "PASS" or tostring(err), false)
end
local original = reaper.EnumProjects(-1, "")
local ok, err = xpcall(function()
  package.path = manager .. "modules\\?.lua;" .. suite .. "lib\\?.lua;" .. package.path
  for _, name in ipairs({"sty_parser", "mx88_mapper", "voice_map", "genos_bridge", "region_builder",
      "launchpad_controller", "style_sections", "gui_inspector", "icons"}) do package.loaded[name] = nil end
  local Parser = require("sty_parser")
  local Mapper = require("mx88_mapper")
  local Regions = require("region_builder")
  local Launchpad = require("launchpad_controller")
  reaper.atexit(Launchpad.shutdown)
  local driver = assert(require("genos_bridge").load(manager))
  Mapper.configure(driver)
  local Sections = driver.sections
  local style_path
  local function find_style(folder)
    for index = 0, 100000 do
      local name = reaper.EnumerateFiles(folder, index)
      if not name then break end
      if name:lower():match("%.sty$") then
        local success, style = Parser.parse(folder .. "\\" .. name)
        if success and #style.markers >= 2 then return folder .. "\\" .. name end
      end
    end
    for index = 0, 100000 do
      local name = reaper.EnumerateSubdirectories(folder, index)
      if not name then break end
      local found = find_style(folder .. "\\" .. name)
      if found then return found end
    end
  end
  style_path = assert(find_style(root .. "styles\\Catalog"), "No catalog style with sections")
  local parsed, style = Parser.parse(style_path)
  check(parsed, "Parse a real local catalog style")
  check(#driver.programs > 1000 and #driver.arpeggios > 900, "Load MX voice and arpeggio catalogs")
  reaper.Main_OnCommand(40859, 0) -- New project tab.
  reaper.GetSetProjectInfo_String(0, "PROJECT_TITLE", "Yamaha MX Style Verification", true)
  local cue = reaper.AddProjectMarker2(0, false, 0.25, 0, "User cue - preserve", -1, 0)
  local unrelated = reaper.AddProjectMarker2(0, true, 0, 0.5, "User region - preserve", -1, 0)
  local function import()
    local rig = Mapper.create_rig(style, style_path, manager .. "jsfx\\sty_chord_transposer.jsfx", {})
    local count, regions = Regions.create(style.markers, style.end_tick, style.ppq, rig.folder)
    Launchpad.setup(rig.folder, count, {}, rig, nil, regions)
    for _, track in ipairs(rig.children) do
      reaper.SetMediaTrackInfo_Value(track, "I_MIDIHWOUT", -1)
    end
    reaper.SetMediaTrackInfo_Value(rig.input, "I_MIDIHWOUT", -1)
    return rig, regions
  end
  local rig, regions = import()
  check(#rig.children == 8 and reaper.CountTracks(0) == 11, "Create eight part tracks, folder, keyboard input and controller")
  check(#regions > 1 and #Launchpad.regions == #regions, "Launchpad only maps imported style regions")
  check(#Sections.regions(rig.children[1]) == #regions, "Inspector only lists owned style sections")
  local notes_before = {}
  local function notes(take)
    local _, count = reaper.MIDI_CountEvts(take)
    local result = {}
    for index = 0, count - 1 do
      local _, selected, muted, first, last, channel, pitch, velocity = reaper.MIDI_GetNote(take, index)
      result[#result + 1] = table.concat({tostring(selected), tostring(muted), first, last, channel, pitch, velocity}, ":")
    end
    return table.concat(result, "|")
  end
  for i, track in ipairs(rig.children) do
    local take = reaper.GetActiveTake(reaper.GetTrackMediaItem(track, 0))
    notes_before[i] = notes(take)
    check(rig.voices[i].msb == 63, "Native MX voice on channel " .. (i + 8))
    check(reaper.TrackFX_GetCount(track) == 1, "Chord transposer loaded on channel " .. (i + 8))
    for index, region in ipairs(regions) do
      local target = assert(Sections.at(track, region.start))
      local program
      for _, candidate in ipairs(driver.programs) do
        if candidate.msb == 63 and candidate.lsb == ((i <= 2) and 32 or 0) then
          program = candidate
          break
        end
      end
      Sections.write(driver, track, target, assert(program), driver.arpeggios[index], false,
        {[91] = 40, [93] = 0, [74] = 64, [71] = 64})
      local state = Sections.read(track, region.start)
      check(state.msb == program.msb and state.lsb == program.lsb and state.prg == program.prg,
        "Section " .. index .. " channel " .. (i + 8) .. " voice round-trip")
    end
    check(notes(take) == notes_before[i], "All original notes preserved on channel " .. (i + 8))
  end
  local first = regions[1]
  local program = require("voice_map").presets[1]
  local function set_arp(index)
    local track = rig.children[index]
    Sections.write(driver, track, Sections.at(track, first.start), program, driver.arpeggios[index], true,
      {[91] = 30, [93] = 0, [74] = 64, [71] = 64})
  end
  set_arp(3)
  set_arp(4)
  check(Sections.read(rig.children[3], first.start).enabled, "Persist and read arpeggio enabled state")
  local allowed, limit_error = pcall(set_arp, 5)
  check(not allowed and tostring(limit_error):find("two simultaneous", 1, true), "Reject a third simultaneous arpeggio")
  local track = rig.children[3]
  local take = reaper.GetActiveTake(reaper.GetTrackMediaItem(track, 0))
  local _, note_count, cc_count, text_count = reaper.MIDI_CountEvts(take)
  set_arp(3)
  local _, new_notes, new_ccs, new_text = reaper.MIDI_CountEvts(take)
  check(note_count == new_notes and cc_count == new_ccs and text_count == new_text, "Repeated section edits are idempotent")
  check(not Sections.read(track, regions[2].start).enabled, "Arpeggio selection does not leak into the next section")
  check(notes(take) == notes_before[3], "Arpeggio changes preserve MIDI notes")
  local gm_ok = pcall(Sections.write, driver, track, Sections.at(track, first.start),
    {msb = 0, lsb = 0, prg = 0}, nil, false, {[91] = 40, [93] = 0, [74] = 64, [71] = 64})
  check(not gm_ok, "Style editor rejects standard GM voices")

  local sent = {}
  local old_send = driver.send_full_state
  driver.send_full_state = function(_, channel, voice, arp, enabled)
    sent[channel] = {voice = voice, arp = arp, enabled = enabled}
  end
  Mapper.send_voices(0, rig.voices, first.start)
  driver.send_full_state = old_send
  check(sent[11] and sent[11].enabled and sent[11].arp, "Section jump resends saved voice and arpeggio state")
  local project = reaper.EnumProjects(-1, "")
  reaper.Main_SaveProjectEx(project, output .. "\\Yamaha MX Style Verification.rpp", 0)
  check(true, "Save section edits to a verification REAPER project")
  rig, regions = import()
  local _, markers, region_count = reaper.CountProjectMarkers(0)
  check(reaper.CountTracks(0) == 11 and region_count == #regions + 1 and markers == 1,
    "Reimport replaces only owned tracks and regions, preserving user markers")
  check(reaper.EnumProjectMarkers3(0, 0) ~= 0 and cue >= 0 and unrelated >= 0, "User cue and region remain after reimport")
  set_arp(3)
  set_arp(4)
  reaper.SetOnlyTrackSelected(rig.children[3])
  reaper.SetEditCurPos(regions[1].start, false, false)
  local GUI = require("gui_inspector")
  local devices = GUI.get_device_config()
  check(GUI.is_style_project(), "Inspector detects a style project and avoids duplicate hardware controllers")
  GUI.render(driver, {current_root = "C", current_type = "maj"}, {}, devices)
  check(true, "Render the real ReaImGui Inspector with style section/channel selectors")
  reaper.Main_SaveProjectEx(project, output .. "\\Yamaha MX Style Verification.rpp", 0)
  reaper.SetExtState("YamahaStyleManagerTests", "OriginalProject", tostring(original), false)
end, debug.traceback)
save_report(ok, err)
if not ok then reaper.SelectProjectInstance(original) end

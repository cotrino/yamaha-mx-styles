-- @description Yamaha STY Style Manager & Live Rig Builder
-- @author Jose M. Cotrino
-- @version 1.2.2
-- @about Browse Yamaha STY files, import their MIDI parts, and create an MX88/Launchpad live rig.
-- @provides
--   [main] .
--   modules/*.lua
--   jsfx/*.jsfx

local reaper = reaper

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "ReaImGui is required. Install ReaImGui from ReaPack and restart REAPER.",
    "Yamaha STY Style Manager", 0)
  return
end

local script_path = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
package.path = script_path .. "modules/?.lua;" .. package.path

-- REAPER keeps required modules between runs, so drop them to always load the installed version.
for _, name in ipairs({ "sty_parser", "mx88_mapper", "voice_map", "region_builder", "launchpad_controller", "chord_detect" }) do package.loaded[name] = nil end

local Parser = require("sty_parser")
local Mapper = require("mx88_mapper")
local Regions = require("region_builder")
local Launchpad = require("launchpad_controller")

local EXT_SECTION, EXT_KEY = "YamahaStyleManager", "RootFolder"
local ctx = reaper.ImGui_CreateContext("Yamaha STY Style Manager & Live Rig Builder")
local state = {
  root = reaper.GetExtState(EXT_SECTION, EXT_KEY),
  filter = "",
  selected = nil,
  files = {},
  directories = {},
  status = "Configure a Yamaha style-library folder to begin.",
  status_is_error = false,
  show_config = false,
  scan_error = nil,
}

local function normalize_path(path)
  return (path or ""):gsub("[/\\]+$", "")
end

local function file_matches(name)
  local extension = name:match("%.([^%.]+)$")
  return extension and (extension:lower() == "sty" or extension:lower() == "mid")
end

local function scan_directory(path, relative, files, directories)
  local sub_index = 0
  while true do
    local subdir = reaper.EnumerateSubdirectories(path, sub_index)
    if not subdir then break end
    local child_relative = relative == "" and subdir or relative .. "/" .. subdir
    directories[child_relative] = true
    scan_directory(path .. "/" .. subdir, child_relative, files, directories)
    sub_index = sub_index + 1
  end

  local file_index = 0
  while true do
    local filename = reaper.EnumerateFiles(path, file_index)
    if not filename then break end
    if file_matches(filename) then
      local display = relative == "" and filename or relative .. "/" .. filename
      files[#files + 1] = { name = filename, display = display, path = path .. "/" .. filename }
    end
    file_index = file_index + 1
  end
end

local function refresh_library()
  state.files, state.directories, state.scan_error = {}, {}, nil
  state.selected = nil
  state.root = normalize_path(state.root)
  if state.root == "" then
    state.status = "Configure a Yamaha style-library folder to begin."
    return
  end
  local ok, err = pcall(scan_directory, state.root, "", state.files, state.directories)
  if not ok then
    state.scan_error = tostring(err)
    state.status = "Cannot scan the configured folder."
    state.status_is_error = true
    return
  end
  table.sort(state.files, function(a, b) return a.display:lower() < b.display:lower() end)
  state.status = string.format("Found %d Yamaha style/MIDI file(s).", #state.files)
  state.status_is_error = false
end

local function selected_file()
  for _, file in ipairs(state.files) do
    if file.path == state.selected then return file end
  end
end

local DEVICE_SLOTS = {
  { key = "yamaha_output", label = "Yamaha output (MX88)", outputs = true, keywords = { "yamaha", "mx" } },
  { key = "yamaha_input", label = "Yamaha input (keys / chords)", keywords = { "yamaha", "mx" } },
  { key = "launchpad_input", label = "Launchpad input", keywords = { "launchpad", "lpmini" }, any = true },
  { key = "launchpad_output", label = "Launchpad output (LEDs)", outputs = true, keywords = { "launchpad", "lpmini" }, any = true },
  { key = "nano_input", label = "nanoKONTROL2 input (mixer)", keywords = { "nanokontrol" } },
}
local device_names = {}
for _, slot in ipairs(DEVICE_SLOTS) do device_names[slot.key] = reaper.GetExtState(EXT_SECTION, slot.key) end

local function enumerate_devices(outputs)
  local list = {}
  local count = outputs and reaper.GetNumMIDIOutputs() or reaper.GetNumMIDIInputs()
  for id = 0, count - 1 do
    local ok, name
    if outputs then ok, name = reaper.GetMIDIOutputName(id, "") else ok, name = reaper.GetMIDIInputName(id, "") end
    if ok and name and name ~= "" then list[#list + 1] = { id = id, name = name } end
  end
  return list
end

local function resolve_device(list, name, keywords, any)
  if name ~= "" then
    for _, device in ipairs(list) do if device.name == name then return device end end
    return nil
  end
  for _, device in ipairs(list) do
    local lower, matches = device.name:lower(), not any
    for _, keyword in ipairs(keywords) do
      local found = lower:find(keyword, 1, true) ~= nil
      if any then matches = matches or found elseif not found then matches = false break end
    end
    if matches then return device end
  end
end

-- Returns {slot_key = device} for UI display and {slot_key = id} for the modules.
local function current_devices()
  local lists = { [true] = enumerate_devices(true), [false] = enumerate_devices(false) }
  local resolved, ids = {}, {}
  for _, slot in ipairs(DEVICE_SLOTS) do
    local list = lists[slot.outputs == true]
    local device = resolve_device(list, device_names[slot.key], slot.keywords, slot.any)
    if device and device_names[slot.key] == "" then
      device_names[slot.key] = device.name
      reaper.SetExtState(EXT_SECTION, slot.key, device.name, true)
    end
    resolved[slot.key] = device
    ids[slot.key] = device and device.id or nil
  end
  return resolved, ids, lists
end

local function device_selector(slot, list, selected)
  reaper.ImGui_SetNextItemWidth(ctx, 420)
  if reaper.ImGui_BeginCombo(ctx, slot.label, selected and selected.name or "Select device...") then
    for _, device in ipairs(list) do
      local is_selected = device.name == device_names[slot.key]
      if reaper.ImGui_Selectable(ctx, device.name, is_selected) then
        device_names[slot.key] = device.name
        reaper.SetExtState(EXT_SECTION, slot.key, device.name, true)
      end
      if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    reaper.ImGui_EndCombo(ctx)
  end
end

local function import_selected()  local file = selected_file()
  if not file then
    state.status, state.status_is_error = "Select a style file first.", true
    return
  end

  local ok, parsed_or_error = Parser.parse(file.path)
  if not ok then
    state.status, state.status_is_error = "Unable to parse style: " .. parsed_or_error, true
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local imported, rig_or_error, region_count, launchpad = pcall(function()
    local rig = Mapper.create_rig(parsed_or_error, file.path, script_path .. "jsfx/sty_chord_transposer.jsfx", select(2, current_devices()))
    local region_count = Regions.create(parsed_or_error.markers, parsed_or_error.end_tick, parsed_or_error.ppq)
    local launchpad = Launchpad.setup(rig.folder, region_count, select(2, current_devices()), rig, Mapper)
    return rig, region_count, launchpad
  end)
  reaper.PreventUIRefresh(-1)

  if not imported then
    reaper.Undo_EndBlock("Import Yamaha style (failed)", -1)
    state.status, state.status_is_error = "Import failed: " .. tostring(rig_or_error), true
    return
  end

  local rig = rig_or_error
  reaper.Undo_EndBlock("Import Yamaha style into MX88 live rig", -1)
  reaper.UpdateArrange()
  state.status = string.format(
    "Imported %s: %d rig tracks, %d section region(s). %s",
    file.name, #rig.children, region_count, launchpad.message)
  state.status_is_error = false
end

local function draw_file_tree()
  local visible = {}
  local needle = state.filter:lower()
  for _, file in ipairs(state.files) do
    if needle == "" or file.display:lower():find(needle, 1, true) then
      visible[#visible + 1] = file
    end
  end

  if #visible == 0 then
    reaper.ImGui_TextDisabled(ctx, "No matching .sty or .mid files.")
    return
  end

  local by_directory = { [""] = {} }
  for directory in pairs(state.directories) do by_directory[directory] = {} end
  for _, file in ipairs(visible) do
    local directory = file.display:match("^(.*)/[^/]+$") or ""
    by_directory[directory] = by_directory[directory] or {}
    by_directory[directory][#by_directory[directory] + 1] = file
  end

  local function draw_directory(relative)
    for _, file in ipairs(by_directory[relative] or {}) do
      local is_selected = state.selected == file.path
      if reaper.ImGui_Selectable(ctx, file.name .. "##" .. file.path, is_selected,
          reaper.ImGui_SelectableFlags_AllowDoubleClick()) then
        state.selected = file.path
        if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then state.import_requested = true end
      end
    end
    local children = {}
    for directory in pairs(state.directories) do
      local parent = directory:match("^(.*)/[^/]+$") or ""
      if parent == relative then children[#children + 1] = directory end
    end
    table.sort(children)
    for _, child in ipairs(children) do
      local title = child:match("([^/]+)$")
      if reaper.ImGui_TreeNode(ctx, title .. "##" .. child) then
        draw_directory(child)
        reaper.ImGui_TreePop(ctx)
      end
    end
  end

  draw_directory("")
end

local function draw_window()
  -- ReaImGui persists window geometry; force a large on-screen window on each launch.
  if not state.sized then
    reaper.ImGui_SetNextWindowPos(ctx, 20, 40, reaper.ImGui_Cond_Always())
    reaper.ImGui_SetNextWindowSize(ctx, 1400, 950, reaper.ImGui_Cond_Always())
    state.sized, state.open_hw = true, true
  end
  local visible, open = reaper.ImGui_Begin(ctx, "Yamaha STY Style Manager & Live Rig Builder", true)
  if visible then
    reaper.ImGui_Text(ctx, "Style library:")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, state.root ~= "" and state.root or "(not configured)")
    if reaper.ImGui_Button(ctx, "Config Directory") then state.show_config = true end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Refresh Library") then refresh_library() end
    reaper.ImGui_SameLine(ctx)
    local can_import = state.selected ~= nil
    if not can_import then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Import Style to Rig") then import_selected() end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Resend MX88 Voices") then
      if Launchpad.mapper then Launchpad.mapper.send_voices(Launchpad.yamaha_output, Launchpad.voices) end
    end
    if not can_import then reaper.ImGui_EndDisabled(ctx) end

    if state.open_hw then
      reaper.ImGui_SetNextItemOpen(ctx, true, reaper.ImGui_Cond_Always())
      state.open_hw = false
    end
    if reaper.ImGui_CollapsingHeader(ctx, "Launchpad Mini MK3 / nanoKONTROL2 - how to use") then
      reaper.ImGui_TextWrapped(ctx, "SETUP: connect the Launchpad and the nanoKONTROL2 in CC mode, select them below, and double-click a style. IMPORTANT: in REAPER > Preferences > Audio > MIDI Devices, both Launchpad input ports ('LPMiniMK3 MIDI' and 'MIDIIN2 (LPMiniMK3 MIDI)') must be set to Enabled, not Enabled+Control, otherwise pad presses do not reach this script. The window closes and the script keeps running in the background (run it again to open the window).")
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, "LAUNCHPAD: no mode button needed - the script switches the Launchpad to Programmer mode by itself (and back to Live mode when it stops). The top 3 rows and the bottom 3 rows above the control row are style sections (section 1 = top-left, left to right then downward, skipping the middle solo row). Pad colours match the REAPER region colours: blue = Intro, green = Main, orange = Fill In, pink = Break, red = Ending. The playing section turns white; a pad you pressed pulses until the section changes at the next bar line. Main sections loop until you press another pad. Fill In and Break play once and return to the last Main (with Auto-fill on, changing Main A to Main B first plays Fill In AA). Intro plays once, then loops the matching Main. Ending plays once and stops.")
      reaper.ImGui_TextWrapped(ctx, "MIDDLE ROW, left to right: Grand Piano, Electric Piano, Organ, Guitar, Violin, Trumpet, Alto Sax, Flute. Press one to change the MX88 soloist voice immediately.")
      reaper.ImGui_TextWrapped(ctx, "BOTTOM ROW, left to right: PLAY/STOP (green), AUTO-FILL on/off (yellow = on), ENDING (red), RESEND MX88 voices (blue), TEMPO - and TEMPO + (cyan, 2 BPM), PREVIOUS and NEXT section (pink).")
      reaper.ImGui_TextWrapped(ctx, "KEYBOARD: the MX88 is split. LEFT hand (below the split point) chooses the chord: the style parts follow it and it is held until you play a new chord. RIGHT hand (from the split point up) plays the soloist voice on MX88 channel 1. Split point and solo voice are set in 'Keyboard split' below and apply to the next import.")
      local regions = Launchpad.regions or {}
      for row = 1, 6 do
        local names = {}
        for col = 1, 8 do
          local region = regions[(row - 1) * 8 + col]
          if region then names[#names + 1] = region.name end
        end
        if #names > 0 then reaper.ImGui_BulletText(ctx, "Pad row " .. row .. " (from top): " .. table.concat(names, " | ")) end
      end
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, "NANOKONTROL2 (mixer for the 8 rig parts, channels 9-16, left to right): sliders = volume, knobs = pan, S = solo, M = mute, R = re-send that part's voice to the MX88. Transport: PLAY / STOP; TRACK < > or MARKER < > = previous / next section; REW / FF = tempo -/+ 2 BPM; REC = Ending; CYCLE = Auto-fill on/off; SET = resend voices. The first track of the rig, '[MIDI] Yamaha MX88 Chord Input', is record-armed from the MX88 keyboard input to play chords.")
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_Button(ctx, "Play / Stop") then Launchpad.play_stop() end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Ending") then Launchpad.trigger_ending() end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Tempo -") then Launchpad.nudge_tempo(-2) end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Tempo +") then Launchpad.nudge_tempo(2) end
      reaper.ImGui_SameLine(ctx)
      local toggled, auto_fill = reaper.ImGui_Checkbox(ctx, "Auto-fill between Mains", Launchpad.auto_fill)
      if toggled then Launchpad.auto_fill = auto_fill; Launchpad.draw_controls() end
      if reaper.ImGui_Button(ctx, "Resend MX88 voices now") then
        if Launchpad.mapper then Launchpad.mapper.send_voices(Launchpad.yamaha_output, Launchpad.voices) end
      end
    end    if reaper.ImGui_CollapsingHeader(ctx, "Keyboard split (applies to next import)") then
      local split = tonumber(reaper.GetExtState(EXT_SECTION, "Split")) or 60
      local solo = tonumber(reaper.GetExtState(EXT_SECTION, "SoloVoice")) or 65
      local c1, new_split = reaper.ImGui_SliderInt(ctx, "Split point (MIDI note, 60 = C4)", split, 36, 84)
      if c1 then reaper.SetExtState(EXT_SECTION, "Split", tostring(new_split), true) end
      local c2, new_solo = reaper.ImGui_SliderInt(ctx, "Solo voice (GM program 0-127, 65 = alto sax)", solo, 0, 127)
      if c2 then reaper.SetExtState(EXT_SECTION, "SoloVoice", tostring(new_solo), true) end
    end
    if reaper.ImGui_CollapsingHeader(ctx, "MIDI Hardware", reaper.ImGui_TreeNodeFlags_DefaultOpen()) then
      reaper.ImGui_TextWrapped(ctx, "The Launchpad has two ports (MIDI and MIDIIN2/MIDIOUT2): both are used automatically for pad presses and LEDs. For input, both Launchpad ports in REAPER must be Enabled (not Enabled+Control). Last Launchpad message seen: " .. (Launchpad.last_seen or "none yet (press a pad)"))
      local resolved, _, lists = current_devices()
      for _, slot in ipairs(DEVICE_SLOTS) do
        device_selector(slot, lists[slot.outputs == true], resolved[slot.key])
      end
    end

    local changed
    changed, state.filter = reaper.ImGui_InputText(ctx, "Search", state.filter)
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_BeginChild(ctx, "StyleBrowser", -1, -60, reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 1) then
      draw_file_tree()
      reaper.ImGui_EndChild(ctx)
    end
    if state.status_is_error then reaper.ImGui_TextColored(ctx, 0xFF5555FF, state.status)
    else reaper.ImGui_Text(ctx, state.status) end
    if state.scan_error then reaper.ImGui_TextWrapped(ctx, state.scan_error) end

    if state.show_config then reaper.ImGui_OpenPopup(ctx, "Configure Style Library"); state.show_config = false end
    if reaper.ImGui_BeginPopupModal(ctx, "Configure Style Library", true) then
      reaper.ImGui_TextWrapped(ctx, "Enter the root folder containing Yamaha .sty files.")
      local edited
      edited, state.root = reaper.ImGui_InputText(ctx, "Folder", state.root)
      if reaper.ImGui_Button(ctx, "Save and Scan") then
        state.root = normalize_path(state.root)
        reaper.SetExtState(EXT_SECTION, EXT_KEY, state.root, true)
        state.show_config = false
        reaper.ImGui_CloseCurrentPopup(ctx)
        refresh_library()
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Cancel") then
        state.show_config = false
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_EndPopup(ctx)
    end
    reaper.ImGui_End(ctx)
  end
  return open
end

if state.root == "" then
  state.root = "C:\\Users\\josem\\workarea\\yamaha-mx-styles\\styles"
  reaper.SetExtState(EXT_SECTION, EXT_KEY, state.root, true)
end
refresh_library()

reaper.atexit(function() Launchpad.shutdown() end)

local Chord = require("chord_detect")
local chord_ctx
local function chord_state()
  local rig = Launchpad.rig
  if not (rig and rig.input and reaper.ValidatePtr(rig.input, "MediaTrack*") and rig.input_fx and rig.input_fx >= 0) then return nil end
  local root = reaper.TrackFX_GetParam(rig.input, rig.input_fx, 3)
  local mask = reaper.TrackFX_GetParam(rig.input, rig.input_fx, 4)
  local bass = reaper.TrackFX_GetParam(rig.input, rig.input_fx, 5)
  return root, mask, bass
end

-- Small always-on window with the active chord; it has its own context so it survives closing the main window.
local function draw_chord_window()
  if not chord_ctx then
    chord_ctx = reaper.ImGui_CreateContext("Active Chord")
  end
  reaper.ImGui_SetNextWindowSize(chord_ctx, 380, 520, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(chord_ctx, "Active Chord", true)
  if visible then
    local root, mask, bass = chord_state()
    if root and mask and mask > 0 then
      reaper.ImGui_TextColored(chord_ctx, 0x55FF88FF, "CHORD:  " .. Chord.name(root, mask))
      reaper.ImGui_Text(chord_ctx, "Notes: " .. Chord.notes(root, mask))
    else
      reaper.ImGui_Text(chord_ctx, "Play a chord with your left hand on the MX88")
    end
    local pos = reaper.GetPlayState() & 1 == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    local region_index = select(3, reaper.GetLastMarkerAndCurRegion(0, pos))
    if region_index and region_index >= 0 then
      local _, _, _, _, name = reaper.EnumProjectMarkers(region_index)
      reaper.ImGui_Text(chord_ctx, "Section: " .. tostring(name))
    end
    reaper.ImGui_Separator(chord_ctx)
    reaper.ImGui_Text(chord_ctx, "Soloist voice (click to change):")
    local solo = Launchpad.current_solo_voice and Launchpad.current_solo_voice()
    for _, preset in ipairs(Launchpad.SOLO_PRESETS or {}) do
      local active = solo and solo.prg == preset.prg
      if reaper.ImGui_RadioButton(chord_ctx, preset.label, active and true or false) then
        Launchpad.set_solo_voice(preset.prg)
      end
    end
    if Launchpad.last_action or Launchpad.last_seen then
      reaper.ImGui_Text(chord_ctx, "Last pad: " .. tostring(Launchpad.last_action or "-") .. "  " .. tostring(Launchpad.last_seen or ""))
    end
    reaper.ImGui_Separator(chord_ctx)
    reaper.ImGui_Text(chord_ctx, "Selected voices on the MX88 (bank MSB/LSB, program):")
    for index, voice in ipairs(Launchpad.voices or {}) do
      local label = voice.solo and "Soloist (Ch 1)" or ("Ch " .. (voice.chan + 1))
      reaper.ImGui_Text(chord_ctx, string.format("%s: %d/%d, prg %d", label, voice.msb or 0, voice.lsb or 0, (voice.prg or 0) + 1))
    end
      reaper.ImGui_End(chord_ctx)
    end
    if not open then chord_ctx = nil end
  end
  if not open then chord_ctx = nil end
end

local gui_open = true
local function loop()
  Launchpad.poll()
  if gui_open then
    local keep_open = draw_window()
    if state.import_requested then
      state.import_requested = false
      import_selected()
      if not state.status_is_error then keep_open = false end
    end
    if not keep_open then
      gui_open = false
      if reaper.ImGui_DestroyContext then reaper.ImGui_DestroyContext(ctx) end
    end
  end
  if (gui_open or Launchpad.active) and Launchpad.rig then
    local ok, err = pcall(draw_chord_window)
    if not ok then reaper.ShowConsoleMsg("Chord window: " .. tostring(err) .. "\n") end
  end
  -- Stay alive without a window while the Launchpad control is active.
  if gui_open or Launchpad.active then reaper.defer(loop) end
end
reaper.defer(loop)

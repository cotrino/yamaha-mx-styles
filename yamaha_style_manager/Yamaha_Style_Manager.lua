-- @description Yamaha STY Style Manager & Live Rig Builder
-- @author Jose M. Cotrino
-- @version 1.1.1
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
for _, name in ipairs({ "sty_parser", "mx88_mapper", "voice_map", "region_builder", "launchpad_controller" }) do package.loaded[name] = nil end

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
      reaper.ImGui_TextWrapped(ctx, "SETUP: connect the Launchpad (use its 'LPMiniMK3 MIDI' port, not the DAW port) and the nanoKONTROL2 in CC mode, select them below, and double-click a style. The window closes and the script keeps running in the background (run it again to open the window).")
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, "LAUNCHPAD: press the USER button (Custom mode 3, the lighting Drum Rack layout; NOT Drums or Keys). LEFT 4x8 block = one pad per style section (section 1 = top-left, left to right then downward). Pad colours match the REAPER region colours: blue = Intro, green = Main, orange = Fill In, pink = Break, red = Ending. The playing section turns white; a pad you pressed pulses until the section changes at the next bar line. Main sections loop until you press another pad. Fill In and Break play once and return to the last Main (with Auto-fill on, changing Main A to Main B first plays Fill In AA). Intro plays once, then loops the matching Main. Ending plays once and stops.")
      reaper.ImGui_TextWrapped(ctx, "RIGHT 4x8 block (top row first): PLAY/STOP (green), AUTO-FILL on/off (yellow = on), ENDING (red), RESEND MX88 voices (blue); second row: TEMPO - and TEMPO + (cyan, 2 BPM), PREVIOUS and NEXT section (pink).")      local regions = Launchpad.regions or {}
      for row = 1, 8 do
        local names = {}
        for col = 1, 4 do
          local region = regions[(row - 1) * 4 + col]
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
    end    if reaper.ImGui_CollapsingHeader(ctx, "MIDI Hardware", reaper.ImGui_TreeNodeFlags_DefaultOpen()) then
      reaper.ImGui_TextWrapped(ctx, "The Launchpad has two ports (MIDI and MIDIIN2/MIDIOUT2): both are enabled in REAPER and both are used automatically for pad presses and LEDs. Last Launchpad message seen: " .. (Launchpad.last_seen or "none yet (press a pad in USER mode)"))
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
  -- Stay alive without a window while the Launchpad control is active.
  if gui_open or Launchpad.active then reaper.defer(loop) end
end
reaper.defer(loop)
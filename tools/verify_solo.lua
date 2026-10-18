-- Run in REAPER. MIDI output and test settings are intercepted; the project is not modified.
local tools = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local root = tools .. "..\\"
local manager = root .. "yamaha_style_manager\\"
local report, sent, labels, settings = {}, {}, {}, {}
local saved = {}
for _, name in ipairs({"defer", "atexit", "StuffMIDIMessage", "SendMIDIMessageToHardware",
    "GetExtState", "SetExtState", "ImGui_Text", "ImGui_RadioButton", "ShowConsoleMsg"}) do
  saved[name] = reaper[name]
end
local function check(ok, label)
  assert(ok, label)
  report[#report + 1] = "PASS " .. label
end
local function finish(ok, err)
  for name, fn in pairs(saved) do reaper[name] = fn end
  reaper.RecursiveCreateDirectory(root .. "build", 0)
  local file = assert(io.open(root .. "build\\solo-verification.txt", "w"))
  file:write("REAPER ", reaper.GetAppVersion(), "\n", table.concat(report, "\n"), "\n",
    ok and "RESULT PASS\n" or ("RESULT FAIL\n" .. tostring(err) .. "\n"))
  file:close()
end
local ok, err = xpcall(function()
  local callback
  reaper.defer = function(fn) callback = fn end
  reaper.atexit = function() end
  reaper.GetExtState = function(section, key)
    if section == "YamahaStyleManager" and
        (key == "SoloVoice" or key == "SoloPreset" or key == "SoloVolume") then
      return settings[key] or ""
    end
    return saved.GetExtState(section, key)
  end
  reaper.SetExtState = function(section, key, value, persist)
    if section == "YamahaStyleManager" then settings[key] = value
    else saved.SetExtState(section, key, value, persist) end
  end
  reaper.StuffMIDIMessage = function(port, status, d1, d2)
    sent[#sent + 1] = {port, status, d1, d2}
  end
  reaper.SendMIDIMessageToHardware = function() end
  reaper.ImGui_Text = function(ctx, text) labels[#labels + 1] = text; saved.ImGui_Text(ctx, text) end
  reaper.ImGui_RadioButton = function(ctx, text, active)
    labels[#labels + 1] = text
    return saved.ImGui_RadioButton(ctx, text, active)
  end
  reaper.ShowConsoleMsg = function(text) error(text) end
  assert(loadfile(manager .. "Yamaha_Style_Manager.lua"))()
  check(callback ~= nil, "Load actual Style Manager main script")
  local Launchpad, Mapper, VoiceMap = require("launchpad_controller"), require("mx88_mapper"), require("voice_map")
  check(Mapper.driver ~= nil, "Load installed Genos catalog and driver")
  local solo = {chan = 0, msb = 63, lsb = 0, prg = 0, solo = true}
  Launchpad.voices, Launchpad.mapper, Launchpad.yamaha_output = {solo}, Mapper, 0
  Launchpad.rig = {voices = Launchpad.voices}
  for _, shortcut in ipairs(Launchpad.SOLO_PRESETS) do
    sent = {}
    Launchpad.set_solo_voice(shortcut.prg)
    local expected = VoiceMap.solo(shortcut.prg)
    check(VoiceMap.id(solo) == VoiceMap.id(expected) and solo.name == expected.name,
      shortcut.label .. " selects " .. expected.name)
    local cc = {}
    for _, msg in ipairs(sent) do
      if msg[2] == 0xB0 then cc[msg[3]] = msg[4] end
    end
    check(cc[0] == 63 and cc[7] == 120 and cc[11] == 127,
      shortcut.label .. " sends native bank, solo level 120 and expression 127")
  end
  Launchpad.set_solo_voice(65, "63:0:21")
  check(settings.SoloPreset == "63:0:21" and solo.name:find("Vintage'74", 1, true),
    "Live custom preset is persisted by native bank/program")
  settings.SoloVolume = "110"
  sent = {}
  Mapper.send_solo_level(0)
  check(sent[1][3] == 7 and sent[1][4] == 110 and sent[2][3] == 11 and sent[2][4] == 127,
    "Adjustable solo volume sends CC7 without a program change")
  saved.defer(function()
    local rendered, render_error = xpcall(function()
      callback()
      local text = table.concat(labels, "\n")
      check(text:find("Flute - Flute: Sweet Flt", 1, true), "Render actual named native shortcut controls")
      check(text:find("Soloist (Ch 1): EP: Vintage'74 (63/0, prg 22)", 1, true),
        "Render actual selected-voice list with Yamaha preset name")
    end, debug.traceback)
    finish(rendered, render_error)
  end)
end, debug.traceback)
if not ok then finish(false, err) end

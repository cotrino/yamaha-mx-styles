-- @noindex
-- Maps the General-MIDI/XG style voices to real Yamaha MX88 voices (bank MSB 63 / 32)
-- using the MX reabank shipped with the Genos suite.
local reaper = reaper
local VoiceMap = { voices = nil }

-- GM program ranges (0-based) -> ordered Lua patterns matched against MX voice names.
local GM_FAMILIES = {
  { 0, 3, { "^APno: CncrtGrand", "^APno:" } },
  { 4, 5, { "^EP: Vintage", "^EP:" } },
  { 6, 7, { "^Clavi:" } },
  { 8, 15, { "^Malet:", "^Bell:" } },
  { 16, 18, { "^TnWhl:" } },
  { 19, 20, { "^RPipe:", "^Pipe:" } },
  { 21, 23, { "^Pipe:", "^TnWhl:" } },
  { 24, 25, { "^A%.Gtr: Steel", "^A%.Gtr:" } },
  { 26, 28, { "^E%.Cln:" } },
  { 29, 31, { "^E%.Dst:" } },
  { 32, 32, { "^ABass:" } },
  { 33, 35, { "^EBass:" } },
  { 36, 37, { "^EBass: Slap", "^EBass:" } },
  { 38, 39, { "^SynBs:" } },
  { 40, 41, { "^Solo: Vln", "^Ensem:" } },
  { 42, 43, { "^Ensem:" } },
  { 44, 45, { "^Pizz:" } },
  { 46, 46, { "^Pizz: BeautyHarp", "^Pizz:" } },
  { 47, 47, { "^PDrum: Timp", "^Perc:" } },
  { 48, 51, { "^Ensem:", "^Orche:" } },
  { 52, 54, { "^Choir:" } },
  { 55, 55, { "^Orche:", "^Hook:" } },
  { 56, 56, { "^Solo: Trumpet", "^BrsEn:" } },
  { 57, 57, { "^Solo: Trombone", "^BrsEn:" } },
  { 58, 60, { "^Orche: F%. Horns", "^Orche:" } },
  { 61, 63, { "^BrsEn:" } },
  { 64, 67, { "^Sax:" } },
  { 68, 71, { "^Blown:", "^Sax:" } },
  { 72, 79, { "^Flute:", "^Blown:" } },
  { 80, 87, { "^Analg:", "^Synth:" } },
  { 88, 95, { "^Warm:", "^Ambie:" } },
  { 96, 103, { "^Ambie:", "^SciFi:" } },
  { 104, 111, { "^Pluk:", "^Bowed:" } },
  { 112, 119, { "^Perc:", "^PDrum:" } },
  { 120, 127, { "^Sweep:", "^SciFi:" } },
}

-- Style drum-kit program -> kit-name patterns.
local DRUM_KITS = {
  [0] = "PwrStdKit1", [1] = "PwrStdKit1", [8] = "DryStd Kit", [16] = "PwrStdKit2",
  [24] = "ElectrcKit", [25] = "AnlgT8 Kit", [32] = "Jazz Kit", [40] = "Brush Kit",
  [48] = "Orch Kit",
}

local function load_voices(path)
  local voices = {}
  local file = io.open(path, "r")
  if not file then return voices end
  local msb, lsb = 0, 0
  for line in file:lines() do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and not line:match("^//") then
      local m, l = line:match("^Bank%s+(%d+)%s+(%d+)")
      if m then
        msb, lsb = tonumber(m), tonumber(l)
      else
        local program, _, name = line:match("^(%d+)%s+(%d+)%s+(.+)$")
        if program and msb == 63 then
          voices[#voices + 1] = { msb = msb, lsb = lsb, prg = tonumber(program), name = name }
        end
      end
    end
  end
  file:close()
  return voices
end

function VoiceMap.init(reabank_path)
  VoiceMap.voices = load_voices(reabank_path)
end

local function find_voice(patterns, min_lsb, max_lsb)
  for _, pattern in ipairs(patterns) do
    for _, voice in ipairs(VoiceMap.voices or {}) do
      if voice.lsb >= min_lsb and voice.lsb <= max_lsb and voice.name:find(pattern) then return voice end
    end
  end
end

-- Returns {msb, lsb, prg, name} for the MX88 voice nearest to the style's voice.
function VoiceMap.resolve(style_voice, is_drum)
  if is_drum then
    local program = style_voice.prg or 0
    local kit = DRUM_KITS[program] or DRUM_KITS[program - program % 8] or "PwrStdKit1"
    local voice = find_voice({ "^Drums: " .. kit }, 32, 32) or find_voice({ "^Drums:" }, 32, 32)
    return voice or { msb = 63, lsb = 32, prg = 0, name = "Drums" }
  end
  local program = style_voice.prg or 0
  for _, family in ipairs(GM_FAMILIES) do
    if program >= family[1] and program <= family[2] then
      local voice = find_voice(family[3], 0, 31)
      if voice then return voice end
    end
  end
  return { msb = 63, lsb = 0, prg = 0, name = "Default" }
end

return VoiceMap

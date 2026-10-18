-- @noindex
local VoiceMap = {}
local programs, gm, native, exact = {}, {}, {}, {}
VoiceMap.presets = {}

local ROLES = {
  bass = { allowed = { { 32, 39 } }, default = 33 },
  chord1 = { allowed = { { 0, 31 }, { 40, 55 }, { 80, 95 } }, default = 4 },
  chord2 = { allowed = { { 0, 31 }, { 40, 55 }, { 80, 95 } }, default = 27 },
  pad = { allowed = { { 40, 55 }, { 88, 103 } }, default = 89 },
  phrase1 = { allowed = { { 0, 31 }, { 40, 103 } }, default = 48 },
  phrase2 = { allowed = { { 0, 31 }, { 40, 103 } }, default = 61 },
}
local KITS = { [8] = 5, [16] = 0, [24] = 35, [25] = 25, [32] = 22, [40] = 21, [48] = 42 }

local function key(msb, lsb, prg) return string.format("%d:%d:%d", msb, lsb, prg) end
local function sound_name(name) return name:match(":%s*(.+)$") or name end
local function normalized(name) return sound_name(name):lower():gsub("[^%w]", "") end

function VoiceMap.configure(catalog)
  programs, gm, native, exact = {}, {}, {}, {}
  VoiceMap.presets = {}
  for _, voice in ipairs(catalog) do programs[#programs + 1] = voice end
  table.sort(programs, function(a, b)
    if a.msb ~= b.msb then return a.msb < b.msb end
    if a.lsb ~= b.lsb then return a.lsb < b.lsb end
    return a.prg < b.prg
  end)
  for _, voice in ipairs(programs) do
    exact[key(voice.msb, voice.lsb, voice.prg)] = voice
    if voice.msb == 0 and voice.lsb == 0 then gm[voice.prg] = voice end
    if voice.msb == 63 and voice.lsb < 8 then
      native[normalized(voice.name)] = native[normalized(voice.name)] or voice
      VoiceMap.presets[#VoiceMap.presets + 1] = voice
    end
  end
  assert(gm[0] and exact["63:0:0"] and exact["63:32:0"], "Incomplete Yamaha MX voice catalog")
  table.sort(VoiceMap.presets, function(a, b) return a.name < b.name end)
end

function VoiceMap.id(voice) return key(voice.msb, voice.lsb, voice.prg) end

function VoiceMap.solo(program, preset)
  local voice = preset and exact[preset]
  if voice and voice.msb == 63 and voice.lsb < 8 then return voice end
  return VoiceMap.resolve({ prg = program }, "solo")
end

function VoiceMap.resolve(style_voice, role)
  assert(gm[0], "Load the Genos Suite voice catalog before importing a style")
  local program = style_voice.prg or 0
  if style_voice.msb == 63 then
    local voice = exact[key(63, style_voice.lsb or 0, program)]
    if voice and ((role == "drums") == (voice.lsb == 32)) then return voice end
  end
  if role == "drums" then return exact[key(63, 32, KITS[program] or 0)] end
  local spec = ROLES[role]
  if spec then
    local allowed = false
    for _, range in ipairs(spec.allowed) do
      if program >= range[1] and program <= range[2] then allowed = true break end
    end
    if not allowed then program = spec.default end
  end
  local alias = assert(gm[program], "Unknown GM program: " .. program)
  if program == 0 then return exact["63:0:0"] end
  local voice = native[normalized(alias.name)]
  if voice then return voice end
  -- A category match keeps the instrument family, never the unrelated preset at the GM program number.
  local category = alias.category or alias.name:match("^([^:]+):")
  for _, candidate in ipairs(programs) do
    if candidate.msb == 63 and candidate.lsb < 8
        and (candidate.category or candidate.name:match("^([^:]+):")) == category then
      return candidate
    end
  end
  error("No native Yamaha MX preset for " .. alias.name)
end

return VoiceMap

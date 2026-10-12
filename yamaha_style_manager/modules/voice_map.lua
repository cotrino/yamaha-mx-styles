-- @noindex
-- Translates the voice a style selects into one the Yamaha MX88 actually has.
-- Styles were written for other keyboards (PSR/Tyros/Genos banks such as MSB 8 or LSB 112+), so their
-- bank numbers mean nothing to the MX88 and their program numbers are only trustworthy when the style
-- uses the plain General MIDI bank. Each part therefore gets a role: a style program is kept only if it
-- belongs to that role's sound family, otherwise a sensible MX88 General MIDI voice is used instead.
-- The MX88 General MIDI bank is MSB 0 / LSB 0; its drum kit is MSB 127 / LSB 0 / program 0.
local VoiceMap = {}

local function between(program, ranges)
  for _, range in ipairs(ranges) do
    if program >= range[1] and program <= range[2] then return true end
  end
  return false
end

-- allowed = GM program ranges acceptable for the role; default = voice used when the style's choice isn't.
local ROLES = {
  bass = { allowed = { { 32, 39 } }, default = 33 },
  chord1 = { allowed = { { 0, 31 }, { 40, 55 }, { 80, 95 } }, default = 4 },
  chord2 = { allowed = { { 0, 31 }, { 40, 55 }, { 80, 95 } }, default = 27 },
  pad = { allowed = { { 40, 55 }, { 88, 103 } }, default = 89 },
  phrase1 = { allowed = { { 0, 31 }, { 40, 79 }, { 80, 103 } }, default = 48 },
  phrase2 = { allowed = { { 0, 31 }, { 40, 79 }, { 80, 103 } }, default = 61 },
}

-- MX88 Preset drum kits (MSB 63 / LSB 32) for the kit families that the single GM kit can't represent.
local SPECIAL_KITS = {
  [32] = { 63, 32, 22, "Jazz Kit" },
  [40] = { 63, 32, 21, "Brush Kit" },
  [24] = { 63, 32, 35, "Electric Kit" },
  [25] = { 63, 32, 25, "Analog T8 Kit" },
  [48] = { 63, 32, 42, "Orchestra Kit" },
}

-- style_voice = { msb, lsb, prg } as found in the style; role = "drums" or a key of ROLES.
function VoiceMap.resolve(style_voice, role)
  local program = style_voice.prg or 0
  if role == "drums" then
    local special = SPECIAL_KITS[program]
    if special then return { msb = special[1], lsb = special[2], prg = special[3], name = special[4] } end
    return { msb = 127, lsb = 0, prg = 0, name = "GM Drum Kit" }
  end
  local spec = ROLES[role] or ROLES.chord1
  -- A pure General MIDI/XG normal voice (bank 0/0) is trusted if it fits the role; banked voices keep
  -- only their program number, and only if it fits.
  if between(program, spec.allowed) then
    return { msb = 0, lsb = 0, prg = program, name = "GM " .. program }
  end
  return { msb = 0, lsb = 0, prg = spec.default, name = "GM " .. spec.default .. " (role default)" }
end

return VoiceMap

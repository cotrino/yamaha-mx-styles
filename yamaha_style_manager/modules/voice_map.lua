-- @noindex
-- Translates the voice a style selects into one the Yamaha MX88 actually has.
-- The MX88 provides a General MIDI bank (MSB 0 / LSB 0, program = GM number) and a GM2 drum
-- bank (MSB 127 / LSB 0, program = kit number). Styles written for other keyboards use
-- XG/Genos banks that the MX88 lacks, so only the program number is kept and the bank
-- is forced to the MX88 equivalent.
local VoiceMap = {}

local DRUM_KITS = { [0] = true, [8] = true, [16] = true, [24] = true, [25] = true, [32] = true, [40] = true, [48] = true }

function VoiceMap.resolve(style_voice, is_drum)
  local program = style_voice.prg or 0
  if is_drum then
    local kit = DRUM_KITS[program] and program or (DRUM_KITS[program - program % 8] and program - program % 8) or 0
    return { msb = 127, lsb = 0, prg = kit, name = "GM Drum Kit " .. kit }
  end
  return { msb = 0, lsb = 0, prg = program, name = "GM " .. program }
end

return VoiceMap

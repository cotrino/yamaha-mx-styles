-- @noindex
-- Names a chord from the pitch-class mask published by the chord transposer JSFX (bit n = n semitones above root).
local Chord = {}

local NAMES = { "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B" }

-- Ordered most specific first; masks use the intervals present, ignoring the doubled root.
local TEMPLATES = {
  { suffix = "maj7", intervals = { 0, 4, 7, 11 } },
  { suffix = "m7", intervals = { 0, 3, 7, 10 } },
  { suffix = "7", intervals = { 0, 4, 7, 10 } },
  { suffix = "m7b5", intervals = { 0, 3, 6, 10 } },
  { suffix = "dim7", intervals = { 0, 3, 6, 9 } },
  { suffix = "6", intervals = { 0, 4, 7, 9 } },
  { suffix = "m6", intervals = { 0, 3, 7, 9 } },
  { suffix = "add9", intervals = { 0, 2, 4, 7 } },
  { suffix = "m(maj7)", intervals = { 0, 3, 7, 11 } },
  { suffix = "7sus4", intervals = { 0, 5, 7, 10 } },
  { suffix = "m", intervals = { 0, 3, 7 } },
  { suffix = "dim", intervals = { 0, 3, 6 } },
  { suffix = "aug", intervals = { 0, 4, 8 } },
  { suffix = "sus4", intervals = { 0, 5, 7 } },
  { suffix = "sus2", intervals = { 0, 2, 7 } },
  { suffix = "", intervals = { 0, 4, 7 } },
  { suffix = "m", intervals = { 0, 3 } },
  { suffix = "5", intervals = { 0, 7 } },
  { suffix = "", intervals = { 0, 4 } },
}

local function mask_of(intervals)
  local mask = 0
  for _, interval in ipairs(intervals) do mask = mask | (1 << interval) end
  return mask
end

for _, template in ipairs(TEMPLATES) do template.mask = mask_of(template.intervals) end

function Chord.note_name(pitch_class) return NAMES[(pitch_class % 12) + 1] end

-- root_pc: bass pitch class; mask: intervals above it. Returns the chord root pitch class, suffix and bass pitch class.
function Chord.analyze(root_pc, mask)
  mask = math.floor(mask or 1)
  root_pc = math.floor(root_pc or 0) % 12
  for _, template in ipairs(TEMPLATES) do
    if mask == template.mask then return root_pc, template.suffix, root_pc end
  end
  for shift = 1, 11 do
    if mask & (1 << shift) ~= 0 then
      local rotated = 0
      for bit = 0, 11 do
        if mask & (1 << bit) ~= 0 then rotated = rotated | (1 << ((bit - shift) % 12)) end
      end
      for _, template in ipairs(TEMPLATES) do
        if rotated == template.mask then return (root_pc + shift) % 12, template.suffix, root_pc end
      end
    end
  end
  for _, template in ipairs(TEMPLATES) do
    if mask & template.mask == template.mask then return root_pc, template.suffix, root_pc end
  end
  return root_pc, "", root_pc
end

-- Display name and the chord's list of note names.
function Chord.name(root_pc, mask)
  local root, suffix, bass = Chord.analyze(root_pc, mask)
  if root ~= bass then return Chord.note_name(root) .. suffix .. "/" .. Chord.note_name(bass) end
  return Chord.note_name(root) .. suffix
end

function Chord.notes(root_pc, mask)
  local names = {}
  mask = math.floor(mask or 1)
  for bit = 0, 11 do
    if mask & (1 << bit) ~= 0 then names[#names + 1] = Chord.note_name(root_pc + bit) end
  end
  return table.concat(names, " ")
end

return Chord

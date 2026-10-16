-- @noindex
-- Key detection and next-chord suggestions from the played chord history.
-- Approach follows the scale-degree / functional-harmony tables used by chord tools such as ChordGun:
-- diatonic triads per scale degree, weighted functional transitions, secondary dominants and borrowed chords.
local Chord = require("chord_detect")
local Theory = { history = {}, max_history = 12 }

local MAJOR = { 0, 2, 4, 5, 7, 9, 11 }
local MINOR = { 0, 2, 3, 5, 7, 8, 10 }
local MAJOR_QUALITY = { "", "m", "m", "", "", "m", "dim" }
local MINOR_QUALITY = { "m", "dim", "", "m", "m", "", "" }
local MAJOR_ROMAN = { "I", "ii", "iii", "IV", "V", "vi", "vii\194\176" }
local MINOR_ROMAN = { "i", "ii\194\176", "III", "iv", "v", "VI", "VII" }
-- Krumhansl-Kessler key profiles.
local PROFILE_MAJOR = { 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 }
local PROFILE_MINOR = { 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 }

-- Functional transition weights per degree (tonic -> subdominant/dominant, dominant -> tonic, deceptive cadence...).
local TRANSITIONS = {
  major = {
    [1] = { { 4, .30 }, { 5, .30 }, { 6, .20 }, { 2, .15 }, { 3, .05 } },
    [2] = { { 5, .60 }, { 7, .10 }, { 4, .15 }, { 1, .15 } },
    [3] = { { 6, .45 }, { 4, .30 }, { 2, .25 } },
    [4] = { { 5, .45 }, { 1, .25 }, { 2, .20 }, { 6, .10 } },
    [5] = { { 1, .65 }, { 6, .20 }, { 4, .15 } },
    [6] = { { 2, .30 }, { 4, .35 }, { 5, .25 }, { 3, .10 } },
    [7] = { { 1, .80 }, { 6, .20 } },
  },
  minor = {
    [1] = { { 4, .30 }, { 5, .25 }, { 6, .20 }, { 7, .15 }, { 3, .10 } },
    [2] = { { 5, .70 }, { 1, .30 } },
    [3] = { { 6, .40 }, { 4, .30 }, { 7, .30 } },
    [4] = { { 5, .40 }, { 1, .30 }, { 7, .15 }, { 2, .15 } },
    [5] = { { 1, .65 }, { 6, .25 }, { 4, .10 } },
    [6] = { { 4, .30 }, { 7, .30 }, { 3, .20 }, { 5, .20 } },
    [7] = { { 3, .45 }, { 1, .35 }, { 6, .20 } },
  },
}

local MODE_NAMES = { major = "major (Ionian)", minor = "natural minor (Aeolian)" }

local function quality_of(suffix)
  if suffix == "7" or suffix == "7sus4" then return "dom" end
  if suffix == "dim" or suffix == "m7b5" or suffix == "dim7" then return "dim" end
  if suffix == "aug" then return "aug" end
  if suffix:sub(1, 1) == "m" and suffix:sub(1, 3) ~= "maj" then return "min" end
  return "maj"
end

local function tones_of(root, quality)
  if quality == "min" then return { root, root + 3, root + 7 } end
  if quality == "dim" then return { root, root + 3, root + 6 } end
  if quality == "aug" then return { root, root + 4, root + 8 } end
  if quality == "dom" then return { root, root + 4, root + 7, root + 10 } end
  return { root, root + 4, root + 7 }
end

function Theory.reset() Theory.history, Theory.key = {}, nil end

-- Records a chord when it differs from the previous one.
function Theory.push(root_pc, mask)
  local root, suffix = Chord.analyze(root_pc, mask)
  local last = Theory.history[#Theory.history]
  if last and last.root == root and last.suffix == suffix then return false end
  Theory.history[#Theory.history + 1] = { root = root, suffix = suffix, quality = quality_of(suffix), name = Chord.note_name(root) .. suffix }
  if #Theory.history > Theory.max_history then table.remove(Theory.history, 1) end
  Theory.key = nil
  return true
end

local function correlation(histogram, profile, tonic)
  local sum_h, sum_p = 0, 0
  for i = 0, 11 do sum_h = sum_h + histogram[i]; sum_p = sum_p + profile[((i - tonic) % 12) + 1] end
  local mean_h, mean_p, num, den_h, den_p = sum_h / 12, sum_p / 12, 0, 0, 0
  for i = 0, 11 do
    local h, p = histogram[i] - mean_h, profile[((i - tonic) % 12) + 1] - mean_p
    num, den_h, den_p = num + h * p, den_h + h * h, den_p + p * p
  end
  if den_h == 0 or den_p == 0 then return -1 end
  return num / math.sqrt(den_h * den_p)
end

-- Best-fitting major / natural-minor key for the recent chords (newer chords weigh more, the root weighs double).
function Theory.detect_key()
  if Theory.key then return Theory.key end
  if #Theory.history == 0 then return nil end
  local histogram = {}
  for i = 0, 11 do histogram[i] = 0 end
  for index, chord in ipairs(Theory.history) do
    local weight = 0.6 + 0.4 * index / #Theory.history
    for n, pc in ipairs(tones_of(chord.root, chord.quality)) do
      histogram[pc % 12] = histogram[pc % 12] + weight * (n == 1 and 2 or 1)
    end
  end
  local best
  for tonic = 0, 11 do
    for mode, profile in pairs({ major = PROFILE_MAJOR, minor = PROFILE_MINOR }) do
      local score = correlation(histogram, profile, tonic) + (mode == "major" and 0.02 or 0)
      -- The first chord and the last chord are good tonic hints.
      if Theory.history[1].root == tonic then score = score + 0.03 end
      if Theory.history[#Theory.history].root == tonic then score = score + 0.03 end
      if not best or score > best.score then best = { tonic = tonic, mode = mode, score = score } end
    end
  end
  local steps = best.mode == "major" and MAJOR or MINOR
  best.name = Chord.note_name(best.tonic) .. " " .. MODE_NAMES[best.mode]
  best.notes = {}
  for i, step in ipairs(steps) do best.notes[i] = Chord.note_name(best.tonic + step) end
  best.confidence = math.max(0, math.min(1, (best.score + 0.2) / 1.2))
  Theory.key = best
  return best
end

local function degree_of(key, root)
  local steps = key.mode == "major" and MAJOR or MINOR
  for degree, step in ipairs(steps) do
    if (key.tonic + step) % 12 == root then return degree end
  end
end

local function common_tones(a, b)
  local set, count = {}, 0
  for _, pc in ipairs(a) do set[pc % 12] = true end
  for _, pc in ipairs(b) do if set[pc % 12] then count = count + 1 end end
  return count
end

function Theory.roman(key, chord)
  local degree = degree_of(key, chord.root)
  if not degree then return "?" end
  local base = (key.mode == "major" and MAJOR_ROMAN or MINOR_ROMAN)[degree]
  local diatonic = (key.mode == "major" and MAJOR_QUALITY or MINOR_QUALITY)[degree]
  local text = base
  if chord.quality == "min" and diatonic ~= "m" then text = base:lower()
  elseif chord.quality == "maj" and diatonic ~= "" then text = base:upper() end
  if chord.quality == "dom" then text = base:upper() .. "7" end
  return text
end

local function make(key, degree, quality, why, weight, current)
  local steps = key.mode == "major" and MAJOR or MINOR
  local root = (key.tonic + steps[degree]) % 12
  local suffix = ({ min = "m", dim = "dim", dom = "7", maj = "", aug = "aug" })[quality]
  local roman = (key.mode == "major" and MAJOR_ROMAN or MINOR_ROMAN)[degree]
  if quality == "maj" or quality == "dom" then roman = roman:upper() elseif quality == "min" then roman = roman:lower() end
  if quality == "dom" then roman = roman .. "7" end
  local tones = tones_of(root, quality)
  local smooth = current and common_tones(tones_of(current.root, current.quality), tones) or 0
  return { name = Chord.note_name(root) .. suffix, roman = roman, why = why, weight = weight * (1 + 0.1 * smooth),
    root = root, quality = quality }
end

-- Ranked next-chord suggestions for the latest chord in the detected key.
function Theory.suggest(limit)
  local key = Theory.detect_key()
  local current = Theory.history[#Theory.history]
  if not (key and current) then return {}, key end
  local results, seen = {}, { [current.name] = true }
  local function add(item)
    if item and not seen[item.name] then seen[item.name] = true; results[#results + 1] = item end
  end
  local diatonic_quality = key.mode == "major" and MAJOR_QUALITY or MINOR_QUALITY
  local degree = degree_of(key, current.root)
  local function quality_for(target)
    local q = diatonic_quality[target]
    if q == "m" then return "min" elseif q == "dim" then return "dim" end
    return "maj"
  end
  local function why(target)
    if target == 1 then return "resolves to the tonic"
    elseif target == 5 then return "dominant - builds tension"
    elseif target == 4 or target == 2 then return "subdominant - moves away from home"
    elseif target == 6 and key.mode == "major" then return "relative minor / deceptive"
    else return "diatonic colour" end
  end
  if current.quality == "dom" and not (degree == 5) then
    -- Secondary dominant: it wants to resolve a fifth down.
    local target = degree_of(key, (current.root + 5) % 12)
    if target then add(make(key, target, quality_for(target), "resolves the secondary dominant", 1.0, current)) end
  end
  if degree then
    for _, option in ipairs(TRANSITIONS[key.mode][degree]) do
      local target, weight = option[1], option[2]
      local quality = quality_for(target)
      if target == 5 and key.mode == "minor" then quality = "maj" end -- harmonic-minor dominant
      add(make(key, target, quality, why(target), weight, current))
      if target == 5 then
        add(make(key, 5, "dom", "dominant seventh - strongest pull home", weight * 0.9, current))
      end
    end
    if key.mode == "major" and degree == 1 then
      add(make(key, 5, "dom", "secondary dominant of V: use V7/V", 0.12, current))
      local sub = make(key, 7, "maj", "borrowed bVII (mixolydian colour)", 0.10, current)
      sub.name, sub.roman, sub.root = Chord.note_name(key.tonic + 10), "bVII", (key.tonic + 10) % 12
      add(sub)
    end
  else
    -- Chord outside the key: steer back with the dominant or the tonic.
    add(make(key, 5, "dom", "back to the key via the dominant", 0.5, current))
    add(make(key, 1, key.mode == "major" and "maj" or "min", "return to the tonic", 0.5, current))
  end
  table.sort(results, function(a, b) return a.weight > b.weight end)
  local total = 0
  for _, item in ipairs(results) do total = total + item.weight end
  for _, item in ipairs(results) do item.percent = math.floor(100 * item.weight / total + 0.5) end
  while limit and #results > limit do table.remove(results) end
  return results, key
end

return Theory

-- @noindex
local Parser = {}

local SECTION_PATTERNS = {
  { "^INTRO%s*([A-D])$", "Intro %s" },
  { "^MAIN%s*([A-D])$", "Main %s" },
  { "^FILL%s*IN%s*([A-D])([A-D])$", "Fill In %s%s" },
  { "^FILL%s*([A-D])([A-D])$", "Fill In %s%s" },
  { "^ENDING%s*([A-D])$", "Ending %s" },
  { "^BREAK$", "Break" },
}

local function read_vlq(data, position, limit)
  local value = 0
  for _ = 1, 4 do
    if position > limit then return nil, position, "truncated variable-length quantity" end
    local byte = data:byte(position)
    position = position + 1
    value = (value << 7) | (byte & 0x7F)
    if (byte & 0x80) == 0 then return value, position end
  end
  return nil, position, "invalid variable-length quantity"
end

local function section_name(text)
  local normalized = text:upper():gsub("[%z\r\n]+", ""):gsub("^%s+", ""):gsub("%s+$", "")
  for _, entry in ipairs(SECTION_PATTERNS) do
    local a, b = normalized:match(entry[1])
    if a then return string.format(entry[2], a, b) end
  end
end

local function parse_track(data, first, last, track_number, result)
  local position, tick, running_status = first, 0, nil
  while position <= last do
    local delta, next_position, delta_error = read_vlq(data, position, last)
    if not delta then return nil, delta_error end
    position, tick = next_position, tick + delta
    result.end_tick = math.max(result.end_tick, tick)
    if position > last then return nil, "truncated MIDI event" end

    local first_byte = data:byte(position)
    local status = first_byte
    if first_byte < 0x80 then
      if not running_status then return nil, "running status without previous MIDI status" end
      status = running_status
    else
      position = position + 1
    end

    if status == 0xFF then
      if position > last then return nil, "truncated meta event" end
      local meta_type = data:byte(position)
      position = position + 1
      local length, content_position, length_error = read_vlq(data, position, last)
      if not length then return nil, length_error end
      position = content_position
      if position + length - 1 > last then return nil, "truncated meta-event payload" end
      if meta_type == 0x01 or meta_type == 0x06 then
        local label = section_name(data:sub(position, position + length - 1))
        if label then result.markers[#result.markers + 1] = { name = label, tick = tick } end
      end
      position = position + length
    elseif status == 0xF0 or status == 0xF7 then
      local length, content_position, length_error = read_vlq(data, position, last)
      if not length then return nil, length_error end
      position = content_position + length
      if position - 1 > last then return nil, "truncated SysEx event" end
    elseif status >= 0x80 and status <= 0xEF then
      running_status = status
      local type = status & 0xF0
      local data_length = (type == 0xC0 or type == 0xD0) and 1 or 2
      local data1
      if first_byte < 0x80 then
        data1 = first_byte
      else
        if position > last then return nil, "truncated MIDI event data" end
        data1 = data:byte(position)
        position = position + 1
      end
      local data2 = 0
      if data_length == 2 then
        if position > last then return nil, "truncated MIDI event data" end
        data2 = data:byte(position)
        position = position + 1
      end
      result.events[#result.events + 1] = {
        tick = tick, status = status, data1 = data1, data2 = data2, track = track_number,
      }
    else
      return nil, string.format("unsupported system status 0x%02X", status)
    end
  end
  return true
end

function Parser.parse(path)
  local ok, parsed_or_error = pcall(function()
    local handle, open_error = io.open(path, "rb")
    if not handle then error(open_error) end
    local data = handle:read("*a")
    handle:close()
    local header = data:find("MThd", 1, true)
    if not header then error("no Standard MIDI header (MThd) found") end
    if #data < header + 13 then error("truncated Standard MIDI header") end
    local header_length = string.unpack(">I4", data, header + 4)
    if header_length < 6 then error("invalid Standard MIDI header length") end
    local format, track_count, ppq = string.unpack(">I2I2I2", data, header + 8)
    if (ppq & 0x8000) ~= 0 then error("SMPTE timing is not supported") end
    if format > 2 or track_count == 0 or ppq == 0 then error("invalid Standard MIDI header") end

    local result = { ppq = ppq, events = {}, markers = {}, end_tick = 0 }
    local position, track_number = header + 8 + header_length, 0
    while position <= #data - 7 do
      local chunk = data:sub(position, position + 3)
      local length = string.unpack(">I4", data, position + 4)
      local content_start, content_end = position + 8, position + 7 + length
      if content_end > #data then error("truncated MIDI chunk") end
      if chunk == "MTrk" then
        track_number = track_number + 1
        local success, track_error = parse_track(data, content_start, content_end, track_number, result)
        if not success then error(track_error) end
      end
      position = content_end + 1
    end
    if track_number == 0 then error("no MIDI tracks found") end
    table.sort(result.markers, function(a, b) return a.tick < b.tick end)
    local unique, seen = {}, {}
    for _, marker in ipairs(result.markers) do
      local key = marker.name .. ":" .. marker.tick
      if not seen[key] then unique[#unique + 1], seen[key] = marker, true end
    end
    result.markers = unique
    return result
  end)
  if not ok then return false, tostring(parsed_or_error):gsub("^.-:%d+: ", "") end
  return true, parsed_or_error
end

return Parser

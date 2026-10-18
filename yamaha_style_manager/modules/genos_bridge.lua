-- @noindex
local Bridge = {}
local section, key = "YamahaStyleManager", "GenosSuiteFolder"
local sep = package.config:sub(1, 1)
local main = "Yamaha_MX_Genos_Inspector.lua"

local function exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function find_suite(folder, depth)
  if exists(folder .. sep .. main) then return folder end
  if depth == 0 then return end
  local index = 0
  while true do
    local child = reaper.EnumerateSubdirectories(folder, index)
    if not child then return end
    local found = find_suite(folder .. sep .. child, depth - 1)
    if found then return found end
    index = index + 1
  end
end

function Bridge.load(script_path)
  Bridge.folder, Bridge.driver = nil, nil
  local configured = reaper.GetExtState(section, key)
  local sibling = script_path .. ".." .. sep .. ".." .. sep .. "yamaha-mx-genos-suite" ..
    sep .. "Scripts" .. sep .. "Yamaha_MX_Genos_Suite"
  local folder
  if configured ~= "" then
    folder = configured
  elseif exists(sibling .. sep .. main) then
    folder = sibling
  else
    folder = find_suite(reaper.GetResourcePath() .. sep .. "Scripts", 5)
  end
  if not folder or not exists(folder .. sep .. main) then
    return nil, "Install Yamaha MX Genos Suite or set its script folder below."
  end
  local loader, err = loadfile(folder .. sep .. "lib" .. sep .. "midi_yamaha_driver.lua")
  if not loader then return nil, err end
  local ok, driver, voices, arps = pcall(function()
    local loaded = loader()
    local sections, sections_error = loadfile(folder .. sep .. "lib" .. sep .. "style_sections.lua")
    assert(sections, sections_error or "Update the Genos Suite to enable style section editing")
    loaded.sections = sections()
    local voice_count, arp_count = loaded.init(folder .. sep .. "data" .. sep .. "Yamaha_MX49.reabank",
      folder .. sep .. "data" .. sep .. "Yamaha_MX88_Arpeggios.csv")
    require("voice_map").configure(loaded.programs)
    return loaded, voice_count, arp_count
  end)
  if not ok then return nil, "Cannot load Genos Suite: " .. tostring(driver) end
  if voices == 0 or arps == 0 then return nil, "Genos Suite voice/arpeggio data is missing in " .. folder end
  Bridge.folder, Bridge.driver = folder, driver
  return driver
end

function Bridge.open()
  if not Bridge.folder then return false, "Load the Genos Suite first." end
  local action = reaper.AddRemoveReaScript(true, 0, Bridge.folder .. sep .. main, true)
  if action == 0 then return false, "Cannot register the Genos Inspector action." end
  reaper.Main_OnCommand(action, 0)
  return true
end

return Bridge

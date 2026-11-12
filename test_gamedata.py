import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent / "pytools"))
from lupa import lua54

scripts = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/PBZBossRematch/Scripts"
lua = lua54.LuaRuntime()
lua.execute(f'package.path = "{scripts}/?.lua;" .. package.path')
lua.execute(r'''
local function name(s) return { ToString = function() return s end } end
local function obj(fields)
  fields.IsValid = function() return true end
  return fields
end

local codexRows = {
  { "BP_Monster_GreatBladeMan", { bIsBoss = true, Enemy_CH_Hans_Name = name("横刀：毕峰"), OwnMapID = name("DengDingShanDao"), DisplayOrder = 5 } },
  { "BP_Monster_MBoss",         { bIsBoss = true, Enemy_CH_Hans_Name = name("昆仑叛教者：荒行子"), OwnMapID = name("DengDingShanDao"), DisplayOrder = 8 } },
  { "BP_Monster_MBossVariants", { bIsBoss = true, Enemy_CH_Hans_Name = name("荒行子：撕裂锯轮"), OwnMapID = name("DengDingShanDao"), DisplayOrder = 9 } },
  { "BP_Monster_PowerMan",      { bIsBoss = true, Enemy_CH_Hans_Name = name("力者和锯者"), OwnMapID = name("DuanHunYa"), DisplayOrder = 1 } },
  { "BP_Monster_PowerMan_P2",   { bIsBoss = true, Enemy_CH_Hans_Name = name("力者：石破天惊之态"), OwnMapID = name("DuanHunYa"), DisplayOrder = 2 } },
  { "BP_Monster_XiaoXue",       { bIsBoss = true, Enemy_CH_Hans_Name = name("吞噬尸体的小雪"), OwnMapID = name("ZhengDaoDaYing"), DisplayOrder = 3 } },
  { "BP_Monster_MobMan",        { bIsBoss = false, Enemy_CH_Hans_Name = name("暴徒"), OwnMapID = name("DengDingShanDao"), DisplayOrder = 1 } },
}
local codexDT = obj({
  RowStruct = { GetFName = function() return name("CodexEnemyRow") end },
  ForEachRow = function(self, fn) for _, r in ipairs(codexRows) do fn(name(r[1]), r[2]) end end,
})

local discovered = { "BP_Monster_GreatBladeMan_C", "BP_Monster_MBoss_C", "BP_Monster_MBossVariants_C", "BP_Monster_PowerMan_C", "BP_Monster_PowerMan_P2_C" }
local codexSub = obj({
  GetWorld = function() return { GetFullName = function() return "World X" end } end,
  DiscoveredEnemyPaths = { ForEach = function(self, fn)
    for _, c in ipairs(discovered) do
      fn({ get = function() return { AssetPath = { PackageName = name("/Game/Path/" .. c), AssetName = name(c) } } end })
    end
  end },
})

function FindAllOf(cls)
  if cls == "DataTable" then return { codexDT } end
  if cls == "PBZCodexSubsystem" then return { codexSub } end
  if cls == "PlayerController" then return { obj({ IsLocalPlayerController = function() return true end, GetWorld = function() return { GetFullName = function() return "World X" end } end }) } end
  return {}
end
function FName(s) return s end
function print() end

local U = require("util")
local Data = require("gamedata")

local byMap, order = Data.availableBossesByMap()
for _, m in ipairs(order) do
  local names = {}
  for _, b in ipairs(byMap[m]) do table.insert(names, b.name .. "/" .. b.id) end
  _G.__out = (_G.__out or "") .. m .. ": " .. table.concat(names, ", ") .. "\n"
end

local tmp = U.DataDir .. "/_test_roundtrip.lua"
U.saveTable(tmp, { a = 1, ["Bell_DDSD_005"] = { x = -62016, s = "横刀：毕峰\"q\"", list = { 1, 2 } } })
local back = U.loadTable(tmp)
os.remove(tmp)
_G.__out = _G.__out .. "roundtrip: " .. tostring(back and back.Bell_DDSD_005.s) .. " x=" .. tostring(back and back.Bell_DDSD_005.x) .. " list2=" .. tostring(back and back.Bell_DDSD_005.list[2]) .. "\n"
_G.__out = _G.__out .. "dirs: mod=" .. U.ModDir .. " game=" .. tostring(U.GameRoot) .. "\n"
''')
print(lua.globals().__out)

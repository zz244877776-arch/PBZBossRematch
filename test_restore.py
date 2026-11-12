import sys, pathlib, shutil, time
sys.path.insert(0, str(pathlib.Path(__file__).parent / "pytools"))
from lupa import lua54

work = pathlib.Path(__file__).parent
fake = work / "test_saves"
if fake.exists():
    shutil.rmtree(fake)
for sub in ("1RealTime", "2Hourly", "3Daily"):
    (fake / sub).mkdir(parents=True)

now = time.time()
created_at = int(now) - 3600
def name(offset):
    return time.strftime("%Y%m%d-%H%M%S", time.localtime(created_at + offset)) + "-123.sav"

same_second = time.strftime("%Y%m%d-%H%M%S", time.localtime(created_at)) + "-404.sav"
files = {
    "1RealTime/" + name(-60): "keep (before challenge)",
    "1RealTime/" + same_second: "remove (teleport save in the same second as the snapshot)",
    "1RealTime/" + name(30): "remove (during challenge)",
    "1RealTime/" + name(400): "remove (during challenge)",
    "2Hourly/" + name(-7200): "keep (old hourly)",
    "2Hourly/" + name(120): "remove (hourly during challenge)",
    "3Daily/" + name(-90000): "keep (old daily)",
    "1RealTime/notes.txt": "keep (not a save)",
}
for rel in files:
    (fake / rel).write_text("x")
(fake / "PBZSaveGame.sav").write_text("challenge state")

scripts = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/PBZBossRematch/Scripts"
lua = lua54.LuaRuntime()
lua.execute(f'package.path = "{scripts}/?.lua;" .. package.path')
lua.execute("function FindAllOf() return {} end function FName(s) return s end function print() end")
lua.execute(f'''
local U = require("util")
local Save = require("savesnap")
Save.SaveDir = "{fake.as_posix()}"
U.writeFile(U.DataDir .. "/snapshot/PBZSaveGame.sav", "SNAPSHOT")
_G.ok = Save.restoreFiles({{
  createdAt = {created_at},
  slots = {{ {{ slot = "PBZSaveGame", size = 8 }} }},
  newestRolling = {{ ["1RealTime"] = "{name(-60)}", ["2Hourly"] = "{name(-7200)}", ["3Daily"] = "{name(-90000)}" }},
}})
''')
print("restoreFiles returned", lua.globals().ok)

fails = 0
for rel, expect in files.items():
    exists = (fake / rel).exists()
    want = expect.startswith("keep")
    ok = exists == want
    fails += not ok
    print("PASS" if ok else "FAIL", rel, "->", "exists" if exists else "removed", f"({expect})")
main = (fake / "PBZSaveGame.sav").read_text()
print("PASS" if main == "SNAPSHOT" else "FAIL", "main save restored:", main)
fails += main != "SNAPSHOT"

shutil.rmtree(fake)
pathlib.Path(scripts.replace("Scripts", "data/snapshot/PBZSaveGame.sav")).unlink()
sys.exit(1 if fails else 0)

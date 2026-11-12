import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent / "pytools"))
from lupa import lua54

lua = lua54.LuaRuntime()
check = lua.eval("function(src, name) local f, err = load(src, '@' .. name); return err end")

ok = True
for p in sys.argv[1:]:
    for f in sorted(pathlib.Path(p).rglob("*.lua")):
        err = check(f.read_text(encoding="utf-8"), f.name)
        if err:
            ok = False
            print("FAIL", err)
        else:
            print("ok  ", f)
sys.exit(0 if ok else 1)

"""Builds the distributable installer package into _modwork/dist."""
import pathlib, re, shutil, zipfile

WORK = pathlib.Path(__file__).resolve().parent
GAME = WORK.parent
UE4SS_ZIP = WORK / "downloads" / "phantombladezero_ue4ss_v3.0.1-1195-g1ceefac8.zip"
MOD_SRC = WORK / "ue4ss_pkg" / "ue4ss" / "Mods" / "PBZBossRematch" / "Scripts"
INSTALLER_SRC = WORK / "installer_src"
DOC = GAME / "宿敌再战Mod_使用说明.md"

PKG_NAME = "宿敌再战Mod安装包"
DIST = WORK / "dist"
OUT = DIST / PKG_NAME
PAYLOAD = OUT / "payload"

BAT = (
    "@echo off\r\n"
    "chcp 65001 >nul\r\n"
    "powershell -NoProfile -ExecutionPolicy Bypass -STA -File \"%~dp0installer\\installer.ps1\"\r\n"
    "if errorlevel 1 pause\r\n"
)


def set_ini(text, key, value):
    new, n = re.subn(rf"(?m)^{re.escape(key)}\s*=.*$", f"{key} = {value}", text)
    assert n == 1, key
    return new


def lint():
    import subprocess, sys
    result = subprocess.run([sys.executable, str(WORK / "lua_lint.py"), str(MOD_SRC)], capture_output=True, text=True)
    print(result.stdout.strip().splitlines()[-1] if result.stdout.strip() else result.stderr)
    if result.returncode != 0:
        print(result.stdout)
        raise SystemExit("lint failed, package not built")


def main():
    lint()
    OUT.mkdir(parents=True, exist_ok=True)
    for child in OUT.iterdir():
        shutil.rmtree(child) if child.is_dir() else child.unlink()
    PAYLOAD.mkdir(parents=True)

    runtime = PAYLOAD / "ue4ss_runtime"
    with zipfile.ZipFile(UE4SS_ZIP) as z:
        z.extractall(runtime)

    ini_path = runtime / "ue4ss" / "UE4SS-settings.ini"
    ini = ini_path.read_text(encoding="utf-8")
    for k, v in {"EnableHotReloadSystem": "0", "ConsoleEnabled": "0", "GuiConsoleEnabled": "1", "GuiConsoleVisible": "0"}.items():
        ini = set_ini(ini, k, v)
    ini_path.write_text(ini, encoding="utf-8", newline="")

    mods_path = runtime / "ue4ss" / "Mods" / "mods.txt"
    mods = mods_path.read_text(encoding="utf-8")
    if "PBZBossRematch" not in mods:
        idx = mods.index("; Built-in keybinds")
        mods = mods[:idx] + "PBZBossRematch : 1\n\n" + mods[idx:]
    mods_path.write_text(mods, encoding="utf-8", newline="")

    mod_out = PAYLOAD / "PBZBossRematch" / "Scripts"
    shutil.copytree(MOD_SRC, mod_out)
    (PAYLOAD / "PBZBossRematch" / "data" / "snapshot").mkdir(parents=True)
    cfg_path = mod_out / "config.lua"
    cfg = cfg_path.read_text(encoding="utf-8")
    cfg = re.sub(r'(?m)^(\s*GameRoot\s*=\s*)"[^"]*"', r'\1""', cfg)
    cfg = re.sub(r'(?m)^(\s*SteamId\s*=\s*)"[^"]*"', r'\1""', cfg)
    cfg_path.write_text(cfg, encoding="utf-8", newline="")

    doc = DOC.read_text(encoding="utf-8")
    doc = doc.split("\n---\n\n## 附录")[0].rstrip() + "\n"
    (PAYLOAD / DOC.name).write_text(doc, encoding="utf-8")
    (OUT / DOC.name).write_text(doc, encoding="utf-8")

    inst = OUT / "installer"
    inst.mkdir()
    for name in ("installer.ps1", "installer_core.ps1"):
        text = (INSTALLER_SRC / name).read_text(encoding="utf-8").replace("\r\n", "\n").replace("\n", "\r\n")
        (inst / name).write_text(text, encoding="utf-8-sig", newline="")

    (OUT / "安装宿敌再战Mod.bat").write_bytes(BAT.encode("ascii"))

    zip_path = DIST / f"{PKG_NAME}.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(OUT.rglob("*")):
            z.write(f, f.relative_to(DIST))

    files = [f for f in OUT.rglob("*") if f.is_file()]
    print(f"built {OUT} ({len(files)} files)")
    print(f"zip   {zip_path} ({zip_path.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()

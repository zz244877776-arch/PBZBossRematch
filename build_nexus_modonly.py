"""Build a Nexus-friendly zip with only the Lua mod (no UE4SS / no DLL)."""
import pathlib, re, shutil, zipfile

WORK = pathlib.Path(__file__).resolve().parent
MOD_SRC = WORK / "ue4ss_pkg" / "ue4ss" / "Mods" / "PBZBossRematch" / "Scripts"
DOC_CN = WORK / "docs" / "使用说明.md"
DOC_EN = WORK / "docs" / "Usage.en.md"
DIST = WORK / "dist"
OUT = DIST / "PBZBossRematch-Nexus-modonly"
ZIP = DIST / "PBZBossRematch-v0.1.22-Nexus-modonly.zip"

FORBIDDEN_SUFFIXES = (".dll", ".exe", ".bat", ".ps1")


def player_doc(src: pathlib.Path, marker: str) -> str:
    doc = src.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    player, sep, _ = doc.partition(marker)
    if not sep:
        raise SystemExit(f"missing marker in {src.name}")
    return player.rstrip() + "\n"


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    mod = OUT / "PBZBossRematch"
    scripts = mod / "Scripts"
    shutil.copytree(MOD_SRC, scripts)
    (mod / "data" / "snapshot").mkdir(parents=True)

    cfg_path = scripts / "config.lua"
    cfg = cfg_path.read_text(encoding="utf-8")
    cfg = re.sub(r'(?m)^(\s*GameRoot\s*=\s*)"[^"]*"', r'\1""', cfg)
    cfg = re.sub(r'(?m)^(\s*SteamId\s*=\s*)"[^"]*"', r'\1""', cfg)
    cfg_path.write_text(cfg, encoding="utf-8", newline="\n")

    (OUT / "宿敌再战Mod_使用说明.md").write_text(
        player_doc(DOC_CN, "\n---\n\n## 附录"), encoding="utf-8"
    )
    (OUT / "PBZBossRematch_Usage_EN.md").write_text(
        player_doc(DOC_EN, "\n---\n\n## Appendix:"), encoding="utf-8"
    )

    readme = """# Boss Rematch (宿敌再战) — Nexus package (no UE4SS / no DLL)

This zip contains ONLY the Lua mod. It does not include UE4SS, dwmapi.dll, or any native binaries.

## Requirements
1. Steam Phantom Blade Zero
2. UE4SS already installed for PBZ (KintaroModding / official PBZ UE4SS package)

## Install
1. Fully quit the game.
2. Copy the `PBZBossRematch` folder into:
   `<game>\\platform\\steam\\ue4ss\\Mods\\`
3. Open `platform\\steam\\ue4ss\\Mods\\mods.txt` and make sure it has:
   `PBZBossRematch : 1`
4. Start the game. Open any bell → 宿敌再战.

## Update
Replace the `PBZBossRematch` folder with the new one. Keep your existing `Scripts\\config.lua` if you customized keys.

## Uninstall
Delete `platform\\steam\\ue4ss\\Mods\\PBZBossRematch`, or set `PBZBossRematch : 0` in mods.txt.

## Full installer (with UE4SS)
GitHub Releases: https://github.com/zz244877776-arch/PBZBossRematch/releases
Source: https://github.com/zz244877776-arch/PBZBossRematch
"""
    (OUT / "INSTALL.txt").write_text(readme, encoding="utf-8", newline="\n")

    if ZIP.exists():
        ZIP.unlink()
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(OUT.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(OUT))

    names = zipfile.ZipFile(ZIP).namelist()
    bad = [n for n in names if n.lower().endswith(FORBIDDEN_SUFFIXES)]
    if bad:
        raise SystemExit(f"forbidden files in zip: {bad}")

    print(f"zip   {ZIP} ({ZIP.stat().st_size:,} bytes)")
    print(f"files {len(names)}")
    for n in names:
        print(" ", n)


if __name__ == "__main__":
    main()

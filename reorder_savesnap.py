import pathlib

p = pathlib.Path(r"E:\SteamLibrary\steamapps\common\PBZ\_modwork\ue4ss_pkg\ue4ss\Mods\PBZBossRematch\Scripts\savesnap.lua")
text = p.read_text(encoding="utf-8")

start = text.index("-- ===== Rolling auto-saves =====")
end = text.index("function M.restoreFiles(state)")
section = text[start:end]
text = text[:start] + text[end:]

anchor = text.index("-- Copies the current save files aside")
text = text[:anchor] + section + text[anchor:]
p.write_text(text, encoding="utf-8")
print("moved", section.count("\n"), "lines")

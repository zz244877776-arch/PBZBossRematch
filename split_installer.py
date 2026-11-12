import pathlib

src = pathlib.Path(r"E:\SteamLibrary\steamapps\common\PBZ\_modwork\installer_src")
text = (src / "installer.ps1").read_text(encoding="utf-8")
marker = "# ---------------- 界面 ----------------"
idx = text.index(marker)
core, gui = text[:idx], text[idx:]

core_header_old = core[: core.index("$PackageRoot")]
core = "# 宿敌再战 Mod 安装逻辑（被 installer.ps1 引用，也可单独加载做测试）\n\n" + core[len(core_header_old):]

gui_header = (
    "# 宿敌再战 Mod 一键安装工具\n"
    "# 由安装包根目录的“安装宿敌再战Mod.bat”启动。\n\n"
    "$ErrorActionPreference = 'Stop'\n"
    "Add-Type -AssemblyName System.Windows.Forms\n"
    "Add-Type -AssemblyName System.Drawing\n"
    "[System.Windows.Forms.Application]::EnableVisualStyles()\n\n"
    ". (Join-Path $PSScriptRoot 'installer_core.ps1')\n\n"
)

(src / "installer_core.ps1").write_text(core, encoding="utf-8")
(src / "installer.ps1").write_text(gui_header + gui, encoding="utf-8")
print("core lines", core.count("\n"), "gui lines", (gui_header + gui).count("\n"))

# 宿敌再战 Mod（影之刃零 / Phantom Blade Zero）

基于 UE4SS Lua 的本地 mod：在铃铛菜单里加入「宿敌再战」入口，可重新挑战已击败的 Boss。挑战是临时的，结束（胜利、失败或按 Home 退出）后自动还原存档并回到出发的铃铛，进度不变。

详细说明见 [docs/使用说明.md](docs/使用说明.md)。

## 目录

- `ue4ss_pkg/ue4ss/Mods/PBZBossRematch/Scripts/`：mod 源码
- `ue4ss_pkg/ue4ss/Mods/PBZBossProbe/`：开发期的数据探针 mod（默认不启用）
- `installer_src/`：一键安装工具（PowerShell + WinForms）
- `build_dist.py`：检查 Lua 后打包安装包到 `dist/`
- `test_*.py` / `test_installer.ps1`：测试
- `lua_lint.py`、`pytools_check_lua.py`：Lua 语法与未定义变量检查（依赖 `pytools/` 下的 lupa、luaparser）

## 构建

UE4SS 运行库不在仓库内。打包前需把 UE4SS（PBZ 适配版）解压到 `ue4ss_pkg/`，然后运行：

```
python build_dist.py
powershell -ExecutionPolicy Bypass -File test_installer.ps1
```

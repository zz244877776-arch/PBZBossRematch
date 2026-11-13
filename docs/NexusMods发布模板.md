# Nexus Mods 发布模板：宿敌再战 / Boss Rematch

按 Nexus 上传页面的顺序排列。`【待填】` 是需要你自己确认或补充的地方。
「Description」「Changelog」两段是 BBCode，直接整段粘进 Nexus 编辑器（切到 BBCode 模式）。

---

## 1. 基本信息（Mod details）

| 字段 | 填写内容 |
|---|---|
| Mod name | `Boss Rematch - 宿敌再战` |
| Version | `0.1.5` |
| Language | English / Chinese（模组内文字为简体中文） |
| Category | `Gameplay`（若没有，选 `Utilities` 或 `Miscellaneous`） |
| Author | `joeyzhuzhu` |
| Created by | `joeyzhuzhu` |
| Mod page | https://www.nexusmods.com/games/phantombladezero/mods/1132 |
| Tags | Gameplay, Bosses, Quality of Life, UE4SS, Lua |
| Contains adult content | No |
| Primary source | GitHub: https://github.com/zz244877776-arch/PBZBossRematch |

### Brief overview（Summary，限 350 字符，建议英文）

```
Re-fight any boss you have already defeated, straight from the bell menu. A new "宿敌再战" option lists beaten bosses by region; pick one and you are taken to its arena. Win, lose or quit, your save is restored and you return to the bell with progress unchanged. Multi-phase bosses, loading screen and pre-fight countdown included.
```

中文对照（可放进正文，不用填进 Summary）：

```
在铃铛菜单里直接重新挑战已击败的 Boss。新增「宿敌再战」选项，按地区列出已击败的 Boss，选中即可前往战场。无论胜负或中途退出，都会还原存档并回到出发的铃铛，进度不变。支持多阶段 Boss、加载黑屏和开战倒计时。
```

---

## 2. 正文（Description，BBCode）

```bbcode
[center][size=6][b]Boss Rematch - 宿敌再战[/b][/size]
[size=3]Re-fight defeated bosses from the bell menu, without touching your save.[/size]
[size=3]在铃铛菜单中重新挑战已击败的 Boss，不影响存档。[/size][/center]

[line]

[size=5][b]English[/b][/size]

[size=4][b]Features[/b][/size]
[list]
[*][b]Bell menu entry[/b] - a new "宿敌再战" option in every bell menu, listing the bosses you have defeated, grouped by region. Works with mouse, keyboard and gamepad.
[*][b]Temporary challenge[/b] - your save is snapshotted before the fight. Win, lose or quit, it is restored and you are sent back to the bell you started from. Progress, items and kills stay exactly as they were.
[*][b]Loading screen[/b] - the screen stays black while the mod travels, finds the boss and loads the arena, then fades in.
[*][b]Pre-fight countdown[/b] - the boss is frozen for a 3-second countdown so you can get ready.
[*][b]Multi-phase bosses[/b] - phase two follows phase one with a fade-out transition, and the fight only counts as won after the last phase.
[*][b]Crash protection[/b] - if the game closes mid-challenge, your save is restored automatically on the next launch.
[/list]

[size=4][b]Requirements[/b][/size]
[list]
[*]Phantom Blade Zero, Steam version
[*]UE4SS is [b]bundled[/b] in the installer, nothing else to download
[/list]

[size=4][b]Installation[/b][/size]
[list=1]
[*][b]Fully exit the game.[/b]
[*]Download and extract the zip anywhere.
[*]Double-click [b]安装宿敌再战Mod.bat[/b].
[*]Pick the game folder or [i]PBZ.exe[/i] (it is usually detected automatically), then click Install.
[*]Start the game and open any bell.
[/list]
Updating: run the installer again and click Install / Update. Your config.lua settings are kept.
Uninstalling: run the installer and click Uninstall. UE4SS is only removed if this installer put it there.

[size=4][b]Controls[/b][/size]
[list]
[*][b]Bell menu > 宿敌再战[/b] - pick a region, then a boss
[*][b]Home[/b] - quit the current challenge and return
[*][b]End[/b] - instantly kill the current boss (testing aid, can be turned off)
[/list]

[size=4][b]Configuration[/b][/size]
Edit [i]platform\steam\ue4ss\Mods\PBZBossRematch\Scripts\config.lua[/i]:
[list]
[*]ExitKey / KillKey / EnableKillKey - hotkeys
[*]VictoryReturnDelayMs / DefeatReturnDelayMs - delay before returning
[*]LoadingCurtain - black loading screen on/off
[*]CountdownSeconds - countdown length, 0 to disable
[*]OnlyDiscovered - only list bosses unlocked in the codex
[/list]

[size=4][b]Known limitations[/b][/size]
[list]
[*]A few bosses that only exist inside story cutscenes cannot be re-fought yet; they are marked "（暂不支持）" in the list.
[*]The first visit to a region may take a little longer while the mod learns where the boss is. Later visits go straight to it.
[*]Only the Steam version is supported (save location).
[*]The in-game text of the mod is Simplified Chinese.
[/list]

[size=4][b]Save safety[/b][/size]
The mod copies your save before each challenge and blocks saving while you fight. Autosaves the game writes during the challenge are removed when it ends. Even so, this is a test release: [b]please back up[/b] [i]ProjectPBZ\Saved\SaveGames[/i] before your first use.

[size=4][b]Bug reports[/b][/size]
Please attach [i]platform\steam\ue4ss\Mods\PBZBossRematch\data\rematch.log[/i] and say which boss you picked.

[line]

[size=5][b]中文[/b][/size]

[size=4][b]功能[/b][/size]
[list]
[*][b]铃铛菜单入口[/b]：每个铃铛菜单新增「宿敌再战」，按地区列出已击败的 Boss，支持鼠标、键盘和手柄。
[*][b]临时挑战[/b]：开战前快照存档，胜利、失败或中途退出都会还原存档，并回到出发的铃铛，进度、物品、击杀记录都不变。
[*][b]加载黑屏[/b]：传送、定位 Boss、加载战场期间保持黑屏，准备好再淡入画面。
[*][b]开战倒计时[/b]：画面出现后 Boss 定格，倒数 3 秒再开打。
[*][b]多阶段 Boss[/b]：一阶段结束后淡入黑屏转入二阶段，打完最后一个阶段才算胜利。
[*][b]防崩溃[/b]：挑战中途游戏关闭或崩溃，下次启动会自动还原存档。
[/list]

[size=4][b]前置要求[/b][/size]
[list]
[*]影之刃零 Steam 版
[*]安装包已[b]自带 UE4SS[/b]，无需另外下载
[/list]

[size=4][b]安装[/b][/size]
[list=1]
[*][b]完全退出游戏。[/b]
[*]下载并解压压缩包。
[*]双击 [b]安装宿敌再战Mod.bat[/b]。
[*]选择游戏目录或 [i]PBZ.exe[/i]（通常会自动识别），点「安装」。
[*]进入游戏，打开任意铃铛。
[/list]
更新：重新运行安装工具，点「安装 / 更新」，原有的 config.lua 设置会保留。
卸载：运行安装工具点「卸载」。UE4SS 只有在当初由本工具安装时才会被移除。

[size=4][b]按键[/b][/size]
[list]
[*][b]铃铛菜单 → 宿敌再战[/b]：选择地区，再选择 Boss
[*][b]Home[/b]：退出当前挑战并返回
[*][b]End[/b]：一键击杀当前 Boss（测试用，可在配置中关闭）
[/list]

[size=4][b]配置[/b][/size]
编辑 [i]platform\steam\ue4ss\Mods\PBZBossRematch\Scripts\config.lua[/i]：
[list]
[*]ExitKey / KillKey / EnableKillKey：快捷键
[*]VictoryReturnDelayMs / DefeatReturnDelayMs：胜负后多久返回
[*]LoadingCurtain：是否启用加载黑屏
[*]CountdownSeconds：倒计时秒数，0 为关闭
[*]OnlyDiscovered：只显示图鉴中已解锁的 Boss
[/list]

[size=4][b]已知限制[/b][/size]
[list]
[*]少数只在剧情动画里出现的 Boss 暂时无法再战，列表中标为「（暂不支持）」。
[*]第一次前往某个地区时会稍慢，mod 需要先记录 Boss 的位置，之后会直接到达。
[*]目前只支持 Steam 版（存档路径）。
[/list]

[size=4][b]存档安全[/b][/size]
每次挑战前都会备份存档，战斗期间禁止存档，结束后清理挑战期间游戏写入的自动存档。但这仍是测试版，首次使用前[b]请手动备份[/b] [i]ProjectPBZ\Saved\SaveGames[/i]。

[size=4][b]反馈问题[/b][/size]
请附上 [i]platform\steam\ue4ss\Mods\PBZBossRematch\data\rematch.log[/i]，并说明挑战的是哪个 Boss。

[line]

[size=4][b]Credits / 致谢[/b][/size]
[list]
[*]RE-UE4SS team - [url=https://github.com/UE4SS-RE/RE-UE4SS]UE4SS[/url] (MIT License)
[*]【待填：你使用的 PBZ 适配版 UE4SS 的作者及链接】
[/list]
[size=2]Made by joeyzhuzhu. Source code / 源码：[url=https://github.com/zz244877776-arch/PBZBossRematch]GitHub[/url][/size]
```

---

## 3. 文件（Files）

| 字段 | 填写内容 |
|---|---|
| File name | `Boss Rematch - 宿敌再战` |
| File version | `0.1.5` |
| Category | Main files |
| Upload | `PBZBossRematch-v0.1.5.zip`（GitHub Release 里的同一个包） |
| Set as main version | 是 |
| Remove from Mod Manager download button | 勾选（需要运行自带安装工具，Vortex 无法直接装） |

### File description

```
Installer with bundled UE4SS. Extract, run 安装宿敌再战Mod.bat, pick the game folder. Fully exit the game before installing or updating.
内含 UE4SS 与一键安装工具。解压后运行 安装宿敌再战Mod.bat，选择游戏目录即可。安装或更新前请完全退出游戏。
```

---

## 4. 权限（Permissions）

| 项目 | 建议 |
|---|---|
| Upload permission | 需要先联系作者 |
| Modification permission | 需要先联系作者（或注明“源码在 GitHub，可自由修改”） |
| Conversion permission | 需要先联系作者 |
| Asset use permission | 可以使用，需署名 |
| Asset use permission in mods/files that are being sold | 不可以 |
| Asset use permission in mods/files that earn donation points | 【待填】 |

其他说明（Author notes）：

```
UE4SS is bundled under its MIT license. Please do not re-upload this mod elsewhere; link to this page or the GitHub repository instead.
```

---

## 5. 更新日志（Changelog）

在 Nexus 「Changelogs」里按版本逐条添加，每条一行：

```
0.1.5
- Black loading screen while travelling to the boss; the arena fades in only once everything is loaded.
- 3-second countdown with the boss frozen before the fight starts.
- Fade-out transition between phases of multi-phase bosses; the previous phase's body is hidden.
- Gamepad navigation and button sounds for the new bell menu entries.
- New config options: LoadingCurtain, CountdownSeconds.

0.1.4
- Jump straight to known boss arenas; less map scanning and less stutter.
- Pull in minions, formations and sequences that belong to the same encounter.
- Longer delay after victory so the death performance can finish.

0.1.3
- Boss music advances when a multi-phase boss enters its next stage.
- Fixed phase two counting as an instant win.

0.1.2
- Fixed a freeze when the chosen boss is on the current map.

0.1.1
- Fixed challenges failing to start when there is only one Steam save folder.

0.1.0
- First release.
```

---

## 6. 图片和视频（Media）

建议准备：

1. **封面图（主图）：** 铃铛菜单里打开「宿敌再战」，显示地图列表。
2. Boss 列表（某个地区展开后）。
3. 倒计时画面（「准备迎战 舞狮尊主 3」）。
4. 二阶段 Boss 战斗截图。
5. 「挑战成功，即将返回」提示。
6. 安装工具窗口（可用 `_modwork/installer_preview.png`）。
7. 【可选】30～60 秒演示视频：铃铛 → 选 Boss → 黑屏加载 → 倒计时 → 战斗 → 胜利返回。

---

## 7. 置顶帖（Sticky post，可选）

```
Before reporting a bug, please:
1. Make sure you are on the latest version.
2. Attach rematch.log from platform\steam\ue4ss\Mods\PBZBossRematch\data\
3. Say which boss you picked and what happened.

反馈问题前请：
1. 确认已更新到最新版本；
2. 附上 platform\steam\ue4ss\Mods\PBZBossRematch\data\ 下的 rematch.log；
3. 说明挑战的是哪个 Boss、出现了什么情况。
```

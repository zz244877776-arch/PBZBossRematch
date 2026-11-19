# Phantom Blade Zero — Boss Rematch Mod User Guide

Re-challenge bosses you have already defeated from the bell menu. Challenges are temporary: when they end, your save is restored and you return to the bell you started from. Progress is not changed.

> Status: Feature-complete and playable. Please follow the first-run checks in section 7 if this is your first install.
>
> Supported build: Steam *Phantom Blade Zero* (tested around game version CL-302256).

---

## 1. One-click install

1. **Fully quit the game.**
2. Extract the package and double-click **`安装宿敌再战Mod.bat`**.
3. The tool looks for the game in your Steam libraries. If it is not found, click:
   - **选择游戏程序…** (Choose game exe…): pick any `PBZ.exe` under the game folder, or
   - **选择游戏文件夹…** (Choose game folder…): pick the install folder (usually `steamapps\common\PBZ`).
4. Confirm the status bar shows a green game path, then click **安装 / 更新** (Install / Update).
5. When you see install complete, start the game.

What the installer does:

- Backs up saves to `_rematch_backup\` under the game folder (can be unchecked).
- Installs the UE4SS runtime (required). If UE4SS is already present, it is left alone by default; if you opt in to update it, your existing `mods.txt` and `UE4SS-settings.ini` are kept.
- Installs this mod, detects your save folder, and writes config.
- Enables the mod in `mods.txt`.

**Updating**: run **安装 / 更新** again with a newer package. Your `config.lua` and learned boss locations are preserved.

**If the `.bat` does nothing**: right-click `installer\installer.ps1` → Run with PowerShell.

---

## 2. Files after install

Everything lives under the game folder. No original game files are patched.

| Path | Purpose |
|---|---|
| `platform\steam\dwmapi.dll` | UE4SS loader |
| `platform\steam\ue4ss\` | UE4SS runtime and settings |
| `platform\steam\ue4ss\Mods\PBZBossRematch\` | This mod |
| `platform\steam\ue4ss\Mods\PBZBossRematch\Scripts\config.lua` | Config (keys, delays, etc.) |
| `platform\steam\ue4ss\Mods\PBZBossRematch\data\` | Runtime data: logs, save snapshots, boss location cache |
| `_rematch_backup\` | Save backup created by the installer |

UE4SS is the Phantom Blade Zero package from KintaroModding (v3.0.1-1195). MIT license: `platform\steam\ue4ss\LICENSE`.

---

## 3. How to use

1. Launch the game and load a save as usual.
2. Interact with any bell and open the bell menu.
3. At the bottom of the menu you should see **「宿敌再战」** (Boss Rematch). Select it.
4. Pick a map (the number in parentheses is how many rematchable bosses are listed there), then pick a boss.
5. After the menu closes you are teleported near the boss (~7 m, facing it). When the fight is ready, an on-screen toast confirms the challenge has started.
6. When the challenge ends you are returned automatically:
   - **Victory**: return after a short delay (default ~8 s).
   - **Defeat (player death)**: return after ~7 s.
   - **Quit early**: press `Home` to return immediately.
7. You should see “已返回，进度未改变” (Returned; progress unchanged) and end up back at the bell you started from.

### Multi-phase bosses

- Later phases are not listed separately; defeating phase 1 automatically continues into the next phase.
- When phase 1 ends, a toast warns that the next phase is loading (some fights, such as 七星阵大师兄, take a while to stream in).
- On rematch kills, the mod also tries to show the game’s BossDead「斩」UI even if the story sequence that normally triggers it was skipped.

### Which bosses appear in the list

- Only bosses unlocked in the codex (when `OnlyDiscovered` is on).
- Follow-up phases of multi-phase bosses and tutorial fights are hidden; they are entered from phase 1.
- Bosses in the list (except those marked unsupported) are generally challengeable. On a first rematch, if the arena isn’t cached yet, the mod travels to a map bell then quietly streams regions to locate the boss (toast: “Locating…”). The first visit can take a few extra seconds; later rematches are faster.
- Other bosses discovered during that scan are cached too. While you explore normally, the mod also records nearby bosses about every 30 seconds.
- Names marked **（暂不支持）** / **(unsupported)** mean no spawner was found on that map (often sequence- or special-space-only bosses). Choosing them will not teleport you into a fight.

---

## 4. Hotkeys

| Key | Action | When |
|---|---|---|
| `Home` | Quit challenge, restore save, return to start bell | During a challenge only |
| `End` | Instantly kill the current rematch boss (for testing) | During a challenge only |
| `Ctrl + O` | Show / hide the UE4SS debug console | Anytime |

Avoid conflicts: `Ctrl + F11` toggles fullscreen; `F10` / `~` open the game console.

Keys can be changed in `config.lua` (section 5).

---

## 5. Config (`config.lua`)

Edit `platform\steam\ue4ss\Mods\PBZBossRematch\Scripts\config.lua` in a text editor, then restart the game.

| Option | Default | Meaning |
|---|---|---|
| `ExitKey` | `"HOME"` | Quit-challenge key |
| `EnableKillKey` | `false` | Instant-kill hotkey; set `true` to enable |
| `KillKey` | `"DEL"` | Instant-kill key |
| `VictoryReturnDelayMs` | `8000` | Ms to wait after victory before returning |
| `DefeatReturnDelayMs` | `7000` | Ms to wait after defeat before returning |
| `LoadingCurtain` | `true` | Black screen while traveling / loading the boss; set `false` to disable |
| `CountdownSeconds` | `8` | Frozen-boss countdown after reveal; `0` skips countdown |
| `OnlyDiscovered` | `true` | Only list codex-unlocked bosses |
| `HiddenBossPatterns` | see file | Codex rows hidden from the list |
| `EntryLabel` | `"宿敌再战"` | Bell-menu button label |
| `SteamId` | set by installer | Save folder name under `ProjectPBZ\Saved\SaveGames\Steam\` |
| `GameRoot` | set by installer | Game install path |

Key names are listed in `platform\steam\ue4ss\Mods\Keybinds\Scripts\main.lua` (e.g. `HOME`, `END`, `INS`, `DEL`, `PAGE_UP`, `PAGE_DOWN`, `F5`).

---

## 6. Save safety

Rematches do not keep story progress. Protection is three layers:

1. **Snapshot before the fight**: after you pick a boss, `PBZSaveGame.sav` is copied to `data\snapshot\`.
2. **Save veto during the fight**: once at the arena, the game’s save-veto path blocks new writes.
3. **Restore + reload after**: the snapshot is written back and the slot is reloaded so memory matches the pre-challenge save.

### Crash recovery

Starting a challenge writes `data\challenge_state.lua`. If the game crashes or is force-closed mid-challenge, the next launch detects that file and restores the snapshot to the main save. **After a crash, boot to the main menu first, then load your save.**

### Steam Cloud

If Steam reports a cloud conflict on launch, choose **local files**.

### Manual restore (if needed)

Save path: `ProjectPBZ\Saved\SaveGames\Steam\<your numeric folder>\`

| Location | Contents |
|---|---|
| `_rematch_backup\saves_<timestamp>\` | Full save backup from each installer run |
| `platform\steam\ue4ss\Mods\PBZBossRematch\data\snapshot\` | Snapshot from the latest challenge start |
| `1RealTime\`, `2Hourly\`, `3Daily\` under the save folder | Game rolling backups (same format as the main save) |

**Fully quit the game**, copy the chosen `.sav` over `PBZSaveGame.sav` in the save folder, then launch again.

---

## 7. First-run checks

1. Start the game, press `Ctrl + O`, and confirm the UE4SS console shows `PBZBossRematch loaded` plus two `hook ... ok` lines.
2. Load a save and stay ~30 seconds in a map that has bosses so locations can be learned.
3. Open a bell menu and confirm **「宿敌再战」** is present.
4. Pick a boss on the current map.
5. Confirm: menu closes, travel/spawn happens, toast shows the challenge starting.
6. Press `End` to kill, then wait for auto-return.
7. Confirm progress is unchanged after return.

If anything fails, note which step and check:
`platform\steam\ue4ss\Mods\PBZBossRematch\data\rematch.log`

---

## 8. Known limitations

- Bosses spawned from spawners **do not play their intro cutscenes**.
- Instant-kill has **no death performance**; the boss is marked dead immediately.
- Rematches grant **no drops or rewards**; everything is rolled back afterward.
- A few bosses that only exist via sequences or special spaces may show as unsupported.
- After a game update, UE4SS and/or this mod may need an update.

---

## 9. Uninstall

**Recommended**: run `安装宿敌再战Mod.bat` and click **卸载** (Uninstall).

- If an unfinished challenge is detected, finish one game launch first so the mod can restore the save.
- If this tool installed UE4SS, it asks whether to remove it too. Choose No if you still use other UE4SS mods.

**Manual uninstall** (fully quit the game first):

- Mod only: delete `platform\steam\ue4ss\Mods\PBZBossRematch\`, or set `PBZBossRematch : 0` in `mods.txt`.
- Full UE4SS stack: delete `platform\steam\dwmapi.dll` and `platform\steam\ue4ss\`.

---

## Appendix: developer-only backups

These exist only on the machine used to develop the mod; they are **not** in the player installer package:

| Path | Contents |
|---|---|
| `_modwork\save_backup\...` | Local save backups from development |
| `_modwork\dist\` | Built installer packages |
| `platform\steam\ue4ss\Mods\PBZBossProbe\` | Dev probe mod (disabled in `mods.txt`; keybinds overlap — do not enable with Rematch) |

# Valheim Server Restart

A small Windows console utility (Delphi) that **gracefully restarts a [Valheim](https://store.steampowered.com/app/892970/Valheim/) dedicated server** on a schedule. It sends a real `Ctrl+C` to the running server so it saves the world and shuts down cleanly, waits for it to exit, zips the world saves and player-list files, optionally updates the server via SteamCMD, and relaunches it — all driven by a simple `.ini` file.

Designed to be run from **Windows Task Scheduler** for unattended daily restarts. A second mode, [`/autoarchive`](#auto-backup-archiving-autoarchive), archives Valheim's rolling world auto-backups on a frequent schedule (e.g. every 30 minutes) without touching the running server.

Sibling project to [SCUM Server Restart](https://github.com/Dawn-Patrol-Gaming/scum_server_admin) — same architecture, adapted for Valheim.

---

## Why this exists

The Valheim dedicated server has **no RCON** and no remote shutdown command. It autosaves only periodically (every 30 minutes by default, tunable with `-saveinterval`); killing the process (window **X**, `Stop-Process -Force`, taskkill) throws away everything since the last autosave and risks a corrupt/partial world write. The only safe way to stop it is a genuine **`Ctrl+C` console control signal** — the official `start_headless_server.bat` literally prints *"Starting server PRESS CTRL-C to exit"*, and on Ctrl+C the server runs its quit path (`OnApplicationQuit` → `ZNet` shutdown) which **saves the world to disk** before exiting.

Doing that reliably from a separate process is fiddly (console attachment, integrity levels, sessions), so this tool packages the working approach into one scheduled executable.

---

## Valheim 1.0 save format

Valheim **1.0** changed the on-disk save layout, and this tool backs up the new format:

- **A world is now a folder.** `worlds_local` no longer holds a flat `<World>.db` + `<World>.fwl` pair. Each world is a **folder** named exactly after the world (`<World>\`), containing chunked pieces — `_main.N.fwl2` (seed/metadata), `_main.N.db2` (world data), `_main.N.chunks` (index), many `XX_XX__X_X.chunk` terrain files, and a `_main.N.ok` save-complete marker (`N` is a generation counter). Only the pieces that change are rewritten each save, which is why 1.0 saves are faster.
- **Rolling auto-backups are folders too.** Valheim keeps ~4 rolling backups plus one on update, each as its own folder `<World>_backup_auto-<date>-<time>\` inside `worlds_local`.
- **Back up / restore the *whole* folder.** A partial copy makes a broken world. This tool always zips a complete top-level entry, and each zip preserves the folder name inside it, so restoring recreates `<World>\…` verbatim.
- **Old worlds convert in place.** The first time a 1.0 server loads a pre-1.0 world it converts it to the folder format (after writing a backup) and leaves the old `<World>.db`/`.fwl`/`.old` files beside the new folder. This tool still captures those loose legacy files (into a `<prefix>loose_<timestamp>.zip`) and still handles pre-1.0 servers that remain on the flat format, so it works across the transition.
- **The list files are unchanged.** `adminlist.txt`, `bannedlist.txt` and `permittedlist.txt` still sit at the Valheim root and are backed up as before.

> The graceful **Ctrl+C** shutdown is unaffected by this change — it's a console signal, independent of the save format — so the server still saves cleanly on stop.

---

## Features

- **Graceful shutdown** via `AttachConsole` + `GenerateConsoleCtrlEvent(CTRL_C_EVENT)` — the same thing as pressing Ctrl+C in the server window.
- **Waits for a clean exit** (configurable timeout) before continuing — world save time scales with world size.
- **Timestamped world backup** — zips each world in `worlds_local` to **its own** archive while the server is stopped (files flushed and unlocked). Since **Valheim 1.0** a world is a *folder* (`<World>\` holding `_main.N.db2`/`.fwl2`/`.chunks`/`*.chunk`/`.ok`), not a flat `.db`/`.fwl` pair, so every top-level world folder becomes `<prefix><World>_<timestamp><suffix>.zip`. Legacy flat/`.old` leftovers still work (see [Valheim 1.0 save format](#valheim-10-save-format)).
- **Player-list backup** — zips `adminlist.txt`, `bannedlist.txt` and `permittedlist.txt` to a separate archive.
- **Auto-backup archiving mode** (`/autoarchive`) — a second, independent schedulable mode that sweeps Valheim's rolling `<World>_backup_auto-*` backups out of `worlds_local`, zipping **each one to its own archive** and removing the original, **without touching the running server**. Since 1.0 those backups are *folders* too; the mode handles them (and legacy backup files) and keeps `worlds_local` from filling up with 100 MB+ copies while preserving every one in a timestamped archive.
- **Optional SteamCMD update** of the dedicated server (app `896660`) before relaunch, with SteamCMD's output captured line-by-line into the log.
- **Automatic restart** with your configured launch arguments, including the `SteamAppId=892970` environment variable the official launch script sets.
- **All settings in an `.ini` file** — no recompilation to change paths, arguments, or timings.
- **Date-stamped logging** — every action is written to both the console and `logs\<AppName>\<AppName>_yyyy-mm-dd.log`. The per-app subfolder means several of these restart utilities (SCUM, Valheim, …) can run out of one shared folder without their logs mixing.
- **Self-documenting first run** — if no `.ini` exists, it writes one with default values and exits so you can edit it.

---

## Requirements

- Windows (tested on Windows Server 2019 / Windows 11).
- A Valheim dedicated server installed locally (SteamCMD app `896660`).
- **Delphi** (the project targets Delphi 12+/13; uses only the standard RTL — no third-party packages) to build from source, **or** just grab a prebuilt `ValheimServerRestart.exe`.

---

## Building

1. Open `ValheimServerRestart\ValheimServerRestart.dpr` in Delphi (this generates the `.dproj` automatically).
2. In **Project → Options → Application → Manifest**, set **Execution Level = Require Administrator** — see [Elevation](#elevation-required) below.
3. Build the **Release / Win32** (or Win64) configuration.

> **Debugging:** because the manifest requests elevation, the IDE must also be elevated to launch it under the debugger. Either run the Delphi IDE **as administrator**, or temporarily set the Debug config's execution level to *As invoker* (note: without elevation it cannot attach to an elevated server's console).

> **Prefer Free Pascal / Lazarus?** The code is Delphi-first, but it's plain Win32 + RTL and can be ported with a couple of small changes — see [docs/Building-with-Lazarus.md](docs/Building-with-Lazarus.md).

---

## Configuration

On first run, the tool looks for an `.ini` next to the executable (same base name, e.g. `ValheimServerRestart.ini`). If it's missing, a default one is created and the program exits so you can edit it.

> The config is **self-healing**: when you upgrade to a build that adds new options, any keys missing from your existing `.ini` are appended with their defaults on the next run — so new sections show up automatically. Review them before relying on them.

> Path values may contain environment references like `%USERPROFILE%` — they are expanded when the config is read. (Valheim's default save location is per-user, so this keeps the config portable.)

```ini
[Server]
; Executable name exactly as it appears in Task Manager
ExeName=valheim_server.exe
; Full path to the server executable
ExePath=C:\SteamCMD\Valheim_Server\valheim_server.exe
; Working directory for the server process (blank = folder of ExePath)
WorkDir=C:\SteamCMD\Valheim_Server\
; Command-line arguments passed on restart. CHANGE name/world/password!
; Password must be >= 5 characters and must not appear in the server name.
Args=-nographics -batchmode -name "My server" -port 2456 -world "Dedicated" -password "secret" -crossplay
; The official start_headless_server.bat sets SteamAppId=892970 (the GAME's
; app id) before launching; this replicates that. Blank = don't set it.
SteamAppIdEnv=892970

[Restart]
; Seconds to wait for the server to shut down cleanly before giving up
ShutdownTimeoutSec=120
; Seconds to wait after shutdown before relaunching
RestartDelaySec=10

[Backup]
; Folder containing the world saves to back up. Each world FOLDER directly under
; it (Valheim 1.0 stores a world as <World>\...) is zipped to its own archive;
; the *_backup_auto-* backup folders are skipped here (see [AutoArchive]).
; Blank = skip backup. NOTE: this is per-user — it must be the profile of the
; account the SERVER runs under. If you launch with -savedir, point this there.
WorldsDir=%USERPROFILE%\AppData\LocalLow\IronGate\Valheim\worlds_local
; Folder where the timestamped backup zips are written.
; Keep this OUTSIDE the server install folder so a Steam update can't wipe it.
BackupDir=C:\Valheim_Backups
; Worlds backup file name = <prefix><World>_<timestamp><suffix>.zip (one per world
; folder). Any loose legacy files go to <prefix>loose_<timestamp><suffix>.zip.
; Both prefix and suffix may be blank.
WorldsBackupPrefix=worlds_
WorldsBackupSuffix=
; Semicolon-separated name masks excluded from the regular backups. Default *.old
; drops Valheim's one-generation fallback pair (redundant inside a timestamped
; archive). Blank = exclude nothing.
ExcludeMasks=*.old
; Folder whose top-level *.txt files (adminlist/bannedlist/permittedlist) are
; zipped to a separate archive. Blank = skip.
ConfigDir=%USERPROFILE%\AppData\LocalLow\IronGate\Valheim
; Config backup file name = <prefix><timestamp><suffix>.zip. Both may be blank.
ConfigBackupPrefix=lists_
ConfigBackupSuffix=

[Cleanup]
; Optional folder whose files are deleted after a successful worlds backup.
; Valheim has NO per-session log folder (unlike e.g. SCUM), so this is blank
; (disabled) by default. Only set it if you point -logFile at a dedicated
; folder you want cleared on each restart.
ServerLogDir=

[AutoArchive]
; Settings for the "/autoarchive" command-line mode (see below). Source folder
; is WorldsDir above; each matching backup is zipped here and then deleted.
; Keep this OUTSIDE the server install folder too.
ArchiveDir=C:\Valheim_Backups\auto
; Which top-level entries count as auto-backups. The default matches Valheim
; 1.0's <World>_backup_auto-<date>-<time> backup FOLDERS (and any legacy
; <World>_backup_auto-*.db/.fwl files) and never matches the live <World> folder
; or the .old pair.
FileMask=*_backup_auto-*
; Archive file name = <prefix><BackupName>_<timestamp><suffix>.zip (one per
; backup). Both prefix and suffix may be blank.
ArchivePrefix=auto_
ArchiveSuffix=
; 1 = delete each original after ITS OWN zip succeeds; 0 = archive only.
DeleteAfterArchive=1
; 1 = also run the auto-archive sweep during the restart cycle (before the worlds
; backup) so the two archives stay separate; 0 = only run it via /autoarchive.
RunOnRestart=1

[Update]
; Set to 1 to run a SteamCMD update (after backup, before restart). 0 = skip.
EnableUpdate=0
; Full path to steamcmd.exe
SteamCmdPath=C:\SteamCMD\steamcmd.exe
; Steam app id of the Valheim DEDICATED SERVER (not the game, which is 892970)
SteamAppId=896660
; Server install root passed to SteamCMD's +force_install_dir
InstallDir=C:\SteamCMD\Valheim_Server
```

> [!WARNING]
> **Put `BackupDir` on a different drive or path than the server install.** A SteamCMD / Steam app update can delete and recreate the entire install folder — if your backups live under it (e.g. `...\Valheim_Server\Backups`), they get wiped right when you'd need them. Use somewhere like `C:\Valheim_Backups` instead. (Valheim's world saves already live *outside* the install folder, under `AppData\LocalLow\IronGate\Valheim`, which is one reason they survive updates — keep your zips out of the install folder too.)

### Settings reference

| Section | Key | Meaning |
|---|---|---|
| `Server` | `ExeName` | Process image name used to find the running server. **Required.** |
| `Server` | `ExePath` | Full path used to relaunch the server. **Required.** |
| `Server` | `WorkDir` | Working directory for the new process. Defaults to `ExePath`'s folder if blank. |
| `Server` | `Args` | Launch arguments on restart. See [Launch arguments](#launch-arguments) below. |
| `Server` | `SteamAppIdEnv` | Value for the `SteamAppId` environment variable on relaunch (official script uses `892970`). Blank = don't set it. |
| `Restart` | `ShutdownTimeoutSec` | How long to wait for a clean exit before reporting failure. |
| `Restart` | `RestartDelaySec` | Pause between shutdown and relaunch. |
| `Backup` | `WorldsDir` | Folder holding the worlds. Each top-level **world folder** (`<World>\`, the 1.0 format) is zipped to its own archive; the `*_backup_auto-*` folders are skipped (handled by `/autoarchive`). Blank disables backup. |
| `Backup` | `BackupDir` | Destination folder for the zips (created if missing). **Point this *outside* the server install folder.** |
| `Backup` | `WorldsBackupPrefix` / `WorldsBackupSuffix` | Optional text before/after the worlds backup file name `<prefix><World>_<timestamp><suffix>.zip` (one per world; loose legacy files go to `<prefix>loose_<timestamp><suffix>.zip`). Either may be blank. |
| `Backup` | `ExcludeMasks` | Semicolon-separated name masks excluded from the worlds/config backups (matched against the top-level entry name). Default `*.old`. Blank excludes nothing. |
| `Backup` | `ConfigDir` | Folder whose **top-level** `*.txt` files are zipped to a separate backup (the admin/banned/permitted lists). Blank disables. |
| `Backup` | `ConfigBackupPrefix` / `ConfigBackupSuffix` | Optional text before/after the timestamp in the config backup file name. Either may be blank. |
| `Cleanup` | `ServerLogDir` | Folder whose files are deleted after a successful backup. **Blank (default) disables** — Valheim has no per-session log folder. |
| `AutoArchive` | `ArchiveDir` | Destination folder for `/autoarchive` zips (created if missing). Keep it outside the server install folder. |
| `AutoArchive` | `FileMask` | Which top-level entries in `WorldsDir` count as auto-backups — matches the 1.0 `<World>_backup_auto-<date>-<time>` **folders** (and legacy backup files). Default `*_backup_auto-*`. |
| `AutoArchive` | `ArchivePrefix` / `ArchiveSuffix` | Optional text before/after the archive file name `<prefix><BackupName>_<timestamp><suffix>.zip` (one per backup). Either may be blank. |
| `AutoArchive` | `DeleteAfterArchive` | `1` (default) = delete each original after **its own** zip succeeds; `0` = archive only. |
| `AutoArchive` | `RunOnRestart` | `1` (default) = also run the sweep during the restart cycle (before the worlds backup); `0` = only via `/autoarchive`. |
| `Update` | `EnableUpdate` | `1` = run a SteamCMD update before restart; `0` = skip. |
| `Update` | `SteamCmdPath` | Full path to `steamcmd.exe`. |
| `Update` | `SteamAppId` | Steam app id of the Valheim dedicated server (`896660`; configurable in case it ever changes). |
| `Update` | `InstallDir` | Server install root, passed to SteamCMD's `+force_install_dir`. |

### Launch arguments

The default `Args` mirrors the official `start_headless_server.bat`. Commonly used options:

| Argument | Meaning |
|---|---|
| `-nographics -batchmode` | Headless mode. **Keep both.** |
| `-name "..."` | Server name in the browser. Must not contain the password. |
| `-port 2456` | Base port (uses 2456–2457 UDP; forward them unless using `-crossplay`). |
| `-world "..."` | World name; created on first run, loaded afterwards. |
| `-password "..."` | Minimum 5 characters. |
| `-crossplay` | Use the PlayFab backend (console/Game Pass players can join; no port-forwarding needed). Omit for Steam-only. |
| `-savedir <path>` | Override the save location. If used, update `WorldsDir`/`ConfigDir` to match. |
| `-saveinterval <sec>` | Autosave interval (default 1800 = 30 min). |
| `-backups` / `-backupshort` / `-backuplong` | Tune Valheim's own rolling auto-backups (kept inside `worlds_local` as `<World>_backup_auto-*` folders; [`/autoarchive`](#auto-backup-archiving-autoarchive) sweeps them into their own archives on a schedule). |
| `-public 0` | Don't list in the community server browser. |
| `-logFile <path>` | Write the server log to a file. |

---

## What it does, step by step

1. **Load config** and verify `ExePath` and `WorkDir` exist (errors out if not).
2. **Find** the running `valheim_server.exe`.
3. **Shut down gracefully** — attach to the server's console and send `Ctrl+C`, then wait up to `ShutdownTimeoutSec` for it to exit. Valheim saves the world as part of this shutdown, so the files on disk are current when it exits.
4. **Sweep the auto-backups** (if `RunOnRestart=1`) — archive the `*_backup_auto-*` backup folders to `ArchiveDir` and remove them, exactly as [`/autoarchive`](#auto-backup-archiving-autoarchive) does, so they stay in their own archive and out of the worlds backup. Non-fatal.
5. **Back up the worlds** — zip each world folder under `WorldsDir` to its own `BackupDir\worlds_<World>_<timestamp>.zip` (any loose legacy files go to `worlds_loose_<timestamp>.zip`). The `*_backup_auto-*` backup folders are excluded here (step 4 handles them).
6. **Purge logs** — only if `ServerLogDir` is set (off by default; Valheim has no per-session log folder) and **only if the worlds backup succeeded**.
7. **Back up the lists** — zip the top-level `*.txt` files under `ConfigDir` (adminlist/bannedlist/permittedlist) to `BackupDir\lists_<timestamp>.zip`.
8. **Update** — if `EnableUpdate=1`, run SteamCMD (`+force_install_dir … +login anonymous +app_update 896660 validate +quit`) and wait for it to finish. SteamCMD's output is captured line-by-line into the log file.
9. **Wait** `RestartDelaySec`, then **relaunch** the server with `Args` (setting `SteamAppId=892970` in its environment, as the official script does).

A failed/skipped backup is logged but **does not** stop the restart. A failed log purge is logged per-file and is never fatal. A failed/disabled SteamCMD update is logged and the restart still proceeds.

---

## Auto-backup archiving (`/autoarchive`)

Valheim's built-in rolling backups (`-backupshort`/`-backuplong`) drop full copies of the world into `worlds_local` as `<World>_backup_auto-<date>-<time>` **folders** (since 1.0 — 100 MB+ each on a mature world, `.db`/`.fwl` file pairs pre-1.0), accumulating until the folder balloons. This mode sweeps them into timestamped zips on their own schedule:

```
ValheimServerRestart.exe /autoarchive
```

1. **Load config** (same `.ini`).
2. **Find** all top-level entries in `WorldsDir` matching `FileMask` (default `*_backup_auto-*`) — the 1.0 backup **folders** and any legacy backup files.
3. **Zip each one to its own** `ArchiveDir\auto_<BackupName>_<timestamp>.zip`, preserving the folder inside so a restore recreates it verbatim.
4. **Delete each archived original** (if `DeleteAfterArchive=1`) — only after its own zip has been written. The live `<World>` folder and the `.old` pair are never touched, and an auto-backup created *after* the entry list was taken survives to the next run.

The server is **not stopped, restarted, or signalled** — this mode never attaches to its console and is safe to run while the server is up: the auto-backups are finished copies the server is no longer writing. If one entry is locked (the server is writing a fresh auto-backup at that exact moment), only *that* entry's zip fails and it is left in place for the next run; the others still archive.

Every run logs its find result explicitly — `Auto-archive: found N backup entr… matching *_backup_auto-* in ... (X folder(s), Y loose file(s))` — so there is never a question whether the sweep saw anything. No matching entries logs *"Auto-archive: nothing to do"* and exits `0`. Output goes to the same console + `logs\ValheimServerRestart\ValheimServerRestart_yyyy-mm-dd.log`.

Schedule it independently of the restart task — see the next section.

---

## Scheduling with Task Scheduler

> [!IMPORTANT]
> ### Elevation required
> The server typically runs **elevated**, and you can only attach to an elevated process's console if you are **also elevated**. The exe ships with a `requireAdministrator` manifest; in Task Scheduler also tick **Run with highest privileges**.
>
> ### Must run in the same session
> `AttachConsole` only works within the **same Windows session** as the server. The scheduled task must use **"Run only when user is logged on"** (`InteractiveToken`) as the **same account** the server runs under. The "Run whether user is logged on or not" option (`Password`) runs in session 0 and fails with *Access is denied*. Keep that account logged in (disconnect RDP rather than logging off).

> The `/autoarchive` task never attaches to the server's console, so the same-session rule doesn't strictly apply to it — but the exe's `requireAdministrator` manifest means it still needs **Run with highest privileges** to start without a UAC prompt.

### Option A — import the samples (fastest)

Two ready-to-edit task definitions are included, both with the required options (`InteractiveToken` + `HighestAvailable`) set correctly:

- [`Valheim Server Restart.sample.xml`](Valheim%20Server%20Restart.sample.xml) — the nightly restart cycle (daily at 04:00).
- [`Valheim Archive Autobackups.sample.xml`](Valheim%20Archive%20Autobackups.sample.xml) — runs `/autoarchive` every 30 minutes (edit `<Repetition><Interval>PT30M</Interval>` to change the cadence; the `:15` start offset keeps it clear of a restart task on the hour).

1. Open the file in a text editor and change the two placeholders:
   - `<UserId>COMPUTERNAME\YourUser</UserId>` → the account the server runs under (or its SID).
   - `<Command>C:\SteamCMD\Valheim_Server\ValheimServerRestart.exe</Command>` → the path to your built exe.
   - Optionally adjust `<StartBoundary>` for your preferred restart time.
2. In **Task Scheduler → Action → Import Task…**, select the file.
3. When prompted, confirm the account and enter credentials if asked.

> The sample is saved as **UTF-16 with a BOM** — the only encoding Task Scheduler's importer accepts. If you recreate it in another editor, preserve that encoding or the import fails with *"one root element"*.

### Option B — create it by hand in the GUI

- **General:** Run only when user is logged on · Run with highest privileges.
- **Triggers:** Daily, at your chosen restart time.
- **Actions:** Start a program → `C:\SteamCMD\Valheim_Server\ValheimServerRestart.exe`.
- **Settings:** *Stop the task if it runs longer than 1 hour* (safety net).

For the auto-backup archive task, create a second task the same way but add `/autoarchive` in the action's **Add arguments** box, and set the trigger to *Daily* + *Repeat task every 30 minutes for a duration of 1 day*.

### Starting the server at boot

If the server isn't running, this tool starts it — so you can also use it to bring the server up after a reboot. The key is that it must run **in the same interactive session** the server should live in (so later restarts can attach to its console). Suggested approach: set the box to **auto-log-on** the server account, and trigger the start **at log on** of that account (a logon-triggered task, or a login batch that calls `schtasks /run /tn "Valheim Server Restart"`) — not an "At startup" trigger, which runs in the isolated session 0.

---

## Logging

Every run appends to a date-stamped file alongside the executable, inside a per-app subfolder of `logs\`:

```
logs\ValheimServerRestart\ValheimServerRestart_2026-07-06.log
```

Each line is timestamped. The same output is echoed to the console when run interactively.

The subfolder is named after the executable (rename the exe and the `.ini` and log folder follow), so multiple restart utilities can share a single install folder — each keeps its own `logs\<AppName>\` tree.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `2` | Server did not shut down cleanly within the timeout (restart aborted). |
| `3` | Configuration problem (missing/invalid `.ini`, or a default was just written). |
| `4` | Server executable or working directory not found. |
| `5` | `/autoarchive`: the archive failed (nothing was deleted). |

Task Scheduler can be configured to alert on non-zero exit codes.

---

## Troubleshooting

| Symptom (in the log) | Cause / Fix |
|---|---|
| `AttachConsole(...) failed: Access is denied` | Not elevated, **or** running in a different session than the server. Use highest privileges + "Run only when user is logged on" as the server's account. |
| `session=0` (server `session=1`) | Task is running non-interactively (`Password`). Switch to `InteractiveToken`. |
| `Server did not exit within Ns` | Increase `ShutdownTimeoutSec`; large worlds take longer to save. |
| `Backup skipped: ... not set` / `folder not found` | Check `WorldsDir` / `BackupDir` paths in the `.ini`. Remember `WorldsDir` is under the **server account's** profile, and `-savedir` moves it entirely. |
| A leftover `cmd` window asks *"Terminate batch job (Y/N)?"* | The server was originally started via `start_headless_server.bat`; the Ctrl+C also reaches the `cmd.exe` running the batch. Harmless — the server itself has exited and saved. It disappears once this tool relaunches the server directly. Answer `Y` to close the stale window. |
| Relaunched server won't start / instantly exits | Make sure `SteamAppIdEnv=892970` is set (the official launch script requires it) and that `Args` has a valid `-password` (≥ 5 chars, not contained in the server name). |

---

## Notes

- The graceful-shutdown mechanism is pure Win32 and needs no mods or wrappers. It is the programmatic equivalent of the officially documented "press Ctrl+C in the server console" — the same mechanism used by established community managers (e.g. ValheimServerWarden) — but as with any inferred behavior, a future Valheim build could change it. If restarts start losing world state after a game update, re-verify the Ctrl+C behavior.
- Since **Valheim 1.0** a world (and each rolling auto-backup) is a *folder*, not a flat `.db`/`.fwl` pair — see [Valheim 1.0 save format](#valheim-10-save-format). This tool zips each world folder to its own archive and sweeps the `<World>_backup_auto-*` backup folders into their own timestamped archives, giving you point-in-time copies *of* those rolling backups.
- Valheim keeps a one-generation `.old` fallback pair beside a converted world; it is excluded from the worlds backup by default (`[Backup] ExcludeMasks=*.old`) since it is redundant inside a timestamped archive.

---

## License

MIT — see [LICENSE](LICENSE).

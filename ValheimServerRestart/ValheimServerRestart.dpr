{
NOTE: in the manifest it's designated to run with elevated privileges, this is
because the app can't attach to another console without it in most cases. In order
to debug either drop the requirement (therefore may not be able to attach to a
console) or run the IDE as admin/elevated
}
program ValheimServerRestart;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Winapi.Windows, Winapi.TlHelp32, System.SysUtils, System.DateUtils, System.IOUtils,
  System.IniFiles, System.SyncObjs, System.Classes, System.Zip, System.Masks, System.StrUtils;

const
  ATTACH_PARENT_PROCESS = DWORD(-1);

var
  LogFileName: string; // date-stamped log file, set in InitLogging
  LogCriticalSection: TCriticalSection;

  {
  Reattach our process to its original (parent / cmd) console after we've been
  attached to the server's console. Falls back to a fresh console only if there
  is no parent console (e.g. launched non-interactively by Task Scheduler).
  }
procedure RestoreOwnConsole;
begin
  if not AttachConsole(ATTACH_PARENT_PROCESS) then
    AllocConsole;
  // After FreeConsole/AttachConsole the console's std handles change, but the
  // RTL's Input/Output/ErrOutput text files still cache the original (now
  // invalid) handles — the next Writeln would raise I/O error 6. Rebind them.
  TTextRec(Input).Handle := GetStdHandle(STD_INPUT_HANDLE);
  TTextRec(Output).Handle := GetStdHandle(STD_OUTPUT_HANDLE);
  TTextRec(ErrOutput).Handle := GetStdHandle(STD_ERROR_HANDLE);
end;

{
---------------------------------------------------------------------------
Configuration — loaded at runtime from ValheimServerRestart.ini (next to the exe)
file name of the ini is determined by executable name, default "ValheimServerRestart"
---------------------------------------------------------------------------
}
var
  SERVER_EXE_NAME: string; // Executable name as shown in Task Manager
  SERVER_EXE_PATH: string; // Full path to the server executable
  SERVER_WORK_DIR: string; // Working directory for the server process
  SERVER_ARGS: string; // Command-line arguments on restart ('' if none)
  SERVER_APPID_ENV: string; // Value for the SteamAppId env var on relaunch ('' = don't set)
  SHUTDOWN_TIMEOUT: Integer; // Seconds to wait for clean shutdown
  RESTART_DELAY: Integer; // Seconds to wait between stop and start
  WORLDS_DIR: string; // Folder containing the world saves to back up ('' = skip backup)
  BACKUP_DIR: string; // Folder where the zipped backup is written
  WORLDS_PREFIX: string; // Prefix on the worlds backup file name (may be blank)
  WORLDS_SUFFIX: string; // Suffix on the worlds backup file name, before .zip (may be blank)
  CONFIG_DIR: string; // Folder of server list/config .txt files to back up ('' = skip)
  CONFIG_PREFIX: string; // Prefix on the config backup file name (may be blank)
  CONFIG_SUFFIX: string; // Suffix on the config backup file name, before .zip (may be blank)
  EXCLUDE_MASKS: string; // Semicolon-separated name masks excluded from the regular backups (e.g. *.old;*.tmp); '' = exclude nothing
  SERVER_LOG_DIR: string; // Optional log folder to purge after a successful backup ('' = skip; Valheim has none by default)
  AUTO_ARCHIVE_DIR: string; // Destination folder for /autoarchive zips ('' = mode disabled)
  AUTO_FILE_MASK: string; // Mask matching Valheim's rolling auto-backups (must NOT match the main .db/.fwl or .old files)
  AUTO_PREFIX: string; // Prefix on the auto-backup archive file name (may be blank)
  AUTO_SUFFIX: string; // Suffix on the auto-backup archive file name, before .zip (may be blank)
  AUTO_DELETE: Boolean; // Whether /autoarchive deletes the originals after a successful zip
  AUTO_RUN_ON_RESTART: Boolean; // Whether the restart cycle runs the auto-archive sweep before the worlds backup
  ENABLE_UPDATE: Boolean; // Whether to run a SteamCMD update before restart
  STEAMCMD_PATH: string; // Full path to steamcmd.exe
  STEAM_APP_ID: string; // Steam app id for the Valheim dedicated server (configurable)
  STEAM_INSTALL_DIR: string; // +force_install_dir target (server root)

function ConfigPath: string;
begin
  // Same folder as the exe, regardless of the current working directory.
  Result := TPath.ChangeExtension(ParamStr(0), '.ini');
end;

{
Expands %VAR% environment references in a path value (e.g. %USERPROFILE%).
Valheim's default save location lives under the profile of the account running
the server, so path settings support this. Unmatched %refs% are left as-is.
}
function ExpandEnv(const Value: string): string;
var
  Needed: DWORD;
begin
  Result := Value;
  if Pos('%', Value) = 0 then
    Exit;
  Needed := ExpandEnvironmentStrings(PChar(Value), nil, 0);
  if Needed <= 1 then
    Exit;
  SetLength(Result, Needed - 1); // Needed includes the terminating #0
  if ExpandEnvironmentStrings(PChar(Value), PChar(Result), Needed) = 0 then
    Result := Value;
end;

{
Reads a key, but if it does not yet exist in the file, writes the supplied
default back first. This makes the config self-healing: when an existing user
upgrades to a build with new options, those options are appended to their .ini
with sensible defaults rather than silently using them in-memory only.
}
function EnsureString(Ini: TIniFile; const Section, Key, Default: string): string;
begin
  if not Ini.ValueExists(Section, Key) then
    Ini.WriteString(Section, Key, Default);
  Result := Ini.ReadString(Section, Key, Default);
end;

function EnsureInteger(Ini: TIniFile; const Section, Key: string; Default: Integer): Integer;
begin
  if not Ini.ValueExists(Section, Key) then
    Ini.WriteInteger(Section, Key, Default);
  Result := Ini.ReadInteger(Section, Key, Default);
end;

{
Loads configuration, creating the file if missing and filling in any missing
keys with defaults (see EnsureString/EnsureInteger). Returns False if the file
was just created (so the caller stops and lets the user edit it) or if a
required value is missing.
}
function LoadConfig: Boolean;
var
  Ini: TIniFile;
  Path: string;
  FreshFile: Boolean;
begin
  Result := False;
  Path := ConfigPath;
  FreshFile := not TFile.Exists(Path);

  Ini := TIniFile.Create(Path);
  try
    SERVER_EXE_NAME := EnsureString(Ini, 'Server', 'ExeName', 'valheim_server.exe');
    SERVER_EXE_PATH := ExpandEnv(EnsureString(Ini, 'Server', 'ExePath', 'C:\SteamCMD\Valheim_Server\valheim_server.exe'));
    SERVER_WORK_DIR := ExpandEnv(EnsureString(Ini, 'Server', 'WorkDir', 'C:\SteamCMD\Valheim_Server\'));
    SERVER_ARGS := EnsureString(Ini, 'Server', 'Args',
      '-nographics -batchmode -name "My server" -port 2456 -world "Dedicated" -password "secret" -crossplay');
    // The official start_headless_server.bat does "set SteamAppId=892970" (the
    // GAME's app id, not the dedicated server's) before launching. Replicated
    // on relaunch so the server starts the same way. Blank = don't set it.
    SERVER_APPID_ENV := EnsureString(Ini, 'Server', 'SteamAppIdEnv', '892970');
    SHUTDOWN_TIMEOUT := EnsureInteger(Ini, 'Restart', 'ShutdownTimeoutSec', 120);
    RESTART_DELAY := EnsureInteger(Ini, 'Restart', 'RestartDelaySec', 10);
    WORLDS_DIR := ExpandEnv(EnsureString(Ini, 'Backup', 'WorldsDir', '%USERPROFILE%\AppData\LocalLow\IronGate\Valheim\worlds_local'));
    BACKUP_DIR := ExpandEnv(EnsureString(Ini, 'Backup', 'BackupDir', 'C:\Valheim_Backups'));
    WORLDS_PREFIX := EnsureString(Ini, 'Backup', 'WorldsBackupPrefix', 'worlds_');
    WORLDS_SUFFIX := EnsureString(Ini, 'Backup', 'WorldsBackupSuffix', '');
    CONFIG_DIR := ExpandEnv(EnsureString(Ini, 'Backup', 'ConfigDir', '%USERPROFILE%\AppData\LocalLow\IronGate\Valheim'));
    CONFIG_PREFIX := EnsureString(Ini, 'Backup', 'ConfigBackupPrefix', 'lists_');
    CONFIG_SUFFIX := EnsureString(Ini, 'Backup', 'ConfigBackupSuffix', '');
    // *.old = Valheim's own one-generation fallback pair (Dedicated.db.old /
    // .fwl.old) - redundant inside timestamped archives, and half the zip size.
    EXCLUDE_MASKS := EnsureString(Ini, 'Backup', 'ExcludeMasks', '*.old');
    SERVER_LOG_DIR := ExpandEnv(EnsureString(Ini, 'Cleanup', 'ServerLogDir', ''));
    AUTO_ARCHIVE_DIR := ExpandEnv(EnsureString(Ini, 'AutoArchive', 'ArchiveDir', 'C:\Valheim_Backups\auto'));
    AUTO_FILE_MASK := EnsureString(Ini, 'AutoArchive', 'FileMask', '*_backup_auto-*');
    AUTO_PREFIX := EnsureString(Ini, 'AutoArchive', 'ArchivePrefix', 'auto_');
    AUTO_SUFFIX := EnsureString(Ini, 'AutoArchive', 'ArchiveSuffix', '');
    AUTO_DELETE := EnsureInteger(Ini, 'AutoArchive', 'DeleteAfterArchive', 1) <> 0;
    AUTO_RUN_ON_RESTART := EnsureInteger(Ini, 'AutoArchive', 'RunOnRestart', 1) <> 0;
    ENABLE_UPDATE := EnsureInteger(Ini, 'Update', 'EnableUpdate', 0) <> 0;
    STEAMCMD_PATH := ExpandEnv(EnsureString(Ini, 'Update', 'SteamCmdPath', 'C:\SteamCMD\steamcmd.exe'));
    STEAM_APP_ID := EnsureString(Ini, 'Update', 'SteamAppId', '896660');
    STEAM_INSTALL_DIR := ExpandEnv(EnsureString(Ini, 'Update', 'InstallDir', 'C:\SteamCMD\Valheim_Server'));
  finally
    Ini.Free;
  end;

  if FreshFile then
  begin
    Writeln('A default configuration file was created:');
    Writeln('  ' + Path);
    Writeln('Edit it to match your server, then run this program again.');
    Writeln('At minimum set -name, -world and -password in [Server] Args.');
    Exit;
  end;

  if (SERVER_EXE_NAME = '') or (SERVER_EXE_PATH = '') then
  begin
    Writeln('ERROR: ExeName and ExePath must be set in ' + Path);
    Exit;
  end;

  // Default the working directory to the exe's folder if not specified.
  if SERVER_WORK_DIR = '' then
    SERVER_WORK_DIR := ExtractFilePath(SERVER_EXE_PATH);

  Result := True;
end;
// ---------------------------------------------------------------------------

function FindProcessByName(const ExeName: string): DWORD;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := 0;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if SameText(string(Entry.szExeFile), ExeName) then
        begin
          Result := Entry.th32ProcessID;
          Break;
        end; //if SameText(string(Entry.szExeFile), ExeName) then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

function GetParentPID(PID: DWORD): DWORD;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := 0;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = PID then
        begin
          Result := Entry.th32ParentProcessID;
          Break;
        end; //if Entry.th32ProcessID = PID then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

function SessionOf(PID: DWORD): DWORD;
begin
  if not ProcessIdToSessionId(PID, Result) then
    Result := DWORD(-1);
end;

const
  // Redeclared locally so the code compiles regardless of Delphi version.
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;

// Not declared in every Delphi version's Winapi.Windows, so bind it directly.
function GetConsoleProcessList(lpdwProcessList: PDWORD; dwProcessCount: DWORD): DWORD; stdcall;
  external kernel32 name 'GetConsoleProcessList';

{
Executable name of a process, via the same Toolhelp snapshot the other process
helpers use. Returns '?' if the PID no longer exists.
}
function ExeNameOfPID(PID: DWORD): string;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := '?';
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = PID then
        begin
          Result := string(Entry.szExeFile);
          Break;
        end; //if Entry.th32ProcessID = PID then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

{
Lists every process attached to the console we are CURRENTLY attached to, as
'name(PID)' pairs. These are exactly the processes a GenerateConsoleCtrlEvent
broadcast to group 0 will reach, so TrySignalViaConsole records this before
sending Ctrl+C: any unexpected entry in the logged list (a cmd.exe mid-batch,
BEC, ...) names an innocent bystander that took our signal. Never raises.
}
function DescribeConsoleProcesses: string;
var
  PIDs: array[0..63] of DWORD;
  Count: DWORD;
  i: Integer;
begin
  Count := GetConsoleProcessList(@PIDs[0], Length(PIDs));
  if Count = 0 then
    Exit('(GetConsoleProcessList failed: ' + SysErrorMessage(GetLastError) + ')');
  if Count > DWORD(Length(PIDs)) then
    Count := DWORD(Length(PIDs)); // more than 64 attached: report the first 64
  Result := '';
  for i := 0 to Integer(Count) - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + ExeNameOfPID(PIDs[i]) + '(' + PIDs[i].ToString + ')';
  end; //for i := 0 to Integer(Count) - 1 do
end;

{
Guards the parent-PID retry in ShutdownServerGracefully against PID reuse:
th32ParentProcessID is only a number - if the original launcher has exited,
the same PID may since have been recycled by a completely unrelated process
(e.g. the cmd.exe running another game's restart batch). Attaching to THAT
process's console and broadcasting Ctrl+C would signal every innocent process
on it. So the parent is only trusted if it (a) still exists, (b) lives in the
same session as the server, and (c) was created BEFORE the server - a recycled
PID is always younger than the child it supposedly spawned. Returns True when
the parent looks genuine; otherwise False with Reason for the caller to log.
}
function ParentLooksGenuine(ParentPID, ChildPID: DWORD; out Reason: string): Boolean;
var
  hParent, hChild: THandle;
  ParentCreate, ChildCreate, ftExit, ftKernel, ftUser: TFileTime;
begin
  Result := False;
  Reason := '';

  hParent := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ParentPID);
  if hParent = 0 then
  begin
    Reason := 'parent PID ' + ParentPID.ToString + ' cannot be opened (probably exited): ' + SysErrorMessage(GetLastError);
    Exit;
  end; //if hParent = 0 then
  try
    hChild := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ChildPID);
    if hChild = 0 then
    begin
      Reason := 'server PID ' + ChildPID.ToString + ' cannot be opened: ' + SysErrorMessage(GetLastError);
      Exit;
    end; //if hChild = 0 then
    try
      if SessionOf(ParentPID) <> SessionOf(ChildPID) then
      begin
        Reason := 'parent PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) + ') is in session ' +
          SessionOf(ParentPID).ToString + ' but the server is in session ' + SessionOf(ChildPID).ToString +
          ' - not the real launcher';
        Exit;
      end; //if SessionOf(ParentPID) <> SessionOf(ChildPID) then

      if not GetProcessTimes(hParent, ParentCreate, ftExit, ftKernel, ftUser) or
         not GetProcessTimes(hChild, ChildCreate, ftExit, ftKernel, ftUser) then
      begin
        Reason := 'GetProcessTimes failed: ' + SysErrorMessage(GetLastError);
        Exit;
      end; //if not GetProcessTimes(...) then

      if CompareFileTime(ParentCreate, ChildCreate) > 0 then
      begin
        Reason := 'parent PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) +
          ') was created AFTER the server - the PID was recycled by an unrelated process';
        Exit;
      end; //if CompareFileTime(ParentCreate, ChildCreate) > 0 then

      Result := True;
    finally
      CloseHandle(hChild);
    end;
  finally
    CloseHandle(hParent);
  end;
end;

{
Appends a timestamped line to TheFile, creating it (and any missing parent
folders) as needed. Thread-safe and never raises — logging must not become a
new failure point.
}
procedure LogIt(const TheMsg, TheFile: string);
var
  fs: TFileStream;
  Buf: TBytes;
  TheDir, TheMessage: string;
begin
  try
    LogCriticalSection.Enter;
    try
      fs := nil;
      try
        TheDir := ExtractFilePath(TheFile);
        if (TheDir <> '') and not DirectoryExists(TheDir) then
          ForceDirectories(TheDir);
        try
          fs := TFileStream.Create(TheFile, fmOpenReadWrite or fmShareDenyNone);
        except
          fs := TFileStream.Create(TheFile, fmCreate);
        end;
        fs.Seek(0, soFromEnd);
        TheMessage := FormatDateTime('yyyy-mm-dd hh:nn:ssAM/PM', Now) + ' - ' + TheMsg + sLineBreak;
        Buf := TEncoding.Default.GetBytes(TheMessage);
        fs.Write(Buf[0], Length(Buf));
      finally
        fs.Free;
      end;
    finally
      LogCriticalSection.Leave;
    end;
  except
    // swallow any logging error so it never breaks the actual work.
  end;
end;

{
Sets up the date-stamped log file (logs\<AppName>\<AppName>_yyyy-mm-dd.log next
to the exe) and creates the critical section LogIt requires. Each utility gets
its own subfolder under logs\ so several of these restart tools can run from
one shared folder without their logs mixing.
}
procedure InitLogging;
var
  AppName: string;
begin
  if not Assigned(LogCriticalSection) then
    LogCriticalSection := TCriticalSection.Create;
  AppName := TPath.GetFileNameWithoutExtension(ParamStr(0));
  LogFileName := TPath.Combine(TPath.Combine(TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs'), AppName),
    AppName + '_' + FormatDateTime('yyyy-mm-dd', Now) + '.log');
end;

{ Writes to both the console and the date-stamped log file. }
procedure Log(const Msg: string);
begin
  Writeln(Format('[%s] %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), Msg]));
  LogIt(Msg, LogFileName); // LogIt prepends its own timestamp
end;
{
Sends a real Ctrl+C (CTRL_C_EVENT) to the Valheim server console and waits for
the process to exit. valheim_server.exe is a Unity headless build that runs as
a console app: on Ctrl+C it runs its quit path (OnApplicationQuit -> ZNet
shutdown), which SAVES THE WORLD to disk before exiting. The official
start_headless_server.bat even prints "PRESS CTRL-C to exit". Window messages
(WM_CLOSE etc.) do NOT trigger this — only a genuine console control signal
does. A hard kill loses everything since the last autosave.

Verified sequence:
  1. Open a handle to the target so we can wait on it afterwards.
  2. Detach our own console, attach to the server's console.
  3. Disable Ctrl handling for OURSELVES (the event broadcasts to every
     process on the console group, including this one — without this we'd
     kill ourselves before we could wait/restart).
  4. GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) — 0 = whole console group.
  5. Wait for the target to exit (while still attached). Save time scales
     with world size / player count, so poll up to the timeout in the ini.
     Increase the timeout if necessary in the ini file.
  6. Detach, re-enable our Ctrl handling, restore our own console.

NOTE: while attached to the server's console, Writeln goes to THAT console,
not ours — so we buffer status and log it only after we've restored our own.
Attaches to AttachPID's console, sends Ctrl+C to the whole group, then waits
for WaitPID (the actual server) to exit. AttachPID may be the server itself
or its console-owning parent (e.g. the cmd.exe running
start_headless_server.bat). Returns True if the server exited in time.
StatusMsg / Attached report what happened (logged by the caller after the
console is restored — we must not Log() while attached to another console).
}
function TrySignalViaConsole(AttachPID, WaitPID: DWORD; TimeoutSec: Integer; out Attached: Boolean; out StatusMsg: string): Boolean;
var
  hProc: THandle;
  WaitResult, AttachErr: DWORD;
  SignalSent: Boolean;
  ConsoleProcs: string;
begin
  Result := False;
  Attached := False;

  hProc := OpenProcess(SYNCHRONIZE, False, WaitPID);
  if hProc = 0 then
  begin
    StatusMsg := 'ERROR: Cannot open server process (PID ' + WaitPID.ToString + '): ' + SysErrorMessage(GetLastError);
    Exit;
  end; //if hProc = 0 then

  try
    FreeConsole;
    if not AttachConsole(AttachPID) then
    begin
      AttachErr := GetLastError;
      RestoreOwnConsole;
      StatusMsg := 'AttachConsole(PID ' + AttachPID.ToString + ') failed: ' + SysErrorMessage(AttachErr);
      Exit;
    end; //if not AttachConsole(AttachPID) then
    Attached := True;

    // Do NOT Log() past this point — output would go to the attached console.
    // Record who shares this console BEFORE signalling: the CTRL_C_EVENT
    // broadcast below reaches every one of these processes, so this list
    // (appended to StatusMsg and logged by the caller) names any innocent
    // bystander that took the signal (a cmd.exe mid-batch, BEC, ...).
    ConsoleProcs := DescribeConsoleProcesses;

    SetConsoleCtrlHandler(nil, True); // don't let the signal kill us
    SignalSent := GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);

    if SignalSent then
    begin
      WaitResult := WaitForSingleObject(hProc, DWORD(TimeoutSec) * 1000);
      Result := (WaitResult = WAIT_OBJECT_0);
      if Result then
        StatusMsg := 'CTRL_C_EVENT sent via PID ' + AttachPID.ToString + ' - server exited cleanly.'
      else
        StatusMsg := 'CTRL_C_EVENT sent via PID ' + AttachPID.ToString + ', but server did not exit within ' + TimeoutSec.ToString + 's.';
    end //if SignalSent then
    else
      StatusMsg := 'GenerateConsoleCtrlEvent failed: ' + SysErrorMessage(GetLastError);

    StatusMsg := StatusMsg + ' [console group: ' + ConsoleProcs + ']';

    SetConsoleCtrlHandler(nil, False);
    FreeConsole;
    RestoreOwnConsole;
  finally
    CloseHandle(hProc);
  end;
end;

function ShutdownServerGracefully(PID: DWORD; TimeoutSec: Integer): Boolean;
var
  ParentPID: DWORD;
  Attached: Boolean;
  StatusMsg, Reason: string;
begin
  Log('Server session=' + SessionOf(PID).ToString + ', ' + ExtractFileName(ParamStr(0)) + ' session=' + SessionOf(GetCurrentProcessId).ToString +
    '.');

  // First attempt: attach to the server's own console.
  Result := TrySignalViaConsole(PID, PID, TimeoutSec, Attached, StatusMsg);
  Log(StatusMsg);
  if Result then
    Exit;

  // If the attach itself failed, the console is probably owned by a parent launcher (batch/Steam/wrapper). Try attaching to that instead.
  if not Attached then
  begin
    ParentPID := GetParentPID(PID);
    if (ParentPID <> 0) and (ParentPID <> PID) then
    begin
      // Vet the recorded parent before attaching: its PID may have been
      // recycled by an unrelated process since the server was launched (see
      // ParentLooksGenuine) - Ctrl+C into that console would hit innocents.
      if ParentLooksGenuine(ParentPID, PID, Reason) then
      begin
        Log('Retrying via parent process PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) + ', session=' +
          SessionOf(ParentPID).ToString + ')...');
        Result := TrySignalViaConsole(ParentPID, PID, TimeoutSec, Attached, StatusMsg);
        Log(StatusMsg);
      end //if ParentLooksGenuine(ParentPID, PID, Reason) then
      else
        Log('NOT retrying via parent PID ' + ParentPID.ToString + ': ' + Reason);
    end //if (ParentPID <> 0) and (ParentPID <> PID) then
    else
      Log('No usable parent process to retry against.');
  end; //if not Attached then
end;

{ True when FileName matches ANY mask in the semicolon-separated Masks list
  (blank entries are ignored). Used for the [Backup] ExcludeMasks option. }
function MatchesAnyMask(const FileName, Masks: string): Boolean;
var
  Mask: string;
begin
  Result := False;
  for Mask in Masks.Split([';']) do
    if (Trim(Mask) <> '') and MatchesMask(FileName, Trim(Mask)) then
      Exit(True);
end;

{
Adds one filesystem entry to an already-open zip. A file is stored under its name
relative to RootDir; a FOLDER has every file beneath it added recursively, each
under its path relative to RootDir — so the folder's own name is preserved as the
top level inside the archive (restoring the zip recreates <Folder>\... verbatim).
Returns the number of files actually written.

This is what makes the tool work with the Valheim 1.0 save format, where a world
(and each rolling auto-backup) is a FOLDER of chunked files rather than a flat
<World>.db/.fwl pair.
}
function AddEntryToZip(Zip: TZipFile; const RootDir, EntryPath: string): Integer;
var
  Base, Rel, F: string;
  SubFiles: TArray<string>;
begin
  Result := 0;
  Base := IncludeTrailingPathDelimiter(RootDir);
  if TDirectory.Exists(EntryPath) then
  begin
    SubFiles := TDirectory.GetFiles(EntryPath, '*', TSearchOption.soAllDirectories);
    for F in SubFiles do
    begin
      Rel := F;
      if Rel.StartsWith(Base, True) then
        Rel := Rel.Substring(Length(Base));
      Zip.Add(F, Rel);
      Inc(Result);
    end;
  end //if TDirectory.Exists(EntryPath) then
  else if TFile.Exists(EntryPath) then
  begin
    Rel := EntryPath;
    if Rel.StartsWith(Base, True) then
      Rel := Rel.Substring(Length(Base));
    Zip.Add(EntryPath, Rel);
    Result := 1;
  end; //else if TFile.Exists(EntryPath) then
end;

{
Zips a single top-level entry (a folder or a loose file) that lives directly in
SourceDir into DestDir as <Prefix><EntryName>_<timestamp><Suffix>.zip, preserving
the entry's own name inside the archive. One entry, one zip — the whole point of
the per-world / per-backup layout. Returns True if the zip was written (even if
the entry happened to be empty); False, with the reason logged, on any error.
}
function ZipEntry(const Description, SourceDir, EntryPath, DestDir, Prefix, Suffix: string): Boolean;
var
  Zip: TZipFile;
  ZipPath, EntryName: string;
  Count: Integer;
begin
  Result := False;
  EntryName := ExtractFileName(ExcludeTrailingPathDelimiter(EntryPath));
  try
    if not TDirectory.Exists(DestDir) then
      TDirectory.CreateDirectory(DestDir);

    ZipPath := TPath.Combine(DestDir,
      Prefix + EntryName + '_' + FormatDateTime('yyyy_mm_dd_hh_nn_ss', Now) + Suffix + '.zip');

    Zip := TZipFile.Create;
    try
      Zip.Open(ZipPath, zmWrite);
      Count := AddEntryToZip(Zip, SourceDir, EntryPath);
      Zip.Close;
    finally
      Zip.Free;
    end;

    if Count = 0 then
      Log('WARNING: ' + Description + ' "' + EntryName + '" had no files - empty archive written: ' + ZipPath)
    else
      Log(Description + ' archive written: ' + ZipPath + ' (' + Count.ToString + ' file(s)).');
    Result := True;
  except
    on E: Exception do
      Log('WARNING: ' + Description + ' archive of "' + EntryName + '" failed: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

{
Zips files matching FileMask under SourceDir (recursively if Recurse, preserving
folder structure) into BACKUP_DIR as <Prefix>yyyy_mm_dd_hh_nn_ss<Suffix>.zip.
Prefix and Suffix may be blank. Files whose NAME matches any mask in the
semicolon-separated ExcludeMasks list are left out ('' = exclude nothing).
Meant to run while the server is stopped so files are flushed and unlocked.
Returns False on any problem (logged by the caller); a failed backup is
non-fatal.
}
function ZipFolder(const Description, SourceDir, FileMask, Prefix, Suffix: string; Recurse: Boolean; const ExcludeMasks: string = ''): Boolean;
var
  Zip: TZipFile;
  Files: TArray<string>;
  SrcFile, ZipPath, RelName, BaseDir: string;
  SearchOption: TSearchOption;
  i, Kept: Integer;
begin
  Result := False;

  if (SourceDir = '') or (BACKUP_DIR = '') then
  begin
    Log(Description + ' backup skipped: source or BackupDir not set in ' + ConfigPath + '.');
    Exit;
  end;//if (SourceDir = '') or (BACKUP_DIR = '') then

  if not TDirectory.Exists(SourceDir) then
  begin
    Log('WARNING: ' + Description + ' backup skipped - folder not found: ' + SourceDir);
    Exit;
  end;//if not TDirectory.Exists(SourceDir) then

  try
    if not TDirectory.Exists(BACKUP_DIR) then
      TDirectory.CreateDirectory(BACKUP_DIR);

    ZipPath := TPath.Combine(BACKUP_DIR, Prefix + FormatDateTime('yyyy_mm_dd_hh_nn_ss', Now) + Suffix + '.zip');

    BaseDir := IncludeTrailingPathDelimiter(SourceDir);
    if Recurse then
      SearchOption := TSearchOption.soAllDirectories
    else
      SearchOption := TSearchOption.soTopDirectoryOnly;
    Files := TDirectory.GetFiles(SourceDir, FileMask, SearchOption);

    if ExcludeMasks <> '' then
    begin
      Kept := 0;
      for i := 0 to High(Files) do
        if not MatchesAnyMask(ExtractFileName(Files[i]), ExcludeMasks) then
        begin
          Files[Kept] := Files[i];
          Inc(Kept);
        end; //if not MatchesAnyMask(ExtractFileName(Files[i]), ExcludeMasks) then
      if Kept < Length(Files) then
        Log('  Excluded ' + (Length(Files) - Kept).ToString + ' ' + Description + ' file(s) matching "' + ExcludeMasks + '".');
      SetLength(Files, Kept);
    end; //if ExcludeMasks <> '' then

    if Length(Files) = 0 then
    begin
      Log('WARNING: No ' + Description + ' files found to back up in ' + SourceDir + '.');
      Exit;
    end;

    Log('Backing up ' + Length(Files).ToString + ' ' + Description + ' file(s) from ' + SourceDir + '...');

    Zip := TZipFile.Create;
    try
      Zip.Open(ZipPath, zmWrite);
      for SrcFile in Files do
      begin
        // Preserve the folder structure relative to SourceDir inside the zip.
        RelName := SrcFile;
        if RelName.StartsWith(BaseDir, True) then
          RelName := RelName.Substring(Length(BaseDir));
        Zip.Add(SrcFile, RelName);
      end; //for SrcFile in Files do
      Zip.Close;
    finally
      Zip.Free;
    end;

    Log(Description + ' backup written: ' + ZipPath);
    Result := True;
  except
    on E: Exception do
      Log('WARNING: ' + Description + ' backup failed: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

{
Backs up the live world saves. Since Valheim 1.0 each world in worlds_local is a
FOLDER (<World>\ holding _main.N.db2 / .fwl2 / .chunks / *.chunk / _main.N.ok), so
every top-level world folder is zipped to its OWN archive:
  <WorldsPrefix><World>_<timestamp><WorldsSuffix>.zip
The rolling auto-backup folders (<World>_backup_auto-*) are NOT touched here — they
belong to the AutoArchive sweep, keeping the two archives cleanly separated (and
they are skipped even if that sweep is disabled, so they never bloat a world zip).

For backward compatibility — a server still on the pre-1.0 flat format, or legacy
<World>.db/.fwl[.old] files left beside a world that has since converted — any
loose top-level FILES that are not auto-backups and not excluded by [Backup]
ExcludeMasks (default *.old) are gathered into one extra
<WorldsPrefix>loose_<timestamp><WorldsSuffix>.zip so nothing at the root is
silently dropped. Returns True if at least one archive was written; a
failed/skipped backup is non-fatal (logged by the caller).
}
function BackupWorlds: Boolean;
var
  Dirs, AllFiles: TArray<string>;
  Loose: TArray<string>;
  Dir, F, ZipPath: string;
  Zip: TZipFile;
  Count: Integer;
begin
  Result := False;

  if (WORLDS_DIR = '') or (BACKUP_DIR = '') then
  begin
    Log('worlds backup skipped: WorldsDir or BackupDir not set in ' + ConfigPath + '.');
    Exit;
  end; //if (WORLDS_DIR = '') or (BACKUP_DIR = '') then

  if not TDirectory.Exists(WORLDS_DIR) then
  begin
    Log('WARNING: worlds backup skipped - folder not found: ' + WORLDS_DIR);
    Exit;
  end; //if not TDirectory.Exists(WORLDS_DIR) then

  // 1) Each live world folder -> its own zip. Skip the *_backup_auto-* folders:
  //    those are the AutoArchive sweep's job, kept in a separate archive.
  Dirs := TDirectory.GetDirectories(WORLDS_DIR, '*', TSearchOption.soTopDirectoryOnly);
  for Dir in Dirs do
  begin
    if MatchesAnyMask(ExtractFileName(ExcludeTrailingPathDelimiter(Dir)), AUTO_FILE_MASK) then
      Continue; // rolling auto-backup folder - handled by AutoArchive
    if ZipEntry('worlds', WORLDS_DIR, Dir, BACKUP_DIR, WORLDS_PREFIX, WORLDS_SUFFIX) then
      Result := True;
  end; //for Dir in Dirs do

  // 2) Loose top-level files (a pre-1.0 flat world, or legacy leftovers beside a
  //    converted one) -> one combined zip. Excludes auto-backups and the
  //    [Backup] ExcludeMasks (default *.old, Valheim's one-generation fallback).
  AllFiles := TDirectory.GetFiles(WORLDS_DIR, '*', TSearchOption.soTopDirectoryOnly);
  SetLength(Loose, 0);
  for F in AllFiles do
    if not MatchesAnyMask(ExtractFileName(F), AUTO_FILE_MASK + ';' + EXCLUDE_MASKS) then
    begin
      SetLength(Loose, Length(Loose) + 1);
      Loose[High(Loose)] := F;
    end; //if not MatchesAnyMask(...) then

  if Length(Loose) > 0 then
  begin
    try
      if not TDirectory.Exists(BACKUP_DIR) then
        TDirectory.CreateDirectory(BACKUP_DIR);
      ZipPath := TPath.Combine(BACKUP_DIR,
        WORLDS_PREFIX + 'loose_' + FormatDateTime('yyyy_mm_dd_hh_nn_ss', Now) + WORLDS_SUFFIX + '.zip');
      Zip := TZipFile.Create;
      try
        Zip.Open(ZipPath, zmWrite);
        Count := 0;
        for F in Loose do
          Inc(Count, AddEntryToZip(Zip, WORLDS_DIR, F));
        Zip.Close;
      finally
        Zip.Free;
      end;
      Log('worlds archive written: ' + ZipPath + ' (' + Count.ToString + ' loose file(s)).');
      Result := True;
    except
      on E: Exception do
        Log('WARNING: loose worlds file backup failed: ' + E.ClassName + ' - ' + E.Message);
    end; //try..except
  end; //if Length(Loose) > 0 then

  if not Result then
    Log('WARNING: worlds backup produced no archives - nothing to back up in ' + WORLDS_DIR + '.');
end;

{
Backs up the server's list/config files (adminlist.txt, bannedlist.txt,
permittedlist.txt) into a separate zip. Top level only — the worlds_local
subfolder underneath has its own backup above.
}
function BackupServerConfig: Boolean;
begin
  Result := ZipFolder('config', CONFIG_DIR, '*.txt', CONFIG_PREFIX, CONFIG_SUFFIX, False, EXCLUDE_MASKS);
end;

{
Sweeps Valheim's rolling auto-backups out of WorldsDir into [AutoArchive]
ArchiveDir, then deletes each archived original (DeleteAfterArchive=1).

Since Valheim 1.0 each auto-backup is a FOLDER (<World>_backup_auto-<date>-<time>\)
of chunked files, not a flat <World>_backup_auto-*.db/.fwl pair, so this enumerates
top-level FOLDERS matching AUTO_FILE_MASK — and, for a pre-1.0 / un-migrated server,
also any loose FILES still matching it. Each matching entry is zipped to its OWN
archive (<AutoPrefix><EntryName>_<timestamp><AutoSuffix>.zip) and, if
DeleteAfterArchive=1, removed only AFTER its own zip has been written successfully.

The live world folder (<World>\), the legacy .old pair and any other worlds_local
content are NEVER matched — the mask only ever matches the auto-backups, which the
server recreates from scratch each backup cycle. Safe to run while the server is up:
the auto-backups are finished copies the server is no longer writing, and the server
is neither stopped nor restarted. If one entry is locked (e.g. a backup is being
written right now) its zip fails, that entry alone is left in place for the next run,
and the others still archive. Runs standalone via the /autoarchive parameter, and
also as a step of the restart cycle (RunOnRestart=1) so the worlds backup and the
auto-backup archives stay cleanly separated.
Returns the process exit code (0 = archived or nothing to do, 5 = a zip failed).
}
function AutoArchive: Integer;
var
  Dirs, LegacyFiles, Entries: TArray<string>;
  Entry: string;
  i, Zipped, Deleted, Failed: Integer;
  AnyZipFailed: Boolean;
begin
  Result := 5;

  if (WORLDS_DIR = '') or (AUTO_ARCHIVE_DIR = '') then
  begin
    Log('ERROR: Auto-archive skipped - WorldsDir or ArchiveDir not set in ' + ConfigPath + '.');
    Exit;
  end;//if (WORLDS_DIR = '') or (AUTO_ARCHIVE_DIR = '') then

  if not TDirectory.Exists(WORLDS_DIR) then
  begin
    Log('ERROR: Auto-archive skipped - folder not found: ' + WORLDS_DIR);
    Exit;
  end;//if not TDirectory.Exists(WORLDS_DIR) then

  // Top level only, both folders (1.0) and loose files (legacy). Not recursing
  // means a stray file inside a world folder can never be swept into delete.
  Dirs := TDirectory.GetDirectories(WORLDS_DIR, AUTO_FILE_MASK, TSearchOption.soTopDirectoryOnly);
  LegacyFiles := TDirectory.GetFiles(WORLDS_DIR, AUTO_FILE_MASK, TSearchOption.soTopDirectoryOnly);

  SetLength(Entries, Length(Dirs) + Length(LegacyFiles));
  for i := 0 to High(Dirs) do
    Entries[i] := Dirs[i];
  for i := 0 to High(LegacyFiles) do
    Entries[Length(Dirs) + i] := LegacyFiles[i];

  // Always state the find result, found or not — an unattended run must leave no
  // question about whether the sweep saw anything to do.
  Log('Auto-archive: found ' + Length(Entries).ToString + ' backup entr' +
    IfThen(Length(Entries) = 1, 'y', 'ies') + ' matching ' + AUTO_FILE_MASK + ' in ' + WORLDS_DIR +
    ' (' + Length(Dirs).ToString + ' folder(s), ' + Length(LegacyFiles).ToString + ' loose file(s)).');
  if Length(Entries) = 0 then
  begin
    Log('Auto-archive: nothing to do.');
    Result := 0;
    Exit;
  end;//if Length(Entries) = 0 then

  if not TDirectory.Exists(AUTO_ARCHIVE_DIR) then
    TDirectory.CreateDirectory(AUTO_ARCHIVE_DIR);

  // Each entry -> its own zip; delete it only after its own zip succeeds. Snapshot
  // was taken above, so an auto-backup created mid-run survives to the next run.
  Zipped := 0;
  Deleted := 0;
  Failed := 0;
  AnyZipFailed := False;
  for Entry in Entries do
  begin
    if not ZipEntry('auto-backup', WORLDS_DIR, Entry, AUTO_ARCHIVE_DIR, AUTO_PREFIX, AUTO_SUFFIX) then
    begin
      AnyZipFailed := True;
      Log('  Left in place (zip failed): ' + Entry);
      Continue; // never delete an entry we did not manage to archive
    end;//if not ZipEntry(...) then
    Inc(Zipped);

    if not AUTO_DELETE then
      Continue;

    try
      if TDirectory.Exists(Entry) then
        TDirectory.Delete(Entry, True) // recursive: the whole backup folder
      else
        TFile.Delete(Entry);
      Inc(Deleted);
    except
      on E: Exception do
      begin
        Inc(Failed);
        Log('  Could not delete ' + Entry + ': ' + E.Message);
      end;//on E: Exception do
    end;//try..except
  end;//for Entry in Entries do

  if AUTO_DELETE then
    Log(Format('Auto-archive: %d archived, %d original(s) removed, %d delete failure(s).', [Zipped, Deleted, Failed]))
  else
    Log(Format('Auto-archive: %d archived - DeleteAfterArchive=0, originals left in place.', [Zipped]));

  // A delete failure is non-fatal (the archive exists; the leftover folder is
  // retried next run). Only a failed zip is reported as an error exit.
  if AnyZipFailed then
    Result := 5
  else
    Result := 0;
end;

{
Runs a command line with its stdout+stderr captured through a pipe, relaying each
line to Log() (so it lands in both the console and the date-stamped log file).
Waits for the process to finish. Returns False only if the process failed to
launch; ExitCode receives the process exit code otherwise.

SteamCMD's progress is line-buffered with CR/LF, so each progress update becomes
its own logged line - exactly what we want for an unattended record.
}
function RunCapturedToLog(const ACmdLine, AWorkDir: string; out ExitCode: DWORD): Boolean;
var
  Sec: TSecurityAttributes;
  hReadOut, hWriteOut: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  LineBuf: AnsiString;
  i: Integer;

  procedure FlushLine;
  begin
    if LineBuf <> '' then
    begin
      Log(string(LineBuf));
      LineBuf := '';
    end;//if LineBuf <> '' then
  end;//procedure FlushLine;

begin
  Result := False;
  ExitCode := DWORD(-1);

  FillChar(Sec, SizeOf(Sec), 0);
  Sec.nLength := SizeOf(Sec);
  Sec.bInheritHandle := True; // child must inherit the pipe's write end

  if not CreatePipe(hReadOut, hWriteOut, @Sec, 0) then
  begin
    Log('WARNING: CreatePipe failed: ' + SysErrorMessage(GetLastError));
    Exit;
  end;//if not CreatePipe(hReadOut, hWriteOut, @Sec, 0) then

  // The parent's read end must NOT be inherited by the child.
  SetHandleInformation(hReadOut, HANDLE_FLAG_INHERIT, 0);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
  SI.hStdOutput := hWriteOut;
  SI.hStdError := hWriteOut;

  Cmd := ACmdLine;
  UniqueString(Cmd); // CreateProcessW may modify lpCommandLine in place

  if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(AWorkDir), SI, PI) then
  begin
    Log('WARNING: Failed to launch process: ' + SysErrorMessage(GetLastError));
    CloseHandle(hReadOut);
    CloseHandle(hWriteOut);
    Exit;
  end;//if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(AWorkDir), SI, PI) then

  // Close our copy of the write end so ReadFile sees EOF when the child exits.
  CloseHandle(hWriteOut);

  LineBuf := '';
  while ReadFile(hReadOut, Buffer, SizeOf(Buffer), BytesRead, nil) and (BytesRead > 0) do
    for i := 0 to Integer(BytesRead) - 1 do
      if CharInSet(Buffer[i], [#13, #10]) then
        FlushLine
      else
        LineBuf := LineBuf + Buffer[i];
  FlushLine; // anything left without a trailing newline

  WaitForSingleObject(PI.hProcess, INFINITE);
  if not GetExitCodeProcess(PI.hProcess, ExitCode) then
    ExitCode := DWORD(-1);

  CloseHandle(hReadOut);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
  Result := True;
end;

{
Runs SteamCMD to update the Valheim dedicated server, waiting for it to finish
and capturing its output to the log. Controlled by [Update] EnableUpdate.
Non-fatal: any problem is logged and the restart still proceeds. Returns True
only if an update actually ran and SteamCMD reported success (exit code 0).
}
function UpdateServer: Boolean;
var
  CmdLine, WorkDir: string;
  ExitCode: DWORD;
begin
  Result := False;

  if not ENABLE_UPDATE then
  begin
    Log('SteamCMD update skipped (EnableUpdate=0).');
    Exit;
  end; //if not ENABLE_UPDATE then

  if (STEAMCMD_PATH = '') or not TFile.Exists(STEAMCMD_PATH) then
  begin
    Log('WARNING: SteamCMD update skipped - steamcmd.exe not found: ' + STEAMCMD_PATH);
    Exit;
  end; //if (STEAMCMD_PATH = '') or not TFile.Exists(STEAMCMD_PATH) then

  if (STEAM_APP_ID = '') or (STEAM_INSTALL_DIR = '') then
  begin
    Log('WARNING: SteamCMD update skipped - SteamAppId or InstallDir not set in ' + ConfigPath + '.');
    Exit;
  end; //if (STEAM_APP_ID = '') or (STEAM_INSTALL_DIR = '') then

  // +force_install_dir must come BEFORE +login per SteamCMD's argument ordering.
  CmdLine := Format('"%s" +force_install_dir "%s" +login anonymous +app_update %s validate +quit', [STEAMCMD_PATH,
    ExcludeTrailingPathDelimiter(STEAM_INSTALL_DIR), STEAM_APP_ID]);
  WorkDir := ExtractFilePath(STEAMCMD_PATH);

  Log('Running SteamCMD update (app ' + STEAM_APP_ID + ')...');

  if not RunCapturedToLog(CmdLine, WorkDir, ExitCode) then
    Exit; // launch failure already logged

  if ExitCode = 0 then
  begin
    Log('SteamCMD update completed successfully.');
    Result := True;
  end //if ExitCode = 0 then
  else
    Log('WARNING: SteamCMD exited with code ' + Integer(ExitCode).ToString + ' - the server may not have updated. Restart will proceed anyway.');
end;

{
Deletes every file in SERVER_LOG_DIR (recursively), leaving the folder itself in
place. Intended to run only after a successful backup. Individual delete failures
(e.g. a file still locked) are logged and skipped, not fatal.

Valheim has NO per-session log folder by default (Unity writes a single
Player.log/console output), so this is off (blank) unless the user points
-logFile at a dedicated folder they want cleared.
}
procedure PurgeServerLogs;
var
  Files: TArray<string>;
  AFile: string;
  Deleted, Failed: Integer;
begin
  if SERVER_LOG_DIR = '' then
    Exit;

  if not TDirectory.Exists(SERVER_LOG_DIR) then
  begin
    Log('Log purge skipped - folder not found: ' + SERVER_LOG_DIR);
    Exit;
  end;

  Deleted := 0;
  Failed := 0;
  try
    Files := TDirectory.GetFiles(SERVER_LOG_DIR, '*', TSearchOption.soAllDirectories);
    for AFile in Files do
    begin
      try
        TFile.Delete(AFile);
        Inc(Deleted);
      except
        on E: Exception do
        begin
          Inc(Failed);
          Log('  Could not delete ' + AFile + ': ' + E.Message);
        end;//on E: Exception do
      end;//try..except
    end;//for AFile in Files do
    Log(Format('Purged server logs in %s - %d deleted, %d skipped.',
      [SERVER_LOG_DIR, Deleted, Failed]));
  except
    on E: Exception do
      Log('WARNING: Log purge failed: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

procedure RestartServer;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
begin
  // The official start_headless_server.bat sets SteamAppId=892970 before
  // launching the server; set it in our own environment so the child inherits
  // it. Configurable via [Server] SteamAppIdEnv (blank = don't set).
 if SERVER_APPID_ENV <> '' then
    if not SetEnvironmentVariable('SteamAppId', PChar(SERVER_APPID_ENV)) then
      Log('WARNING: could not set SteamAppId=' + SERVER_APPID_ENV + ': ' + SysErrorMessage(GetLastError));

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_SHOWMINNOACTIVE; // Start minimised; change to SW_SHOW if preferred

  if SERVER_ARGS <> '' then
    CmdLine := '"' + SERVER_EXE_PATH + '" ' + SERVER_ARGS
  else
    CmdLine := '"' + SERVER_EXE_PATH + '"';

  // CreateProcessW may modify lpCommandLine in place, so it must point to a writable, uniquely-owned buffer — otherwise it can access-violate.
  UniqueString(CmdLine);

  if CreateProcess(nil, PChar(CmdLine), nil, nil, False, CREATE_NEW_CONSOLE, nil, PChar(SERVER_WORK_DIR), SI, PI) then
  begin
    Log('Server restarted successfully (PID ' + PI.dwProcessId.ToString + ').');
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end //if CreateProcess( nil, PChar(CmdLine), nil, nil, False, CREATE_NEW_CONSOLE, nil, PChar(SERVER_WORK_DIR), SI, PI) then
  else
    Log('ERROR: CreateProcess failed: ' + SysErrorMessage(GetLastError));
end;

var
  PID: DWORD;
  i: Integer;
  Mode: string;
begin
  Writeln('=== Valheim Server Restart Utility ===');
  Writeln;

  InitLogging;
  if not LoadConfig then
  begin
    ExitCode := 3;
    Exit;
  end;

  // --- Alternate mode: /autoarchive — archive the world auto-backup files ---
  // Does NOT stop, restart, or otherwise touch the server. Meant to be run on
  // its own (frequent) Task Scheduler trigger, independent of the restart job.
  Mode := ParamStr(1);
  if Mode <> '' then
  begin
    if SameText(Mode, '/autoarchive') or SameText(Mode, '-autoarchive') or SameText(Mode, '--autoarchive') then
    begin
      Log('=== Auto-backup archive mode (server is not touched) ===');
      ExitCode := AutoArchive;
      Log('=== Done ===');
      Exit;
    end;//if SameText(Mode, '/autoarchive') ...

    Writeln('Unknown parameter: ' + Mode);
    Writeln('Usage:');
    Writeln('  ' + ExtractFileName(ParamStr(0)) + '                restart cycle (shutdown, backup, update, relaunch)');
    Writeln('  ' + ExtractFileName(ParamStr(0)) + ' /autoarchive   zip world auto-backup files to [AutoArchive] ArchiveDir and remove them');
    ExitCode := 3;
    Exit;
  end;//if Mode <> '' then

  Log('=== Valheim Server Restart Utility started ===');

  // --- Step 0: verify the server executable exists before doing anything ---
  if not TFile.Exists(SERVER_EXE_PATH) then
  begin
    Log('ERROR: Server executable not found: ' + SERVER_EXE_PATH);
    Log('Check ExePath in ' + ConfigPath + ' and try again.');
    ExitCode := 4;
    Exit;
  end;//if not TFile.Exists(SERVER_EXE_PATH) then
  if not TDirectory.Exists(SERVER_WORK_DIR) then
  begin
    Log('ERROR: Working directory not found: ' + SERVER_WORK_DIR);
    Log('Check WorkDir in ' + ConfigPath + ' and try again.');
    ExitCode := 4;
    Exit;
  end;//if not TDirectory.Exists(SERVER_WORK_DIR) then

  // --- Step 1: find the running server ---
  Log('Looking for ' + SERVER_EXE_NAME + '...');
  PID := FindProcessByName(SERVER_EXE_NAME);
  if PID = 0 then
    Log('Server process not found. Skipping shutdown, proceeding to start.')
  else
  begin
    Log('Found server at PID ' + PID.ToString + '. Sending Ctrl+C and waiting up to ' + SHUTDOWN_TIMEOUT.ToString + 's for clean shutdown...');

    if not ShutdownServerGracefully(PID, SHUTDOWN_TIMEOUT) then
    begin
      Log('WARNING: Server did not shut down cleanly. It may still be running.');
      Log('Check manually before relying on the restart.');
      ExitCode := 2;
      Exit;
    end; //if not ShutdownServerGracefully(PID, SHUTDOWN_TIMEOUT) then
  end; //if..then..else PID = 0 then

  // --- Step 2: sweep the auto-backups into their own archive ---
  // Keeps them out of the worlds backup below (which excludes them by mask
  // regardless, so a failure here can't leak them in). Non-fatal.
  if AUTO_RUN_ON_RESTART and (AUTO_ARCHIVE_DIR <> '') then
  begin
    if AutoArchive <> 0 then
      Log('WARNING: auto-backup archive failed - matching files stay in place (and out of the worlds backup) until the next /autoarchive run.');
  end //if AUTO_RUN_ON_RESTART and (AUTO_ARCHIVE_DIR <> '') then
  else
    Log('Auto-backup archive sweep skipped (RunOnRestart=0 or ArchiveDir not set).');

  // --- Step 3: back up the worlds while the server is stopped ---
  // The server has just saved the world as part of its Ctrl+C shutdown, so the
  // .db/.fwl files on disk are current and unlocked.
  // Non-fatal: a failed/skipped backup is logged but the restart still proceeds.
  // Only purge logs (if configured at all) once we have a confirmed good backup.
  if BackupWorlds then
    PurgeServerLogs
  else if SERVER_LOG_DIR <> '' then
    Log('Skipping log purge because the worlds backup did not complete.');

  // --- Step 4: back up the server list files (adminlist/bannedlist/permittedlist) ---
  BackupServerConfig;

  // --- Step 5: update the server via SteamCMD (if enabled) ---
  UpdateServer;

  // --- Step 6: wait before restarting ---
  Log('Waiting ' + RESTART_DELAY.ToString + 's before restart...');
  for i := RESTART_DELAY downto 1 do
  begin
    Write(#13 + '  Restarting in ' + i.ToString + 's...  ');
    Sleep(1000);
  end; //for i := RESTART_DELAY downto 1 do
  Writeln;

  // --- Step 7: launch the server ---
  Log('Starting ' + SERVER_EXE_PATH + '...');
  RestartServer;

  Writeln;
  Log('=== Done ===');
end.

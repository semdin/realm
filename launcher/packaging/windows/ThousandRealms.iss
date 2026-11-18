; Thousand Realms per-user installer. Built in CI by launcher-packages.yml:
;   ISCC /DLauncherExe=<ThousandRealms_Launcher.exe> /DOutputDir=<dir> ThousandRealms.iss
; No administrator prompt: everything goes under the player's own profile, so
; the launcher can keep replacing itself. The game itself is not in here; the
; launcher downloads it to %LOCALAPPDATA%\ThousandRealms.

#ifndef LauncherExe
  #define LauncherExe "..\..\..\dist\ThousandRealms_Launcher.exe"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\..\dist"
#endif
#define AppTitle "Thousand Realms"
#define ExeName "ThousandRealms_Launcher.exe"
#define SupportUrl "https://github.com/semdin/realm/issues"

[Setup]
; Never change AppId: it is how a new setup finds an existing install.
AppId={{6E0C8E5B-5B1F-4A8E-9C55-0E7C3B7F4D21}
AppName={#AppTitle}
; The launcher updates itself, so no version is claimed in Apps & features.
AppVerName={#AppTitle}
AppPublisher={#AppTitle}
AppPublisherURL=https://github.com/semdin/realm
AppSupportURL={#SupportUrl}
AppUpdatesURL=https://github.com/semdin/realm/releases/latest
VersionInfoDescription={#AppTitle} Setup
VersionInfoProductName={#AppTitle}
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#AppTitle}
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableWelcomePage=yes
UsedUserAreasWarning=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; A launcher of either name must be closed first.
AppMutex=ThousandRealms_Launcher_Singleton,HPMMO_Launcher_Singleton
CloseApplications=yes
RestartApplications=no
SetupIconFile=..\..\assets\thousand_realms.ico
UninstallDisplayIcon={app}\{#ExeName}
UninstallDisplayName={#AppTitle}
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=ThousandRealms-Setup
ShowLanguageDialog=no
LanguageDetectionMethod=uilanguage

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[CustomMessages]
english.RemoveGameData=Also delete the downloaded game files and your game settings?%n%nChoose No to keep them, so a later reinstall does not download the game again.
turkish.RemoveGameData=İndirilen oyun dosyaları ve oyun ayarların da silinsin mi?%n%nHayır dersen saklanır; yeniden kurduğunda oyun tekrar indirilmez.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#LauncherExe}"; DestDir: "{app}"; DestName: "{#ExeName}"; Flags: ignoreversion
Source: "..\..\THIRD_PARTY_NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#AppTitle}"; Filename: "{app}\{#ExeName}"
Name: "{userdesktop}\{#AppTitle}"; Filename: "{app}\{#ExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#ExeName}"; Description: "{cm:LaunchProgram,{#AppTitle}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; What the launcher itself leaves beside its executable.
Type: files; Name: "{app}\launcher.log"
Type: files; Name: "{app}\{#ExeName}.swapnew"
Type: files; Name: "{app}\.thousandrealms-write-test-*"
Type: dirifempty; Name: "{app}"

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Attempt: Integer;
  Exe: String;
begin
  { A virus scanner can still hold the launcher for a moment: keep trying, so
    no program folder is left behind. }
  if CurUninstallStep = usPostUninstall then
  begin
    Exe := ExpandConstant('{app}\{#ExeName}');
    for Attempt := 1 to 60 do
    begin
      if (not FileExists(Exe)) or DeleteFile(Exe) then
        Break;
      Sleep(250);
    end;
    RemoveDir(ExpandConstant('{app}'));
  end;
  { A silent uninstall never deletes game data or settings. }
  if (CurUninstallStep = usPostUninstall) and not UninstallSilent then
    if MsgBox(CustomMessage('RemoveGameData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    begin
      DelTree(ExpandConstant('{localappdata}\ThousandRealms'), True, True, True);
      DelTree(ExpandConstant('{userappdata}\ThousandRealms'), True, True, True);
    end;
end;

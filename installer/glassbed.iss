; Glassbed – Windows installer (Inno Setup 6)
; Per-user installation without administrator rights. Built by build.ps1:
;   ISCC.exe /DAppVersion=<version> installer\glassbed.iss

#ifndef AppVersion
  #error AppVersion must be passed on the command line, e.g. /DAppVersion=0.2.0
#endif

; release builds compress; /DCompression=none produces an uncompressed copy for content checks
#ifndef Compression
  #define Compression "lzma2/max"
#endif

#define AppName "Glassbed"
#define AppExe "Glassbed.exe"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
; must match glassbed/config.py (organization and default profile)
#define SettingsKey "Software\Glassbed\Glassbed\ui"

[Setup]
AppId={{8C5F2B1E-6E2A-4C2F-9B7A-3D1E5A9F4C21}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=ARFEP IT-Service
AppPublisherURL=https://arfep.de/
AppSupportURL=https://github.com/ARFEP-IT-Service/Glassbed/issues
AppUpdatesURL=https://github.com/ARFEP-IT-Service/Glassbed/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoCompany=ARFEP IT-Service
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#AppName}
DisableProgramGroupPage=yes
DefaultGroupName={#AppName}
UsedUserAreasWarning=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
SetupIconFile=..\glassbed\assets\icon\glassbed.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename={#AppName}-{#AppVersion}-setup
Compression={#Compression}
SolidCompression=yes
CloseApplications=yes
ShowLanguageDialog=auto

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[CustomMessages]
english.AutostartTask=Start Glassbed with Windows (also shows the icon in the notification area)
german.AutostartTask=Glassbed mit Windows starten (zeigt auch das Symbol im Infobereich)
turkish.AutostartTask=Glassbed'i Windows ile başlat (bildirim alanındaki simgeyi de gösterir)
english.StartupGroup=Startup:
german.StartupGroup=Start:
turkish.StartupGroup=Başlangıç:

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "{cm:AutostartTask}"; GroupDescription: "{cm:StartupGroup}"; Flags: unchecked

[Files]
; the whole PyInstaller folder: Glassbed.exe, _internal\ (Qt stays replaceable), LICENSE,
; THIRD_PARTY_NOTICES.md and licenses\
Source: "..\dist\Glassbed\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; "Start with Windows": Run entry plus the app settings that switch the tray icon on.
; The app manages the same Run value ("Glassbed") when the option is changed later.
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{app}\{#AppExe}"" --tray"; Tasks: autostart; Flags: uninsdeletevalue
Root: HKCU; Subkey: "{#SettingsKey}"; ValueType: string; ValueName: "tray"; ValueData: "true"; Tasks: autostart
Root: HKCU; Subkey: "{#SettingsKey}"; ValueType: string; ValueName: "autostart"; ValueData: "true"; Tasks: autostart

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { the Run value may also have been created by the app itself (settings page),
    so remove it unconditionally; user settings under Software\Glassbed stay }
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, '{#RunKey}', '{#AppName}');
end;

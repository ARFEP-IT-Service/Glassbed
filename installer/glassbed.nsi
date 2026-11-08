; Glassbed – Windows installer (NSIS 3)
; Per-user installation without administrator rights. Built by build.ps1:
;   makensis /DVERSION=<version> installer\glassbed.nsi
; Silent install: Glassbed-<version>-setup.exe /S [/DESKTOP] [/AUTOSTART]
; Installing over an existing version keeps shortcuts, autostart and settings.
; /DNOCOMPRESS builds an uncompressed copy for content checks, /DOUTDIR=<folder> writes it elsewhere.

!ifndef VERSION
  !error "VERSION must be passed on the command line, e.g. /DVERSION=0.2.0"
!endif

!define APPNAME     "Glassbed"
!define APPEXE      "Glassbed.exe"
!define PUBLISHER   "ARFEP IT-Service"
!define RUNKEY      "Software\Microsoft\Windows\CurrentVersion\Run"
!define UNINSTKEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
; must match glassbed/config.py (organization and default profile)
!define SETTINGSKEY "Software\Glassbed\Glassbed\ui"

Unicode true
RequestExecutionLevel user
ManifestDPIAware true
!ifdef NOCOMPRESS
  SetCompress off
!else
  SetCompressor /SOLID lzma
!endif

Name "${APPNAME}"
!ifndef OUTDIR
  !define OUTDIR "..\dist"
!endif
OutFile "${OUTDIR}\${APPNAME}-${VERSION}-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
; installing over an existing version goes where that one is
InstallDirRegKey HKCU "${UNINSTKEY}" "InstallLocation"
BrandingText "${APPNAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=0 "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=0 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=0 "CompanyName" "${PUBLISHER}"
VIAddVersionKey /LANG=0 "FileDescription" "${APPNAME} Setup"
VIAddVersionKey /LANG=0 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=0 "LegalCopyright" "Halil Ayberk Bulut (ARFEP IT-Service), MIT License"

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!define MUI_ICON   "..\glassbed\assets\icon\glassbed.ico"
!define MUI_UNICON "..\glassbed\assets\icon\glassbed.ico"
!define MUI_ABORTWARNING
!define MUI_LANGDLL_REGISTRY_ROOT "HKCU"
!define MUI_LANGDLL_REGISTRY_KEY "${UNINSTKEY}"
!define MUI_LANGDLL_REGISTRY_VALUENAME "InstallerLanguage"
!define MUI_COMPONENTSPAGE_NODESC
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APPEXE}"

!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "German"
!insertmacro MUI_LANGUAGE "Turkish"
!insertmacro MUI_RESERVEFILE_LANGDLL

LangString SecApp       ${LANG_ENGLISH} "${APPNAME} (required)"
LangString SecApp       ${LANG_GERMAN}  "${APPNAME} (erforderlich)"
LangString SecApp       ${LANG_TURKISH} "${APPNAME} (gerekli)"
LangString SecDesktop   ${LANG_ENGLISH} "Desktop shortcut"
LangString SecDesktop   ${LANG_GERMAN}  "Desktop-Verknüpfung"
LangString SecDesktop   ${LANG_TURKISH} "Masaüstü kısayolu"
LangString SecAutostart ${LANG_ENGLISH} "Start with Windows (also shows the icon in the notification area)"
LangString SecAutostart ${LANG_GERMAN}  "Mit Windows starten (zeigt auch das Symbol im Infobereich)"
LangString SecAutostart ${LANG_TURKISH} "Windows ile başlat (bildirim alanındaki simgeyi de gösterir)"
LangString AppRunning   ${LANG_ENGLISH} "${APPNAME} is running. Please close it and click Retry."
LangString AppRunning   ${LANG_GERMAN}  "${APPNAME} läuft noch. Bitte beende es und klicke auf Wiederholen."
LangString AppRunning   ${LANG_TURKISH} "${APPNAME} çalışıyor. Lütfen kapatın ve Yeniden Dene'ye tıklayın."

; ------------------------------------------------------------------ running app
!macro CHECK_RUNNING un
Function ${un}CheckRunning
  ${Do}
    nsExec::ExecToStack 'cmd.exe /c tasklist /FI "IMAGENAME eq ${APPEXE}" /NH | find /I "${APPEXE}"'
    Pop $0   ; exit code: 0 = found
    Pop $1
    ${If} $0 != 0
      ${Break}
    ${EndIf}
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "$(AppRunning)" /SD IDCANCEL IDRETRY +2
    Abort
  ${Loop}
FunctionEnd
!macroend
!insertmacro CHECK_RUNNING ""
!insertmacro CHECK_RUNNING "un."

; ------------------------------------------------------------------ install
Section "$(SecApp)" SecMain
  SectionIn RO
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  ; replace the program files completely, so nothing of an older version is left behind
  RMDir /r "$INSTDIR\_internal"
  RMDir /r "$INSTDIR\licenses"
  ; the whole PyInstaller folder: Glassbed.exe, the _internal folder (Qt stays replaceable),
  ; LICENSE, THIRD_PARTY_NOTICES.md and the licenses folder
  File /r "..\dist\Glassbed\*.*"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateShortCut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${APPEXE}"

  ; Settings → Apps
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayName"          "${APPNAME}"
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayVersion"       "${VERSION}"
  WriteRegStr   HKCU "${UNINSTKEY}" "Publisher"            "${PUBLISHER}"
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayIcon"          "$INSTDIR\${APPEXE}"
  WriteRegStr   HKCU "${UNINSTKEY}" "InstallLocation"      "$INSTDIR"
  WriteRegStr   HKCU "${UNINSTKEY}" "UninstallString"      '"$INSTDIR\uninstall.exe"'
  WriteRegStr   HKCU "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegStr   HKCU "${UNINSTKEY}" "URLInfoAbout"         "https://github.com/ARFEP-IT-Service/Glassbed"
  WriteRegStr   HKCU "${UNINSTKEY}" "HelpLink"             "https://github.com/ARFEP-IT-Service/Glassbed/issues"
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTKEY}" "EstimatedSize" "$0"
SectionEnd

Section /o "$(SecDesktop)" SecDesktop
  SetShellVarContext current
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${APPEXE}"
SectionEnd

Section /o "$(SecAutostart)" SecAutostart
  ; Run entry plus the app settings that switch the tray icon on.
  ; The app manages the same Run value ("Glassbed") when the option is changed later.
  WriteRegStr HKCU "${RUNKEY}" "${APPNAME}" '"$INSTDIR\${APPEXE}" --tray'
  WriteRegStr HKCU "${SETTINGSKEY}" "tray" "true"
  WriteRegStr HKCU "${SETTINGSKEY}" "autostart" "true"
SectionEnd

Function .onInit
  ${IfNot} ${Silent}
    !insertmacro MUI_LANGDLL_DISPLAY
  ${EndIf}
  ; silent options: /DESKTOP and /AUTOSTART select the optional parts
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/DESKTOP" $R1
  ${IfNot} ${Errors}
    SectionSetFlags ${SecDesktop} ${SF_SELECTED}
  ${EndIf}
  ClearErrors
  ${GetOptions} $R0 "/AUTOSTART" $R1
  ${IfNot} ${Errors}
    SectionSetFlags ${SecAutostart} ${SF_SELECTED}
  ${EndIf}
  Call CheckRunning
FunctionEnd

; ------------------------------------------------------------------ uninstall
Section "Uninstall"
  SetShellVarContext current
  ; remove exactly what the installer put there – never the whole folder blindly
  RMDir /r "$INSTDIR\_internal"
  RMDir /r "$INSTDIR\licenses"
  Delete "$INSTDIR\${APPEXE}"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\THIRD_PARTY_NOTICES.md"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  Delete "$DESKTOP\${APPNAME}.lnk"
  ; the Run value may also have been created by the app itself (settings page), so remove it
  ; unconditionally; user settings under Software\Glassbed stay
  DeleteRegValue HKCU "${RUNKEY}" "${APPNAME}"
  DeleteRegKey HKCU "${UNINSTKEY}"
SectionEnd

Function un.onInit
  !insertmacro MUI_UNGETLANGUAGE
  Call un.CheckRunning
FunctionEnd

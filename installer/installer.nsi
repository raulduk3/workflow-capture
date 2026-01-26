; L7S Workflow Analyzer - NSIS Installer Script
; This creates a full MSI-style installer with OBS setup

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "x64.nsh"

; ============================================
; Installer Configuration
; ============================================

!define PRODUCT_NAME "L7S Workflow Analyzer"
!define PRODUCT_VERSION "1.0.0"
!define PRODUCT_PUBLISHER "Layer 7 Systems"
!define PRODUCT_WEB_SITE "https://layer7systems.com"
!define PRODUCT_UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
!define PRODUCT_UNINST_ROOT_KEY "HKLM"

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "..\release\L7S-Workflow-Analyzer-Setup-${PRODUCT_VERSION}.exe"
InstallDir "$PROGRAMFILES64\Layer 7 Systems\Workflow Analyzer"
InstallDirRegKey HKLM "${PRODUCT_UNINST_KEY}" "InstallLocation"
RequestExecutionLevel admin
ShowInstDetails show
ShowUnInstDetails show

; ============================================
; Modern UI Configuration
; ============================================

!define MUI_ABORTWARNING
!define MUI_ICON "..\build\icon.ico"
!define MUI_UNICON "..\build\icon.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "..\build\installer-sidebar.bmp"

; Welcome page
!define MUI_WELCOMEPAGE_TITLE "Welcome to ${PRODUCT_NAME} Setup"
!define MUI_WELCOMEPAGE_TEXT "This wizard will guide you through the installation of ${PRODUCT_NAME}.$\r$\n$\r$\nThis installer will:$\r$\n$\r$\n• Install ${PRODUCT_NAME}$\r$\n• Install OBS Studio (if not present)$\r$\n• Configure OBS for screen recording$\r$\n• Set up the recording directory$\r$\n$\r$\nClick Next to continue."

; License page
!define MUI_LICENSEPAGE_CHECKBOX

; Directory page
!define MUI_DIRECTORYPAGE_TEXT_TOP "Setup will install ${PRODUCT_NAME} in the following folder. Click Install to start the installation."

; Install page
!define MUI_INSTFILESPAGE_COLORS "000000 FFFFFF"

; Finish page
!define MUI_FINISHPAGE_RUN "$INSTDIR\L7S Workflow Analyzer.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch ${PRODUCT_NAME}"
!define MUI_FINISHPAGE_SHOWREADME ""
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Create Desktop Shortcut"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateDesktopShortcut

; ============================================
; Installer Pages
; ============================================

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

; Uninstaller pages
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; Language
!insertmacro MUI_LANGUAGE "English"

; ============================================
; Installer Sections
; ============================================

Section "Main Application" SecMain
    SectionIn RO ; Required section
    
    SetOutPath "$INSTDIR"
    
    ; Install application files
    File /r "..\release\win-unpacked\*.*"
    
    ; Install OBS setup script
    SetOutPath "$INSTDIR\setup"
    File "install-obs.ps1"
    
    ; Create uninstaller
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    
    ; Create Start Menu shortcuts
    CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
    CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\L7S Workflow Analyzer.exe"
    CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
    
    ; Write registry keys for uninstall
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "UninstallString" "$INSTDIR\Uninstall.exe"
    WriteRegDWORD ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "NoModify" 1
    WriteRegDWORD ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "NoRepair" 1
    
    ; Calculate installed size
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "EstimatedSize" "$0"
    
SectionEnd

Section "OBS Studio Setup" SecOBS
    
    DetailPrint "Checking OBS Studio installation..."
    
    ; Check if OBS is installed
    IfFileExists "$PROGRAMFILES64\obs-studio\bin\64bit\obs64.exe" OBSExists OBSNotExists
    
OBSNotExists:
    DetailPrint "OBS Studio not found. Installing..."
    Goto InstallOBS
    
OBSExists:
    DetailPrint "OBS Studio is already installed."
    Goto ConfigureOBS
    
InstallOBS:
    DetailPrint "Running OBS installation and configuration..."
    
ConfigureOBS:
    ; Run PowerShell script to install/configure OBS
    DetailPrint "Configuring OBS for screen capture..."
    
    ; Use quoted path for PowerShell script execution
    ; -NoProfile speeds up execution, -NonInteractive prevents prompts
    nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\setup\install-obs.ps1" -SetAsDefault'
    Pop $0
    
    ${If} $0 != 0
        DetailPrint "Warning: OBS configuration may have encountered issues (exit code: $0)"
        MessageBox MB_OK|MB_ICONEXCLAMATION "OBS configuration encountered issues. You may need to configure OBS manually.$\r$\n$\r$\nThe application will still work, but please run the setup again if you experience issues."
    ${Else}
        DetailPrint "OBS configuration completed successfully!"
    ${EndIf}
    
SectionEnd

Section "Create BandaStudy Directory" SecDir
    
    ; Create the sessions directory
    CreateDirectory "C:\BandaStudy\Sessions"
    DetailPrint "Created: C:\BandaStudy\Sessions"
    
SectionEnd

; ============================================
; Functions
; ============================================

Function CreateDesktopShortcut
    CreateShortCut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\L7S Workflow Analyzer.exe"
FunctionEnd

Function .onInit
    ; Check Windows version (require Windows 10+)
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK|MB_ICONSTOP "This application requires Windows 10 or later."
        Abort
    ${EndIf}
    
    ; Check for 64-bit Windows
    ${IfNot} ${RunningX64}
        MessageBox MB_OK|MB_ICONSTOP "This application requires 64-bit Windows."
        Abort
    ${EndIf}
    
    ; Check for admin rights
    UserInfo::GetAccountType
    Pop $0
    ${If} $0 != "admin"
        MessageBox MB_OK|MB_ICONSTOP "Administrator privileges are required to install this application."
        Abort
    ${EndIf}
FunctionEnd

; ============================================
; Uninstaller Section
; ============================================

Section "Uninstall"
    
    ; Kill running application
    nsExec::ExecToLog 'taskkill /F /IM "L7S Workflow Analyzer.exe"'
    
    ; Remove application files
    RMDir /r "$INSTDIR"
    
    ; Remove Start Menu shortcuts
    RMDir /r "$SMPROGRAMS\${PRODUCT_NAME}"
    
    ; Remove Desktop shortcut
    Delete "$DESKTOP\${PRODUCT_NAME}.lnk"
    
    ; Remove registry keys
    DeleteRegKey ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}"
    
    ; Note: We don't remove OBS or BandaStudy folder to preserve user data
    
SectionEnd

; ============================================
; Section Descriptions
; ============================================

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "Install the main ${PRODUCT_NAME} application."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecOBS} "Install and configure OBS Studio for screen recording."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecDir} "Create the BandaStudy sessions directory."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; L7S Workflow Analyzer - NSIS Include Script
; This is included by electron-builder's NSIS target

!include "FileFunc.nsh"
!include "WinVer.nsh"

; ============================================
; Custom Installation Macros
; ============================================

!macro customHeader
    ; Custom header - runs at the start
    !system "echo Building L7S Workflow Analyzer installer..."
!macroend

!macro preInit
    ; Pre-initialization - runs before anything else
    ; Check Windows version
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK|MB_ICONSTOP "L7S Workflow Analyzer requires Windows 10 or later."
        Abort
    ${EndIf}
!macroend

!macro customInit
    ; Custom initialization after GUI init
!macroend

!macro customInstall
    ; Custom installation steps after files are copied
    
    ; Create BandaStudy directory
    CreateDirectory "C:\BandaStudy\Sessions"
    
    ; Run OBS installation/configuration script
    DetailPrint "Configuring OBS Studio for screen capture..."
    
    ; Check if OBS is installed
    IfFileExists "$PROGRAMFILES64\obs-studio\bin\64bit\obs64.exe" ConfigureOBS InstallOBS
    
InstallOBS:
    DetailPrint "OBS Studio not found. Installing and configuring..."
    Goto RunPowerShell
    
ConfigureOBS:
    DetailPrint "OBS Studio found. Configuring for L7S..."
    
RunPowerShell:
    ; Run the PowerShell configuration script
    ; -NoProfile: Skip loading user profile (faster)
    ; -NonInteractive: Don't prompt for input
    ; -ExecutionPolicy Bypass: Allow script execution
    ; -SetAsDefault: Set L7S profile as default for new installs
    nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\resources\setup\install-obs.ps1" -SetAsDefault'
    Pop $0
    
    ${If} $0 == 0
        DetailPrint "OBS configuration completed successfully!"
    ${Else}
        DetailPrint "OBS configuration completed with warnings (exit: $0)"
        ; Show message but don't abort installation
        MessageBox MB_OK|MB_ICONINFORMATION "OBS setup completed with some warnings. The application should still work correctly.$\r$\n$\r$\nIf you experience issues, you can re-run the OBS setup from the application settings."
    ${EndIf}
    
!macroend

!macro customInstallMode
    ; Force "all users" installation
    StrCpy $isForceCurrentInstall "0"
!macroend

!macro customUnInstall
    ; Custom uninstall steps
    
    ; Kill the app if running
    nsExec::ExecToLog 'taskkill /F /IM "L7S Workflow Analyzer.exe" 2>nul'
    
    ; Note: We intentionally don't remove OBS or BandaStudy folder
    ; to preserve user recordings and OBS settings
    
    DetailPrint "Note: OBS Studio and recordings in C:\BandaStudy were preserved."
!macroend

!macro customRemoveFiles
    ; Custom file removal - called before default file removal
!macroend

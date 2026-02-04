; Workflow Capture - NSIS Include Script
; This is included by electron-builder's NSIS target

!include "FileFunc.nsh"
!include "WinVer.nsh"

; ============================================
; Custom Installation Macros
; ============================================

!macro customHeader
    ; Custom header - runs at the start
    !system "echo Building Workflow Capture installer..."
!macroend

!macro preInit
    ; Pre-initialization - runs before anything else
    ; Check Windows version
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK|MB_ICONSTOP "Workflow Capture requires Windows 10 or later."
        Abort
    ${EndIf}
!macroend

!macro customInit
    ; Custom initialization after GUI init
!macroend

!macro customInstall
    ; Custom installation steps after files are copied
    ; No external dependencies required - standalone recorder
    DetailPrint "Installation complete!"
!macroend

!macro customInstallMode
    ; Per-machine installation (all users) - required for NinjaRMM/SYSTEM deployments
    ; Remove per-user forcing to allow proper Program Files installation
!macroend

!macro customUnInstall
    ; Custom uninstall steps
    
    ; Kill the app if running
    nsExec::ExecToLog 'taskkill /F /IM "Workflow Capture.exe" 2>nul'
    
    DetailPrint "Application uninstalled."
!macroend

!macro customRemoveFiles
    ; Custom file removal - called before default file removal
!macroend

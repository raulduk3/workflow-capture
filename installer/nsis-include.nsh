; Workflow Capture - NSIS Include Script
; This is included by electron-builder's NSIS target
; Configured for TRUE MACHINE-WIDE install (Program Files + HKLM)

!include "FileFunc.nsh"
!include "WinVer.nsh"

; ============================================
; Custom Installation Macros
; ============================================

!macro customHeader
    ; Custom header - runs at the start
    !system "echo Building Workflow Capture installer (per-machine)..."
!macroend

!macro preInit
    ; Pre-initialization - runs before anything else
    ; Check Windows version
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK|MB_ICONSTOP "Workflow Capture requires Windows 10 or later."
        Abort
    ${EndIf}
    
    ; FORCE per-machine install context from the very start
    ; This ensures registry writes go to HKLM, not HKCU
    SetShellVarContext all
    
    ; Set install directory to Program Files (machine-wide location)
    StrCpy $INSTDIR "$PROGRAMFILES64\Workflow Capture"
!macroend

!macro customInit
    ; Custom initialization after GUI init
    ; Reinforce per-machine context
    SetShellVarContext all
    StrCpy $INSTDIR "$PROGRAMFILES64\Workflow Capture"
!macroend

!macro customInstall
    ; Custom installation steps after files are copied
    ; Ensure we're in per-machine context for shortcut creation
    SetShellVarContext all
    
    ; Write install location to HKLM for discovery
    WriteRegStr HKLM "Software\Layer7Systems\WorkflowCapture" "InstallPath" "$INSTDIR"
    WriteRegStr HKLM "Software\Layer7Systems\WorkflowCapture" "Version" "${VERSION}"
    
    DetailPrint "Installed to: $INSTDIR"
    DetailPrint "Registry: HKLM\Software\Layer7Systems\WorkflowCapture"
    DetailPrint "Installation complete!"
!macroend

!macro customInstallMode
    ; Force per-machine installation (all users) - required for NinjaRMM/SYSTEM deployments
    ; This is THE critical macro for electron-builder's NSIS
    SetShellVarContext all
    StrCpy $INSTDIR "$PROGRAMFILES64\Workflow Capture"
!macroend

!macro customUnInstall
    ; Custom uninstall steps
    SetShellVarContext all
    
    ; Kill the app if running
    nsExec::ExecToLog 'taskkill /F /IM "Workflow Capture.exe" 2>nul'
    
    ; Remove custom registry keys
    DeleteRegKey HKLM "Software\Layer7Systems\WorkflowCapture"
    
    DetailPrint "Application uninstalled."
!macroend

!macro customRemoveFiles
    ; Custom file removal - called before default file removal
    SetShellVarContext all
!macroend

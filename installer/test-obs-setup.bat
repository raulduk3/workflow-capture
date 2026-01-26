@echo off
REM ============================================
REM Test OBS Installation Script
REM Run this as Administrator to test the OBS setup
REM ============================================

echo.
echo ============================================
echo   L7S Workflow Analyzer - OBS Setup Test
echo ============================================
echo.
echo This will test the OBS installation script.
echo Make sure you're running as Administrator!
echo.
pause

REM Check for Admin rights
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Please run this script as Administrator
    echo Right-click and select "Run as administrator"
    pause
    exit /b 1
)

echo.
echo Running OBS installation and configuration...
echo.

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0install-obs.ps1" -SetAsDefault

echo.
if %ERRORLEVEL% equ 0 (
    echo ============================================
    echo   SUCCESS! OBS is configured correctly.
    echo ============================================
) else (
    echo ============================================
    echo   WARNING: OBS setup had issues (code: %ERRORLEVEL%)
    echo   Check the output above for details.
    echo ============================================
)

echo.
pause

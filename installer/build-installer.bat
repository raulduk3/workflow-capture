@echo off
REM L7S Workflow Capture - Windows Installer Build Script
REM This script builds the Electron app and creates the NSIS installer

setlocal EnableDelayedExpansion

echo.
echo ============================================
echo   L7S Workflow Capture - Build Installer
echo ============================================
echo.

REM Check for Node.js
where node >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: Node.js is not installed or not in PATH
    exit /b 1
)

REM Check for NSIS
where makensis >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo WARNING: NSIS not found in PATH
    echo Please install NSIS from https://nsis.sourceforge.io/
    echo Or use: winget install NSIS.NSIS
    echo.
    echo Continuing with electron-builder only...
    set USE_NSIS=0
) else (
    set USE_NSIS=1
)

REM Navigate to project root
cd /d "%~dp0\.."

echo [1/4] Installing dependencies...
call npm install
if %ERRORLEVEL% neq 0 (
    echo ERROR: npm install failed
    exit /b 1
)

echo.
echo [2/4] Building TypeScript...
call npm run build
if %ERRORLEVEL% neq 0 (
    echo ERROR: TypeScript build failed
    exit /b 1
)

echo.
echo [3/4] Building Electron app...
call npx electron-builder --win --dir
if %ERRORLEVEL% neq 0 (
    echo ERROR: electron-builder failed
    exit /b 1
)

if %USE_NSIS%==1 (
    echo.
    echo [4/4] Creating NSIS installer...
    cd installer
    makensis installer.nsi
    if %ERRORLEVEL% neq 0 (
        echo ERROR: NSIS build failed
        exit /b 1
    )
    cd ..
    echo.
    echo ============================================
    echo   Build Complete!
    echo ============================================
    echo.
    echo Installer: release\L7S-Workflow-Capture-Setup-1.0.0.exe
) else (
    echo.
    echo [4/4] Skipping NSIS installer (not installed)
    echo.
    echo ============================================
    echo   Build Complete!
    echo ============================================
    echo.
    echo Portable app: release\win-unpacked\
)

echo.
pause

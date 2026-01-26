@echo off
REM ============================================
REM L7S Workflow Analyzer - Build Script
REM Run this to create the installer for distribution
REM ============================================

echo.
echo ============================================
echo   L7S Workflow Analyzer - Build Script
echo ============================================
echo.

REM Check if running from correct directory
if not exist "..\package.json" (
    echo ERROR: Please run this script from the 'installer' directory
    echo        cd installer
    echo        build-for-boss.bat
    pause
    exit /b 1
)

cd ..

REM Check for Node.js
where node >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: Node.js is not installed or not in PATH
    echo        Please install Node.js from https://nodejs.org/
    pause
    exit /b 1
)

echo [1/4] Checking dependencies...
call npm install
if %ERRORLEVEL% neq 0 (
    echo ERROR: npm install failed
    pause
    exit /b 1
)

echo.
echo [2/4] Building TypeScript...
call npm run build
if %ERRORLEVEL% neq 0 (
    echo ERROR: Build failed
    pause
    exit /b 1
)

echo.
echo [3/4] Creating Windows installer...
call npm run dist:win
if %ERRORLEVEL% neq 0 (
    echo ERROR: Installer creation failed
    pause
    exit /b 1
)

echo.
echo [4/4] Build complete!
echo.
echo ============================================
echo   SUCCESS! Installer created at:
echo   release\L7S Workflow Analyzer-*-x64.exe
echo ============================================
echo.
echo You can now send this installer to your boss!
echo.

REM Open the release folder
explorer release

pause

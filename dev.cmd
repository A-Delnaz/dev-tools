@echo off
rem =================================================================
rem  dev.cmd - developer menu. The SAME file in every project.
rem  Double-click it, or run "dev.cmd pull", "dev.cmd run", "dev.cmd push" ...
rem
rem  The tool itself lives in github.com/A-Delnaz/dev-tools and is kept
rem  in %LOCALAPPDATA%\dev-tools. It is updated here on every start.
rem  Per-project settings live in dev.json next to this file.
rem =================================================================
chcp 65001 >nul
set "PSModulePath="
set "GIT_TERMINAL_PROMPT=0"
cd /d "%~dp0"
set "DEVTOOLS=%LOCALAPPDATA%\dev-tools"

where git >nul 2>nul
if errorlevel 1 (
    echo Git is not installed. Install it from https://git-scm.com and run dev.cmd again.
    pause
    exit /b 1
)

if exist "%DEVTOOLS%\.git" (
    git -C "%DEVTOOLS%" pull -q --ff-only >nul 2>nul
    if errorlevel 1 echo Could not update the dev tool ^(no internet?^). Using the copy on this PC.
) else (
    echo Downloading the dev tool...
    git clone -q --depth 1 https://github.com/A-Delnaz/dev-tools.git "%DEVTOOLS%"
    if errorlevel 1 (
        echo Download failed. Check the internet connection and try again.
        pause
        exit /b 1
    )
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DEVTOOLS%\dev.ps1" -Root "%~dp0." %*
set "DEV_EXIT=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %DEV_EXIT%

@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Reveric Windows Development

pushd "%~dp0" || (
    echo Could not open the Reveric project folder.
    pause
    exit /b 1
)

set "PATH=%PATH%;%LOCALAPPDATA%\FVM\fvm;%USERPROFILE%\.cargo\bin;%LOCALAPPDATA%\Pub\Cache\bin"
if defined PUB_CACHE set "PATH=%PATH%;%PUB_CACHE%\bin"

rem Build the Windows runner with its UTF-8 source encoding.
set "CL=/utf-8 %CL%"

where fvm >nul 2>&1
if errorlevel 1 (
    echo FVM was not found. Install FVM and make it available on PATH.
    goto failed
)

if not exist "build\depth-native\product-windows\bin\reveric-depth-native.exe" (
    echo Preparing the Windows depth runtime...
    call :prepare_depth
    if errorlevel 1 goto failed
)

call fvm flutter run -d windows
if errorlevel 1 goto failed

popd
exit /b 0

:prepare_depth
set "cmake_dir="
where cmake >nul 2>&1
if errorlevel 1 (
    for /f "usebackq delims=" %%I in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.CMake.Project -find Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`) do set "cmake_dir=%%~dpI"
)
if defined cmake_dir set "PATH=%cmake_dir%;%PATH%"
where cmake >nul 2>&1
if errorlevel 1 (
    echo CMake was not found. Install the Visual Studio C++ CMake tools or add CMake to PATH.
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "third\depth-native\prepare-product-windows.ps1"
exit /b %errorlevel%

:failed
set "exit_code=%errorlevel%"
echo.
echo Reveric failed to start. See the output above.
popd
pause
exit /b %exit_code%

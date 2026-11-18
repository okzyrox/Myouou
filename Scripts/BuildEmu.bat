@echo off
setlocal

set "ROOT=%~dp0.."

:: Dynarmic
:: call "%ROOT%\Scripts\BuildDynarmic.bat" Release || exit /b 1
:: just gonna assume its already built cause cmake is slow as hell.

:: Emu
dub build --arch=x86_64
@echo off
setlocal

set "ROOT=%~dp0.."

:: Dynarmic
call "%ROOT%\Scripts\BuildDynarmic.bat" Release || exit /b 1

:: Emu
dub build --arch=x86_64
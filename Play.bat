@echo off
rem Double-click to start Beasts and Bumpkins on Windows (after Install.bat).
setlocal
cd /d "%~dp0"
set "PY=python"
py -3 -c "import sys" >nul 2>nul && set "PY=py -3"
%PY% scripts\bb.py run %*
if errorlevel 1 pause

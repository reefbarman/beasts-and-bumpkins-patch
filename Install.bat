@echo off
rem Double-click to set up Beasts and Bumpkins on Windows.
rem It asks for your disc, then prepares, installs and (optionally) starts the game.
setlocal
cd /d "%~dp0"

call :findpython
if defined PY goto run

echo Python 3.9 or newer is needed and wasn't found.
where winget >nul 2>nul || goto nopython
choice /m "Install Python 3.12 now with winget"
if errorlevel 2 goto nopython
winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
call :findpython
if defined PY goto run

:nopython
echo Install Python 3 from https://www.python.org/downloads/ then double-click Install.bat again.
pause
exit /b 1

:run
%PY% scripts\bb.py setup %*
pause
exit /b

:findpython
set "PY="
py -3 -c "import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>nul && set "PY=py -3" && exit /b
python -c "import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>nul && set "PY=python"
exit /b

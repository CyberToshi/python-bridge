@echo off
rem ---------------------------------------------------------------------------
rem  Python Bridge Worker - Doppelklick-Starter fuer Windows.
rem  Oeffnet die Worker-App ohne Konsolenfenster (pythonw).
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

where pythonw >nul 2>nul
if %errorlevel%==0 (
    start "" pythonw "%~dp0worker_app.py"
    goto :eof
)

where pyw >nul 2>nul
if %errorlevel%==0 (
    start "" pyw -3 "%~dp0worker_app.py"
    goto :eof
)

where py >nul 2>nul
if %errorlevel%==0 (
    start "" py -3 "%~dp0worker_app.py"
    goto :eof
)

echo.
echo  Python 3 wurde nicht gefunden.
echo.
echo  Bitte Python 3 von https://www.python.org/downloads/ installieren
echo  und beim Setup "Add python.exe to PATH" aktivieren.
echo.
pause

@echo off
setlocal
cd /d "%~dp0"
set "DCC=%ProgramFiles(x86)%\Embarcadero\Studio\22.0\bin\dcc32.exe"
set "BRCC=%ProgramFiles(x86)%\Embarcadero\Studio\22.0\bin\brcc32.exe"
if not exist "%DCC%" (
  echo Delphi 11 dcc32.exe was not found. Edit the DCC path in this file.
  pause
  exit /b 1
)
"%BRCC%" AutoKey.rc
if errorlevel 1 (
  echo Icon resource compilation failed.
  pause
  exit /b 1
)
"%DCC%" -B -Q --codepage:65001 AutoKey.dpr
if errorlevel 1 (
  echo Compilation failed. See the error above.
  pause
  exit /b 1
)
echo Built AutoKey.exe successfully.
pause

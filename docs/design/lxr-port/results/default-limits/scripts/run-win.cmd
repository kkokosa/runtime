@echo off
rem usage: run-win.cmd <dll name in C:\lx-run\frame> <tagb> <log> <tlgb> [env file]
setlocal
set FR=C:\lx-run\frame
set DOTNET_gcServer=1
set DOTNET_GCPath=%FR%\%1
if not "%5"=="" call %5
echo start %date% %time% gc=%1 tagb=%2 tlgb=%4 > %3
%FR%\corerun.exe C:\lx-run\gcoom\GCPerfSim.dll -tc 28 -tagb %2 -tlgb %4 -lohar 0 -pohar 0 -sohsr 100-4000 -lohsr 102400-204800 -pohsr 100-204800 -sohsi 50 -lohsi 0 -pohsi 0 -sohpi 0 -lohpi 0 -sohfi 0 -lohfi 0 -pohfi 0 -ramb 20 -rlmb 2 -allocType reference -testKind time >> %3 2>&1
echo exit %ERRORLEVEL% %date% %time% >> %3

@echo off
rem Reconfigure the existing CoreCLR build tree with the Laxori option and build the Laxori targets.
rem usage: cmake-laxori.cmd <target> [<target> ...]
call "C:\Program Files\Microsoft Visual Studio\18\IntPreview\VC\Auxiliary\Build\vcvarsall.bat" amd64 >nul
set CMAKE="C:\Program Files\Microsoft Visual Studio\18\IntPreview\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set B=K:\artifacts\obj\coreclr\windows.x64.Release
%CMAKE% -DCLR_CMAKE_ENABLE_LAXORI_GC=1 %B% || exit /b 1
for %%T in (%*) do (
  %CMAKE% --build %B% --target %%T --parallel 6 || exit /b 1
)

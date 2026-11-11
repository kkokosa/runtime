@echo off
rem Rebuild gc_lxr targets in the Windows build tree of the K: worktree. usage: win-rebuild.cmd <target> [<target> ...]
call "C:\Program Files\Microsoft Visual Studio\18\IntPreview\VC\Auxiliary\Build\vcvarsall.bat" amd64 >nul
set CMAKE="C:\Program Files\Microsoft Visual Studio\18\IntPreview\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set B=K:\artifacts\obj\coreclr\windows.x64.Release
for %%T in (%*) do (
  %CMAKE% --build %B% --target %%T --parallel 8 || exit /b 1
)
echo WINREBUILD_OK

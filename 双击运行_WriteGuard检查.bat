@echo off
chcp 65001 >nul
title WriteGuard 接手入口（跑测试 + 列未完成项）
cd /d "%~dp0"

echo ================================================================
echo   WriteGuard 接手入口
echo ================================================================
echo   双击这个 = 跑一遍测试 + 列出还没做完的事。
echo   库本体只有一个文件：WriteGuard.psm1（复制走就能用）。
echo.

where pwsh >nul 2>nul
if errorlevel 1 (
  echo [错误] 找不到 pwsh ^(需要 PowerShell 7 或更高^)。
  echo         装一个：https://aka.ms/powershell
  echo.
  pause
  exit /b 2
)

pwsh -NoProfile -File "%~dp0Start-Here.ps1"
set WC=%ERRORLEVEL%
echo.
pause
exit /b %WC%

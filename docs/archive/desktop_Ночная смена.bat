@echo off
chcp 65001 >nul
rem Launcher for the game. Double-click to play.
rem Add --fresh to start from the beginning:  play.bat --fresh
title Ночная смена
cd /d "%~dp0"
if not exist "tools\Godot_v4.7.2-stable_win64.exe" (
  echo Не найден движок: tools\Godot_v4.7.2-stable_win64.exe
  echo Проверь, что папка проекта распакована целиком.
  pause
  exit /b 1
)
"tools\Godot_v4.7.2-stable_win64.exe" --path "%~dp0." %*

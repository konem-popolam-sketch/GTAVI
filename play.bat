@echo off
chcp 65001 >nul
rem Launcher for the game. Double-click to play.
rem Add --fresh to start from the beginning:  play.bat --fresh
title ГТА 6
cd /d "%~dp0"

set "ENGINE=tools\Godot_v4.7.2-stable_win64.exe"
set "ENGINE_CONSOLE=tools\Godot_v4.7.2-stable_win64_console.exe"
set "ENGINE_ZIP=tools\Godot_v4.7.2-stable_win64.exe.zip"

rem --- 1. Движок: если exe нет, но рядом лежит архив из репозитория, распаковать ---
if not exist "%ENGINE%" (
  if exist "%ENGINE_ZIP%" (
    echo Первый запуск: распаковываю движок Godot 4.7.2, подожди немного...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%~dp0%ENGINE_ZIP%' -DestinationPath '%~dp0tools' -Force"
  )
)

if not exist "%ENGINE%" (
  echo.
  echo Не найден движок: %ENGINE%
  echo Скачай Godot 4.7.2 ^(не .NET^) с https://godotengine.org/download/archive
  echo и положи Godot_v4.7.2-stable_win64.exe в папку tools рядом с этим файлом.
  echo.
  pause
  exit /b 1
)

rem --- 2. Импорт ресурсов: без него не находятся классы и текстуры, игра падает ---
if not exist ".godot\imported" (
  echo Первый запуск: импортирую ресурсы игры, это займёт 1-2 минуты...
  if exist "%ENGINE_CONSOLE%" (
    "%ENGINE_CONSOLE%" --headless --path "%~dp0." --import
  ) else (
    "%ENGINE%" --headless --path "%~dp0." --import
  )
  echo Импорт завершён.
)

rem --- 3. Запуск игры ---
"%ENGINE%" --path "%~dp0." %*

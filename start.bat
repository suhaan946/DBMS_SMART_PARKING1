@echo off
title SmartPark Launcher
echo ========================================================
echo               SmartPark Launcher
echo ========================================================
echo.

cd /d "%~dp0"

echo [1/3] Checking PostgreSQL 17...
netstat -ano | findstr 127.0.0.1:5432 >nul 2>&1
if %errorlevel% equ 0 (
    echo       PostgreSQL is already running on port 5432.
) else (
    echo       Starting PostgreSQL 17...
    if exist "C:\Users\ASUS\pgsql\data\postmaster.pid" (
        del /f /q "C:\Users\ASUS\pgsql\data\postmaster.pid" >nul 2>&1
    )
    "C:\Users\ASUS\pgsql\pgsql\bin\pg_ctl.exe" start -D "C:\Users\ASUS\pgsql\data" >nul 2>&1
    timeout /t 2 /nobreak >nul
)

echo [2/3] Starting SmartPark API Server...
start "" /b .venv\Scripts\uvicorn.exe app:app --port 8077

timeout /t 2 /nobreak >nul

echo [3/3] Opening SmartPark in your default browser...
start http://127.0.0.1:8077

echo.
echo ========================================================
echo  SmartPark is running at http://127.0.0.1:8077
echo  Admin credentials:
echo    Email:    admin@smartpark.in
echo    Password: Parking@123
echo ========================================================
echo.
pause

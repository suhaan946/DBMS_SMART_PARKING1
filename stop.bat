@echo off
title Stop SmartPark
echo Stopping SmartPark and PostgreSQL...
taskkill /f /im uvicorn.exe >nul 2>&1
"C:\Users\ASUS\pgsql\pgsql\bin\pg_ctl.exe" -D "C:\Users\ASUS\pgsql\data" stop >nul 2>&1
echo Services stopped.
pause

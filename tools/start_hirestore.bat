@echo off
chcp 65001 >nul
cd /d "%~dp0"
set PYTHONUTF8=1
echo HiRestore PC receiver - keep this window open.
echo Phone and PC must use the same Wi-Fi.
echo If Windows Firewall asks, allow Python on private networks.
echo Use the LAN address printed below in the phone app.
python -u report_server_hirestore.py
if errorlevel 1 goto :error
pause
exit /b 0

:error
echo HiRestore receiver failed to start on port 8719.
echo Check whether another receiver is already using the port.
pause
exit /b 1

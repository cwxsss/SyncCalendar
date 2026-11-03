@echo off
set "DEVECO_DIR=E:\software\DevEco Studio"
if not exist "%DEVECO_DIR%" set "DEVECO_DIR=D:\DevEco\DevEco Studio 26.0.0.821"

set "JAVA_HOME=%DEVECO_DIR%\jbr"
set "NODE_HOME=%DEVECO_DIR%\tools\node"
set "DEVECO_SDK_HOME=%DEVECO_DIR%\sdk"
set "PATH=%DEVECO_DIR%\jbr\bin;%DEVECO_DIR%\tools\node;%PATH%"

set "SRC_DIR=%~dp0"
set "BUILD_DIR=D:\SyncCalendar_Project"

robocopy "%SRC_DIR:~0,-1%" "%BUILD_DIR%" /E /XD .hvigor build /XF *.log build_hap.bat >nul

cd /d "%BUILD_DIR%"
call "%DEVECO_DIR%\tools\hvigor\bin\hvigorw.bat" assembleApp --mode project -p product=default -p buildMode=debug --no-daemon

if exist "%BUILD_DIR%\entry\build\default\outputs\default\app\entry-default.hap" (
    copy /y "%BUILD_DIR%\entry\build\default\outputs\default\app\entry-default.hap" "%SRC_DIR%entry-default.hap"
    echo Build HAP successfully: %SRC_DIR%entry-default.hap
)
if exist "%BUILD_DIR%\build\outputs\default\SyncCalendar_Project-default-unsigned.app" (
    copy /y "%BUILD_DIR%\build\outputs\default\SyncCalendar_Project-default-unsigned.app" "%SRC_DIR%entry-default.app"
    echo Build APP successfully: %SRC_DIR%entry-default.app
)
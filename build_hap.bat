@echo off
set "JAVA_HOME=D:\DevEco\DevEco Studio 26.0.0.821\jbr"
set "NODE_HOME=D:\DevEco\DevEco Studio 26.0.0.821\tools\node"
set "DEVECO_SDK_HOME=D:\DevEco\DevEco Studio 26.0.0.821\sdk"
set "PATH=D:\DevEco\DevEco Studio 26.0.0.821\jbr\bin;D:\DevEco\DevEco Studio 26.0.0.821\tools\node;%PATH%"

set "SRC_DIR=%~dp0"
set "BUILD_DIR=D:\SyncCalendar_Project"

robocopy "%SRC_DIR:~0,-1%" "%BUILD_DIR%" /E /XD .hvigor build /XF *.log build_hap.bat >nul

cd /d "%BUILD_DIR%"
call "D:\DevEco\DevEco Studio 26.0.0.821\tools\hvigor\bin\hvigorw.bat" assembleApp --mode project -p product=default -p buildMode=debug --no-daemon

if exist "%BUILD_DIR%\entry\build\default\outputs\default\app\entry-default.hap" (
    copy /y "%BUILD_DIR%\entry\build\default\outputs\default\app\entry-default.hap" "%SRC_DIR%entry-default.hap"
    echo Build HAP successfully: %SRC_DIR%entry-default.hap
)

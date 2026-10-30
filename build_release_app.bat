@echo off
set "JAVA_HOME=E:\software\DevEco Studio\jbr"
set "NODE_HOME=E:\software\DevEco Studio\tools\node"
set "DEVECO_SDK_HOME=E:\software\DevEco Studio\sdk"
set "PATH=E:\software\DevEco Studio\jbr\bin;E:\software\DevEco Studio\tools\node;%PATH%"
cd /d "E:\syncCalendar"
call "E:\software\DevEco Studio\tools\hvigor\bin\hvigorw.bat" --stop-daemon
call "E:\software\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleApp --mode project -p product=default -p buildMode=release --no-daemon

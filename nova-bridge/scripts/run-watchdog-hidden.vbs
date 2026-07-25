' Launches watchdog-bridge.ps1 with no visible window. Used as the Task
' Scheduler action so the watchdog starts at logon without a console flash.
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "watchdog-bridge.ps1")
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & psScript & """"
' 0 = hidden window, False = don't wait (watchdog runs forever).
shell.Run cmd, 0, False

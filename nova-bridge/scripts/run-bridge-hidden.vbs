' Launches start-bridge.ps1 with no visible window. Used as the Task Scheduler
' action so the bridge starts at logon without flashing a console window.
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "start-bridge.ps1")
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & psScript & """"
' 0 = hidden window, False = don't wait for it to finish.
shell.Run cmd, 0, False

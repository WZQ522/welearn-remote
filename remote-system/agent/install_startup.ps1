$ErrorActionPreference = "Stop"

$AgentDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentScript = Join-Path $AgentDirectory "agent.py"
$PythonLauncher = (Get-Command py.exe).Source
$TaskName = "UnifiedTaskAgent"

$Action = New-ScheduledTaskAction `
    -Execute $PythonLauncher `
    -Argument "-3 `"$AgentScript`"" `
    -WorkingDirectory $AgentDirectory
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description "Fetch Supabase tasks and run the local processor" `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -RunLevel Limited `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed and started $TaskName"


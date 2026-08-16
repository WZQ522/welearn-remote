$ErrorActionPreference = "Stop"
$TaskName = "UnifiedTaskAgent"
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed $TaskName"
} else {
    Write-Host "$TaskName is not installed"
}


Write-Host "--- Estado del sistema ---"
Write-Host "Nombre del equipo: $env:COMPUTERNAME"

$ip = (Get-NetIPAddress | Where-Object InterfaceAlias -eq "Ethernet 2" | Where-Object AddressFamily -eq "IPv4").IPAddress
Write-Host "IP Actual: $ip"
Write-Host "Espacio en disco (C:)"
Get-PSDrive C | Select-Object @{n='Usado(GB)';e=
{[math]::round($_.Used/1GB,2)}},@{n='Libre(GB)';e=
{[math]::round($_.Free/1GB,2)}}
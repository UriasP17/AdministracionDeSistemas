Write-Host "Iniciando servicio de Identidad de Aplicacion (Obligatorio para AppLocker)..." -ForegroundColor Cyan
Set-Service -Name AppIDSvc -StartupType Automatic
Start-Service -Name AppIDSvc

Write-Host "Extrayendo el Hash del Bloc de Notas (Notepad)..." -ForegroundColor Yellow
$NotepadInfo = Get-AppLockerFileInformation -Path "C:\Windows\System32\notepad.exe"

Write-Host "Generando regla de bloqueo para los No Cuates..." -ForegroundColor Yellow

$GrupoBloqueo = "REPROBADOS\No Cuates"

$DefaultRules = New-AppLockerPolicy -RuleType Path,Publisher,Hash -User Everyone -Xml -Optimize


$PoliticaNotepad = New-AppLockerPolicy -RuleType Hash -User $GrupoBloqueo -Action Deny -FileInformation $NotepadInfo 

Write-Host "Aplicando la politica de AppLocker..." -ForegroundColor Cyan
Set-AppLockerPolicy -PolicyObject $PoliticaNotepad -Merge

Write-Host "Compartiendo carpetas FSRM en la red..." -ForegroundColor Yellow

try { New-SmbShare -Name "Cuates" -Path "C:\Compartido\Cuates" -FullAccess "Everyone" -ErrorAction Stop } catch {}
try { New-SmbShare -Name "NoCuates" -Path "C:\Compartido\NoCuates" -FullAccess "Everyone" -ErrorAction Stop } catch {}

Write-Host "Activando Forzar Cierre de Sesion al expirar horario..." -ForegroundColor Yellow

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "EnableForcedLogOff" -Value 1 -Type DWord

Write-Host "¡AppLocker, Carpetas Compartidas y Horarios forzados listos al 100%!" -ForegroundColor Green

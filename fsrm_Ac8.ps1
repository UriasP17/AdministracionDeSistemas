Write-Host "Instalando FSRM..." -ForegroundColor Cyan
Install-WindowsFeature -Name FS-Resource-Manager -IncludeManagementTools


Import-Module FileServerResourceManager

Write-Host "Creando carpetas físicas en C:\Compartido..." -ForegroundColor Cyan
$rutaCuates = "C:\Compartido\Cuates"
$rutaNoCuates = "C:\Compartido\NoCuates"

if (-not (Test-Path $rutaCuates)) { New-Item -ItemType Directory -Path $rutaCuates | Out-Null }
if (-not (Test-Path $rutaNoCuates)) { New-Item -ItemType Directory -Path $rutaNoCuates | Out-Null }

Write-Host "Aplicando Cuotas de Disco Estrictas..." -ForegroundColor Yellow

New-FsrmQuota -Path $rutaCuates -Size 10MB -Template "10 MB Limit" -Description "Cuota estricta Cuates" -ErrorAction SilentlyContinue

New-FsrmQuota -Path $rutaNoCuates -Size 5MB -Template "10 MB Limit" -Description "Cuota estricta No Cuates" -ErrorAction SilentlyContinue
Set-FsrmQuota -Path $rutaNoCuates -Size 5MB

Write-Host "Configurando el Bloqueo de Archivos (File Screen)..." -ForegroundColor Yellow

New-FsrmFileGroup -Name "Prohibidos Practica" -IncludePattern @("*.mp3", "*.mp4", "*.exe", "*.msi") -ErrorAction SilentlyContinue


$EventoFSRM = New-FsrmAction -Type Event -EventType Warning -Body "BLOQUEO FSRM: El usuario [Source Io Owner] intentó guardar el archivo prohibido [Source File Path] en el servidor."


New-FsrmFileScreen -Path $rutaCuates -Active $true -FileGroup "Prohibidos Practica" -Notification $EventoFSRM -ErrorAction SilentlyContinue
New-FsrmFileScreen -Path $rutaNoCuates -Active $true -FileGroup "Prohibidos Practica" -Notification $EventoFSRM -ErrorAction SilentlyContinue

Write-Host "¡FSRM configurado al 100%!" -ForegroundColor Green

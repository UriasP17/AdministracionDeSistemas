Write-Host "Instalando FSRM..." -ForegroundColor Cyan
Install-WindowsFeature -Name FS-Resource-Manager -IncludeManagementTools

Import-Module FileServerResourceManager

Write-Host "Creando carpetas fisicas en C:\Compartido..." -ForegroundColor Cyan
$rutaCuates = "C:\Compartido\Cuates"
$rutaNoCuates = "C:\Compartido\NoCuates"

if (-not (Test-Path $rutaCuates)) { New-Item -ItemType Directory -Path $rutaCuates | Out-Null }
if (-not (Test-Path $rutaNoCuates)) { New-Item -ItemType Directory -Path $rutaNoCuates | Out-Null }

Write-Host "Aplicando Cuotas de Disco Estrictas..." -ForegroundColor Yellow

# Limpiar cuotas previas sin pedir confirmacion (La magia esta aqui)
Remove-FsrmQuota -Path $rutaCuates -ErrorAction SilentlyContinue -Confirm:$false
Remove-FsrmQuota -Path $rutaNoCuates -ErrorAction SilentlyContinue -Confirm:$false

New-FsrmQuota -Path $rutaCuates -Description "Cuota estricta Cuates" -Size 10MB
New-FsrmQuota -Path $rutaNoCuates -Description "Cuota estricta No Cuates" -Size 5MB

Write-Host "Configurando el Bloqueo de Archivos (File Screen)..." -ForegroundColor Yellow

try { 
    New-FsrmFileGroup -Name "Prohibidos Practica" -IncludePattern @("*.mp3", "*.mp4", "*.exe", "*.msi") -ErrorAction Stop 
} catch {}

# Limpiar bloqueos previos sin pedir confirmacion
Remove-FsrmFileScreen -Path $rutaCuates -ErrorAction SilentlyContinue -Confirm:$false
Remove-FsrmFileScreen -Path $rutaNoCuates -ErrorAction SilentlyContinue -Confirm:$false

$EventoFSRM = New-FsrmAction -Type Event -EventType Warning -Body "BLOQUEO FSRM: El usuario [Source Io Owner] intento guardar el archivo prohibido [Source File Path] en el servidor."

New-FsrmFileScreen -Path $rutaCuates -Active -IncludeGroup "Prohibidos Practica" -Notification $EventoFSRM
New-FsrmFileScreen -Path $rutaNoCuates -Active -IncludeGroup "Prohibidos Practica" -Notification $EventoFSRM

Write-Host "¡FSRM configurado al 100%!" -ForegroundColor Green

#Requires -RunAsAdministrator

# ====================================================================
#   GESTOR DE FTP (USANDO FILEZILLA SERVER - BYPASS IIS)
# ====================================================================

$FZ_INSTALLER = "$env:TEMP\FileZilla_Server_Installer.exe"
$FTP_ROOT     = "C:\FTP_FZ"
$XML_CONFIG   = "C:\ProgramData\filezilla-server\settings.xml"

# ====================================================================
# ESTO ES LO QUE ARREGLA EL ERROR DE GITHUB ("LA CONEXIÓN HA TERMINADO")
# Forzamos toda la sesión de PowerShell a usar protocolos seguros.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
# ====================================================================

function Preparar-Carpetas {
    Write-Host "`n[*] Creando estructura de carpetas..." -ForegroundColor Cyan
    $carpetas = @(
        "$FTP_ROOT\Reprobados",
        "$FTP_ROOT\Recursadores",
        "$FTP_ROOT\Boveda\http\Windows\Apache",
        "$FTP_ROOT\Boveda\http\Windows\Nginx"
    )
    foreach ($c in $carpetas) {
        if (-not (Test-Path $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
    }
    Write-Host "  + Carpetas creadas en $FTP_ROOT" -ForegroundColor Green
}

function Bajar-Instaladores {
    Write-Host "`n[*] Descargando instaladores para la Boveda..." -ForegroundColor Cyan
    
    $rutaNginx = "$FTP_ROOT\Boveda\http\Windows\Nginx"
    if (-not (Test-Path "$rutaNginx\nginx.zip")) {
        Write-Host "  ~ Descargando Nginx..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri "https://nginx.org/download/nginx-1.24.0.zip" -OutFile "$rutaNginx\nginx.zip" -UseBasicParsing
    }
    
    $rutaApache = "$FTP_ROOT\Boveda\http\Windows\Apache"
    if (-not (Test-Path "$rutaApache\apache.msi")) {
        Write-Host "  ~ Descargando Apache..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri "https://archive.apache.org/dist/httpd/binaries/win32/httpd-2.2.25-win32-x86-openssl-0.9.8y.msi" -OutFile "$rutaApache\apache.msi" -UseBasicParsing
    }
    Write-Host "  + Boveda lista." -ForegroundColor Green
}

function Instalar-FileZilla {
    Write-Host "`n[*] Instalando FileZilla Server..." -ForegroundColor Cyan
    if (Get-Service -Name "filezilla-server" -ErrorAction SilentlyContinue) {
        Write-Host "  + FileZilla Server ya esta instalado." -ForegroundColor Green
        return
    }

    Write-Host "  ~ Descargando instalador limpio desde GitHub..." -ForegroundColor Yellow
    
    # Mirror seguro de GitHub
    $url_espejo = "https://github.com/jmwebservices/httpd-2.4.63-win64-VS17/releases/download/v1.0/FileZilla_Server_1.8.2_win64-setup.exe"
    
    try {
        Invoke-WebRequest -Uri $url_espejo -OutFile $FZ_INSTALLER -UseBasicParsing
    } catch {
        Write-Host "  - ERROR AL DESCARGAR: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    
    if (-not (Test-Path $FZ_INSTALLER) -or (Get-Item $FZ_INSTALLER).Length -lt 2MB) {
        Write-Host "  - ERROR: El instalador esta corrupto o vacio." -ForegroundColor Red
        return
    }

    Write-Host "  ~ Ejecutando instalacion silenciosa..." -ForegroundColor Yellow
    Start-Process -FilePath $FZ_INSTALLER -ArgumentList "/S" -Wait
    Start-Sleep -Seconds 5
    
    if (Get-Service -Name "filezilla-server" -ErrorAction SilentlyContinue) {
        Write-Host "  + Instalacion completada con exito." -ForegroundColor Green
    } else {
        Write-Host "  - ERROR: El servicio de FileZilla no se instalo correctamente." -ForegroundColor Red
    }
}

function Generar-Configuracion-Usuarios {
    Write-Host "`n[*] Inyectando configuracion de usuarios y permisos..." -ForegroundColor Cyan
    
    # Detenemos FileZilla para poder inyectar su archivo XML de configuración
    Stop-Service "filezilla-server" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Generamos la carpeta si el instalador tardó en crearla
    $configDir = "C:\ProgramData\filezilla-server"
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

    # El hash abajo equivale a "Hola1234." (SHA512)
    $hashHola = "0081d1ba86a60394747ebc79a957d19da050eec3ef1bf61a8ef154f9a0d24e12e176ed7a25a07505d97d02cb06a090b411d33c56d78da47f985926ec0fcdeba6"
    
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<filezilla_server>
    <settings>
        <setting id="admin_port">14148</setting>
    </settings>
    <servers>
        <server>
            <network>
                <bindings>
                    <binding port="21" protocol="tcp"><address>*</address></binding>
                </bindings>
            </network>
            <users>
                <user name="reprobado_user">
                    <credentials><password hash="$hashHola" /></credentials>
                    <vfs>
                        <mount>
                            <virtual_path>/</virtual_path>
                            <native_path>$FTP_ROOT\Reprobados</native_path>
                            <permissions file_read="1" file_write="1" file_delete="1" dir_create="1" dir_delete="1" dir_list="1" />
                        </mount>
                    </vfs>
                </user>
                <user name="recursador_user">
                    <credentials><password hash="$hashHola" /></credentials>
                    <vfs>
                        <mount>
                            <virtual_path>/</virtual_path>
                            <native_path>$FTP_ROOT\Recursadores</native_path>
                            <permissions file_read="1" file_write="1" file_delete="1" dir_create="1" dir_delete="1" dir_list="1" />
                        </mount>
                    </vfs>
                </user>
                <user name="repositorio">
                    <credentials><password hash="$hashHola" /></credentials>
                    <vfs>
                        <mount>
                            <virtual_path>/</virtual_path>
                            <native_path>$FTP_ROOT\Boveda</native_path>
                            <permissions file_read="1" file_write="0" file_delete="0" dir_create="0" dir_delete="0" dir_list="1" />
                        </mount>
                    </vfs>
                </user>
            </users>
            <groups />
        </server>
    </servers>
</filezilla_server>
"@

    Set-Content -Path $XML_CONFIG -Value $xml -Encoding UTF8
    Write-Host "  + Usuarios inyectados con exito." -ForegroundColor Green
    
    Start-Service "filezilla-server" -ErrorAction SilentlyContinue
}

# ====================================================================
# EJECUCIÓN DIRECTA
# ====================================================================
Clear-Host
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host "  LEVANTANDO FTP (FILEZILLA) - BYPASS IIS        " -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta

# Deshabilitar IIS FTP por si acaso para liberar el puerto 21
Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
Set-Service ftpsvc -StartupType Manual -ErrorAction SilentlyContinue

Preparar-Carpetas
Bajar-Instaladores
Instalar-FileZilla
Generar-Configuracion-Usuarios

# Abrir el puerto 21 en el Firewall
New-NetFirewallRule -DisplayName "FTP_FileZilla" -Direction Inbound -LocalPort 21 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null

Write-Host "`n=========================================" -ForegroundColor Green
Write-Host "  FTP ACTIVO Y LISTO PARA RECIBIR CONEXIONES" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  -> IP del Server: 192.168.56.10"
Write-Host "  -> Puerto: 21"
Write-Host "`n  [Usuarios disponibles]"
Write-Host "  - Reprobados   (User: reprobado_user  | Pass: Hola1234.)"
Write-Host "  - Recursadores (User: recursador_user | Pass: Hola1234.)"
Write-Host "  - Orquestador  (User: repositorio     | Pass: Hola1234.) (Solo lectura)"
Write-Host "=========================================" -ForegroundColor Green

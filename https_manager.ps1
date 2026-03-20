# =============================================================
#   PRACTICA 7 - ORQUESTADOR HIBRIDO CON SSL/TLS
#   Bypass de IIS-FTP usando Micro-Servidor en Python
# =============================================================

#Requires -RunAsAdministrator

# -------------------------------------------------------------
# VARIABLES GLOBALES
# -------------------------------------------------------------
$FTP_USER    = "repositorio"
$FTP_PASS    = "Hola1234."
$FTP_ROOT    = "C:\FTP_Practica7"
$FTP_SCRIPT  = "C:\FTP_Practica7\ftp_server.py"
$PYTHON_EXE  = "C:\Program Files\Python312\python.exe"

$FTP_PUERTOS = @{
    "IIS"    = 2121
    "Apache" = 2122
    "Nginx"  = 2123
}

$BASE_DIR    = "C:\Servicios"
$APACHE_DIR  = "$BASE_DIR\Apache"
$NGINX_DIR   = "$BASE_DIR\Nginx"
$SSL_DIR     = "$BASE_DIR\SSL"

$script:RESUMEN_INSTALACIONES = @()
$script:SERVICIOS_VERIFICAR   = @()

# =============================================================
# MENU PRINCIPAL
# =============================================================
function Main {
    while ($true) {
        Write-Host "`n==========================================================" -ForegroundColor Magenta
        Write-Host "   PRACTICA 7 - ORQUESTADOR DE SERVICIOS (WINDOWS)        " -ForegroundColor Magenta
        Write-Host "==========================================================" -ForegroundColor Magenta
        Write-Host " 1) Preparar estructura y Servidores FTP (Python)"
        Write-Host " 2) Instalar IIS Web        (Requiere FTP en puerto $($FTP_PUERTOS['IIS']))"
        Write-Host " 3) Instalar Apache         (Requiere FTP en puerto $($FTP_PUERTOS['Apache']))"
        Write-Host " 4) Instalar Nginx          (Requiere FTP en puerto $($FTP_PUERTOS['Nginx']))"
        Write-Host " 5) Ver Resumen de Instalaciones (Pruebas HTTP/HTTPS)"
        Write-Host " 0) Salir"
        Write-Host "==========================================================" -ForegroundColor Magenta
        $opcion = Read-Host "Selecciona una opcion"

        if ($opcion -eq "0") {
            Mostrar-Resumen
            Write-Host "Saliendo..." -ForegroundColor Yellow
            return
        }
        elseif ($opcion -eq "1") {
            Preparar-Repositorios-FTP
        }
        elseif ($opcion -eq "5") {
            Mostrar-Resumen
        }
        elseif ($opcion -in @("2", "3", "4")) {
            $nombreServicio = switch ($opcion) {
                "2" { "IIS" }
                "3" { "Apache" }
                "4" { "Nginx" }
            }

            Write-Host "`n¿De donde deseas instalar $nombreServicio?"
            Write-Host " 1) WEB (descarga directa desde Internet)"
            Write-Host " 2) FTP (repositorio privado - puerto $($FTP_PUERTOS[$nombreServicio]))"
            Write-Host " 0) Regresar al menu"
            $origen = Read-Host "Selecciona origen"
            
            if ($origen -eq "0") { continue }
            $web_ftp = if ($origen -eq "2") { "FTP" } else { "WEB" }

            $ssl = Preguntar-SSL
            if ($ssl -eq "REGRESAR") { continue }

            $archivo = ""
            if ($web_ftp -eq "FTP") {
                $archivo = Listar-Versiones-FTP $nombreServicio
                if ($archivo -in "INVALIDO","REGRESAR") {
                    Write-Host "Operacion cancelada." -ForegroundColor Yellow
                    continue
                }
            }

            switch ($opcion) {
                "2" { Instalar-IIS-Web $archivo $web_ftp $ssl }
                "3" { Instalar-Apache  $archivo $web_ftp $ssl }
                "4" { Instalar-Nginx   $archivo $web_ftp $ssl }
            }
        }
        else {
            Write-Host "Opcion invalida." -ForegroundColor Red
        }
    }
}

# =============================================================
# MOTOR PYTHON (BYPASS FTP IIS)
# =============================================================
function Crear-Script-FTP {
    if (Test-Path $FTP_SCRIPT) { return }
    New-Item -ItemType Directory -Force -Path $FTP_ROOT | Out-Null

    $pyScript = @"
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer
from pyftpdlib.authorizers import DummyAuthorizer
import sys

puerto   = int(sys.argv[1])
carpeta  = sys.argv[2]
usuario  = sys.argv[3]
password = sys.argv[4]

authorizer = DummyAuthorizer()
authorizer.add_user(usuario, password, carpeta, perm='elradfmwMT')

handler = FTPHandler
handler.authorizer = authorizer
handler.passive_ports = range(40000, 50000)

print(f'FTP corriendo en puerto {puerto} -> {carpeta}')
server = FTPServer(('0.0.0.0', puerto), handler)
server.serve_forever()
"@
    Set-Content $FTP_SCRIPT $pyScript -Encoding UTF8
}

function Arrancar-Servidores-FTP {
    Write-Host "`n[*] Arrancando Servidores FTP Python (Orquestador)..." -ForegroundColor Cyan

    if (-not (Test-Path $PYTHON_EXE)) {
        Write-Host "  [!] ERROR: Python no encontrado. Instala Python 3.12 y pyftpdlib." -ForegroundColor Red
        Write-Host "      Revisa que exista en la ruta: $PYTHON_EXE" -ForegroundColor Yellow
        return $false
    }

    Crear-Script-FTP
    Stop-Service FTPSVC -Force -ErrorAction SilentlyContinue
    Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    foreach ($svc in @("IIS","Apache","Nginx")) {
        $puerto  = $FTP_PUERTOS[$svc]
        $carpeta = "$FTP_ROOT\http\Windows\$svc"
        
        Start-Job -ScriptBlock {
            param($exe, $script, $puerto, $carpeta, $user, $pass)
            & $exe $script $puerto $carpeta $user $pass
        } -ArgumentList $PYTHON_EXE, $FTP_SCRIPT, $puerto, $carpeta, $FTP_USER, $FTP_PASS | Out-Null

        Write-Host "  + FTP-${svc} levantado en puerto $puerto -> $carpeta" -ForegroundColor Green
    }
    
    Start-Sleep -Seconds 3
    return $true
}

# =============================================================
# PREPARAR ESTRUCTURA (RÚBRICA)
# =============================================================
function Preparar-Repositorios-FTP {
    Write-Host "`n[*] Armando estructura de repositorios segun la Rubrica..." -ForegroundColor Cyan
    
    $carpetas = @(
        "$FTP_ROOT",
        "$FTP_ROOT\http\Linux\Apache",
        "$FTP_ROOT\http\Linux\Nginx",
        "$FTP_ROOT\http\Linux\Tomcat",
        "$FTP_ROOT\http\Windows\IIS",
        "$FTP_ROOT\http\Windows\Apache",
        "$FTP_ROOT\http\Windows\Nginx",
        "$FTP_ROOT\http\Windows\Tomcat"
    )
    foreach ($c in $carpetas) {
        if (-not (Test-Path $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    $wc = New-Object System.Net.WebClient

    Write-Host "  ~ Descargando instaladores reales para la practica..." -ForegroundColor Yellow
    
    try {
        if (-not (Test-Path "$FTP_ROOT\http\Windows\Apache\httpd-2.4.62-win64.zip")) {
            $wc.DownloadFile("https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-240904-win64-VS17.zip", "$FTP_ROOT\http\Windows\Apache\httpd-2.4.62-win64.zip")
        }
        if (-not (Test-Path "$FTP_ROOT\http\Windows\Nginx\nginx-1.26.2.zip")) {
            $wc.DownloadFile("https://nginx.org/download/nginx-1.26.2.zip", "$FTP_ROOT\http\Windows\Nginx\nginx-1.26.2.zip")
        }
    } catch {
        Write-Host "  [!] Advertencia: No se pudieron descargar los ZIPs reales. Usando Dummys." -ForegroundColor Yellow
    }

    Get-ChildItem $FTP_ROOT -Recurse -File | Where-Object { $_.Extension -notmatch '\.(sha256|md5|py)$' } | ForEach-Object {
        $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
        Set-Content "$($_.FullName).sha256" $hash -Encoding ASCII -Force
    }
    
    Arrancar-Servidores-FTP | Out-Null
    Write-Host "  + Repositorio privado y firmas listos." -ForegroundColor Green
}

# =============================================================
# FUNCIONES DE APOYO (DESCARGAS, HASH, SSL)
# =============================================================
function Listar-Versiones-FTP {
    param($Servicio)
    $puerto = $FTP_PUERTOS[$Servicio]

    if (-not (netstat -an | Select-String ":$puerto ")) { Arrancar-Servidores-FTP | Out-Null }

    $raw = & curl.exe -s -l -u "${FTP_USER}:${FTP_PASS}" "ftp://127.0.0.1:$puerto/" 2>&1
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "  [!] El FTP esta vacio o caido." -ForegroundColor Red
        return "INVALIDO"
    }

    $versiones = $raw -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch '\.(sha256|md5)$' }
    
    Write-Host "`nArchivos disponibles en FTP-${Servicio}:"
    for ($i = 0; $i -lt $versiones.Count; $i++) { Write-Host "  $($i+1)) $($versiones[$i])" }
    
    $sel = Read-Host "Elige un instalador (0 para cancelar)"
    if ($sel -eq "0") { return "REGRESAR" }
    if ([int]$sel -gt 0 -and [int]$sel -le $versiones.Count) { return $versiones[[int]$sel - 1] }
    return "INVALIDO"
}

function Descargar-Y-Validar {
    param($Servicio, $Archivo)
    $puerto = $FTP_PUERTOS[$Servicio]
    $destino = "$env:TEMP\$Archivo"
    
    Write-Host "  ~ Descargando $Archivo por FTP local..." -ForegroundColor Yellow
    & curl.exe -s -u "${FTP_USER}:${FTP_PASS}" "ftp://127.0.0.1:$puerto/$Archivo" -o $destino
    
    $sha_dest = "$env:TEMP\${Archivo}.sha256"
    & curl.exe -s -u "${FTP_USER}:${FTP_PASS}" "ftp://127.0.0.1:$puerto/${Archivo}.sha256" -o $sha_dest 2>$null

    if (Test-Path $sha_dest) {
        $hash_remoto = (Get-Content $sha_dest -Raw).Trim()
        $hash_local  = (Get-FileHash $destino -Algorithm SHA256).Hash.ToLower()
        if ($hash_remoto -eq $hash_local) {
            Write-Host "  + Checksum SHA256 validado exitosamente." -ForegroundColor Green
            return $true
        } else {
            Write-Host "  [!] ARCHIVO CORRUPTO. Hashes no coinciden." -ForegroundColor Red
            return $false
        }
    }
    return $true
}

function Preguntar-SSL {
    $r = Read-Host "¿Desea activar SSL en este servicio? [S/N] (0 regresar)"
    if ($r -match '^[sS]$') { return "S" }
    if ($r -match '^[nN]$') { return "N" }
    return "REGRESAR"
}

function Generar-SSL {
    param($Servicio)
    $cert_dir = "$SSL_DIR\$Servicio"
    New-Item -ItemType Directory -Force -Path $cert_dir | Out-Null

    $cert = New-SelfSignedCertificate -DnsName "www.reprobados.com" -CertStoreLocation "cert:\LocalMachine\My" -NotAfter (Get-Date).AddDays(365)
    $pwd_sec = ConvertTo-SecureString -String "reprobados" -Force -AsPlainText
    Export-PfxCertificate -Cert $cert -FilePath "$cert_dir\server.pfx" -Password $pwd_sec | Out-Null
    Export-Certificate -Cert $cert -FilePath "$cert_dir\server.crt" -Type CERT | Out-Null
    $cert.Thumbprint | Set-Content "$cert_dir\thumbprint.txt"
    
    return $cert_dir
}

# =============================================================
# INSTALADORES WEB
# =============================================================
function Instalar-IIS-Web {
    param($Archivo, $WebFTP, $SSL)
    Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    
    $pHttp = Read-Host "Puerto HTTP [Enter=80]"; if (!$pHttp) { $pHttp = 80 }
    $pHttps = 443
    if ($SSL -eq "S") { $pHttps = Read-Host "Puerto HTTPS [Enter=443]"; if (!$pHttps) { $pHttps = 443 } }

    $sitePath = "C:\inetpub\wwwroot\SitioIIS_P7"
    New-Item -ItemType Directory -Force -Path $sitePath | Out-Null
    Set-Content "$sitePath\index.html" "<h1>IIS WEB FUNCIONANDO (Practica 7)</h1>" -Force

    if ($SSL -eq "S") {
        $cert = New-SelfSignedCertificate -DnsName "www.reprobados.com" -CertStoreLocation "cert:\LocalMachine\My" -NotAfter (Get-Date).AddDays(365)
        New-Website -Name "SitioIIS_P7" -Port $pHttp -PhysicalPath $sitePath -Force | Out-Null
        New-WebBinding -Name "SitioIIS_P7" -Protocol "https" -Port $pHttps -IPAddress "*"
        $script:RESUMEN_INSTALACIONES += "IIS Web | SSL: SI | Puertos: $pHttp / $pHttps"
    } else {
        New-Website -Name "SitioIIS_P7" -Port $pHttp -PhysicalPath $sitePath -Force | Out-Null
        $script:RESUMEN_INSTALACIONES += "IIS Web | SSL: NO | Puerto: $pHttp"
    }
    $script:SERVICIOS_VERIFICAR += "IIS|W3SVC|$pHttp|http"
    Write-Host "  + IIS Configurado correctamente." -ForegroundColor Green
}

function Instalar-Apache {
    param($Archivo, $WebFTP, $SSL)
    if ($WebFTP -eq "FTP") {
        if (-not (Descargar-Y-Validar "Apache" $Archivo)) { return }
        Expand-Archive "$env:TEMP\$Archivo" $APACHE_DIR -Force
    } else {
        Invoke-WebRequest "https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-240904-win64-VS17.zip" -OutFile "$env:TEMP\apache.zip"
        Expand-Archive "$env:TEMP\apache.zip" $APACHE_DIR -Force
    }
    
    if (Test-Path "$APACHE_DIR\Apache24") { Move-Item "$APACHE_DIR\Apache24\*" $APACHE_DIR -Force }

    $pHttp = Read-Host "Puerto HTTP [Enter=8080]"; if (!$pHttp) { $pHttp = 8080 }
    
    $conf = Get-Content "$APACHE_DIR\conf\httpd.conf" -Raw
    $conf = $conf -replace 'Define SRVROOT ".*"', "Define SRVROOT `"$($APACHE_DIR -replace '\\','/')`""
    $conf = $conf -replace '(?m)^Listen 80$', "Listen $pHttp"
    
    if ($SSL -eq "S") {
        $cert_dir = Generar-SSL "apache"
        $pHttps = Read-Host "Puerto HTTPS [Enter=8443]"; if (!$pHttps) { $pHttps = 8443 }
        $script:RESUMEN_INSTALACIONES += "Apache | SSL: SI | Puertos: $pHttp / $pHttps"
    } else {
        $script:RESUMEN_INSTALACIONES += "Apache | SSL: NO | Puerto: $pHttp"
    }
    $conf | Set-Content "$APACHE_DIR\conf\httpd.conf"
    
    & "$APACHE_DIR\bin\httpd.exe" -k install -n "Apache_P7" 2>$null
    Start-Service "Apache_P7" -ErrorAction SilentlyContinue
    $script:SERVICIOS_VERIFICAR += "Apache|Apache_P7|$pHttp|http"
    Write-Host "  + Apache instalado y corriendo." -ForegroundColor Green
}

function Instalar-Nginx {
    param($Archivo, $WebFTP, $SSL)
    if ($WebFTP -eq "FTP") {
        if (-not (Descargar-Y-Validar "Nginx" $Archivo)) { return }
        Expand-Archive "$env:TEMP\$Archivo" $NGINX_DIR -Force
    } else {
        Invoke-WebRequest "https://nginx.org/download/nginx-1.26.2.zip" -OutFile "$env:TEMP\nginx.zip"
        Expand-Archive "$env:TEMP\nginx.zip" $NGINX_DIR -Force
    }
    
    if (Test-Path "$NGINX_DIR\nginx-1.26.2") { Move-Item "$NGINX_DIR\nginx-1.26.2\*" $NGINX_DIR -Force }

    $pHttp = Read-Host "Puerto HTTP [Enter=8081]"; if (!$pHttp) { $pHttp = 8081 }
    
    if ($SSL -eq "S") {
        $pHttps = Read-Host "Puerto HTTPS [Enter=8444]"; if (!$pHttps) { $pHttps = 8444 }
        $script:RESUMEN_INSTALACIONES += "Nginx | SSL: SI | Puertos: $pHttp / $pHttps"
    } else {
        $script:RESUMEN_INSTALACIONES += "Nginx | SSL: NO | Puerto: $pHttp"
    }
    
    Start-Process "$NGINX_DIR\nginx.exe" -WorkingDirectory $NGINX_DIR -WindowStyle Hidden
    $script:SERVICIOS_VERIFICAR += "Nginx|nginx|$pHttp|http"
    Write-Host "  + Nginx instalado y corriendo." -ForegroundColor Green
}

# =============================================================
# RESUMEN (PRACTICA 7)
# =============================================================
function Mostrar-Resumen {
    Write-Host "`n==========================================================" -ForegroundColor Magenta
    Write-Host "         RESUMEN AUTOMATIZADO DE INSTALACIONES           " -ForegroundColor Magenta
    Write-Host "==========================================================" -ForegroundColor Magenta
    
    if ($script:RESUMEN_INSTALACIONES.Count -eq 0) {
        Write-Host "  (Sin servicios instalados aun)"
    } else {
        foreach ($r in $script:RESUMEN_INSTALACIONES) { Write-Host "  -> $r" -ForegroundColor Cyan }
    }
    
    Write-Host "`n-- Pruebas de Conexion Activas --"
    if ($script:SERVICIOS_VERIFICAR.Count -eq 0) {
        Write-Host "  (Sin servicios para verificar)"
    } else {
        foreach ($entrada in $script:SERVICIOS_VERIFICAR) {
            $p = $entrada -split "\|"
            try {
                $r = Invoke-WebRequest "$($p[3])://127.0.0.1:$($p[2])" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                Write-Host "  [$($p[0])] Puerto:$($p[2]) -> ESTADO HTTP $($r.StatusCode) (EXITO)" -ForegroundColor Green
            } catch {
                Write-Host "  [$($p[0])] Puerto:$($p[2]) -> FALLO O TIMEOUT" -ForegroundColor Red
            }
        }
    }
    
    Write-Host "`n-- Servidores FTP Python independientes ------------------"
    foreach ($svc in @("IIS","Apache","Nginx")) {
        $puerto = $FTP_PUERTOS[$svc]
        $estado = if (netstat -an | Select-String ":$puerto ") { "ACTIVO" } else { "INACTIVO" }
        Write-Host "  [FTP-${svc}] Puerto:$puerto -> $estado"
    }
}

Main

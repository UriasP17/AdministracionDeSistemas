# ==============================================================================
# MODULO HTTP/FTP COMBINADO - WINDOWS (P07)
# ==============================================================================

Import-Module WebAdministration -ErrorAction SilentlyContinue

$PUERTOS_BLOQUEADOS = @(1,7,9,11,13,15,17,19,20,21,22,23,25,37,42,43,53,69,77,79,
    87,95,101,102,103,104,109,110,111,113,115,117,119,123,135,139,142,143,179,389,
    465,512,513,514,515,526,530,531,532,540,548,554,556,563,587,601,636,993,995,
    2049,3659,4045,6000,6665,6666,6667,6668,6669,6697)

# ================================================================
# LIMPIEZA Y PAGINA
# ================================================================

function Garantizar-Chocolatey {
    $chocoPath = "C:\ProgramData\chocolatey\bin\choco.exe"
    if (!(Test-Path $chocoPath)) {
        Write-Host "[!] Chocolatey no detectado. Iniciando instalacion..." -ForegroundColor Yellow
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path += ";C:\ProgramData\chocolatey\bin"
    }
    return "C:\ProgramData\chocolatey\bin\choco.exe"
}

function Limpiar-Entorno {
    param($Puerto)
    Write-Host "[*] Limpiando servicios en puerto $Puerto..." -ForegroundColor Gray
    Stop-Service nginx, Apache, Apache2.4, W3SVC, ftpsvc -Force -ErrorAction SilentlyContinue
    taskkill /F /IM nginx.exe /T 2>$null
    taskkill /F /IM httpd.exe /T 2>$null
    $con = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    if ($con) { $con.OwningProcess | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Seconds 2
}

function Crear-Pagina {
    param($servicio, $puerto)
    
    $paths = @{
        "nginx"  = "C:\tools\nginx-1.29.6\html\index.html"
        "apache" = "C:\Users\vboxuser\AppData\Roaming\Apache24\htdocs\index.html"
        "iis"    = "C:\Sitio_IIS_Limpio\index.html"
    }
    
    $path = $paths[$servicio]
    if (!$path) { return }
    
    $dir = Split-Path $path
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    
    $color = "#009688"
    $msg   = "Servicio Activo"
    
    if ($servicio -eq "apache") { $color = "#D32F2F" }
    if ($servicio -eq "iis")    { $color = "#0288D1" }

    $servidorNombre = $servicio.ToUpper()

    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<title>$servidorNombre</title>
<style>
  body { margin: 0; font-family: sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; background: #fafafa; color: #111; }
  .wrap { text-align: center; }
  .dot { width: 10px; height: 10px; border-radius: 50%; background: $color; display: inline-block; margin-bottom: 2rem; }
  h1 { font-size: 1.6rem; font-weight: 600; margin: 0 0 .4rem; }
  .badge { display: inline-block; margin: 1.2rem 0; padding: .3rem .9rem; border: 1.5px solid $color; color: $color; font-size: .85rem; border-radius: 99px; }
  .meta { font-size: .85rem; color: #777; margin-top: .5rem; }
</style>
</head>
<body>
<div class="wrap">
  <div class="dot"></div>
  <h1>$servidorNombre</h1>
  <div class="badge">$msg</div>
  <div class="meta">www.reprobados.com - Puerto: $puerto</div>
</div>
</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $html, $utf8NoBom)
}


# ================================================================
# CERTIFICADO SSL
# ================================================================

function Generar-Certificado-SSL {
    $dir = "C:\ssl\reprobados"
    $crt = "$dir\reprobados.crt"
    $key = "$dir\reprobados.key"

    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }

    $crtOk = (Test-Path $crt) -and ((Get-Content $crt -First 1) -like "-----BEGIN*")
    $keyOk = (Test-Path $key) -and ((Get-Content $key -First 1) -like "-----BEGIN*")

    if ($crtOk -and $keyOk) {
        Write-Host "[*] Reutilizando certificado existente." -ForegroundColor Yellow
        return @{ CRT = $crt; KEY = $key; OK = $true }
    }

    $opensslPath = $null
    foreach ($c in @("C:\Program Files\Git\usr\bin\openssl.exe","C:\Program Files (x86)\Git\usr\bin\openssl.exe","C:\ProgramData\chocolatey\bin\openssl.exe")) {
        if (Test-Path $c) { $opensslPath = $c; break }
    }
    if (!$opensslPath) {
        $cmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($cmd) { $opensslPath = $cmd.Source }
    }

    if ($opensslPath) {
        Write-Host "[*] Generando certificado SSL con OpenSSL..." -ForegroundColor Cyan
        & $opensslPath genrsa -out $key 2048 2>$null
        & $opensslPath req -new -x509 -key $key -out $crt -days 365 -subj "/C=MX/ST=Sinaloa/L=LosMochis/O=Reprobados/CN=www.reprobados.com" 2>$null
        return @{ CRT = $crt; KEY = $key; OK = $true }
    } else {
        Write-Host "[!] OpenSSL no encontrado. Solo IIS usara SSL." -ForegroundColor Yellow
        return @{ CRT = $crt; KEY = $key; OK = $false }
    }
}

function Obtener-CertObj {
    $certObj = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Subject -like "*CN=www.reprobados.com*" } | Select-Object -First 1
    
    if (!$certObj) {
        $subject = "C=MX, S=Sinaloa, L=LosMochis, O=Reprobados, CN=www.reprobados.com"
        $certObj = New-SelfSignedCertificate -Subject $subject -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddDays(365) -KeyExportPolicy Exportable
    }
    return $certObj
}

# ================================================================
# DESPLIEGUE POR SERVICIO
# ================================================================

function Aplicar-Despliegue {
    param($Servicio)

    Write-Host ""
    $P_Ingresado = Read-Host "Ingrese el puerto para $Servicio (ej. 8081, 8443, 9090)"
    
    if ($P_Ingresado -match '^\d+$') {
        $P = [int]$P_Ingresado
    } else {
        Write-Host "[!] Puerto invalido, usando puerto configurado por defecto: $global:PUERTO_ACTUAL" -ForegroundColor Yellow
        $P = [int]$global:PUERTO_ACTUAL
    }

    if ($P -in $PUERTOS_BLOQUEADOS) {
        Write-Host "[!] Advertencia: El puerto $P esta en la lista de bloqueados." -ForegroundColor Yellow
        $confirma = Read-Host "Desea continuar de todos modos? [S/N]"
        if ($confirma -notmatch '^[Ss]$') { return }
    }

    $cert = Generar-Certificado-SSL
    $respSSL  = Read-Host "Desea activar SSL en este servicio? [S/N]"
    $usarSSL  = ($respSSL -match '^[Ss]$') -and $cert.OK
    $protocolo = if ($usarSSL) { "https" } else { "http" }
    Write-Host "[*] SSL: $(if ($usarSSL) { 'ACTIVADO' } else { 'DESACTIVADO' })" -ForegroundColor $(if ($usarSSL) { 'Green' } else { 'Yellow' })

    Limpiar-Entorno $P

    switch ($Servicio) {

        "nginx" {
            $nginxExeItem = Get-ChildItem "C:\tools" -Recurse -Filter "nginx.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (!$nginxExeItem) { Write-Host "[!] nginx no encontrado" -ForegroundColor Red; Pause; return }
            $nginxDir = $nginxExeItem.DirectoryName
            $conf     = "$nginxDir\conf\nginx.conf"
            $certAbs  = "C:/ssl/reprobados/reprobados.crt"
            $keyAbs   = "C:/ssl/reprobados/reprobados.key"

            if ($usarSSL) {
                $cfg = @"
worker_processes  1;
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    server {
        listen       80;
        server_name  www.reprobados.com;
        return 301   https://`$host:$P`$request_uri;
    }
    server {
        listen       $P ssl;
        server_name  www.reprobados.com;
        ssl_certificate      $certAbs;
        ssl_certificate_key  $keyAbs;
        add_header Strict-Transport-Security "max-age=31536000" always;
        location / { root html; index index.html; }
    }
}
"@
            } else {
                $cfg = @"
worker_processes  1;
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    server {
        listen       $P;
        server_name  www.reprobados.com;
        location / { root html; index index.html; }
    }
}
"@
            }
            Set-Content $conf $cfg -Encoding ASCII
            Crear-Pagina "nginx" $P
            Start-Process "$nginxDir\nginx.exe" -WorkingDirectory $nginxDir -WindowStyle Hidden
            Start-Sleep -Seconds 3
        }

       "apache" {
            $rutaApache = $null
            $svcWmi = Get-CimInstance Win32_Service | Where-Object { $_.Name -like "Apache*" } | Select-Object -First 1
            if ($svcWmi) {
                if ($svcWmi.PathName -match '"([^"]+bin[^"]+httpd\.exe)"') { $rutaApache = Split-Path (Split-Path $matches[1] -Parent) -Parent }
                elseif ($svcWmi.PathName -match '([A-Za-z]:[^ ]+httpd\.exe)') { $rutaApache = Split-Path (Split-Path $matches[1] -Parent) -Parent }
            }
            if (!$rutaApache) {
                foreach ($c in @("C:\Apache24","$env:APPDATA\Apache24")) {
                    if (Test-Path "$c\bin\httpd.exe") { $rutaApache = $c; break }
                }
            }
            if (!$rutaApache) { Write-Host "[!] Apache no encontrado." -ForegroundColor Red; Pause; return }
            
            $conf    = "$rutaApache\conf\httpd.conf"
            $webRoot = "$rutaApache\htdocs"
            $certDir = "C:/ssl/reprobados"
            $webDir  = $webRoot -replace '\\','/'

            $lineas = Get-Content $conf
            for ($i = 0; $i -lt $lineas.Count; $i++) {
                if ($lineas[$i] -match '^<VirtualHost') { $lineas = $lineas[0..($i-1)]; break }
            }

            $lineas = $lineas | Where-Object { $_ -notmatch '^Listen ' }
            $lineas = $lineas | ForEach-Object {
                if ($_ -match '^#?ServerName ') { "ServerName www.reprobados.com:$P" }
                elseif ($_ -match '^#LoadModule ssl_module') { "LoadModule ssl_module modules/mod_ssl.so" }
                elseif ($_ -match '^#LoadModule socache_shmcb_module') { "LoadModule socache_shmcb_module modules/mod_socache_shmcb.so" }
                elseif ($_ -match '^#LoadModule headers_module') { "LoadModule headers_module modules/mod_headers.so" }
                else { $_ }
            }

            if ($usarSSL) { $lineas = @("Listen 80", "Listen $P") + $lineas }
            else { $lineas = @("Listen $P") + $lineas }

            if ($usarSSL) {
                $vhost = @"

<VirtualHost *:80>
    ServerName www.reprobados.com
    Redirect permanent / https://www.reprobados.com:$P/
</VirtualHost>

<VirtualHost *:$P>
    ServerName www.reprobados.com
    DocumentRoot "$webDir"
    SSLEngine on
    SSLCertificateFile    "$certDir/reprobados.crt"
    SSLCertificateKeyFile "$certDir/reprobados.key"
    Header always set Strict-Transport-Security "max-age=31536000"
    <Directory "$webDir">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
"@
            } else {
                $vhost = @"
<VirtualHost *:$P>
    ServerName www.reprobados.com
    DocumentRoot "$webDir"
    <Directory "$webDir">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
"@
            }
            $lineas += ($vhost -split "`n")
            Set-Content $conf $lineas -Encoding ASCII

            $test = & "$rutaApache\bin\httpd.exe" -t 2>&1
            if ($test -match "Syntax OK") {
                Cr

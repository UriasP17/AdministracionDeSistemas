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

function Obtener-CertObj {
    $certObj = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Subject -like "*CN=www.reprobados.com*" } | Select-Object -First 1
    
    if (!$certObj) {
        Write-Host "[*] Generando Certificado Autofirmado con PowerShell..." -ForegroundColor Cyan
        $subject = "C=MX, S=Sinaloa, L=LosMochis, O=Reprobados, CN=www.reprobados.com"
        $certObj = New-SelfSignedCertificate -Subject $subject -DnsName "www.reprobados.com" -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddDays(365) -KeyExportPolicy Exportable
    } else {
        Write-Host "[*] Reutilizando Certificado SSL existente en el almacen." -ForegroundColor Yellow
    }
    
    $dir = "C:\ssl\reprobados"
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    
    $crt = "$dir\reprobados.crt"
    $key = "$dir\reprobados.key"

    if (!(Test-Path $crt) -or !(Test-Path $key)) {
        $opensslPath = $null
        foreach ($c in @("C:\Program Files\Git\usr\bin\openssl.exe","C:\Program Files (x86)\Git\usr\bin\openssl.exe","C:\ProgramData\chocolatey\bin\openssl.exe")) {
            if (Test-Path $c) { $opensslPath = $c; break }
        }
        if ($opensslPath) {
            & $opensslPath genrsa -out $key 2048 2>$null
            & $opensslPath req -new -x509 -key $key -out $crt -days 365 -subj "/C=MX/ST=Sinaloa/L=LosMochis/O=Reprobados/CN=www.reprobados.com" 2>$null
        }
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

    $certObj = Obtener-CertObj
    $respSSL  = Read-Host "Desea activar SSL en este servicio? [S/N]"
    $usarSSL  = ($respSSL -match '^[Ss]$')
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

            if ($usarSSL -and (Test-Path $certAbs)) {
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

            if ($usarSSL -and (Test-Path "$certDir\reprobados.crt")) {
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
                Crear-Pagina "apache" $P
                Restart-Service Apache* -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            } else {
                Write-Host "[!] Error en config de Apache:" -ForegroundColor Red
                $test | Out-String | Write-Host -ForegroundColor Yellow
                Pause; return
            }
        }

      "iis" {
            Write-Host "[*] Configurando IIS en puerto $P..." -ForegroundColor Cyan
            
            Get-Website | Stop-Website -ErrorAction SilentlyContinue
            Remove-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
            Remove-Website -Name "SitioP7" -ErrorAction SilentlyContinue

            $webRoot = "C:\Sitio_IIS_Limpio"
            if (!(Test-Path $webRoot)) { New-Item $webRoot -ItemType Directory -Force | Out-Null }
            
            Crear-Pagina "iis" $P

            if ($usarSSL -and $certObj) {
                New-Website -Name "SitioP7" -Port 80 -PhysicalPath $webRoot -Force | Out-Null
                Get-ChildItem -Path "IIS:\SslBindings" | Where-Object { $_.Port -eq $P } | Remove-Item -Force -ErrorAction SilentlyContinue
                New-WebBinding -Name "SitioP7" -IPAddress "*" -Port $P -Protocol "https"
                
                $certObj | New-Item -Path "IIS:\SslBindings\*!$P" -Force | Out-Null
                Write-Host "[OK] SSL vinculado al puerto $P" -ForegroundColor Green
                
            } else {
                New-Website -Name "SitioP7" -Port $P -PhysicalPath $webRoot -Force | Out-Null
            }

            New-NetFirewallRule -DisplayName "IIS_Port_$P" -Direction Inbound -LocalPort $P -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
            Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
            Write-Host "[*] Esperando a que IIS despierte..."
            Start-Sleep -Seconds 5
        }
    }

    if (Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "[OK] $Servicio ONLINE en puerto $P" -ForegroundColor Green
    } else {
        Write-Host "[!] $Servicio no levanto en puerto $P" -ForegroundColor Red
    }
    Pause
}

# ================================================================
# FTP E INSTALACION
# ================================================================

function Instalar-Servicio {
    param($Servicio)
    
    $ServicioFTP = switch ($Servicio.ToLower()) {
        "nginx"  { "Nginx" }
        "apache" { "Apache" }
        "iis"    { "IIS" }
        default  { $Servicio }
    }
    $paquete = switch ($Servicio.ToLower()) {
        "nginx"  { "nginx" }
        "apache" { "apache-httpd" }
        "iis"    { "iis" }
    }

    Write-Host ""; Write-Host "[I] --- Instalando: $Servicio ---" -ForegroundColor Blue
    Write-Host "1) Chocolatey (Oficial) | 2) FTP ($global:FTP_IP)"
    $origen = Read-Host "Elija origen"

    if ($origen -eq "1") {
        if ($Servicio -eq "iis") {
            $checkIIS = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
            if ($checkIIS.Installed) {
                Write-Host "[OK] IIS ya se encuentra instalado en el sistema." -ForegroundColor Green
            } else {
                Write-Host "[*] Instalando IIS y el modulo de FTP... (esto puede tardar unos minutos)" -ForegroundColor Cyan
                Install-WindowsFeature -Name Web-Server, Web-Ftp-Server, Web-Ftp-Service, Web-Ftp-Ext -IncludeManagementTools
                Write-Host "[OK] IIS instalado correctamente." -ForegroundColor Green
            }
            
            $dep = Read-Host "Desplegar IIS ahora? [S/N]"
            if ($dep -match '^[Ss]$') { Aplicar-Despliegue "iis" }
            return
        }
        $chocoExe = Garantizar-Chocolatey
        Limpiar-Entorno 80
        & $chocoExe install $paquete -y | Out-Null
        Write-Host "[OK] Instalacion completada." -ForegroundColor Green
        
    } else {
        # === INSTALACION POR FTP SEGURO (FTPS) ===
        $ftpRuta = "ftp://$($global:FTP_IP)/http/Windows/$ServicioFTP"
        
        $archivo = switch ($Servicio.ToLower()) {
            "nginx"  { "nginx.zip" }
            "apache" { "apache_2.4.zip" }
            "iis"    { "iis_installer.exe" }
            default  { "$($Servicio.ToLower()).zip" }
        }

        $destLocal = Join-Path $env:TEMP $archivo
        $hashFileLocal = Join-Path $env:TEMP "$archivo.sha256"

        Write-Host "[*] Descargando $archivo desde $ftpRuta (FTP Seguro)..." -ForegroundColor Cyan
        
        try {
            function Bajar-FTPS($url, $destino) {
                # Ignorar validacion de certificado autofirmado (evita errores de SSL root)
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
                
                $req = [System.Net.WebRequest]::Create($url)
                $req.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
                
                # PARCHE PARA ERROR 530 (Not Logged In): Mandar string vacio
                $req.Credentials = New-Object System.Net.NetworkCredential("anonymous", "")
                
                $req.EnableSsl = $true
                # PARCHE PARA ERROR 530 en transferencias: Modo Activo en vez de Pasivo
                $req.UsePassive = $false 
                $req.UseBinary = $true
                
                $resp = $req.GetResponse()
                $stream = $resp.GetResponseStream()
                $fs = [System.IO.File]::Create($destino)
                $stream.CopyTo($fs)
                $fs.Close(); $stream.Close(); $resp.Close()
            }

            # Descargar archivo e info hash
            Bajar-FTPS "$ftpRuta/$archivo" $destLocal
            Bajar-FTPS "$ftpRuta/$archivo.sha256" $hashFileLocal
            
            Write-Host "[*] Validando integridad (Get-FileHash)..." -ForegroundColor Yellow
            
            $hashCalculado = (Get-FileHash -Path $destLocal -Algorithm SHA256).Hash
            $hashEsperado = (Get-Content $hashFileLocal).Trim().ToUpper()

            if ($hashCalculado -ne $hashEsperado) {
                Write-Host "[!] HASH INVALIDO. Archivo corrupto." -ForegroundColor Red
                Write-Host "    Calculado: $hashCalculado" -ForegroundColor Red
                Write-Host "    Esperado : $hashEsperado" -ForegroundColor Red
                Pause
                return
            }
            Write-Host "[OK] Hash verificado correctamente." -ForegroundColor Green

            if ($archivo -like "*.zip") {
                $dest = "C:\tools\$Servicio"
                if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
                Expand-Archive -Path $destLocal -DestinationPath $dest -Force
            } elseif ($archivo -like "*.msi" -or $archivo -like "*.exe") {
                Start-Process msiexec.exe -ArgumentList "/i `"$destLocal`" /quiet" -Wait
            }
        } catch {
            Write-Host "[!] Error descargando archivo desde FTP Seguro: $_" -ForegroundColor Red
            Pause
            return

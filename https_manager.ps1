#Requires -RunAsAdministrator
# ====================================================================
#   ORQUESTADOR WEB (IIS, APACHE, NGINX) + HTTPS
# ====================================================================

function Validar-Puerto-HTTP {
    param([string]$Puerto)
    if ($Puerto -notmatch "^\d+$" -or [int]$Puerto -lt 1) { return 1 }
    if (Get-NetTCPConnection -LocalPort $Puerto -ErrorAction SilentlyContinue) { return 2 }
    return 0
}

function Instalar-Chocolatey {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "> Instalando Chocolatey..." -ForegroundColor Cyan
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
    }
}

function Generar-Certificados-Web {
    param([string]$DirectorioDestino)
    if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
        Instalar-Chocolatey
        choco install openssl.light -y --force | Out-Null
        $env:Path += ";C:\Program Files\OpenSSL\bin;C:\Program Files\OpenSSL-Win64\bin"
    }
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$DirectorioDestino\server.key" -out "$DirectorioDestino\server.crt" -subj "/C=MX/ST=Estado/O=Reprobados/CN=localhost" 2>$null
}

function Invoke-DescargaSeguraFTP {
    param([string]$ServidorIP, [string]$UsuarioFTP, [securestring]$PassFTP, [string]$RutaRemota, [string]$RutaLocalDestino)
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
    [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $passPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PassFTP))
    
    $UrlArchivo = "ftp://${ServidorIP}${RutaRemota}"
    $UrlHash = "${UrlArchivo}.sha256"
    $RutaLocalHash = "${RutaLocalDestino}.sha256"
    $DirectorioLocal = Split-Path $RutaLocalDestino -Parent
    if (-not (Test-Path $DirectorioLocal)) { New-Item -ItemType Directory -Path $DirectorioLocal -Force | Out-Null }

    try {
        Write-Host "> Descargando instalador desde FTPS..." -ForegroundColor Yellow
        $wc = New-Object System.Net.WebClient
        $wc.Credentials = New-Object System.Net.NetworkCredential($UsuarioFTP, $passPlain)
        $wc.DownloadFile($UrlArchivo, $RutaLocalDestino)
        $wc.DownloadFile($UrlHash, $RutaLocalHash)
    } catch { Write-Host "- Falla conexion al FTP." -ForegroundColor Red; return $false }

    $HashRemoto = (Get-Content $RutaLocalHash -Raw).Trim().ToUpper()
    $HashLocal = (Get-FileHash -Path $RutaLocalDestino -Algorithm SHA256).Hash.ToUpper()
    if ($HashRemoto -eq $HashLocal) { return $true } else { Write-Host "- Hashes no coinciden." -ForegroundColor Red; return $false }
}

function Desplegar-IIS {
    Write-Host "`n> DESPLIEGUE IIS WEB" -ForegroundColor Cyan
    $usarSSL = Read-Host "Desea activar SSL? [S/N]"
    do { $PUERTO = Read-Host "Puerto HTTP base" } while ((Validar-Puerto-HTTP $PUERTO) -ne 0)

    Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    Import-Module WebAdministration
    Get-WebBinding -Name "Default Web Site" | Remove-WebBinding -ErrorAction SilentlyContinue
    New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port $PUERTO -Protocol http | Out-Null
    Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value "<h1>IIS Funcionando</h1>" -Force

    if ($usarSSL -match "^[Ss]$") {
        $cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(1)
        New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port 443 -Protocol https | Out-Null
        (Get-WebBinding -Name "Default Web Site" -Port 443 -Protocol https).AddSslCertificate($cert.Thumbprint, "my")
        Instalar-Chocolatey; choco install urlrewrite -y | Out-Null
        
        $webConfig = @"
<?xml version="1.0" encoding="UTF-8"?><configuration><system.webServer><rewrite><rules>
<rule name="HTTPS" stopProcessing="true"><match url="(.*)" /><conditions><add input="{HTTPS}" pattern="off" /></conditions><action type="Redirect" url="https://{HTTP_HOST}/{R:1}" redirectType="Permanent" /></rule>
</rules></rewrite></system.webServer></configuration>
"@
        Set-Content -Path "C:\inetpub\wwwroot\web.config" -Value $webConfig -Force
    }
    iisreset /restart | Out-Null
    Write-Host "+ IIS Web Desplegado." -ForegroundColor Green
    $null = Read-Host "Presiona ENTER para continuar"
}

function Desplegar-Nginx-Windows {
    Write-Host "`n> DESPLIEGUE NGINX" -ForegroundColor Cyan
    $origen = Read-Host "1) Internet o 2) FTP Privado"
    $usarSSL = Read-Host "Desea activar SSL? [S/N]"
    $nginxDir = $null

    if ($origen -eq "1") {
        Instalar-Chocolatey; choco install nginx -y --force
        $nginxDir = (Get-ChildItem -Path "C:\ProgramData\chocolatey\lib\nginx" -Filter "nginx.exe" -Recurse | Select -First 1).DirectoryName
    } elseif ($origen -eq "2") {
        $ip = Read-Host "IP FTP"; $usr = Read-Host "Usuario FTP"; $pass = Read-Host "Pass FTP" -AsSecureString
        if (Invoke-DescargaSeguraFTP $ip $usr $pass "/Instaladores/http/Windows/Nginx/nginx.zip" "C:\Temp\nginx.zip") {
            Expand-Archive -Path "C:\Temp\nginx.zip" -DestinationPath "C:\nginx_local" -Force
            $nginxDir = (Get-ChildItem -Path "C:\nginx_local" -Filter "nginx.exe" -Recurse | Select -First 1).DirectoryName
        }
    }
    
    if (-not $nginxDir) { return }
    do { $PUERTO = Read-Host "Puerto HTTP base" } while ((Validar-Puerto-HTTP $PUERTO) -ne 0)

    $confPath = "$nginxDir\conf\nginx.conf"
    if ($usarSSL -match "^[Ss]$") {
        Generar-Certificados-Web "$nginxDir\conf"
        $nginxConfSSL = "worker_processes 1; events { worker_connections 1024; } http { include mime.types; server { listen $PUERTO; server_name localhost; return 301 https://`$host`$request_uri; } server { listen 443 ssl; server_name localhost; ssl_certificate server.crt; ssl_certificate_key server.key; location / { root html; index index.html; } } }"
        Set-Content -Path $confPath -Value $nginxConfSSL -Force
    } else {
        $contenido = (Get-Content $confPath) -replace 'listen\s+\d+;', "listen $PUERTO;"
        $contenido | Set-Content $confPath -Force
    }

    Set-Content -Path "$nginxDir\html\index.html" -Value "<h1>Nginx Funcionando</h1>" -Force
    Stop-Process -Name "nginx" -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath "$nginxDir\nginx.exe" -WorkingDirectory $nginxDir -WindowStyle Hidden
    Write-Host "+ Nginx Desplegado." -ForegroundColor Green
    $null = Read-Host "Presiona ENTER para continuar"
}

function Desplegar-Apache-Windows {
    Write-Host "`n> DESPLIEGUE APACHE" -ForegroundColor Cyan
    $origen = Read-Host "1) Internet o 2) FTP Privado"
    $usarSSL = Read-Host "Desea activar SSL? [S/N]"
    $apacheDir = $null

    if ($origen -eq "1") {
        Instalar-Chocolatey; choco install apache-httpd -y --force
        $apacheDir = (Get-ChildItem -Path "C:\tools" -Filter "httpd.exe" -Recurse | Select -First 1).DirectoryName
        $apacheDir = (Get-Item $apacheDir).Parent.FullName
    } elseif ($origen -eq "2") {
        $ip = Read-Host "IP FTP"; $usr = Read-Host "Usuario FTP"; $pass = Read-Host "Pass FTP" -AsSecureString
        if (Invoke-DescargaSeguraFTP $ip $usr $pass "/Instaladores/http/Windows/Apache/apache.msi" "C:\Temp\apache.msi") {
            Start-Process "msiexec.exe" -ArgumentList "/i `"C:\Temp\apache.msi`" /quiet ALLUSERS=1" -Wait
            $apacheDir = "C:\Program Files (x86)\Apache Software Foundation\Apache2.2"
        }
    }

    if (-not $apacheDir -or -not (Test-Path $apacheDir)) { return }
    do { $PUERTO = Read-Host "Puerto HTTP base" } while ((Validar-Puerto-HTTP $PUERTO) -ne 0)

    $confPath = "$apacheDir\conf\httpd.conf"
    $rutaCorregida = $apacheDir -replace '\\', '/'
    $contenido = Get-Content $confPath
    $contenido = $contenido -replace 'Listen \d+', "Listen $PUERTO" -replace 'ServerName localhost:\d+', "ServerName localhost:$PUERTO" -replace 'Define SRVROOT ".*"', "Define SRVROOT `"$rutaCorregida`""
    $contenido | Set-Content $confPath -Force

    if ($usarSSL -match "^[Ss]$") {
        Generar-Certificados-Web "$apacheDir\conf"
        $conf = Get-Content $confPath
        $conf = $conf -replace '#LoadModule ssl_module', 'LoadModule ssl_module' -replace '#LoadModule rewrite_module', 'LoadModule rewrite_module'
        $conf | Set-Content $confPath -Force
        Add-Content -Path $confPath -Value "`n<VirtualHost *:$PUERTO>`nRedirect permanent / https://localhost/`n</VirtualHost>`nListen 443`n<VirtualHost *:443>`nDocumentRoot `"$rutaCorregida/htdocs`"`nSSLEngine on`nSSLCertificateFile `"$rutaCorregida/conf/server.crt`"`nSSLCertificateKeyFile `"$rutaCorregida/conf/server.key`"`n</VirtualHost>"
    }

    Stop-Process -Name "httpd" -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath "$apacheDir\bin\httpd.exe" -WindowStyle Hidden
    Write-Host "+ Apache Desplegado." -ForegroundColor Green
    $null = Read-Host "Presiona ENTER para continuar"
}

while ($true) {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "   ORQUESTADOR WEB (IIS, APACHE, NGINX)  " -ForegroundColor Magenta
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host " 1) Desplegar IIS Web"
    Write-Host " 2) Desplegar Apache Web"
    Write-Host " 3) Desplegar Nginx Web"
    Write-Host " 0) Salir"
    $opc = Read-Host "Selecciona opcion"
    switch ($opc) {
        "1" { Desplegar-IIS }
        "2" { Desplegar-Apache-Windows }
        "3" { Desplegar-Nginx-Windows }
        "0" { break }
    }
    if ($opc -eq "0") { break }
}

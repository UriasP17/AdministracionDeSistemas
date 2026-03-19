#Requires -RunAsAdministrator

# ====================================================================
# VARIABLES GLOBALES
# ====================================================================
# PON LA IP DE TU FEDORA AQUI (De donde va a bajar los .zip)
$FTP_SERVER   = "192.168.56.20" 
$FTP_USER     = "repositorio"
$FTP_PASS     = "Hola1234."
$FTP_BASE     = "http/Windows"

# Tu IP de Windows donde estas corriendo esto
$IP_WINDOWS   = "192.168.56.10"

$RESUMEN_INSTALACIONES = @()
$SERVICIOS_VERIFICAR   = @()

$BASE_DIR     = "C:\Servicios"
$APACHE_DIR   = "$BASE_DIR\Apache"
$NGINX_DIR    = "$BASE_DIR\Nginx"
$IIS_DIR      = "$BASE_DIR\IIS_Content"
$IIS_REDIR    = "$BASE_DIR\IIS_Redir"
$SSL_DIR      = "$BASE_DIR\SSL"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ====================================================================
# FUNCIONES DE FTP Y DESCARGA (SIN INTERFAZ, PURO SSH)
# ====================================================================
function Listar-Versiones-FTP {
    param($Servicio)
    $url = "ftp://${FTP_SERVER}/${FTP_BASE}/${Servicio}/"
    Write-Host "`nNavegando en $url ..." -ForegroundColor Cyan

    try {
        $request = [System.Net.FtpWebRequest]::Create($url)
        $request.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectory
        $request.Credentials = New-Object System.Net.NetworkCredential($FTP_USER, $FTP_PASS)
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $contenido = $reader.ReadToEnd()
        $reader.Close(); $response.Close()

        $versiones = $contenido -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch '\.(sha256|md5)$' }
    } catch {
        Write-Host "[ERROR] No se pudo conectar al FTP de Linux o no existe la ruta. Verificaste la IP?" -ForegroundColor Red
        return "INVALIDO"
    }

    if ($versiones.Count -eq 0) { Write-Host "No hay archivos."; return "INVALIDO" }

    for ($i = 0; $i -lt $versiones.Count; $i++) { Write-Host "$($i+1)) $($versiones[$i])" }
    $sel = Read-Host "Selecciona el instalador"
    if ($sel -match '^\d+$' -and [int]$sel -le $versiones.Count) { return $versiones[[int]$sel - 1] }
    return "INVALIDO"
}

function Descargar-Y-Validar {
    param($Servicio, $Archivo)
    $url_base = "ftp://${FTP_SERVER}/${FTP_BASE}/${Servicio}/"
    $destino  = "$env:TEMP\$Archivo"
    $sha_dest = "$env:TEMP\${Archivo}.sha256"

    Write-Host "Descargando $Archivo por FTP..."
    $wc = New-Object System.Net.WebClient
    $wc.Credentials = New-Object System.Net.NetworkCredential($FTP_USER, $FTP_PASS)

    try { $wc.DownloadFile("${url_base}${Archivo}", $destino) }
    catch { Write-Host "ERROR al descargar binario." -ForegroundColor Red; return $false }

    Write-Host "Descargando firma de integridad (.sha256)..."
    try {
        $wc.DownloadFile("${url_base}${Archivo}.sha256", $sha_dest)
        $hash_remoto = (Get-Content $sha_dest).Split(" ")[0].Trim().ToLower()
        $hash_local  = (Get-FileHash $destino -Algorithm SHA256).Hash.ToLower()

        if ($hash_remoto -eq $hash_local) {
            Write-Host "[OK] Integridad SHA256 validada correctamente." -ForegroundColor Green
            return $true
        } else {
            Write-Host "[ERROR] Archivo corrupto. Hashes no coinciden." -ForegroundColor Red
            return $false
        }
    } catch { 
        Write-Host "[ALERTA] No se encontro archivo .sha256 en el servidor Linux. Omitiendo hash..." -ForegroundColor Yellow
        return $true 
    }
}

function Extraer-Instalador {
    param($Archivo, $Destino)
    New-Item -ItemType Directory -Force -Path $Destino | Out-Null
    Expand-Archive -Path "$env:TEMP\$Archivo" -DestinationPath $Destino -Force
    $sub = Get-ChildItem $Destino -Directory | Select-Object -First 1
    if ($sub) {
        Get-ChildItem "$($sub.FullName)\*" | Move-Item -Destination $Destino -Force -ErrorAction SilentlyContinue
        Remove-Item $sub.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ====================================================================
# SSL Y SEGURIDAD
# ====================================================================
function Generar-SSL-App {
    param($Nombre)
    $cert_dir = "$SSL_DIR\$Nombre"
    New-Item -ItemType Directory -Force -Path $cert_dir | Out-Null
    
    $cert = New-SelfSignedCertificate -DnsName "www.reprobados.com", $IP_WINDOWS -CertStoreLocation "cert:\LocalMachine\My" -NotAfter (Get-Date).AddDays(365) -FriendlyName "Reprobados-$Nombre"
    $pwd = ConvertTo-SecureString -String "reprobados" -Force -AsPlainText
    Export-PfxCertificate -Cert $cert -FilePath "$cert_dir\server.pfx" -Password $pwd | Out-Null
    Export-Certificate -Cert $cert -FilePath "$cert_dir\server.crt" -Type CERT | Out-Null
    return $cert_dir
}

function Generar-SSL-Nativo {
    param($Nombre)
    $cert = New-SelfSignedCertificate -DnsName "www.reprobados.com", $IP_WINDOWS -CertStoreLocation "cert:\LocalMachine\My" -NotAfter (Get-Date).AddDays(365) -FriendlyName "Reprobados-$Nombre"
    return $cert.Thumbprint
}

function Abrir-Puerto {
    param($Puerto, $Nombre)
    New-NetFirewallRule -DisplayName "Practica7-$Nombre" -Direction Inbound -Protocol TCP -LocalPort $Puerto -Action Allow -ErrorAction SilentlyContinue | Out-Null
}

function Crear-Index {
    param($Servidor, $Destino)
    New-Item -ItemType Directory -Force -Path $Destino | Out-Null
    $html = "<html><body><h1>Instancia HTTP: $Servidor</h1><h2>Dominio: www.reprobados.com</h2></body></html>"
    Set-Content -Path "$Destino\index.html" -Value $html -Encoding UTF8
}

# ====================================================================
# MOTOR 1: IIS (NATIVO, BYPASS SSH CON APPCMD)
# ====================================================================
function Instalar-IIS {
    param($SSL)
    $p_http = Read-Host "Puerto HTTP para IIS [80]" ; if(!$p_http) {$p_http=80}
    $p_https = Read-Host "Puerto HTTPS para IIS [443]" ; if(!$p_https) {$p_https=443}

    Write-Host "Instalando IIS usando DISM..."
    dism.exe /Online /Enable-Feature /FeatureName:IIS-WebServerRole /All /NoRestart /quiet | Out-Null
    dism.exe /Online /Enable-Feature /FeatureName:IIS-WebServerManagementTools /All /NoRestart /quiet | Out-Null
    dism.exe /Online /Enable-Feature /FeatureName:IIS-HttpRedirect /All /NoRestart /quiet | Out-Null
    Start-Service WAS, W3SVC -ErrorAction SilentlyContinue

    $appcmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
    & $appcmd delete site "Practica7_IIS_HTTP" 2>$null
    & $appcmd delete site "Practica7_IIS_HTTPS" 2>$null
    & $appcmd delete site "Default Web Site" 2>$null

    Crear-Index "IIS Windows Server" $IIS_DIR
    New-Item -ItemType Directory -Force -Path $IIS_REDIR | Out-Null

    if ($SSL -eq "S") {
        Write-Host "Configurando HTTPS, Redireccion automatica y HSTS..."
        $thumb = Generar-SSL-Nativo "IIS-Web"
        
        $guid = [guid]::NewGuid().ToString("B")
        netsh http delete sslcert ipport=0.0.0.0:$p_https 2>$null
        netsh http add sslcert ipport=0.0.0.0:$p_https certhash=$thumb appid="$guid" | Out-Null

        # HTTPS Real
        & $appcmd add site /name:"Practica7_IIS_HTTPS" /bindings:https://*:${p_https} /physicalPath:"$IIS_DIR"
        & $appcmd set config "Practica7_IIS_HTTPS" /section:system.webServer/httpProtocol /+customHeaders.[name='Strict-Transport-Security',value='max-age=31536000; includeSubDomains'] /commit:apphost

        # HTTP Redireccion (Redirige a la IP o al Dominio)
        & $appcmd add site /name:"Practica7_IIS_HTTP" /bindings:http://*:${p_http} /physicalPath:"$IIS_REDIR"
        & $appcmd set config "Practica7_IIS_HTTP" /section:system.webServer/httpRedirect /enabled:true /destination:"https://$IP_WINDOWS:$p_https" /exactDestination:false /httpResponseStatus:Permanent /commit:apphost
        
        Abrir-Puerto $p_https "IIS-HTTPS"
        $script:SERVICIOS_VERIFICAR += "IIS-HTTPS|W3SVC|$p_https|https"
    } else {
        & $appcmd add site /name:"Practica7_IIS_HTTP" /bindings:http://*:${p_http} /physicalPath:"$IIS_DIR"
    }

    Abrir-Puerto $p_http "IIS-HTTP"
    $script:SERVICIOS_VERIFICAR += "IIS-HTTP|W3SVC|$p_http|http"
    $script:RESUMEN_INSTALACIONES += "IIS Web | SSL:$SSL | Puertos: $p_http -> $p_https"
    Write-Host "[OK] IIS Web configurado." -ForegroundColor Green
}

# ====================================================================
# MOTOR 2: APACHE
# ====================================================================
function Instalar-Apache {
    param($Archivo, $WebFTP, $SSL)
    $p_http = Read-Host "Puerto HTTP para Apache [8080]" ; if(!$p_http) {$p_http=8080}
    $p_https = Read-Host "Puerto HTTPS para Apache [8443]" ; if(!$p_https) {$p_https=8443}

    if ($WebFTP -eq "FTP") {
        if (-not (Descargar-Y-Validar "Apache" $Archivo)) { return }
        Extraer-Instalador $Archivo $APACHE_DIR
    } else {
        Write-Host "Descargando Apache oficial..."
        & curl.exe -s -L -o "$env:TEMP\apache.zip" "https://github.com/jmwebservices/httpd-2.4.63-win64-VS17/archive/refs/heads/main.zip"
        Extraer-Instalador "apache.zip" $APACHE_DIR
    }

    Crear-Index "Apache Windows" "$APACHE_DIR\htdocs"
    $conf = "$APACHE_DIR\conf\httpd.conf"
    
    (Get-Content $conf) -replace '^Listen 80$',"Listen $p_http" | Set-Content $conf
    (Get-Content $conf) -replace 'SRVROOT ".*"',"SRVROOT `"$APACHE_DIR`"" | Set-Content $conf
    (Get-Content $conf) -replace '#LoadModule rewrite_module','LoadModule rewrite_module' | Set-Content $conf
    (Get-Content $conf) -replace '#LoadModule headers_module','LoadModule headers_module' | Set-Content $conf

    if ($SSL -eq "S") {
        $cert_dir = Generar-SSL-App "Apache"
        (Get-Content $conf) -replace '#LoadModule ssl_module','LoadModule ssl_module' | Set-Content $conf
        
        $ssl_conf = @"
Listen $p_https
<VirtualHost *:$p_https>
    ServerName $IP_WINDOWS
    DocumentRoot "$APACHE_DIR\htdocs"
    SSLEngine on
    SSLCertificateFile    "$cert_dir\server.crt"
    SSLCertificateKeyFile "$cert_dir\server.pfx"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
</VirtualHost>

<VirtualHost *:$p_http>
    ServerName $IP_WINDOWS
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}:$p_https`$1 [R=301,L]
</VirtualHost>
"@
        Set-Content "$APACHE_DIR\conf\extra\reprobados.conf" $ssl_conf
        Add-Content $conf "Include conf/extra/reprobados.conf"
        
        Abrir-Puerto $p_https "Apache-HTTPS"
        $script:SERVICIOS_VERIFICAR += "Apache-HTTPS|Apache2.4|$p_https|https"
    }

    Abrir-Puerto $p_http "Apache-HTTP"
    $script:SERVICIOS_VERIFICAR += "Apache-HTTP|Apache2.4|$p_http|http"

    & "$APACHE_DIR\bin\httpd.exe" -k install -n "Apache2.4" 2>$null
    Start-Service "Apache2.4" -ErrorAction SilentlyContinue

    $script:RESUMEN_INSTALACIONES += "Apache  | SSL:$SSL | Puertos: $p_http -> $p_https"
    Write-Host "[OK] Apache configurado." -ForegroundColor Green
}

# ====================================================================
# MOTOR 3: NGINX
# ====================================================================
function Instalar-Nginx {
    param($Archivo, $WebFTP, $SSL)
    $p_http = Read-Host "Puerto HTTP para Nginx [8081]" ; if(!$p_http) {$p_http=8081}
    $p_https = Read-Host "Puerto HTTPS para Nginx [8444]" ; if(!$p_https) {$p_https=8444}

    if ($WebFTP -eq "FTP") {
        if (-not (Descargar-Y-Validar "Nginx" $Archivo)) { return }
        Extraer-Instalador $Archivo $NGINX_DIR
    } else {
        Write-Host "Descargando Nginx..."
        & curl.exe -s -L -o "$env:TEMP\nginx.zip" "https://nginx.org/download/nginx-1.26.2.zip"
        Extraer-Instalador "nginx.zip" $NGINX_DIR
    }

    Crear-Index "Nginx Windows" "$NGINX_DIR\html"

    if ($SSL -eq "S") {
        $cert_dir = Generar-SSL-App "Nginx"
        $conf = @"
worker_processes 1;
events { worker_connections 1024; }
http {
    include mime.types;
    server {
        listen $p_http;
        server_name $IP_WINDOWS localhost;
        return 301 https://`$host:$p_https`$request_uri;
    }
    server {
        listen $p_https ssl;
        server_name $IP_WINDOWS localhost;
        ssl_certificate "$cert_dir\server.crt";
        ssl_certificate_key "$cert_dir\server.pfx";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        root html; index index.html;
    }
}
"@
        Abrir-Puerto $p_https "Nginx-HTTPS"
        $script:SERVICIOS_VERIFICAR += "Nginx-HTTPS|nginx|$p_https|https"
    } else {
        $conf = "worker_processes 1; events { worker_connections 1024; } http { include mime.types; server { listen $p_http; server_name localhost; root html; index index.html; } }"
    }

    Set-Content "$NGINX_DIR\conf\nginx.conf" $conf
    Abrir-Puerto $p_http "Nginx-HTTP"
    $script:SERVICIOS_VERIFICAR += "Nginx-HTTP|nginx|$p_http|http"

    Start-Process "cmd.exe" -ArgumentList "/c cd /d `"$NGINX_DIR`" && start nginx.exe" -WindowStyle Hidden
    $script:RESUMEN_INSTALACIONES += "Nginx   | SSL:$SSL | Puertos: $p_http -> $p_https"
    Write-Host "[OK] Nginx configurado." -ForegroundColor Green
}

# ====================================================================
# SERVICIO 4: IIS FTP (NATVO CON FTPS Y APPCMD)
# ====================================================================
function Instalar-IISFTP {
    param($SSL)
    $p_ftp = Read-Host "Puerto FTP [21]" ; if(!$p_ftp) {$p_ftp=21}

    Write-Host "Instalando IIS FTP nativo con DISM..."
    dism.exe /Online /Enable-Feature /FeatureName:IIS-FTPServer /All /NoRestart /quiet | Out-Null
    dism.exe /Online /Enable-Feature /FeatureName:IIS-FTPSvc /All /NoRestart /quiet | Out-Null
    Start-Service FTPSVC -ErrorAction SilentlyContinue

    $appcmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
    & $appcmd delete site "Practica7_IIS_FTP" 2>$null

    $ftp_root = "C:\inetpub\ftproot\P7"
    New-Item -ItemType Directory -Force -Path $ftp_root | Out-Null

    & $appcmd add site /name:"Practica7_IIS_FTP" /bindings:ftp://*:${p_ftp} /physicalPath:"$ftp_root"

    if ($SSL -eq "S") {
        Write-Host "Configurando FTPS (Túnel SSL)..."
        $thumb = Generar-SSL-Nativo "IIS-FTP"
        
        & $appcmd set config "Practica7_IIS_FTP" /section:system.applicationHost/sites "/[name='Practica7_IIS_FTP'].ftpServer.security.ssl.controlChannelPolicy:Require" /commit:apphost
        & $appcmd set config "Practica7_IIS_FTP" /section:system.applicationHost/sites "/[name='Practica7_IIS_FTP'].ftpServer.security.ssl.dataChannelPolicy:Require" /commit:apphost
        & $appcmd set config "Practica7_IIS_FTP" /section:system.applicationHost/sites "/[name='Practica7_IIS_FTP'].ftpServer.security.ssl.serverCertHash:$thumb" /commit:apphost
        
        $script:SERVICIOS_VERIFICAR += "IIS-FTPS|FTPSVC|$p_ftp|ftps"
    } else {
        & $appcmd set config "Practica7_IIS_FTP" /section:system.applicationHost/sites "/[name='Practica7_IIS_FTP'].ftpServer.security.ssl.controlChannelPolicy:Allow" /commit:apphost
        $script:SERVICIOS_VERIFICAR += "IIS-FTP|FTPSVC|$p_ftp|ftp"
    }

    & $appcmd set config "Practica7_IIS_FTP" /section:system.applicationHost/sites "/[name='Practica7_IIS_FTP'].ftpServer.security.authentication.anonymousAuthentication.enabled:True" /commit:apphost
    
    Abrir-Puerto $p_ftp "IIS-FTP"
    $script:RESUMEN_INSTALACIONES += "IIS-FTP | SSL:$SSL | Puerto: $p_ftp"
    Write-Host "[OK] IIS FTP configurado." -ForegroundColor Green
}

# ====================================================================
# VERIFICACIÓN
# ====================================================================
function Verificar-HTTP {
    param($Nombre, $Servicio, $Puerto, $Proto)
    $estado = if (Get-Process $Servicio -ErrorAction SilentlyContinue -or (Get-Service $Servicio -ErrorAction SilentlyContinue).Status -eq 'Running') { "ACTIVO" } else { "INACTIVO" }
    
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $r = Invoke-WebRequest "${Proto}://$IP_WINDOWS:${Puerto}" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $resp = $r.StatusCode
        $hsts = if ($r.Headers["Strict-Transport-Security"]) {"HSTS: OK"} else {""}
    } catch {
        $resp = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "ERROR" }
        $hsts = ""
    }
    Write-Host "  [$Nombre] Proceso: $estado | Puerto $Puerto ($Proto): HTTP $resp $hsts"
}

function Verificar-FTP {
    param($Nombre, $Servicio, $Puerto, $Proto)
    $estado = if ((Get-Service $Servicio -ErrorAction SilentlyContinue).Status -eq 'Running') { "ACTIVO" } else { "INACTIVO" }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($IP_WINDOWS, $Puerto)
        $conn = if ($tcp.Connected) {"ABIERTO"} else {"CERRADO"}
        $tcp.Close()
    } catch { $conn = "CERRADO" }
    Write-Host "  [$Nombre] Proceso: $estado | Puerto $Puerto ($Proto): TCP $conn"
}

function Mostrar-Resumen {
    Write-Host "`n=========================================================="
    Write-Host "         RESUMEN DE INFRAESTRUCTURA (RUBRICA P7)         "
    Write-Host "=========================================================="
    foreach ($r in $script:RESUMEN_INSTALACIONES) { Write-Host "  -> $r" }

    Write-Host "`n-- Verificacion Activa de Instancias ----------------------"
    foreach ($e in $script:SERVICIOS_VERIFICAR) {
        $p = $e -split "\|"
        if ($p[3] -in "http","https") { Verificar-HTTP $p[0] $p[1] $p[2] $p[3] }
        else { Verificar-FTP $p[0] $p[1] $p[2] $p[3] }
    }
    Write-Host "=========================================================="
    Read-Host "Presiona Enter para continuar"
}

# Ejecutar el Menú
Main

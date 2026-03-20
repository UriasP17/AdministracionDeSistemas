```powershell
# ================================
# CONFIG GLOBAL
# ================================
$SOURCE = "wim:D:\sources\install.wim:2"
Import-Module WebAdministration -ErrorAction SilentlyContinue

# ================================
# INSTALAR IIS + FTP (FIX REAL)
# ================================
function Instalar-IIS-FTP {

    Write-Host "[*] Instalando IIS + FTP..." -ForegroundColor Cyan

    $features = @(
        "IIS-WebServerRole",
        "IIS-WebServer",
        "IIS-ManagementConsole",
        "IIS-FTPSvc"
    )

    foreach ($f in $features) {
        dism /online /enable-feature /featurename:$f /all /source:$SOURCE /limitaccess | Out-Null
    }

    Start-Sleep -Seconds 5

    $svc = Get-Service W3SVC -ErrorAction SilentlyContinue
    if (!$svc) {
        Write-Host "[ERROR] IIS no se instaló" -ForegroundColor Red
        return $false
    }

    Write-Host "[OK] IIS instalado correctamente" -ForegroundColor Green
    return $true
}

# ================================
# CREAR SITIO IIS
# ================================
function Levantar-IIS {
    param($Puerto)

    if (!(Instalar-IIS-FTP)) { return }

    Import-Module WebAdministration

    $webRoot = "C:\inetpub\wwwroot"
    if (!(Test-Path $webRoot)) {
        New-Item $webRoot -ItemType Directory -Force | Out-Null
    }

    Set-Content "$webRoot\index.html" "<h1>IIS activo en puerto $Puerto</h1>"

    Remove-Website "Default Web Site" -ErrorAction SilentlyContinue

    New-Website -Name "Default Web Site" `
        -Port $Puerto `
        -PhysicalPath $webRoot -Force | Out-Null

    Start-Service W3SVC

    Write-Host "[OK] IIS corriendo en puerto $Puerto" -ForegroundColor Green
}

# ================================
# CONFIG FTP
# ================================
function Configurar-FTP {

    if (!(Instalar-IIS-FTP)) { return }

    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"

    if (!(Test-Path "C:\FTP")) {
        New-Item "C:\FTP" -ItemType Directory | Out-Null
    }

    & $appcmd delete site "ServidorFTP" 2>$null

    & $appcmd add site `
        /name:"ServidorFTP" `
        /bindings:"ftp/*:21:" `
        /physicalPath:"C:\FTP" | Out-Null

    & $appcmd set config "ServidorFTP" `
        /section:system.ftpServer/security/authentication/anonymousAuthentication `
        /enabled:true /commit:apphost

    & $appcmd set config "ServidorFTP" `
        /section:system.ftpServer/security/authentication/basicAuthentication `
        /enabled:true /commit:apphost

    Start-Service ftpsvc
    & $appcmd start site "ServidorFTP"

    Write-Host "[OK] FTP activo en puerto 21" -ForegroundColor Green
}

# ================================
# NGINX SIMPLE
# ================================
function Levantar-Nginx {
    param($Puerto)

    $nginx = "C:\tools\nginx\nginx.exe"

    if (!(Test-Path $nginx)) {
        Write-Host "[ERROR] nginx no encontrado" -ForegroundColor Red
        return
    }

    Stop-Process -Name nginx -Force -ErrorAction SilentlyContinue

    $conf = @"
events {}
http {
    server {
        listen $Puerto;
        location / {
            root html;
            index index.html;
        }
    }
}
"@

    Set-Content "C:\tools\nginx\conf\nginx.conf" $conf

    Set-Content "C:\tools\nginx\html\index.html" "<h1>Nginx puerto $Puerto</h1>"

    Start-Process $nginx -WorkingDirectory "C:\tools\nginx"

    Write-Host "[OK] Nginx en puerto $Puerto" -ForegroundColor Green
}

# ================================
# APACHE SIMPLE
# ================================
function Levantar-Apache {
    param($Puerto)

    $apache = "C:\Apache24\bin\httpd.exe"

    if (!(Test-Path $apache)) {
        Write-Host "[ERROR] Apache no encontrado" -ForegroundColor Red
        return
    }

    Stop-Process -Name httpd -Force -ErrorAction SilentlyContinue

    $conf = "C:\Apache24\conf\httpd.conf"

    (Get-Content $conf) -replace "Listen 80", "Listen $Puerto" | Set-Content $conf

    Set-Content "C:\Apache24\htdocs\index.html" "<h1>Apache puerto $Puerto</h1>"

    Start-Process $apache

    Write-Host "[OK] Apache en puerto $Puerto" -ForegroundColor Green
}

# ================================
# MENU
# ================================
function Menu {

    while ($true) {

        Write-Host ""
        Write-Host "1) IIS"
        Write-Host "2) Nginx"
        Write-Host "3) Apache"
        Write-Host "4) FTP"
        Write-Host "5) Puerto"
        Write-Host "0) Salir"

        $op = Read-Host "Opcion"

        switch ($op) {

            "1" {
                $p = Read-Host "Puerto"
                Levantar-IIS $p
            }

            "2" {
                $p = Read-Host "Puerto"
                Levantar-Nginx $p
            }

            "3" {
                $p = Read-Host "Puerto"
                Levantar-Apache $p
            }

            "4" {
                Configurar-FTP
            }

            "5" {
                $global:PUERTO = Read-Host "Nuevo puerto"
            }

            "0" { exit }
        }
    }
}

Menu
```

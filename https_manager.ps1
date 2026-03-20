```powershell
# ================================
# CONFIG
# ================================
$SOURCE = "wim:D:\sources\install.wim:2"

# ================================
# INSTALAR IIS BIEN
# ================================
function Instalar-IIS {

    Write-Host "[*] Instalando IIS completo..." -ForegroundColor Cyan

    $features = @(
        "IIS-WebServerRole",
        "IIS-WebServer",
        "IIS-CommonHttpFeatures",
        "IIS-StaticContent",
        "IIS-DefaultDocument",
        "IIS-DirectoryBrowsing",
        "IIS-HttpErrors",
        "IIS-HttpRedirect",
        "IIS-ApplicationDevelopment",
        "IIS-NetFxExtensibility45",
        "IIS-ISAPIExtensions",
        "IIS-ISAPIFilter",
        "IIS-ManagementConsole",
        "IIS-FTPSvc"
    )

    foreach ($f in $features) {
        dism /online /enable-feature /featurename:$f /all /source:$SOURCE /limitaccess | Out-Null
    }

    Start-Sleep -Seconds 5

    if (Get-Service W3SVC -ErrorAction SilentlyContinue) {
        Write-Host "[OK] IIS listo" -ForegroundColor Green
        return $true
    } else {
        Write-Host "[ERROR] IIS no quedó instalado" -ForegroundColor Red
        return $false
    }
}

# ================================
# IIS
# ================================
function Levantar-IIS {
    param($Puerto)

    if (!(Instalar-IIS)) { return }

    Import-Module WebAdministration

    $root = "C:\inetpub\wwwroot"
    if (!(Test-Path $root)) {
        New-Item $root -ItemType Directory | Out-Null
    }

    Set-Content "$root\index.html" "<h1>IIS puerto $Puerto</h1>"

    Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
    Remove-Website "Default Web Site" -ErrorAction SilentlyContinue

    New-Website -Name "Default Web Site" -Port $Puerto -PhysicalPath $root -Force | Out-Null

    Start-Service W3SVC

    if (Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "[OK] IIS corriendo en puerto $Puerto" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] IIS no levantó" -ForegroundColor Red
    }
}

# ================================
# FTP
# ================================
function Configurar-FTP {

    if (!(Instalar-IIS)) { return }

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

    Start-Service ftpsvc -ErrorAction SilentlyContinue
    & $appcmd start site "ServidorFTP"

    if (Get-NetTCPConnection -LocalPort 21 -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "[OK] FTP activo" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] FTP no levantó" -ForegroundColor Red
    }
}

# ================================
# NGINX
# ================================
function Levantar-Nginx {
    param($Puerto)

    $nginx = "C:\tools\nginx\nginx.exe"
    if (!(Test-Path $nginx)) {
        Write-Host "[ERROR] nginx no existe" -ForegroundColor Red
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
    Set-Content "C:\tools\nginx\html\index.html" "<h1>Nginx $Puerto</h1>"

    Start-Process $nginx -WorkingDirectory "C:\tools\nginx"

    Write-Host "[OK] Nginx puerto $Puerto" -ForegroundColor Green
}

# ================================
# APACHE
# ================================
function Levantar-Apache {
    param($Puerto)

    $apache = "C:\Apache24\bin\httpd.exe"
    if (!(Test-Path $apache)) {
        Write-Host "[ERROR] Apache no existe" -ForegroundColor Red
        return
    }

    Stop-Process -Name httpd -Force -ErrorAction SilentlyContinue

    (Get-Content "C:\Apache24\conf\httpd.conf") -replace "Listen 80", "Listen $Puerto" | Set-Content "C:\Apache24\conf\httpd.conf"

    Set-Content "C:\Apache24\htdocs\index.html" "<h1>Apache $Puerto</h1>"

    Start-Process $apache

    Write-Host "[OK] Apache puerto $Puerto" -ForegroundColor Green
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

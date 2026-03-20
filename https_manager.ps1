Import-Module WebAdministration -ErrorAction SilentlyContinue

# =========================
# FIX GLOBAL DISM
# =========================
$WIM_PATH = "wim:D:\sources\install.wim:2"

function Instalar-FeatureSeguro {
    param($nombre)

    $feature = Get-WindowsFeature -Name $nombre -ErrorAction SilentlyContinue

    if ($feature -and $feature.InstallState -ne "Installed") {
        Install-WindowsFeature `
            -Name $nombre `
            -IncludeManagementTools `
            -Source $WIM_PATH `
            -LimitAccess `
            -ErrorAction SilentlyContinue | Out-Null
    }
}

# =========================
# PUERTOS BLOQUEADOS
# =========================
$PUERTOS_BLOQUEADOS = @(1,7,9,11,13,15,17,19,20,21,22,23,25,37,42,43,53,69,77,79,
    87,95,101,102,103,104,109,110,111,113,115,117,119,123,135,139,142,143,179,389,
    465,512,513,514,515,526,530,531,532,540,548,554,556,563,587,601,636,993,995,
    2049,3659,4045,6000,6665,6666,6667,6668,6669,6697)

# =========================
# LIMPIAR
# =========================
function Limpiar-Entorno {
    param($Puerto)
    Stop-Service nginx, Apache, Apache2.4, W3SVC, ftpsvc -Force -ErrorAction SilentlyContinue
    taskkill /F /IM nginx.exe /T 2>$null
    taskkill /F /IM httpd.exe /T 2>$null
    $con = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    if ($con) { $con.OwningProcess | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
    Start-Sleep 2
}

# =========================
# PAGINA
# =========================
function Crear-Pagina {
    param($servicio, $puerto)

    $path = switch ($servicio) {
        "nginx"  { "C:\tools\nginx-1.29.6\html\index.html" }
        "apache" { "C:\Apache24\htdocs\index.html" }
        "iis"    { "C:\inetpub\wwwroot\index.html" }
    }

    $dir = Split-Path $path
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }

    "<h1>$servicio activo en $puerto</h1>" | Set-Content $path
}

# =========================
# CERT SSL
# =========================
function Obtener-CertObj {
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*reprobados*" } | Select-Object -First 1
    if (!$cert) {
        $cert = New-SelfSignedCertificate -DnsName "www.reprobados.com" `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddDays(365)
    }
    return $cert
}

# =========================
# DESPLIEGUE
# =========================
function Aplicar-Despliegue {
    param($Servicio)

    if (-not ($global:PUERTO_ACTUAL -match '^\d+$')) {
        $global:PUERTO_ACTUAL = Read-Host "Puerto"
    }

    $P = [int]$global:PUERTO_ACTUAL

    Limpiar-Entorno $P

    switch ($Servicio) {

        "iis" {

            Instalar-FeatureSeguro "Web-Server"
            Instalar-FeatureSeguro "Web-Http-Redirect"

            $cert = Obtener-CertObj
            $root = "C:\inetpub\wwwroot"

            if (!(Test-Path $root)) { New-Item $root -ItemType Directory | Out-Null }

            Crear-Pagina "iis" $P

            Remove-Website "Default Web Site" -ErrorAction SilentlyContinue
            New-Website -Name "Default Web Site" -Port $P -PhysicalPath $root -Force | Out-Null

            New-WebBinding -Name "Default Web Site" -Protocol "https" -Port $P
            Get-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" |
                New-Item "IIS:\SslBindings\*!$P" -Force | Out-Null

            Start-Service W3SVC
        }

        "nginx" {
            Crear-Pagina "nginx" $P
        }

        "apache" {
            Crear-Pagina "apache" $P
        }
    }

    if (Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "[OK] $Servicio en puerto $P" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] No levantó" -ForegroundColor Red
    }
}

# =========================
# FTP SEGURO
# =========================
function Configurar-FTP-Seguro {

    Instalar-FeatureSeguro "Web-Ftp-Server"
    Instalar-FeatureSeguro "Web-Ftp-Service"
    Instalar-FeatureSeguro "Web-Mgmt-Console"

    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"

    if (!(Test-Path "C:\FTP_Publico")) {
        New-Item "C:\FTP_Publico" -ItemType Directory | Out-Null
    }

    & $appcmd add site /name:"ServidorFTP" /bindings:"ftp/*:21:" /physicalPath:"C:\FTP_Publico" 2>$null

    $cert = Obtener-CertObj

    & $appcmd set site "ServidorFTP" "-ftpServer.security.ssl.controlChannelPolicy:SslAllow"
    & $appcmd set site "ServidorFTP" "-ftpServer.security.ssl.serverCertHash:$($cert.Thumbprint)"

    Start-Service ftpsvc

    if (Get-NetTCPConnection -LocalPort 21 -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "[OK] FTP activo" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] FTP no levantó" -ForegroundColor Red
    }
}

# =========================
# PUERTO
# =========================
function Validar-Puerto {
    $global:PUERTO_ACTUAL = Read-Host "Puerto"
}

# =========================
# MENU
# =========================
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
            "1" { Aplicar-Despliegue "iis" }
            "2" { Aplicar-Despliegue "nginx" }
            "3" { Aplicar-Despliegue "apache" }
            "4" { Configurar-FTP-Seguro }
            "5" { Validar-Puerto }
            "0" { break }
        }
    }
}

Menu

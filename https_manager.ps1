# ==============================================================================
# MODULO HTTP/FTP COMBINADO - WINDOWS (P07) FIX
# ==============================================================================

Import-Module WebAdministration -ErrorAction SilentlyContinue

# ================================================================
# INSTALAR IIS (FIX REAL)
# ================================================================
function Instalar-IIS {
    Write-Host "[*] Instalando IIS..." -ForegroundColor Yellow

    # Detecta si existe el comando
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        Install-WindowsFeature -Name Web-Server -IncludeManagementTools
    } else {
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole -All -NoRestart
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-ManagementConsole -All -NoRestart
    }

    Start-Sleep -Seconds 3

    $svc = Get-Service W3SVC -ErrorAction SilentlyContinue
    if ($svc) {
        Start-Service W3SVC
        Write-Host "[OK] IIS instalado correctamente" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] IIS no se instaló" -ForegroundColor Red
    }
}

# ================================================================
# LIMPIAR PUERTO
# ================================================================
function Limpiar-Entorno {
    param($Puerto)

    Write-Host "[*] Limpiando puerto $Puerto..."

    Stop-Service W3SVC -ErrorAction SilentlyContinue
    taskkill /F /IM nginx.exe 2>$null
    taskkill /F /IM httpd.exe 2>$null

    $con = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    if ($con) {
        Stop-Process -Id $con.OwningProcess -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep 2
}

# ================================================================
# PAGINA HTML
# ================================================================
function Crear-Pagina {
    param($servicio, $puerto)

    $path = "C:\inetpub\wwwroot\index.html"

    if (!(Test-Path "C:\inetpub\wwwroot")) {
        New-Item "C:\inetpub\wwwroot" -ItemType Directory -Force
    }

    $html = @"
<html>
<head><title>$servicio</title></head>
<body>
<h1>$servicio funcionando</h1>
<p>Puerto: $puerto</p>
</body>
</html>
"@

    Set-Content $path $html
}

# ================================================================
# CERTIFICADO SSL
# ================================================================
function Obtener-CertObj {
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.Subject -like "*reprobados*"
    } | Select-Object -First 1

    if (!$cert) {
        $cert = New-SelfSignedCertificate `
            -DnsName "www.reprobados.com" `
            -CertStoreLocation "Cert:\LocalMachine\My"
    }

    return $cert
}

# ================================================================
# IIS DESPLIEGUE
# ================================================================
function Deploy-IIS {
    param($puerto)

    Limpiar-Entorno $puerto

    Instalar-IIS

    Crear-Pagina "IIS" $puerto

    Remove-Website "Default Web Site" -ErrorAction SilentlyContinue

    New-Website -Name "Default Web Site" `
        -Port $puerto `
        -PhysicalPath "C:\inetpub\wwwroot"

    Start-Service W3SVC

    Write-Host "[OK] IIS corriendo en puerto $puerto" -ForegroundColor Green
}

# ================================================================
# MENU
# ================================================================
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
            Deploy-IIS $p
        }

        "2" {
            if (!(Test-Path "C:\tools\nginx")) {
                Write-Host "[ERROR] nginx no existe"
            } else {
                Write-Host "[OK] nginx instalado (falta integrar deploy)"
            }
        }

        "3" {
            Write-Host "[INFO] Apache aun no integrado"
        }

        "4" {
            Write-Host "[INFO] FTP aun no integrado"
        }

        "5" {
            $global:PUERTO = Read-Host "Nuevo puerto"
        }

        "0" {
            break
        }

        default {
            Write-Host "Invalido"
        }
    }
}

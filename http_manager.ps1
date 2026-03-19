# ==========================================
# SCRIPT DE GESTION DE SERVIDORES WEB
# ==========================================

# Validar que se corra como Administrador
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "[!] Cierra esta ventana y abre PowerShell como Administrador."
    Start-Sleep -Seconds 4
    exit
}

# --- FUNCIONES DE IIS ---
Function Instalar-IIS {
    Write-Host "`n[*] Instalando IIS (Esto puede tardar un poco)..." -ForegroundColor Cyan
    Install-WindowsFeature -name Web-Server -IncludeManagementTools | Out-Null
    New-NetFirewallRule -DisplayName "HTTP-IIS" -LocalPort 80 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[+] IIS instalado correctamente en el puerto 80." -ForegroundColor Green
}

Function Desinstalar-IIS {
    Write-Host "`n[*] Desinstalando IIS..." -ForegroundColor Yellow
    Uninstall-WindowsFeature -name Web-Server -Remove | Out-Null
    Remove-NetFirewallRule -DisplayName "HTTP-IIS" -ErrorAction SilentlyContinue
    Write-Host "[-] IIS desinstalado." -ForegroundColor Green
}

# --- FUNCIONES DE APACHE / NGINX ---
Function Instalar-Opcional {
    param($Servicio)

    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }

    Write-Host "`n[*] Preparando instalacion de $Servicio..." -ForegroundColor Yellow
    Write-Host "1) Instalar la version mas reciente (Recomendado)"
    Write-Host "2) Escribir una version manual (ej. 2.4.57)"
    $op = Read-Host "Elige una opcion [1/2] (Enter para mas reciente)"
    
    if ($op -eq "2") {
        $ver = Read-Host "Escribe la version exacta"
    } else {
        $ver = "Latest"
    }

    $puerto = Read-Host "Ingresa puerto para $Servicio (ej. 8080)"
    if ([string]::IsNullOrWhiteSpace($puerto)) { $puerto = 8080 }

    # Verificar si el puerto ya se está usando
    $ocupado = Test-NetConnection -ComputerName localhost -Port $puerto -WarningAction SilentlyContinue
    if ($ocupado.TcpTestSucceeded) {
        Write-Host "[X] El puerto $puerto ya esta en uso. Intenta con otro." -ForegroundColor Red
        return
    }

    Write-Host "[*] Descargando e instalando $Servicio desde Chocolatey..." -ForegroundColor Cyan
    
    # Instalacion forzada
    if ($ver -eq "Latest") {
        choco install $paquete -y --force | Out-Null
    } else {
        choco install $paquete --version $ver -y --force | Out-Null
    }

    Write-Host "[*] Configurando puertos y archivos..." -ForegroundColor Yellow
    
    # Buscamos rutas base comunes de Chocolatey
    $rutasBusqueda = @("C:\tools", "C:\ProgramData\chocolatey\lib\$paquete")

    if ($Servicio -eq "nginx") {
        $archivoConf = Get-ChildItem -Path $rutasBusqueda -Filter "nginx.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $nginxRoot = $archivoConf.Directory.Parent.FullName
            $htmlDir = Join-Path -Path $nginxRoot -ChildPath "html"

            (Get-Content $conf) -replace "listen\s+80;", "listen       $puerto;" | Set-Content $conf
            
            if (-not (Test-Path $htmlDir)) { New-Item -ItemType Directory -Path $htmlDir | Out-Null }
            "Servidor: Nginx - Version: $ver - Puerto: $puerto" | Out-File (Join-Path $htmlDir "index.html")
            
            $exeNginx = Join-Path -Path $nginxRoot -ChildPath "nginx.exe"
            if (Test-Path $exeNginx) {
                Start-Process $exeNginx -WorkingDirectory $nginxRoot
            }
        } else {
            Write-Host "[X] Error: Nginx no se configuro. No se encontro nginx.conf." -ForegroundColor Red
            return
        }
    }

    if ($Servicio -eq "apache") {
        $archivoConf = Get-ChildItem -Path $rutasBusqueda -Filter "httpd.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $apacheRoot = $archivoConf.Directory.Parent.FullName
            $htdocs = Join-Path -Path $apacheRoot -ChildPath "htdocs"

            (Get-Content $conf) -replace "Listen 80", "Listen $puerto" | Set-Content $conf
            (Get-Content $conf) -replace "ServerTokens Full", "ServerTokens Prod" | Set-Content $conf
            (Get-Content $conf) -replace "ServerSignature On", "ServerSignature Off" | Set-Content $conf
            
            if (-not (Test-Path $htdocs)) { New-Item -ItemType Directory -Path $htdocs | Out-Null }
            "Servidor: Apache - Version: $ver - Puerto: $puerto" | Out-File (Join-Path $htdocs "index.html")
            
            Restart-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
        } else {
            Write-Host "[X] Error: Apache no se configuro. No se encontro httpd.conf." -ForegroundColor Red
            return
        }
    }

    New-NetFirewallRule -DisplayName "HTTP-$Servicio" -LocalPort $puerto -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[+] $Servicio instalado y configurado correctamente en el puerto $puerto." -ForegroundColor Green
}

Function Desinstalar-Opcional {
    param($Servicio)
    
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }
    
    Write-Host "`n[*] Deteniendo y desinstalando $Servicio..." -ForegroundColor Yellow
    
    if ($Servicio -eq "nginx") {
        Stop-Process -Name "nginx" -ErrorAction SilentlyContinue
    }
    if ($Servicio -eq "apache") {
        Stop-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    }

    choco uninstall $paquete -y | Out-Null
    Remove-NetFirewallRule -DisplayName "HTTP-$Servicio" -ErrorAction SilentlyContinue
    
    # Limpieza general
    if (Test-Path "C:\tools\$paquete") { Remove-Item "C:\tools\$paquete" -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path "C:\tools\apache24") { Remove-Item "C:\tools\apache24" -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path "C:\tools\nginx") { Remove-Item "C:\tools\nginx" -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "[-] $Servicio desinstalado y limpio." -ForegroundColor Green
}

# --- MENU PRINCIPAL ---
do {
    Write-Host "`n======= MENU WINDOWS =======" -ForegroundColor Cyan
    Write-Host "1) Instalar IIS (Obligatorio)"
    Write-Host "2) Instalar Apache (Opcional)"
    Write-Host "3) Instalar Nginx (Opcional)"
    Write-Host "4) Desinstalar IIS"
    Write-Host "5) Desinstalar Apache"
    Write-Host "6) Desinstalar Nginx"
    Write-Host "0) Salir"
    
    $opcion = Read-Host "Elige una opcion"

    switch ($opcion) {
        "1" { Instalar-IIS }
        "2" { Instalar-Opcional -Servicio "apache" }
        "3" { Instalar-Opcional -Servicio "nginx" }
        "4" { Desinstalar-IIS }
        "5" { Desinstalar-Opcional -Servicio "apache" }
        "6" { Desinstalar-Opcional -Servicio "nginx" }
        "0" { Write-Host "Saliendo del script..."; break }
        default { Write-Host "[X] Opcion no valida." -ForegroundColor Red }
    }
} while ($opcion -ne "0")

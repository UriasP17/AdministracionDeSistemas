# ==========================================
# SCRIPT DE GESTION DE SERVIDORES WEB (CHOCOLATEY)
# ==========================================

$VM_IP = "192.168.56.10" # Tu IP de VirtualBox

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "[!] Ejecuta PowerShell como Administrador."
    Start-Sleep -Seconds 4
    exit
}

function Solicitar-Puerto {
    param([string]$ServicioNombre)
    $PUERTOS_RESERVADOS = @(20,21,22,23,25,53,110,143,445,3306,3389,5432)
    
    while ($true) {
        $input_p = Read-Host "Ingresa puerto para $ServicioNombre (ej. 8080, 81)"
        if ([string]::IsNullOrWhiteSpace($input_p)) { return 8080 }
        
        if ($input_p -notmatch '^\d+$') { Write-Host "[!] Solo numeros." -ForegroundColor Red; continue }
        
        $p = [int]$input_p
        
        if ($PUERTOS_RESERVADOS -contains $p) {
            Write-Host "[!] Puerto $p esta reservado por el sistema. Elige otro." -ForegroundColor Red
            continue
        }
        
        $ocupado = Test-NetConnection -ComputerName localhost -Port $p -WarningAction SilentlyContinue
        if ($ocupado.TcpTestSucceeded) {
            Write-Host "[!] El puerto $p ya esta en uso. Intenta con otro." -ForegroundColor Red
            continue
        }
        return $p
    }
}

function Crear-Index {
    param([string]$Ruta, [string]$Servicio, [string]$Version, [int]$Puerto)
    if (!(Test-Path $Ruta)) { New-Item -Path $Ruta -ItemType Directory -Force | Out-Null }
    
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>$Servicio - Puerto $Puerto</title>
  <style>
    body { font-family: Arial, sans-serif; background-color: #f4f4f9; color: #333; text-align: center; padding: 50px; }
    .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0px 0px 10px rgba(0,0,0,0.1); display: inline-block; }
    h1 { color: #0078D7; }
  </style>
</head>
<body>
  <div class="container">
      <h1>¡Servidor Activo!</h1>
      <p><strong>Servidor:</strong> $Servicio</p>
      <p><strong>Version:</strong> $Version</p>
      <p><strong>Puerto:</strong> $Puerto</p>
      <p><strong>IP VirtualBox:</strong> $VM_IP</p>
      <p>URL: http://${VM_IP}:${Puerto}</p>
  </div>
</body>
</html>
"@
    [IO.File]::WriteAllText("$Ruta\index.html", $html)
}

function Configurar-Firewall {
    param([int]$Puerto, [string]$Nombre)
    $ruleName = "HTTP-$Nombre-$Puerto"
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Puerto -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
}

Function Instalar-IIS {
    $puerto = 80
    Write-Host "`n[*] Configurando servidor HTTP Nativo de Windows..." -ForegroundColor Cyan
    
    $webRoot = "C:\inetpub\wwwroot\mi_sitio"
    Crear-Index -Ruta $webRoot -Servicio "Windows HTTP Nativo" -Version "System.Net" -Puerto $puerto
    Configurar-Firewall -Puerto $puerto -Nombre "HTTP-Nativo"
    
    $codigoServidor = @"
try {
`$listener = New-Object System.Net.HttpListener
`$listener.Prefixes.Add('http://*:$puerto/')
`$listener.Start()
while (`$listener.IsListening) {
`$context = `$listener.GetContext()
`$response = `$context.Response
`$content = Get-Content -Path '$webRoot\index.html' -Raw
`$buffer = [System.Text.Encoding]::UTF8.GetBytes(`$content)
`$response.ContentLength64 = `$buffer.Length
`$response.OutputStream.Write(`$buffer, 0, `$buffer.Length)
`$response.Close()
}
} catch { exit }
"@

    Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -NoProfile -Command `"$codigoServidor`""
    Write-Host "[+] Servidor Web Nativo activo en el puerto $puerto." -ForegroundColor Green
    Write-Host "[>] Abre en tu Host: http://${VM_IP}" -ForegroundColor Yellow
}

Function Desinstalar-IIS {
    Write-Host "`n[*] Desinstalando IIS..." -ForegroundColor Yellow
    Stop-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq "" }
    Remove-NetFirewallRule -DisplayName "HTTP-HTTP-Nativo-80" -ErrorAction SilentlyContinue
    Write-Host "[-] Sitio HTTP Nativo apagado." -ForegroundColor Green
}

Function Instalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }

    Write-Host "`n[*] Preparando instalacion de $Servicio..." -ForegroundColor Yellow
    $ver = "Latest"
    $puerto = Solicitar-Puerto -ServicioNombre $Servicio

    Write-Host "[*] Instalando $Servicio ($ver) desde Chocolatey..." -ForegroundColor Cyan
    choco install $paquete -y --force | Out-Null

    $rutasBusqueda = @("C:\tools", "C:\Apache24", "C:\ProgramData\chocolatey\lib\$paquete", "$env:APPDATA\Apache24", "$env:APPDATA\nginx", "$env:APPDATA")

    if ($Servicio -eq "nginx") {
        $archivoConf = Get-ChildItem -Path $rutasBusqueda -Filter "nginx.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $nginxRoot = $archivoConf.Directory.Parent.FullName
            $htmlDir = Join-Path -Path $nginxRoot -ChildPath "html"

            (Get-Content $conf) -replace "listen\s+80;", "listen       $puerto;" | Set-Content $conf
            Crear-Index -Ruta $htmlDir -Servicio "Nginx" -Version $ver -Puerto $puerto
            
            $exeNginx = Join-Path -Path $nginxRoot -ChildPath "nginx.exe"
            if (Test-Path $exeNginx) { Start-Process $exeNginx -WorkingDirectory $nginxRoot -WindowStyle Hidden }
        } else { Write-Host "[X] Error: No se encontro nginx.conf." -ForegroundColor Red; return }
    }

    if ($Servicio -eq "apache") {
        $archivoConf = Get-ChildItem -Path $rutasBusqueda -Filter "httpd.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $apacheRoot = $archivoConf.Directory.Parent.FullName
            $htdocs = Join-Path -Path $apacheRoot -ChildPath "htdocs"

            (Get-Content $conf) -replace "Listen 80", "Listen $puerto" | Set-Content $conf
            (Get-Content $conf) -replace "^ServerName.*", "" | Set-Content $conf
            Add-Content -Path $conf -Value "`nServerName localhost:$puerto"
            
            Crear-Index -Ruta $htdocs -Servicio "Apache" -Version $ver -Puerto $puerto
            
            $apacheExe = Get-ChildItem -Path $apacheRoot -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($apacheExe) {
                Write-Host "[*] Instalando y arrancando Apache como Servicio SSH..." -ForegroundColor Yellow
                
                # Desinstalar cualquier rastro de apache
                & $apacheExe.FullName -k uninstall 2>$null
                Start-Sleep -Seconds 1
                
                # Instalarlo en el sistema real
                & $apacheExe.FullName -k install 2>$null
                Start-Sleep -Seconds 1
                
                # Levantar el servicio usando comandos de red de Windows (Infalible en SSH)
                net start Apache2.4
                
            } else { Write-Host "[X] Error: No encontre httpd.exe" -ForegroundColor Red; return }
        } else { Write-Host "[X] Error: No se encontro httpd.conf." -ForegroundColor Red; return }
    }

    Configurar-Firewall -Puerto $puerto -Nombre $Servicio
    Write-Host "[+] $Servicio instalado correctamente." -ForegroundColor Green
    Write-Host "[>] Abre en tu Host: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}

Function Desinstalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }
    
    Write-Host "`n[*] Desinstalando $Servicio..." -ForegroundColor Yellow
    if ($Servicio -eq "nginx") { Stop-Process -Name "nginx" -Force -ErrorAction SilentlyContinue }
    if ($Servicio -eq "apache") { 
        net stop Apache2.4 2>$null
        $apacheExe = Get-ChildItem -Path "C:\tools", "C:\Apache24" -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($apacheExe) { & $apacheExe.FullName -k uninstall 2>$null }
        Stop-Process -Name "httpd" -Force -ErrorAction SilentlyContinue 
    }

    choco uninstall $paquete -y | Out-Null
    
    Get-NetFirewallRule -DisplayName "HTTP-$Servicio-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    if (Test-Path "C:\tools\$paquete") { Remove-Item "C:\tools\$paquete" -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path "C:\tools\apache24") { Remove-Item "C:\tools\apache24" -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path "C:\Apache24") { Remove-Item "C:\Apache24" -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "[-] $Servicio desinstalado y carpetas limpias." -ForegroundColor Green
}

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

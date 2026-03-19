# ==========================================
# SCRIPT DE GESTION DE SERVIDORES WEB
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
        
        if ($input_p -notmatch '^\d+$') { Write-Host "[-] Solo numeros permitidos." -ForegroundColor Red; continue }
        
        $p = [int]$input_p
        
        if ($PUERTOS_RESERVADOS -contains $p) {
            Write-Host "[-] El puerto $p esta reservado por el sistema. Elige otro." -ForegroundColor Red
            continue
        }
        
        $ocupado = Test-NetConnection -ComputerName localhost -Port $p -WarningAction SilentlyContinue
        if ($ocupado.TcpTestSucceeded) {
            Write-Host "[-] El puerto $p ya esta ocupado. Intenta con otro." -ForegroundColor Red
            continue
        }
        return $p
    }
}

function Crear-Index {
    param([string]$Ruta, [string]$Servicio, [string]$Version, [int]$Puerto)
    if (!(Test-Path $Ruta)) { New-Item -Path $Ruta -ItemType Directory -Force | Out-Null }
    
    # ======== DISENO MINIMALISTA ========
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>$Servicio - Port $Puerto</title>
  <style>
    body { 
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        background-color: #f8f9fa; 
        color: #333; 
        display: flex;
        justify-content: center;
        align-items: center;
        height: 100vh;
        margin: 0;
    }
    .card { 
        background: #ffffff; 
        padding: 40px; 
        border-radius: 8px; 
        box-shadow: 0 4px 6px rgba(0,0,0,0.05); 
        text-align: left;
        min-width: 300px;
        border-top: 4px solid #0078D7;
    }
    h2 { 
        color: #333; 
        margin-top: 0;
        font-weight: 500;
        border-bottom: 1px solid #eee;
        padding-bottom: 10px;
    }
    .info-row {
        margin: 12px 0;
        font-size: 14px;
    }
    .label {
        color: #666;
        display: inline-block;
        width: 100px;
    }
    .value {
        font-weight: 500;
        color: #000;
    }
    .code-block {
        background: #f1f3f5;
        padding: 8px 12px;
        border-radius: 4px;
        font-family: monospace;
        font-size: 13px;
        color: #0078D7;
        margin-top: 20px;
    }
  </style>
</head>
<body>
  <div class="card">
      <h2>Servidor Activo</h2>
      <div class="info-row">
          <span class="label">Servicio:</span>
          <span class="value">$Servicio</span>
      </div>
      <div class="info-row">
          <span class="label">Version:</span>
          <span class="value">$Version</span>
      </div>
      <div class="info-row">
          <span class="label">Puerto:</span>
          <span class="value">$Puerto</span>
      </div>
      <div class="code-block">http://${VM_IP}:${Puerto}</div>
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
    Write-Host "`n[*] Configurando servidor HTTP Nativo..." -ForegroundColor Cyan
    
    $puerto = Solicitar-Puerto -ServicioNombre "IIS_Nativo"
    
    $webRoot = "C:\inetpub\wwwroot\mi_sitio"
    Crear-Index -Ruta $webRoot -Servicio "Windows HTTP Nativo" -Version "System.Net" -Puerto $puerto
    Configurar-Firewall -Puerto $puerto -Nombre "HTTP-Nativo"
    
    $codigoServidor = @"
try {
`$host.ui.RawUI.WindowTitle = 'ServidorNativoIIS'
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
    Write-Host "[+] Servidor activo en puerto $puerto." -ForegroundColor Green
    Write-Host "[>] URL: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}

Function Desinstalar-IIS {
    Write-Host "`n[*] Desinstalando IIS y liberando puertos..." -ForegroundColor Yellow
    
    # Matar proceso via WMI para asegurar que suelte el puerto
    $iisProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%ServidorNativoIIS%'"
    foreach ($p in $iisProcs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    
    # Limpieza agresiva de firewall
    Get-NetFirewallRule -DisplayName "HTTP-HTTP-Nativo-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    
    Write-Host "[-] Sitio apagado. Puerto liberado." -ForegroundColor Green
}

Function Instalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }
    $nombreArchivo = if ($Servicio -eq "apache") { "httpd.conf" } else { "nginx.conf" }

    Write-Host "`n[*] Preparando instalacion de $Servicio..." -ForegroundColor Yellow
    $ver = "Latest"
    $puerto = Solicitar-Puerto -ServicioNombre $Servicio

    Write-Host "[*] Descargando paquetes y desempaquetando (esto tomara unos segundos)..." -ForegroundColor Cyan
    
    if ($Servicio -eq "nginx") {
        choco install $paquete -y --force --package-parameters "/port:$puerto" | Out-Null
    } else {
        # Instalar apache de forma limpia
        choco install $paquete -y --force | Out-Null
    }
    
    # ======= FIX: DAR MAS TIEMPO PARA QUE DESCOMPRIMA =======
    Write-Host "[*] Esperando a que el sistema extraiga los archivos..." -ForegroundColor Yellow
    Start-Sleep -Seconds 8

    $archivoConf = $null
    
    # ======= FIX: BUSQUEDA RECURSIVA MAS AMPLIA =======
    Write-Host "[*] Buscando configuracion de $Servicio..." -ForegroundColor Cyan
    $rutasBusqueda = @("C:\tools", "C:\ProgramData\chocolatey\lib", "C:\nginx", "C:\Apache24")
    
    foreach ($ruta in $rutasBusqueda) {
        if (Test-Path $ruta) {
            # Buscamos en todas las subcarpetas sin importar qué nombre raro les ponga choco
            $resultado = Get-ChildItem -Path $ruta -Filter $nombreArchivo -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($resultado) {
                $archivoConf = $resultado
                break
            }
        }
    }

    if ($Servicio -eq "nginx") {
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $nginxRoot = $archivoConf.Directory.Parent.FullName
            $htmlDir = Join-Path -Path $nginxRoot -ChildPath "html"

            Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 1

            $textoConf = Get-Content $conf
            $textoConf = $textoConf -replace '(?m)^\s*listen\s+\d+\s*;', "        listen       $puerto;"
            $textoConf | Set-Content $conf

            Crear-Index -Ruta $htmlDir -Servicio "Nginx" -Version $ver -Puerto $puerto
            
            $exeNginx = Get-ChildItem -Path $nginxRoot -Filter "nginx.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exeNginx) {
                Start-Process $exeNginx.FullName -WorkingDirectory $exeNginx.Directory.FullName -WindowStyle Hidden
            } else { Write-Host "[-] Error: nginx.exe no encontrado." -ForegroundColor Red; return }
        } else { Write-Host "[-] Error: nginx.conf no encontrado. Revisa que choco haya instalado bien." -ForegroundColor Red; return }
    }

    if ($Servicio -eq "apache") {
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $apacheRoot = $archivoConf.Directory.Parent.FullName
            
            $apacheRootFormat = $apacheRoot -replace "\\", "/"
            $htdocs = Join-Path -Path $apacheRoot -ChildPath "htdocs"

            Write-Host "[*] Inyectando configuracion en Apache..." -ForegroundColor Cyan
            $textoConf = Get-Content $conf
            $textoConf = $textoConf -replace 'Define SRVROOT .*', "Define SRVROOT `"$apacheRootFormat`""
            $textoConf = $textoConf -replace '(?i)c:/Apache24', $apacheRootFormat
            $textoConf = $textoConf -replace '(?m)^Listen\s+\d+', "Listen $puerto"
            $textoConf = $textoConf -replace '(?m)^#?\s*ServerName.*', "ServerName localhost:$puerto"
            $textoConf | Set-Content $conf
            
            Crear-Index -Ruta $htdocs -Servicio "Apache" -Version $ver -Puerto $puerto
            
            $apacheExe = Get-ChildItem -Path $apacheRoot -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($apacheExe) {
                & $apacheExe.FullName -k uninstall 2>$null
                Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 2
                
                Write-Host "[*] Iniciando servicio Apache..." -ForegroundColor Cyan
                & $apacheExe.FullName -k install 2>$null
                Start-Sleep -Seconds 2
                
                net start Apache2.4 | Out-Null
                
            } else { Write-Host "[-] Error: httpd.exe no encontrado." -ForegroundColor Red; return }
        } else { Write-Host "[-] Error: httpd.conf no encontrado. Intenta darle a la opcion 5 (Desinstalar) y vuelve a instalar." -ForegroundColor Red; return }
    }

    Configurar-Firewall -Puerto $puerto -Nombre $Servicio
    Write-Host "[+] $Servicio instalado correctamente en puerto $puerto." -ForegroundColor Green
    Write-Host "[>] URL: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}


Function Desinstalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }
    
    Write-Host "`n[*] Desinstalando $Servicio y liberando puerto..." -ForegroundColor Yellow
    
    # Matar procesos agresivamente para soltar el puerto
    if ($Servicio -eq "nginx") { 
        Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force 
    }
    if ($Servicio -eq "apache") { 
        net stop Apache2.4 2>$null
        $apacheExe = Get-ChildItem -Path "C:\tools" -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($apacheExe) { & $apacheExe.FullName -k uninstall 2>$null }
        Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force 
    }

    choco uninstall $paquete -y | Out-Null
    
    # Limpiar firewall para reusar puerto
    Get-NetFirewallRule -DisplayName "HTTP-$Servicio-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    
    # Borrar archivos
    Get-ChildItem -Path "C:\tools" -Filter "*$paquete*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if ($Servicio -eq "apache") { Get-ChildItem -Path "C:\tools" -Filter "*apache24*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    if ($Servicio -eq "nginx") { Get-ChildItem -Path "C:\tools" -Filter "*nginx*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "[-] $Servicio desinstalado. Puerto liberado." -ForegroundColor Green
}

do {
    Write-Host "`n=== MENU WINDOWS SERVER ===" -ForegroundColor Cyan
    Write-Host "1) Instalar IIS (Nativo)"
    Write-Host "2) Instalar Apache"
    Write-Host "3) Instalar Nginx"
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
        "0" { Write-Host "Saliendo..."; break }
        default { Write-Host "[-] Opcion no valida." -ForegroundColor Red }
    }
} while ($opcion -ne "0")

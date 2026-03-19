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
            Write-Host "[!] El puerto $p ya esta ocupado (seguro un servicio anterior no se cerro bien). Intenta con otro." -ForegroundColor Red
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
    body { 
        font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
        background-color: #1e1e2e; 
        color: #e0e0e0; 
        text-align: center; 
        padding: 50px; 
        margin: 0;
    }
    .container { 
        background: #282a36; 
        padding: 40px; 
        border-radius: 12px; 
        box-shadow: 0px 0px 20px rgba(0, 120, 215, 0.4); 
        display: inline-block; 
        border: 1px solid #44475a;
        min-width: 350px;
    }
    h1 { 
        color: #00e676; 
        margin-top: 0;
        text-transform: uppercase;
        letter-spacing: 2px;
        text-shadow: 0 0 10px rgba(0, 230, 118, 0.3);
    }
    p { font-size: 1.1em; line-height: 1.6; margin: 10px 0; }
    strong { color: #8be9fd; }
    .url-box {
        background: #1e1e2e; padding: 10px; border-radius: 6px;
        margin-top: 20px; font-family: monospace; color: #ff79c6;
        border: 1px dashed #6272a4;
    }
  </style>
</head>
<body>
  <div class="container">
      <h1>¡Servidor Activo!</h1>
      <p><strong>Servidor:</strong> $Servicio</p>
      <p><strong>Versión:</strong> $Version</p>
      <p><strong>Puerto:</strong> $Puerto</p>
      <p><strong>IP VirtualBox:</strong> $VM_IP</p>
      <div class="url-box">URL: http://${VM_IP}:${Puerto}</div>
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
    Write-Host "`n[*] Configurando servidor HTTP Nativo de Windows..." -ForegroundColor Cyan
    
    $puerto = Solicitar-Puerto -ServicioNombre "IIS Nativo"
    
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
    Write-Host "[+] Servidor Web Nativo activo en el puerto $puerto." -ForegroundColor Green
    Write-Host "[>] Abre en tu Host: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}

Function Desinstalar-IIS {
    Write-Host "`n[*] Desinstalando IIS y liberando el puerto..." -ForegroundColor Yellow
    
    # AQUI LA MAGIA: Busca en las entrañas de Windows el script oculto y lo mata liberando tu puerto
    $iisProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%ServidorNativoIIS%'"
    foreach ($p in $iisProcs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    
    # BORRAR LA REGLA DEL PUERTO PARA REUSARLO
    Get-NetFirewallRule -DisplayName "HTTP-HTTP-Nativo-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    
    Write-Host "[-] Sitio HTTP Nativo apagado y puerto liberado con éxito." -ForegroundColor Green
}

Function Instalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }
    $nombreArchivo = if ($Servicio -eq "apache") { "httpd.conf" } else { "nginx.conf" }

    Write-Host "`n[*] Preparando instalacion de $Servicio..." -ForegroundColor Yellow
    $ver = "Latest"
    $puerto = Solicitar-Puerto -ServicioNombre $Servicio

    Write-Host "[*] Instalando $Servicio ($ver) desde Chocolatey (esto puede tardar un poco)..." -ForegroundColor Cyan
    
    if ($Servicio -eq "nginx") {
        choco install $paquete -y --force --package-parameters "/port:$puerto" | Out-Null
    } else {
        choco install $paquete -y --force | Out-Null
    }
    
    Write-Host "[*] Dando tiempo al sistema para desempaquetar archivos..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3

    $archivoConf = $null
    $rutasBusqueda = @("C:\tools", "C:\ProgramData\chocolatey\lib", "C:\nginx")
    
    foreach ($ruta in $rutasBusqueda) {
        if (Test-Path $ruta) {
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
                Write-Host "[*] Arrancando Nginx en segundo plano..." -ForegroundColor Yellow
                Start-Process $exeNginx.FullName -WorkingDirectory $exeNginx.Directory.FullName -WindowStyle Hidden
            } else { Write-Host "[X] Error: Se encontro config, pero no nginx.exe." -ForegroundColor Red; return }
        } else { Write-Host "[X] Error: No se encontro nginx.conf. Revisa si Chocolatey lanzo algun error." -ForegroundColor Red; return }
    }

    if ($Servicio -eq "apache") {
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $apacheRoot = $archivoConf.Directory.Parent.FullName
            
            $apacheRootFormat = $apacheRoot -replace "\\", "/"
            $htdocs = Join-Path -Path $apacheRoot -ChildPath "htdocs"

            $textoConf = Get-Content $conf
            $textoConf = $textoConf -replace 'Define SRVROOT .*', "Define SRVROOT `"$apacheRootFormat`""
            $textoConf = $textoConf -replace '(?i)c:/Apache24', $apacheRootFormat
            $textoConf = $textoConf -replace '(?m)^Listen\s+\d+', "Listen $puerto"
            $textoConf = $textoConf -replace '(?m)^#?\s*ServerName.*', "ServerName localhost:$puerto"
            $textoConf | Set-Content $conf
            
            Crear-Index -Ruta $htdocs -Servicio "Apache" -Version $ver -Puerto $puerto
            
            $apacheExe = Get-ChildItem -Path $apacheRoot -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($apacheExe) {
                Write-Host "[*] Instalando y arrancando Apache como Servicio SSH..." -ForegroundColor Yellow
                
                & $apacheExe.FullName -k uninstall 2>$null
                Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 2
                
                & $apacheExe.FullName -k install 2>$null
                Start-Sleep -Seconds 2
                
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
    
    Write-Host "`n[*] Desinstalando $Servicio y liberando puerto..." -ForegroundColor Yellow
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
    
    # BARREMOS EL FIREWALL DE ESE SERVICIO
    Get-NetFirewallRule -DisplayName "HTTP-$Servicio-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    
    Get-ChildItem -Path "C:\tools" -Filter "*$paquete*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if ($Servicio -eq "apache") { Get-ChildItem -Path "C:\tools" -Filter "*apache24*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    if ($Servicio -eq "nginx") { Get-ChildItem -Path "C:\tools" -Filter "*nginx*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "[-] $Servicio desinstalado y puerto liberado con éxito." -ForegroundColor Green
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

Function Instalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }

    Write-Host "`n[*] Preparando instalacion de $Servicio..." -ForegroundColor Yellow
    $ver = "Latest"

    $puerto = Solicitar-Puerto -ServicioNombre $Servicio

    Write-Host "[*] Instalando $Servicio ($ver) desde Chocolatey..." -ForegroundColor Cyan
    choco install $paquete -y --force | Out-Null

    Write-Host "[*] Configurando puertos y arrancando servicio..." -ForegroundColor Yellow
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
            if (Test-Path $exeNginx) { Start-Process $exeNginx -WorkingDirectory $nginxRoot }
        } else { Write-Host "[X] Error: No se encontro nginx.conf." -ForegroundColor Red; return }
    }

    if ($Servicio -eq "apache") {
        $archivoConf = Get-ChildItem -Path $rutasBusqueda -Filter "httpd.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $apacheRoot = $archivoConf.Directory.Parent.FullName
            $htdocs = Join-Path -Path $apacheRoot -ChildPath "htdocs"

            (Get-Content $conf) -replace "Listen 80", "Listen $puerto" | Set-Content $conf
            Add-Content -Path $conf -Value "`nServerName localhost:$puerto"
            
            Crear-Index -Ruta $htdocs -Servicio "Apache" -Version $ver -Puerto $puerto
            
            # Buscar el ejecutable de apache y arrancarlo en segundo plano
            $apacheExe = Get-ChildItem -Path $apacheRoot -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($apacheExe) {
                Write-Host "[*] Arrancando proceso de Apache en segundo plano..." -ForegroundColor Yellow
                Start-Process -FilePath $apacheExe.FullName -WindowStyle Hidden
            } else {
                Write-Host "[X] Error: No encontre el ejecutable httpd.exe" -ForegroundColor Red
            }

        } else { Write-Host "[X] Error: No se encontro httpd.conf." -ForegroundColor Red; return }
    }

    Configurar-Firewall -Puerto $puerto -Nombre $Servicio
    Write-Host "[+] $Servicio instalado correctamente." -ForegroundColor Green
    Write-Host "[>] Abre en tu Host: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}

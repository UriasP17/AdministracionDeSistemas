#Requires -RunAsAdministrator
Import-Module ServerManager -ErrorAction SilentlyContinue
Import-Module WebAdministration -ErrorAction SilentlyContinue

Function Instalar-IIS {
    $puerto = Read-Host "Ingresa el puerto para IIS (ej. 80, 8080)"
    if ([string]::IsNullOrWhiteSpace($puerto)) { $puerto = 80 }

    $ocupado = Test-NetConnection -ComputerName localhost -Port $puerto -WarningAction SilentlyContinue
    if ($ocupado.TcpTestSucceeded) {
        Write-Host "[X] Error: El puerto $puerto ya esta en uso." -ForegroundColor Red
        return
    }

    Write-Host "`n[*] Instalando IIS silenciosamente..." -ForegroundColor Cyan
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    
    Write-Host "[*] Configurando puerto al $puerto..." -ForegroundColor Yellow
    # Borrar binding viejo para evitar errores de ruta y crear el nuevo correctamente
    Clear-WebConfiguration -PSPath "IIS:\Sites\Default Web Site" -Filter "system.applicationHost/sites/site/bindings/binding" -ErrorAction SilentlyContinue
    New-WebBinding -Name "Default Web Site" -Protocol http -Port $puerto -IPAddress "*" -ErrorAction SilentlyContinue
    
    $webRoot = "C:\inetpub\wwwroot"
    Remove-Item "$webRoot\iisstart.*" -Force -ErrorAction SilentlyContinue
    "Servidor: IIS - Version: 10.0 - Puerto: $puerto" | Out-File "$webRoot\index.html"

    $acl = Get-Acl $webRoot
    $regla = New-Object System.Security.AccessControl.FileSystemAccessRule("IUSR", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($regla)
    Set-Acl $webRoot $acl

    New-NetFirewallRule -DisplayName "HTTP-IIS-Custom" -LocalPort $puerto -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null

    Write-Host "[*] Aplicando seguridad (Ocultar version y bloquear metodos)..." -ForegroundColor Yellow
    
    # Quitar cabeceras y metodos viejos silenciosamente para no generar errores de duplicado
    try { Remove-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -AtElement @{name='X-Powered-By'} -ErrorAction Stop } catch {}
    try { Remove-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -AtElement @{name='X-Frame-Options'} -ErrorAction Stop } catch {}
    try { Remove-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -AtElement @{name='X-Content-Type-Options'} -ErrorAction Stop } catch {}
    try { Remove-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/security/requestFiltering/verbs" -Name "." -AtElement @{verb='TRACE'} -ErrorAction Stop } catch {}
    try { Remove-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/security/requestFiltering/verbs" -Name "." -AtElement @{verb='DELETE'} -ErrorAction Stop } catch {}

    # Ocultar version del servidor
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -Filter "system.webServer/security/requestFiltering" -Name "removeServerHeader" -Value "True" -ErrorAction SilentlyContinue
    
    # Agregar reglas nuevas limpias
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -Value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -Value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/security/requestFiltering/verbs" -Name "." -Value @{verb='TRACE';allowed='False'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/security/requestFiltering/verbs" -Name "." -Value @{verb='DELETE';allowed='False'} -ErrorAction SilentlyContinue
    
    Restart-Service -Name "W3SVC"
    Write-Host "[+] IIS Instalado y seguro en puerto $puerto" -ForegroundColor Green
}

Function Instalar-Opcional {
    param($Servicio)

    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }

    Write-Host "`n[*] Buscando versiones en Chocolatey..." -ForegroundColor Yellow
    $salida = choco info $paquete --all -r | Select-String -Pattern "^$paquete"
    if (-not $salida) {
        Write-Host "[X] No se hallaron versiones para $Servicio." -ForegroundColor Red
        return
    }

    $versiones = @()
    foreach ($linea in $salida) {
        $versiones += ($linea -split '\|')[1]
    }
    $versiones = $versiones | Sort-Object -Descending

    Write-Host "Versiones disponibles:"
    Write-Host "1) Latest: $($versiones[0])"
    if ($versiones.Count -gt 1) {
        Write-Host "2) LTS:    $($versiones[1])"
    }
    $op = Read-Host "Elige opcion [1/2] (o Enter para Latest)"
    if ([string]::IsNullOrWhiteSpace($op) -or $op -eq "1") {
        $ver = $versiones[0]
    } else {
        $ver = $versiones[1]
    }

    $puerto = Read-Host "Ingresa puerto para $Servicio (ej. 8080)"
    if ([string]::IsNullOrWhiteSpace($puerto)) { $puerto = 8080 }

    $ocupado = Test-NetConnection -ComputerName localhost -Port $puerto -WarningAction SilentlyContinue
    if ($ocupado.TcpTestSucceeded) {
        Write-Host "[X] El puerto $puerto ya esta en uso." -ForegroundColor Red
        return
    }

    Write-Host "[*] Instalando $Servicio v$ver silenciosamente..." -ForegroundColor Cyan
    choco install $paquete --version $ver -y --force | Out-Null

    if ($Servicio -eq "nginx") {
        $conf = "C:\tools\nginx\conf\nginx.conf"
        (Get-Content $conf) -replace "listen\s+80;", "listen       $puerto;" | Set-Content $conf
        "Servidor: Nginx - Version: $ver - Puerto: $puerto" | Out-File "C:\tools\nginx\html\index.html"
        Start-Process "C:\tools\nginx\nginx.exe" -WorkingDirectory "C:\tools\nginx"
    }

    if ($Servicio -eq "apache") {
        $conf = "C:\tools\apache24\conf\httpd.conf"
        (Get-Content $conf) -replace "Listen 80", "Listen $puerto" | Set-Content $conf
        (Get-Content $conf) -replace "ServerTokens Full", "ServerTokens Prod" | Set-Content $conf
        (Get-Content $conf) -replace "ServerSignature On", "ServerSignature Off" | Set-Content $conf
        "Servidor: Apache - Version: $ver - Puerto: $puerto" | Out-File "C:\tools\apache24\htdocs\index.html"
        Restart-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    }

    New-NetFirewallRule -DisplayName "HTTP-$Servicio" -LocalPort $puerto -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[+] $Servicio instalado en el puerto $puerto" -ForegroundColor Green
}

# --- MENU PRINCIPAL WINDOWS ---
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "[!] Chocolatey no esta instalado. Instalando..." -ForegroundColor Yellow
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

while ($true) {
    Write-Host "`n======= MENU WINDOWS =======" -ForegroundColor Cyan
    Write-Host "1) Instalar IIS (Obligatorio)"
    Write-Host "2) Instalar Apache (Opcional)"
    Write-Host "3) Instalar Nginx (Opcional)"
    Write-Host "0) Salir"
    
    $opt = Read-Host "Elige una opcion"
    switch ($opt) {
        "1" { Instalar-IIS }
        "2" { Instalar-Opcional -Servicio "apache" }
        "3" { Instalar-Opcional -Servicio "nginx" }
        "0" { exit }
        default { Write-Host "Opcion no valida." -ForegroundColor Red }
    }
}

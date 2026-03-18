if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[X] ERROR: Este script necesita permisos elevados." -ForegroundColor Red
    Write-Host "Por favor, cierra esta consola, haz clic derecho en PowerShell y selecciona 'Ejecutar como administrador'." -ForegroundColor Yellow
    Exit
}

Import-Module ServerManager -ErrorAction SilentlyContinue
Import-Module WebAdministration -ErrorAction SilentlyContinue

Function Obtener-PuertoValido ($Mensaje, $PuertoDefault) {
    while ($true) {
        $puerto = Read-Host $Mensaje
        if ([string]::IsNullOrWhiteSpace($puerto)) { return $PuertoDefault }
        if ($puerto -match "^\d+$" -and [int]$puerto -gt 0 -and [int]$puerto -le 65535) { return [int]$puerto }
        Write-Host "[!] Puerto inválido. Ingresa un número entre 1 y 65535." -ForegroundColor Red
    }
}

Function Instalar-IIS {
    $puerto = Obtener-PuertoValido "Ingresa el puerto para IIS (ej. 80, 8080) [Enter para 80]" 80

    $ocupado = Test-NetConnection -ComputerName localhost -Port $puerto -WarningAction SilentlyContinue
    if ($ocupado.TcpTestSucceeded) {
        Write-Host "[X] Error: El puerto $puerto ya está en uso por otra aplicación." -ForegroundColor Red
        return
    }

    Write-Host "`n[*] Instalando IIS silenciosamente... (Esto puede tardar unos minutos)" -ForegroundColor Cyan
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    
    Write-Host "[*] Configurando el puerto al $puerto..." -ForegroundColor Yellow
    Set-WebBinding -Name "Default Web Site" -BindingInformation "*:80:" -PropertyName "Port" -Value $puerto -ErrorAction SilentlyContinue
    
    $webRoot = "C:\inetpub\wwwroot"
    Remove-Item "$webRoot\iisstart.*" -Force -ErrorAction SilentlyContinue
    "<h1>Servidor: IIS - Version: 10.0 - Puerto: $puerto</h1>" | Out-File "$webRoot\index.html" -Encoding utf8

    $acl = Get-Acl $webRoot
    $regla = New-Object System.Security.AccessControl.FileSystemAccessRule("IUSR", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($regla)
    Set-Acl $webRoot $acl

    New-NetFirewallRule -DisplayName "HTTP-IIS-Custom-$puerto" -LocalPort $puerto -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null

    Write-Host "[*] Aplicando políticas de seguridad (Ocultar versión, X-Frame, etc.)..." -ForegroundColor Yellow
    Remove-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -AtElement @{name='X-Powered-By'} -ErrorAction SilentlyContinue
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -Filter "system.webServer/security/requestFiltering" -Name "removeServerHeader" -Value "True" -ErrorAction SilentlyContinue
    
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -Value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -Value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue
    
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/security/requestFiltering/verbs" -Name "." -Value @{verb='TRACE';allowed='False'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site" -Filter "system.webServer/security/requestFiltering/verbs" -Name "." -Value @{verb='DELETE';allowed='False'} -ErrorAction SilentlyContinue
    
    Restart-Service -Name "W3SVC" -ErrorAction SilentlyContinue
    Write-Host "[+] IIS Instalado y asegurado correctamente en http://localhost:$puerto" -ForegroundColor Green
}

Function Instalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }

    Write-Host "`n[*] Buscando versiones de $Servicio en Chocolatey..." -ForegroundColor Yellow
    $salida = choco info $paquete --all -r | Select-String -Pattern "^$paquete"
    
    if (-not $salida) { 
        Write-Host "[X] No se hallaron versiones o hubo un error de conexión con Chocolatey." -ForegroundColor Red
        return 
    }

    $versiones = @()
    foreach ($linea in $salida) { $versiones += ($linea -split '\|')[1] }
    $versiones = $versiones | Sort-Object -Descending

    Write-Host "`nVersiones disponibles:" -ForegroundColor Cyan
    Write-

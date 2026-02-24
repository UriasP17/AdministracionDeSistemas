
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "¡Ocupas abrir PowerShell como Administrador para correr esto, bro!"
    Exit
}

function Instalar-DNS {
    Clear-Host
    Write-Host "`n=== INSTALANDO SERVICIO DNS ===" -ForegroundColor Cyan
    
    $dnsFeature = Get-WindowsFeature -Name DNS
    if ($dnsFeature.InstallState -ne "Installed") {
        Write-Host "Instalando el rol... (esto puede tardar unos segundos)" -ForegroundColor Yellow
        Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
        Write-Host "¡Servicio DNS instalado al 100!" -ForegroundColor Green
    } else {
        Write-Host "El rol de DNS ya estaba instalado. No se movió nada." -ForegroundColor Green
    }
    
    Write-Host "`nPresiona Enter para volver..."
    Read-Host
}

function Configurar-IP {
    Clear-Host
    Write-Host "`n=== CONFIGURAR IP ESTÁTICA ===" -ForegroundColor Cyan
    

    $interfaz = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    $ipActual = Get-NetIPAddress -InterfaceAlias $interfaz.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue

    if ($ipActual.PrefixOrigin -eq 'Dhcp' -or $ipActual -eq $null) {
        Write-Host "Tu interfaz ($($interfaz.Name)) está en DHCP." -ForegroundColor Yellow
        $nuevaIP = Read-Host "Ingresa la IP estática que le quieres poner (ej. 192.168.10.10)"
        $mascara = Read-Host "Ingresa la máscara en prefijo (ej. 24)"
        
        New-NetIPAddress -InterfaceAlias $interfaz.Name -IPAddress $nuevaIP -PrefixLength $mascara | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $interfaz.Name -ServerAddresses $nuevaIP | Out-Null
        
        Write-Host "¡IP Fija asignada correctamente a $nuevaIP!" -ForegroundColor Green
    } else {
        Write-Host "Tu servidor ya tiene la IP fija: $($ipActual.IPAddress)" -ForegroundColor Green
    }

    Write-Host "`nPresiona Enter para volver..."
    Read-Host
}

function Crear-Zona {
    Clear-Host
    Write-Host "`n=== CREAR ZONA Y REGISTRO DNS ===" -ForegroundColor Cyan
    
    $dominio = Read-Host "Ingresa el nombre del dominio (ej. reprobados.com)"
    $ipDestino = Read-Host "Ingresa la IP que resolverá este dominio"


    $zonaExiste = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue
    
    if (!$zonaExiste) {
        Write-Host "Creando la zona primaria $dominio..." -ForegroundColor Yellow
        Add-DnsServerPrimaryZone -Name $dominio -ZoneFile "$dominio.dns" | Out-Null
        Write-Host "¡Zona creada exitosamente!" -ForegroundColor Green
    } else {
        Write-Host "La zona ya existe, le agregaremos el registro..." -ForegroundColor Yellow
    }

    
    Write-Host "Agregando registros..." -ForegroundColor Yellow

    Add-DnsServerResourceRecordA -Name "@" -ZoneName $dominio -IPv4Address $ipDestino -AllowUpdateAny -ErrorAction SilentlyContinue | Out-Null

    Add-DnsServerResourceRecordA -Name "www" -ZoneName $dominio -IPv4Address $ipDestino -AllowUpdateAny -ErrorAction SilentlyContinue | Out-Null
    
    Write-Host "¡Registros guardados al 100!" -ForegroundColor Green

    Write-Host "`nHaciendo prueba de nslookup rapidita:" -ForegroundColor Cyan
    nslookup "www.$dominio" "127.0.0.1"

    Write-Host "`nPresiona Enter para volver..."
    Read-Host
}

function Mostrar-Zonas {
    Clear-Host
    Write-Host "`n=== ZONAS ACTIVAS EN EL SERVIDOR ===" -ForegroundColor Cyan
    Get-DnsServerZone | Select-Object ZoneName, ZoneType | Format-Table -AutoSize
    
    Write-Host "`nPresiona Enter para volver..."
    Read-Host
}

while ($true) {
    Clear-Host

    Write-Host "    SCRIPT DE DNS BIND - WIN SERVER   " -ForegroundColor Cyan
    
    Write-Host "1) Revisar / Instalar servicio DNS"
    Write-Host "2) Asignar IP estática al Servidor"
    Write-Host "3) Crear nueva Zona (Dominio) y Registros"
    Write-Host "4) Ver dominios configurados"
    Write-Host "5) Salir"
    Write-Host "--------------------------------------"
    
    $opcion = Read-Host "Elige una opción bro"

    switch ($opcion) {
        "1" { Instalar-DNS }
        "2" { Configurar-IP }
        "3" { Crear-Zona }
        "4" { Mostrar-Zonas }
        "5" { 
            Write-Host "¡Sobres, nos vemos!" -ForegroundColor Green
            exit 
        }
        default { 
            Write-Host "¡Opción inválida, checa bien los números!" -ForegroundColor Red
            Start-Sleep -Seconds 2
        }
    }
}

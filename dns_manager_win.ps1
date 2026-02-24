if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Ocupas abrir PowerShell como Administrador para correr esto"
    Exit
}

function Instalar-DNS {
    Clear-Host
    Write-Host "`n=== INSTALANDO SERVICIO DNS ===" -ForegroundColor Cyan
    
    $dnsFeature = Get-WindowsFeature -Name DNS
    if ($dnsFeature.InstallState -ne "Installed") {
        Write-Host "Instalando el rol... " -ForegroundColor Yellow
        Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
        Write-Host "Servicio DNS instalado al 100!" -ForegroundColor Green
    } else {
        Write-Host "El rol de DNS ya estaba instalado." -ForegroundColor Green
    }
    
    Write-Host "`nPresiona Enter para volver..."
    Read-Host
}

function Configurar-IP {
    Clear-Host
    Write-Host "`n=== CONFIGURAR IP ESTATICA ===" -ForegroundColor Cyan
    
    $interfaz = Get-NetAdapter | Where-Object Name -like '*Ethernet 2*' | Select-Object -First 1
    
    if (-not $interfaz) {
        Write-Host "No se encontro Ethernet 2, usando el primer adaptador activo..." -ForegroundColor Yellow
        $interfaz = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    }

    $ipActual = Get-NetIPAddress -InterfaceAlias $interfaz.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue

    Write-Host "Configurando adaptador: $($interfaz.Name)" -ForegroundColor Cyan
    
    $nuevaIP = Read-Host "Ingresa la IP estatica (deja en blanco para auto: 192.168.10.20)"
    $mascara = Read-Host "Ingresa la mascara en prefijo (deja en blanco para auto: 24)"
    
    if ([string]::IsNullOrWhiteSpace($nuevaIP)) { $nuevaIP = "192.168.10.20" }
    if ([string]::IsNullOrWhiteSpace($mascara)) { $mascara = "24" }
    
    Remove-NetIPAddress -InterfaceAlias $interfaz.Name -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    
    New-NetIPAddress -InterfaceAlias $interfaz.Name -IPAddress $nuevaIP -PrefixLength $mascara | Out-Null
    Set-DnsClientServerAddress -InterfaceAlias $interfaz.Name -ServerAddresses $nuevaIP | Out-Null
    
    Write-Host "IP Fija asignada correctamente a $nuevaIP" -ForegroundColor Green

    Write-Host "`nPresiona Enter para volver..."
    Read-Host
}

function Crear-Zona {
    Clear-Host
    Write-Host "`n=== CREAR ZONA Y REGISTRO DNS ===" -ForegroundColor Cyan
    
    $dominio = Read-Host "Ingresa el nombre del dominio"
    $ipDestino = Read-Host "Ingresa la IP que resolvera este dominio"

    $zonaExiste = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue
    
    if (!$zonaExiste) {
        Write-Host "Creando la zona primaria $dominio..." -ForegroundColor Yellow
        Add-DnsServerPrimaryZone -Name $dominio -ZoneFile "$dominio.dns" | Out-Null
        Write-Host "Zona creada exitosamente!" -ForegroundColor Green
    } else {
        Write-Host "La zona ya existe, agregando registro..." -ForegroundColor Yellow
    }

    Add-DnsServerResourceRecordA -Name "@" -ZoneName $dominio -IPv4Address $ipDestino -AllowUpdateAny -ErrorAction SilentlyContinue | Out-Null
    
    Write-Host "Registro guardado al 100!" -ForegroundColor Green

    Write-Host "`nHaciendo prueba rapida:" -ForegroundColor Cyan
    nslookup $dominio "127.0.0.1"

    Write-Host "`nPresiona Enter para volver..."
    Read-Host
}

function Eliminar-Zona {
    Clear-Host
    Write-Host "`n=== ELIMINAR ZONA DNS ===" -ForegroundColor Cyan
    
    $dominio = Read-Host "Ingresa el nombre del dominio a eliminar"
    
    $zonaExiste = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue
    
    if ($zonaExiste) {
        Write-Host "Borrando el dominio $dominio..." -ForegroundColor Yellow
        Remove-DnsServerZone -Name $dominio -Force
        Write-Host "Dominio fulminado al 100!" -ForegroundColor Green
    } else {
        Write-Host "Ese dominio no existe." -ForegroundColor Red
    }
    
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
    Write-Host "2) Asignar IP estatica al Servidor"
    Write-Host "3) Crear nueva Zona (Dominio) y Registros"
    Write-Host "4) Ver dominios configurados"
    Write-Host "5) Eliminar un Dominio (Zona)"
    Write-Host "6) Salir"
    Write-Host "--------------------------------------"
    
    $opcion = Read-Host "Elige una opcion"

    switch ($opcion) {
        "1" { Instalar-DNS }
        "2" { Configurar-IP }
        "3" { Crear-Zona }
        "4" { Mostrar-Zonas }
        "5" { Eliminar-Zona }
        "6" { 
            Write-Host "Sobres, nos vemos!" -ForegroundColor Green
            exit 
        }
        default { 
            Write-Host "Opcion invalida, checa bien los numeros!" -ForegroundColor Red
            Start-Sleep -Seconds 2
        }
    }
}

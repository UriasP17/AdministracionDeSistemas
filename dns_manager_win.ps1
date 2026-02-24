function Crear-Zona {
    Clear-Host
    Write-Host "`n=== CREAR ZONA Y REGISTRO DNS ===" -ForegroundColor Cyan
    
    $dominio = Read-Host "Ingresa el nombre del dominio"
    
    $interfaz = Get-NetAdapter | Where-Object Name -like '*Ethernet 2*' | Select-Object -First 1
    if (-not $interfaz) { $interfaz = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1 }
    $ipAuto = (Get-NetIPAddress -InterfaceAlias $interfaz.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    
    $ipDestino = Read-Host "Ingresa la IP (deja en blanco para auto: $ipAuto)"
    if ([string]::IsNullOrWhiteSpace($ipDestino)) { $ipDestino = $ipAuto }

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

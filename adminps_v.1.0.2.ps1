$adapter = Get-NetAdapter | Where-Object { $_.Name -match "2" -or $_.Name -match "Internal" } | Select-Object -First 1

if (-not $adapter) {
    Write-Host "No encontré 'Ethernet 2' automáticamente." -ForegroundColor Yellow
    Get-NetAdapter | Select-Object Name, InterfaceDescription, Status
    $nombreManual = Read-Host "Escribe el nombre EXACTO de la interfaz para DHCP (ej: Ethernet 2)"
    $adapter = Get-NetAdapter -Name $nombreManual
}

$INTERFACE = $adapter.Name
Write-Host "Detectada interfaz activa: '$INTERFACE'" -ForegroundColor Cyan
Start-Sleep -Seconds 1

function Validate-IP {
    param([string]$IP)
    return $IP -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

function Configure-Network {
    param([string]$IPAddress)
    
    Write-Host "Configurando IP estática $IPAddress en interfaz '$INTERFACE'..." -ForegroundColor Yellow
    
    # Limpiamos configuraciones viejas para evitar conflictos
    Remove-NetIPAddress -InterfaceAlias $INTERFACE -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $INTERFACE -Confirm:$false -ErrorAction SilentlyContinue
    
    # Asignamos la nueva IP
    New-NetIPAddress -InterfaceAlias $INTERFACE -IPAddress $IPAddress -PrefixLength 24 -ErrorAction Stop
}

function Install-DHCP {
    Write-Host "Instalando rol DHCP..." -ForegroundColor Yellow
    Install-WindowsFeature -Name DHCP -IncludeManagementTools
    
    Write-Host "Autorizando servidor en Active Directory (Local)..."
    Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue
    Restart-Service dhcpserver
    Write-Host "[OK] DHCP instalado correctamente" -ForegroundColor Green
}

function Setup-DHCPScope {
    param(
        [string]$ServerIP,
        [string]$StartRange,
        [string]$EndRange,
        [string]$Gateway,
        [string]$DNS
    )
    
    $NetBase = ($ServerIP -split '\.')[0..2] -join '.'
    $ScopeName = "Red_$NetBase"
    $SubnetMask = "255.255.255.0"
    
    Write-Host "Creando ámbito DHCP: $ScopeName..."

    Get-DhcpServerv4Scope | Where-Object {$_.Name -eq $ScopeName} | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
    
    Add-DhcpServerv4Scope -Name $ScopeName `
        -StartRange $StartRange `
        -EndRange $EndRange `
        -SubnetMask $SubnetMask `
        -State Active
    
    if ($Gateway) {
        Set-DhcpServerv4OptionValue -ScopeId "$NetBase.0" -Router $Gateway
    }
    
    if ($DNS) {
        $DNSServers = $DNS -split ','
        Set-DhcpServerv4OptionValue -ScopeId "$NetBase.0" -DnsServer $DNSServers
    }
  
    # Intento de autorización
    Add-DhcpServerInDC -DnsName $env:COMPUTERNAME -IPAddress $ServerIP -ErrorAction SilentlyContinue
}

function Show-Menu {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "    GESTIÓN DHCP WINDOWS SERVER ($INTERFACE)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "1. Instalación DHCP"
    Write-Host "2. Verificación de Estado (Real)"
    Write-Host "3. Configurar Ámbito DHCP + IP Estática"
    Write-Host "4. Ver Leases (Clientes Conectados)"
    Write-Host "5. Desinstalar DHCP (Limpieza Total)"
    Write-Host "6. Salir"
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
}

while ($true) {
    Show-Menu
    $opt = Read-Host "Elige una opción"
    
    switch ($opt) {
        1 {
            Install-DHCP
            Read-Host "`nPresiona Enter para volver al menú..."
        }
        
        2 {
            Write-Host "`nConsultando estado del servicio..." -ForegroundColor Yellow
            try {
                $service = Get-Service dhcpserver -ErrorAction Stop
                
                if ($service.Status -eq "Running") {
                    Write-Host "ESTADO: ACTIVO (Running)" -ForegroundColor Green
                    
                    Write-Host "`n--- Ámbitos Configurados ---"
                    Get-DhcpServerv4Scope | Format-Table ScopeId, Name, State, StartRange, EndRange -AutoSize
                } else {
                    Write-Host "ESTADO: DETENIDO ($($service.Status))" -ForegroundColor Red
                }
            }
            catch {
                Write-Host "ESTADO: NO INSTALADO (El servicio DHCP no existe)" -ForegroundColor DarkGray
            }
            
            Read-Host "`nPresiona Enter para volver al menú..."
        }
        
        3 {
            Write-Host "`nCONFIGURACIÓN SIMPLE DHCP" -ForegroundColor Yellow
            $ServerIP = Read-Host "IP inicial (SERVER) ej: 192.168.10.10"
            $EndIP = Read-Host "IP final (CLIENTE) ej: 192.168.10.50"
            $Gateway = Read-Host "Gateway (opcional, Enter para usar IP del server)"
            $DNS = Read-Host "DNS (opcional, ej: 8.8.8.8,1.1.1.1)"
            
            if (-not (Validate-IP $ServerIP) -or -not (Validate-IP $EndIP)) {
                Write-Host "[X] IPs inválidas" -ForegroundColor Red
                Read-Host "`nPresiona Enter para continuar..."
                continue
            }
            
            $NetBase = ($ServerIP -split '\.')[0..2] -join '.'
            $LastOctet = [int]($ServerIP -split '\.')[-1]
            $StartRange = "$NetBase.$($LastOctet + 1)"
            
            if (-not $Gateway) { $Gateway = $ServerIP }
            if (-not $DNS) { $DNS = "8.8.8.8,1.1.1.1" }
            
            try {
                Configure-Network $ServerIP
                Setup-DHCPScope -ServerIP $ServerIP -StartRange $StartRange -EndRange $EndIP -Gateway $Gateway -DNS $DNS
                
                Write-Host "[OK] DHCP activo y configurado en $INTERFACE" -ForegroundColor Green
                Write-Host "SERVER IP : $ServerIP"
                Write-Host "CLIENTES  : $StartRange -> $EndIP"
            }
            catch {
                Write-Host "[ERROR] Algo falló al configurar: $_" -ForegroundColor Red
            }
            
            Read-Host "`nPresiona Enter para volver al menú..."
        }
        
        4 {
            Write-Host "`n------ LEASES DHCP ------" -ForegroundColor Cyan
            try {
                $leases = Get-DhcpServerv4Lease -AllLeases -ErrorAction Stop
                if ($leases) {
                    $leases | Format-Table IPAddress, HostName, ClientId, LeaseExpiryTime -AutoSize
                } else {
                    Write-Host "No hay clientes conectados todavía." -ForegroundColor Yellow
                }
            }
            catch {
                 Write-Host "El servicio DHCP no está corriendo o no está instalado." -ForegroundColor Red
            }
            Write-Host "-------------------------"
            Read-Host "`nPresiona Enter para volver al menú..."
        }
        
        5 {
            Write-Host "Desinstalando DHCP..." -ForegroundColor Yellow
            try { Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue } catch {}
            
            Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools -Restart:$false
            
            Write-Host "Esperando limpieza de sistema (5 seg)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
            
            if (Get-Service dhcpserver -ErrorAction SilentlyContinue) {
                Write-Host "[AVISO] El servicio sigue marcado para borrar. Reinicia el servidor para completar." -ForegroundColor Yellow
            } else {
                Write-Host "[OK] DHCP desinstalado correctamente." -ForegroundColor Green
            }
            
            Read-Host "`nPresiona Enter para volver al menú..."
        }
        
        6 {
            Write-Host "Bye!"
            exit
        }
    }
}

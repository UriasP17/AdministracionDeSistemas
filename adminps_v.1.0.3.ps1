# --- BÚSQUEDA ESPECÍFICA DE "ETHERNET 2" ---
$adapter = Get-NetAdapter | Where-Object { $_.Name -eq "Ethernet 2" } | Select-Object -First 1

if (-not $adapter) {
    # Si no encuentra "Ethernet 2", busca cualquiera activa como respaldo
    Write-Host "No encontré 'Ethernet 2'. Buscando otras..." -ForegroundColor Yellow
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    
    if (-not $adapter) {
        Write-Host "No encontré adaptadores activos." -ForegroundColor Red
        Get-NetAdapter | Select-Object Name, InterfaceDescription, Status
        $nombreManual = Read-Host "Escribe el nombre EXACTO de la interfaz (ej: Ethernet)"
        $adapter = Get-NetAdapter -Name $nombreManual
    }
}

$INTERFACE = $adapter.Name
Write-Host "Detectada interfaz activa: '$INTERFACE'" -ForegroundColor Cyan
Start-Sleep -Seconds 1

function Validate-IP {
    param([string]$IP)
    return $IP -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

function Get-IPClassInfo {
    param([string]$IP)
    
    $parts = $IP -split '\.'
    if ($parts.Count -lt 4) { return $null }
    
    $Octet1 = [int]$parts[0]
    $Octet2 = $parts[1]
    $Octet3 = $parts[2]

    if ($Octet1 -ge 1 -and $Octet1 -le 126) {
        return @{ Class="A"; Mask="255.0.0.0"; Prefix=8; Subnet="$Octet1.0.0.0" }
    }
    elseif ($Octet1 -ge 128 -and $Octet1 -le 191) {
        return @{ Class="B"; Mask="255.255.0.0"; Prefix=16; Subnet="$Octet1.$Octet2.0.0" }
    }
    elseif ($Octet1 -ge 192 -and $Octet1 -le 223) {
        return @{ Class="C"; Mask="255.255.255.0"; Prefix=24; Subnet="$Octet1.$Octet2.$Octet3.0" }
    }
    else {
        return $null 
    }
}

function Configure-Network {
    param([string]$IPAddress, [int]$Prefix)
    
    Write-Host "Configurando IP $IPAddress/$Prefix en '$INTERFACE'..." -ForegroundColor Yellow
    
    Remove-NetIPAddress -InterfaceAlias $INTERFACE -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $INTERFACE -Confirm:$false -ErrorAction SilentlyContinue
    
    New-NetIPAddress -InterfaceAlias $INTERFACE -IPAddress $IPAddress -PrefixLength $Prefix -ErrorAction Stop
    
    netsh interface ipv4 set interface "$INTERFACE" weakhostreceive=enabled
    netsh interface ipv4 set interface "$INTERFACE" weakhostsend=enabled
    
    Write-Host "[WEAK HOST HABILITADO] Broadcasts ahora funcionan en VMs" -ForegroundColor Green
}


function Install-DHCP {
    Write-Host -NoNewline "Instalando rol DHCP... " -ForegroundColor Yellow
    Install-WindowsFeature -Name DHCP -IncludeManagementTools -WarningAction SilentlyContinue | Out-Null
    
    Write-Host "[OK]" -ForegroundColor Green
    Write-Host "Autorizando..."
    Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue
    Restart-Service dhcpserver
}

function Setup-DHCPScope {
    param(
        [string]$ServerIP,
        [string]$StartRange,
        [string]$EndRange,
        [string]$SubnetMask,   
        [string]$SubnetID      
    )
    
    $ScopeName = "Red_Auto_$SubnetID"
    
    Write-Host "Creando ambito $ScopeName (Mascara: $SubnetMask)..." -ForegroundColor Cyan

    Get-DhcpServerv4Scope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
    
    Add-DhcpServerv4Scope -Name $ScopeName `
        -StartRange $StartRange `
        -EndRange $EndRange `
        -SubnetMask $SubnetMask `
        -State Active
    
    Set-DhcpServerv4OptionValue -ScopeId $SubnetID -Router $ServerIP
    Set-DhcpServerv4OptionValue -ScopeId $SubnetID -DnsServer "8.8.8.8", "1.1.1.1"
    
    Set-DhcpServerv4Binding -BindingState $true -InterfaceAlias $INTERFACE -ErrorAction SilentlyContinue
    
    New-NetFirewallRule -DisplayName "DHCP Server $ScopeName" -Direction Inbound -LocalPort 67 -Protocol UDP -Action Allow -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "DHCP Client $ScopeName" -Direction Outbound -LocalPort 68 -Protocol UDP -Action Allow -ErrorAction SilentlyContinue
    
    Write-Host "[FIREWALL ABIERTO] Puertos 67/68 liberados" -ForegroundColor Green
}


function Clear-AllLeases {
    Write-Host "`n--- ELIMINANDO LEASES Y RESETEANDO ---" -ForegroundColor Yellow
    try {
        $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        if ($scopes) {
            foreach ($scope in $scopes) {
                $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId
                if ($leases) {
                    foreach ($lease in $leases) {
                        Remove-DhcpServerv4Lease -IPAddress $lease.IPAddress -Force
                        Write-Host "Eliminado: $($lease.IPAddress)" -ForegroundColor Red
                    }
                }
            }
            Write-Host "Reiniciando servicio para aplicar cambios..." -ForegroundColor Gray
            Restart-Service dhcpserver
            Write-Host "Clientes reseteados." -ForegroundColor Green
        } else {
            Write-Host "[!] No hay ambitos activos." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-Menu {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "    GESTION DHCP WINDOWS SERVER ($INTERFACE)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "1. Instalacion DHCP"
    Write-Host "2. Verificacion de Estado"
    Write-Host "3. Configurar Ambito (Auto A, B, C)"
    Write-Host "4. Ver Leases (Clientes)"
    Write-Host "5. ELIMINAR LEASES (Resetear Clientes)" 
    Write-Host "6. Desinstalar DHCP"
    Write-Host "7. Salir"
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
}

while ($true) {
    Show-Menu
    $opt = Read-Host "Elige una opcion"
    
    switch ($opt) {
        1 {
            Install-DHCP
            Read-Host "`nPresiona Enter..."
        }
        
        2 {
            Write-Host "`nEstado del servicio..." -ForegroundColor Yellow
            try {
                $s = Get-Service dhcpserver -ErrorAction Stop
                if ($s.Status -eq "Running") {
                    Write-Host "ACTIVO (Running)" -ForegroundColor Green
                    Get-DhcpServerv4Scope | Format-Table ScopeId, SubnetMask, StartRange, EndRange -AutoSize
                } else { Write-Host "DETENIDO" -ForegroundColor Red }
            } catch { Write-Host "NO INSTALADO" -ForegroundColor DarkGray }
            Read-Host "`nPresiona Enter..."
        }
        
        3 {
            Write-Host "`n--- DHCP MULTI-CLASE AUTOMATICO ---" -ForegroundColor Yellow
            $ServerIP = Read-Host "IP inicial (SERVER) ej: 10.0.0.1"
            $EndIP = Read-Host "IP final (CLIENTE) ej: 10.0.0.50"
            
            if (-not (Validate-IP $ServerIP) -or -not (Validate-IP $EndIP)) {
                Write-Host "[X] IPs invalidas" -ForegroundColor Red; Read-Host "Enter..."; continue
            }

            $ClassInfo = Get-IPClassInfo -IP $ServerIP
            
            if (-not $ClassInfo) {
                Write-Host "[X] IP no valida o reservada (Clase D/E)." -ForegroundColor Red; Read-Host "Enter..."; continue
            }

            $BaseIP = ($ServerIP -split '\.')[0..2] -join '.'
            $LastOctet = [int]($ServerIP -split '\.')[-1]
            $StartRange = "$BaseIP.$($LastOctet + 1)"

            Write-Host "`nCLASE DETECTADA: $($ClassInfo.Class)" -ForegroundColor Green
            Write-Host "   Mascara: $($ClassInfo.Mask) (/$($ClassInfo.Prefix))"
            Write-Host "   Subred:  $($ClassInfo.Subnet)"
            Write-Host "--------------------------------"
            Write-Host "Server:  $ServerIP"
            Write-Host "Clientes: $StartRange -> $EndIP"
            Write-Host ""

            try {
                Configure-Network -IPAddress $ServerIP -Prefix $ClassInfo.Prefix
                
                Setup-DHCPScope -ServerIP $ServerIP `
                                -StartRange $StartRange `
                                -EndRange $EndIP `
                                -SubnetMask $ClassInfo.Mask `
                                -SubnetID $ClassInfo.Subnet
                
                Write-Host "`n[OK] DHCP Configurado Exitosamente ($($ClassInfo.Class))" -ForegroundColor Green
            }
            catch {
                Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
            }
            Read-Host "`nPresiona Enter..."
        }
        
        4 {
            Write-Host "`n------ CLIENTES CONECTADOS ------" -ForegroundColor Cyan
            try {
                Get-DhcpServerv4Scope | Get-DhcpServerv4Lease | Format-Table IPAddress, HostName, ClientId -AutoSize
            } catch { Write-Host "Sin clientes o sin ambitos." -ForegroundColor Gray }
            Read-Host "`nPresiona Enter..."
        }

        5 {
            Clear-AllLeases
            Read-Host "`nPresiona Enter..."
        }

        6 {
            Write-Host "Desinstalando..." -ForegroundColor Yellow
            try { Get-DhcpServerv4Scope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue } catch {}
            Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools -Restart:$false | Out-Null
            Write-Host "[OK] Desinstalado." -ForegroundColor Green
            Read-Host "`nPresiona Enter..."
        }
        
        7 { exit }
    }
}

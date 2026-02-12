
$INTERFACE = "Ethernet"

function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "[FATAL] Debe ejecutar como Administrador" -ForegroundColor Red
    exit 1
}

function Validate-IP {
    param([string]$IP)
    return $IP -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

function Configure-Network {
    param([string]$IPAddress)
    
    $adapter = Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Select-Object -First 1
    
    Remove-NetIPAddress -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    
    New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $IPAddress -PrefixLength 24 -ErrorAction SilentlyContinue
}

function Install-DHCP {
    Write-Host "Instalando rol DHCP..." -ForegroundColor Yellow
    Install-WindowsFeature -Name DHCP -IncludeManagementTools
    Add-DhcpServerSecurityGroup
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
  
    Add-DhcpServerInDC -DnsName $env:COMPUTERNAME -IPAddress $ServerIP -ErrorAction SilentlyContinue
}

function Show-Menu {
    Clear-Host
    Write-Host "`n    GESTIÓN DHCP WINDOWS SERVER" -ForegroundColor Cyan
    Write-Host "1. Instalación DHCP"
    Write-Host "2. Verificación de Estado"
    Write-Host "3. Configurar Ámbito DHCP"
    Write-Host "4. Ver Leases"
    Write-Host "5. Desinstalar DHCP"
    Write-Host "6. Salir"
    Write-Host ""
}

while ($true) {
    Show-Menu
    $opt = Read-Host "Opción"
    
    switch ($opt) {
        1 {
            Install-DHCP
            Read-Host "`nEnter para continuar"
        }
        
        2 {
            Get-Service dhcpserver | Format-List
            Get-DhcpServerv4Scope
            Read-Host "`nEnter para continuar"
        }
        
        3 {
            Write-Host "`nCONFIGURACIÓN SIMPLE DHCP" -ForegroundColor Yellow
            $ServerIP = Read-Host "IP inicial (SERVER) ej: 192.168.10.10"
            $EndIP = Read-Host "IP final (CLIENTE) ej: 192.168.10.50"
            $Gateway = Read-Host "Gateway (opcional, Enter para usar IP del server)"
            $DNS = Read-Host "DNS (opcional, ej: 8.8.8.8,1.1.1.1)"
            
            if (-not (Validate-IP $ServerIP) -or -not (Validate-IP $EndIP)) {
                Write-Host "[X] IPs inválidas" -ForegroundColor Red
                Read-Host "`nEnter para continuar"
                continue
            }
            
            $NetBase = ($ServerIP -split '\.')[0..2] -join '.'
            $LastOctet = [int]($ServerIP -split '\.')[-1]
            $StartRange = "$NetBase.$($LastOctet + 1)"
            
            if (-not $Gateway) { $Gateway = $ServerIP }
            if (-not $DNS) { $DNS = "8.8.8.8,1.1.1.1" }
            
            Configure-Network $ServerIP
            Setup-DHCPScope -ServerIP $ServerIP -StartRange $StartRange -EndRange $EndIP -Gateway $Gateway -DNS $DNS
            
            Write-Host "[OK] DHCP activo" -ForegroundColor Green
            Write-Host "SERVER IP : $ServerIP"
            Write-Host "CLIENTES  : $StartRange -> $EndIP"
            Write-Host "GATEWAY   : $Gateway"
            Write-Host "DNS       : $DNS"
            
            Read-Host "`nEnter para continuar"
        }
        
        4 {
            Write-Host "`n------ LEASES DHCP ------" -ForegroundColor Cyan
            Get-DhcpServerv4Lease -AllLeases | Format-Table IPAddress, HostName, ClientId, LeaseExpiryTime -AutoSize
            Write-Host "-------------------------"
            Read-Host "`nEnter para continuar"
        }
        
        5 {
            Write-Host "Desinstalando DHCP..." -ForegroundColor Yellow
            Get-DhcpServerv4Scope | Remove-DhcpServerv4Scope -Force
            Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools
            Write-Host "[OK] DHCP desinstalado" -ForegroundColor Green
            Read-Host "`nEnter para continuar"
        }
        
        6 {
            exit
        }
    }
}

Write-Host "Buscando 'Ethernet 2'..." -ForegroundColor Gray
$adapter = Get-NetAdapter | Where-Object { $_.Name -eq "Ethernet 2" } | Select-Object -First 1

if (-not $adapter) {
    Write-Host "No vi la 'Ethernet 2', agarrando la primera que sirva..." -ForegroundColor Yellow
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    
    if (-not $adapter) {
        Write-Host "No hay red, checa eso." -ForegroundColor Red
        $nombreManual = Read-Host "Pon el nombre de la interfaz tu mismo"
        $adapter = Get-NetAdapter -Name $nombreManual -ErrorAction Stop
    }
}

$INTERFACE = $adapter.Name
Write-Host "Usando: '$INTERFACE'" -ForegroundColor Cyan
Start-Sleep -Seconds 1

function Validar-IP {
    param([string]$IP)
    if ($IP -eq "0.0.0.0" -or $IP -eq "255.255.255.255") { return $false }
    return $IP -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

function IP-A-Numero {
    param([string]$ip)
    $octetos = $ip.Split('.')
    return [double]([int]$octetos[0] * 16777216 + [int]$octetos[1] * 65536 + [int]$octetos[2] * 256 + [int]$octetos[3])
}

function Get-IPClassInfo {
    param([string]$IP)
    $parts = $IP -split '\.'
    if ($parts.Count -lt 4) { return $null }
    $Octet1 = [int]$parts[0]

    if ($Octet1 -ge 1 -and $Octet1 -le 126) { return @{ Class="A"; Mask="255.0.0.0"; Prefix=8; Subnet="$Octet1.0.0.0" } }
    elseif ($Octet1 -ge 128 -and $Octet1 -le 191) { return @{ Class="B"; Mask="255.255.0.0"; Prefix=16; Subnet="$Octet1.$($parts[1]).0.0" } }
    elseif ($Octet1 -ge 192 -and $Octet1 -le 223) { return @{ Class="C"; Mask="255.255.255.0"; Prefix=24; Subnet="$Octet1.$($parts[1]).$($parts[2]).0" } }
    else { return $null }
}

function Configure-Network {
    param([string]$IPAddress, [int]$Prefix)
    Write-Host "Poniendo IP $IPAddress en '$INTERFACE'..." -ForegroundColor Yellow
    Remove-NetIPAddress -InterfaceAlias $INTERFACE -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $INTERFACE -IPAddress $IPAddress -PrefixLength $Prefix -ErrorAction Stop
    
    netsh interface ipv4 set interface "$INTERFACE" weakhostreceive=enabled
    netsh interface ipv4 set interface "$INTERFACE" weakhostsend=enabled
    Write-Host "Listo el weak host." -ForegroundColor Green
}

function Setup-DHCPScope {
    param($ServerIP, $StartRange, $EndRange, $SubnetMask, $SubnetID)
    $ScopeName = "Scope_$SubnetID"
    
    Write-Host "Armando ambito $ScopeName..." -ForegroundColor Cyan
    Get-DhcpServerv4Scope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
    
    Add-DhcpServerv4Scope -Name $ScopeName -StartRange $StartRange -EndRange $EndRange -SubnetMask $SubnetMask -State Active
    Set-DhcpServerv4OptionValue -ScopeId $SubnetID -Router $ServerIP
    Set-DhcpServerv4OptionValue -ScopeId $SubnetID -DnsServer $ServerIP, "8.8.8.8"
    
    Set-DhcpServerv4Binding -BindingState $true -InterfaceAlias $INTERFACE -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "DHCP-IN" -Direction Inbound -LocalPort 67 -Protocol UDP -Action Allow -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "DHCP-OUT" -Direction Outbound -LocalPort 68 -Protocol UDP -Action Allow -ErrorAction SilentlyContinue
    Write-Host "Firewall abierto." -ForegroundColor Green
}

function Show-Menu {
    Clear-Host
    Write-Host "----------------------------------" -ForegroundColor Cyan
    Write-Host "    DHCP MANAGER ($INTERFACE)" -ForegroundColor Cyan
    Write-Host "----------------------------------" -ForegroundColor Cyan
    Write-Host "[1] Ver Rol"
    Write-Host "[2] Instalar/Quitar Rol"
    Write-Host "[3] Configurar Server"
    Write-Host "[4] Ver Clientes"
    Write-Host "[5] Limpiar Clientes"
    Write-Host "[6] Salir"
    Write-Host "----------------------------------" -ForegroundColor Cyan
}

while ($true) {
    Show-Menu
    $opt = Read-Host "Que hacemos"
    
    switch ($opt) {
        "1" {
            $s = Get-WindowsFeature DHCP
            Write-Host "`nEstado: $($s.InstallState)" -ForegroundColor Yellow
            try { 
                if ((Get-Service dhcpserver).Status -eq "Running") { Write-Host "Servicio: JALANDO" -ForegroundColor Green }
                else { Write-Host "Servicio: PARADO" -ForegroundColor Red }
            } catch { Write-Host "Ni esta instalado." -ForegroundColor DarkGray }
            Pause
        }
        
        "2" {
            $s = Get-WindowsFeature DHCP
            if ($s.InstallState -eq "Installed") {
                if ((Read-Host "¿Lo quito? (S/N)") -eq "S") {
                    Uninstall-WindowsFeature DHCP -IncludeManagementTools
                }
            } else {
                Write-Host "Instalando..." -ForegroundColor Yellow
                Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null
                Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue
                Restart-Service dhcpserver
                Write-Host "Ya quedo." -ForegroundColor Green
            }
            Pause
        }
        
        "3" {
            Write-Host "`n--- CONFIGURACION ---" -ForegroundColor Yellow
            
            do { $ServerIP = Read-Host "IP del Server (ej: 10.0.0.1)" } until (Validar-IP $ServerIP)
            
            $ClassInfo = Get-IPClassInfo -IP $ServerIP
            if (-not $ClassInfo) { Write-Host "Esa IP no me sirve." -ForegroundColor Red; Pause; continue }
            
            $Octets = $ServerIP -split '\.'
            $BaseIP = "$($Octets[0]).$($Octets[1]).$($Octets[2])"
            $StartRange = "$BaseIP.$([int]$Octets[3] + 1)"
            
            Write-Host "Es Clase $($ClassInfo.Class). Empieza en $StartRange" -ForegroundColor Gray
            
            do {
                $EndIP = Read-Host "IP Final (ej: 10.0.0.50)"
                $valido = (Validar-IP $EndIP)
                if ($valido) {
                    $nStart = IP-A-Numero $StartRange
                    $nEnd = IP-A-Numero $EndIP
                    $nServer = IP-A-Numero $ServerIP
                    
                    if ($nEnd -le $nStart) { Write-Host "La final debe ser mayor a la inicial" -ForegroundColor Red; $valido = $false }
                    if ($nEnd -eq $nServer) { Write-Host "No pongas la misma del server" -ForegroundColor Red; $valido = $false }
                }
            } until ($valido)

            try {
                Configure-Network -IPAddress $ServerIP -Prefix $ClassInfo.Prefix
                Setup-DHCPScope -ServerIP $ServerIP -StartRange $StartRange -EndRange $EndIP -SubnetMask $ClassInfo.Mask -SubnetID $ClassInfo.Subnet
                Write-Host "`nTodo listo." -ForegroundColor Green
            } catch {
                Write-Host "Algo trono: $($_.Exception.Message)" -ForegroundColor Red
            }
            Pause
        }
        
        "4" {
            Write-Host "`n--- CLIENTES ---" -ForegroundColor Cyan
            try {
                Get-DhcpServerv4Scope | Get-DhcpServerv4Lease | Format-Table IPAddress, HostName, ClientId -AutoSize
            } catch { Write-Host "Nada por aqui." -ForegroundColor Gray }
            Pause
        }
        
        "5" {
            Write-Host "Borrando leases..." -ForegroundColor Yellow
            Get-DhcpServerv4Scope | Get-DhcpServerv4Lease | Remove-DhcpServerv4Lease -Force
            Restart-Service dhcpserver
            Write-Host "Limpio." -ForegroundColor Green
            Pause
        }
        
        "6" { exit }
    }
}

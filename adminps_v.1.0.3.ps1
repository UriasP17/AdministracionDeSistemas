function Validar-IP ($ip) {
    if ($ip -eq "0.0.0.0" -or $ip -eq "255.255.255.255" -or $ip -eq "127.0.0.1") { return $false }
    return $ip -match "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
}

function IP-A-Numero ($ip) {
    $octetos = $ip.Split('.')
    return [double]($octetos[0]) * [math]::Pow(256, 3) + [double]($octetos[1]) * [math]::Pow(256, 2) + [double]($octetos[2]) * 256 + [double]($octetos[3])
}

function Menu-DHCP {
    Clear-Host
    Write-Host " -----  DHCP WINDOWS SERVER -----" -ForegroundColor Cyan
    Write-Host "[1] Verificar estado del Rol DHCP"
    Write-Host "[2] Instalar/Desinstalar Rol"
    Write-Host "[3] Configurar Servidor"
    Write-Host "[4] Monitorear Leases"
    Write-Host "[5] Salir"
    return Read-Host "`nSeleccione una opcion"
}

do {
    $opcion = Menu-DHCP
    switch ($opcion) {
        "1" {
            $status = Get-WindowsFeature DHCP
            Write-Host "`nEstado del rol: $($status.InstallState)" -ForegroundColor Yellow
            Pause
        }
        "2" {
            $status = Get-WindowsFeature DHCP
            $accion = Read-Host "Escriba 'I' para Instalar o 'D' para Desinstalar"
            if ($accion -eq 'I') {
                if ($status.InstallState -eq "Installed") { Write-Host "Ya instalado." -ForegroundColor Yellow }
                else { Install-WindowsFeature DHCP -IncludeManagementTools }
            }
            elseif ($accion -eq 'D') { Uninstall-WindowsFeature DHCP -IncludeManagementTools }
            Pause
        }
        "3" {
            if ((Get-WindowsFeature DHCP).InstallState -ne "Installed") {
                Write-Host "Error: Instale el rol primero." -ForegroundColor Red ; Pause ; break
            }
            
            $nombreAmbito = Read-Host "Nombre del nuevo Ambito"
            do { $ipServer = Read-Host "IP Inicial (Servidor)" } until (Validar-IP $ipServer)

            $partes = $ipServer.Split('.')
            $primerOcteto = [int]$partes[0]
            if ($primerOcteto -le 126) { $mascara = "255.0.0.0" ; $prefix = 8 }
            elseif ($primerOcteto -le 191) { $mascara = "255.255.0.0" ; $prefix = 16 }
            else { $mascara = "255.255.255.0" ; $prefix = 24 }

            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
            if ($adapter) {
                $adapter | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                $adapter | New-NetIPAddress -IPAddress $ipServer -PrefixLength $prefix -ErrorAction SilentlyContinue | Out-Null
                Write-Host "Servidor configurado en $ipServer" -ForegroundColor Green
            }

            $ipInicio = "$($partes[0]).$($partes[1]).$($partes[2]).$([int]$partes[3] + 1)"
            $numInicio = IP-A-Numero $ipInicio
            $numServer = IP-A-Numero $ipServer

            do {
                $ipFinal = Read-Host "IP Final del rango para clientes"
                $valido = (Validar-IP $ipFinal)
                
                if ($valido) {
                    $numFinal = IP-A-Numero $ipFinal
                    
                    if ($numFinal -eq $numServer) {
                        Write-Host "Error: La IP final no puede ser la misma IP del Servidor ($ipServer)." -ForegroundColor Red
                        $valido = $false
                    }
                    elseif ($numFinal -lt $numInicio) {
                        Write-Host "Error: La IP final ($ipFinal) debe ser MAYOR a la inicial ($ipInicio)." -ForegroundColor Red
                        $valido = $false
                    }
                }
            } until ($valido)

            do {
                $secInput = Read-Host "Lease Time (segundos)"
                if ($secInput -match "^\d+$" -and [int]$secInput -gt 0) {
                    $leaseSec = [int]$secInput
                    $validoSec = $true
                } else {
                    Write-Host "Error: Ingrese un numero entero de segundos valido." -ForegroundColor Red
                    $validoSec = $false
                }
            } until ($validoSec)

            $gw = Read-Host "Gateway (Enter para saltar)"
            $dns = Read-Host "DNS (Enter para saltar)"

            try {
                Add-DhcpServerv4Scope -Name $nombreAmbito -StartRange $ipInicio -EndRange $ipFinal -SubnetMask $mascara -LeaseDuration ([TimeSpan]::FromSeconds($leaseSec)) | Out-Null
                if ($gw) { Set-DhcpServerv4OptionValue -Router $gw -Force | Out-Null }
                if ($dns) { Set-DhcpServerv4OptionValue -DnsServer $dns -Force | Out-Null }
                Write-Host "Ambito '$nombreAmbito' activado exitosamente." -ForegroundColor Green
            } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
            Pause
        }
        "4" {
            Get-DhcpServerv4Scope | ForEach-Object {
                Write-Host "Red: $($_.ScopeId)" -ForegroundColor Yellow
                Get-DhcpServerv4Lease -ScopeId $_.ScopeId | Select-Object IPAddress, HostName, LeaseExpiryTime | Format-Table -AutoSize
            }
            Pause
        }
    }
} while ($opcion -ne "5")

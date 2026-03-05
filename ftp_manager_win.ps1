Import-Module ServerManager

$ftpSiteName = "ServidorFTP"
$basePath = "C:\SrvFTP"
$publicPath = "$basePath\Publico"
$gruposPath = "$basePath\Grupos"
$usersPath = "$basePath\LocalUser"

function Escribir-Titulo {
    param([string]$texto)
    Write-Host "`n=== $texto ===" -ForegroundColor Yellow
}

function Escribir-Exito {
    param([string]$texto)
    Write-Host "[v] $texto" -ForegroundColor Green
}

function Escribir-ErrorMsg {
    param([string]$texto)
    Write-Host "[!] Error: $texto" -ForegroundColor Red
}

function Escribir-Info {
    param([string]$texto)
    Write-Host "[*] $texto" -ForegroundColor Cyan
}

function Preparar-EntornoFTP {
    Escribir-Info "Configurando servidor FTP en IIS..."
    
    Install-WindowsFeature Web-FTP-Server, Web-FTP-Service, Web-FTP-Ext -IncludeManagementTools | Out-Null
    Import-Module WebAdministration

    New-Item -ItemType Directory -Force -Path $publicPath, "$gruposPath\reprobados", "$gruposPath\recursadores", "$usersPath", "$usersPath\Public" | Out-Null

    $grupos = @("grupo-ftp", "reprobados", "recursadores")
    foreach ($grp in $grupos) {
        if (-not (Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grp -Description "Grupo FTP $grp" | Out-Null
        }
    }

    icacls $publicPath /grant "grupo-ftp:(RX)" /T /C /Q | Out-Null
    icacls "$gruposPath\reprobados" /grant "reprobados:(M)" /T /C /Q | Out-Null
    icacls "$gruposPath\recursadores" /grant "recursadores:(M)" /T /C /Q | Out-Null

    if (-not (Test-Path "IIS:\Sites\$ftpSiteName")) {
        New-WebFtpSite -Name $ftpSiteName -Port 21 -PhysicalPath $basePath -Force | Out-Null
        
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.userIsolation.mode -Value 2
        
        New-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser" -PhysicalPath $usersPath | Out-Null
        Add-WebConfiguration -Filter /system.ftpServer/security/authorization -PSPath "IIS:\Sites\$ftpSiteName" -Value @{accessType="Allow"; users="*"; permissions="Read,Write"}
    }

    Enable-NetFirewallRule -DisplayGroup "FTP Server" -ErrorAction SilentlyContinue | Out-Null
    Restart-Service ftpsvc -ErrorAction SilentlyContinue
    Escribir-Exito "Servidor FTP IIS configurado correctamente."
}

function Establecer-PuntosMontaje {
    param([string]$usuario, [string]$grupo)
    
    $vdirGeneral = "IIS:\Sites\$ftpSiteName\LocalUser\$usuario\General"
    $vdirGrupo = "IIS:\Sites\$ftpSiteName\LocalUser\$usuario\$grupo"
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    if (-not (Test-Path $vdirGeneral)) {
        New-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$usuario/General" -PhysicalPath $publicPath | Out-Null
    }
    if (-not (Test-Path $vdirGrupo)) {
        New-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$usuario/$grupo" -PhysicalPath "$gruposPath\$grupo" | Out-Null
    }
}

function Dar-AltaUsuario {
    param([string]$user, [string]$pass, [string]$group)

    if (-not $user -or -not $pass) {
        Escribir-ErrorMsg "Usuario y contrasena son obligatorios."
        return
    }

    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
        Escribir-ErrorMsg "El usuario '$user' ya existe en el sistema."
        return
    }

    $securePass = ConvertTo-SecureString $pass -AsPlainText -Force
    New-LocalUser -Name $user -Password $securePass -PasswordNeverExpires | Out-Null

    Add-LocalGroupMember -Group "grupo-ftp" -Member $user
    Add-LocalGroupMember -Group $group -Member $user

    $userHome = "$usersPath\$user"
    New-Item -ItemType Directory -Force -Path $userHome | Out-Null
    icacls $userHome /grant "$($user):(M)" /T /C /Q | Out-Null
    
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    New-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user" -PhysicalPath $userHome -ErrorAction SilentlyContinue | Out-Null

    Establecer-PuntosMontaje -usuario $user -grupo $group
    Escribir-Exito "Usuario '$user' creado y configurado en el grupo '$group'."
}

function Mover-UsuarioGrupo {
    param([string]$user, [string]$n_group)

    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
        Escribir-ErrorMsg "El usuario '$user' no existe."
        return
    }

    $gruposActuales = @()
    foreach ($g in Get-LocalGroup) {
        $members = Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        if ($members -match ".*\\$user$") {
            $gruposActuales += $g.Name
        }
    }

    if ($gruposActuales -contains "reprobados") { Remove-LocalGroupMember -Group "reprobados" -Member $user -ErrorAction SilentlyContinue }
    if ($gruposActuales -contains "recursadores") { Remove-LocalGroupMember -Group "recursadores" -Member $user -ErrorAction SilentlyContinue }

    Add-LocalGroupMember -Group $n_group -Member $user

    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user/reprobados" -ErrorAction SilentlyContinue
    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user/recursadores" -ErrorAction SilentlyContinue

    Establecer-PuntosMontaje -usuario $user -grupo $n_group
    Escribir-Exito "Usuario '$user' movido al grupo '$n_group'."
}

function Eliminar-Usuario {
    param([string]$user)

    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
        Escribir-ErrorMsg "El usuario '$user' no existe."
        return
    }

    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user/General" -ErrorAction SilentlyContinue
    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user/reprobados" -ErrorAction SilentlyContinue
    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user/recursadores" -ErrorAction SilentlyContinue
    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user" -ErrorAction SilentlyContinue

    Remove-LocalUser -Name $user
    $userHome = "$usersPath\$user"
    if (Test-Path $userHome) { Remove-Item -Path $userHome -Recurse -Force }

    Escribir-Exito "Usuario '$user' eliminado por completo del servidor."
}

function Mostrar-ResumenUsuarios {
    Escribir-Titulo "LISTADO DE USUARIOS FTP"
    
    $lineaCabecera = "{0,-20} | {1,-15}" -f "NOMBRE DE USUARIO", "GRUPO ASIGNADO"
    Write-Host $lineaCabecera -ForegroundColor Cyan
    Write-Host "----------------------------------------"
    
    $miembros = Get-LocalGroupMember -Group "grupo-ftp" -ErrorAction SilentlyContinue
    
    if (-not $miembros) {
        Write-Host "No hay usuarios registrados actualmente."
    } else {
        foreach ($u in $miembros) {
            $nombre = $u.Name.Split('\')[-1]
            $userGroups = @()
            foreach ($g in Get-LocalGroup) {
                $members = Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                if ($members -match ".*\\$nombre$") {
                    $userGroups += $g.Name
                }
            }
            if ($userGroups -contains "reprobados") { $gr = "reprobados" }
            elseif ($userGroups -contains "recursadores") { $gr = "recursadores" }
            else { $gr = "Sin asignar" }
            
            $lineaUsuario = "{0,-20} | {1,-15}" -f $nombre, $gr
            Write-Host $lineaUsuario
        }
    }
    Write-Host "----------------------------------------"
}

function Diagnostico-Sistema {
    Escribir-Titulo "ESTADO DEL SERVIDOR FTP"
    
    $servicio = Get-Service ftpsvc -ErrorAction SilentlyContinue
    if ($servicio.Status -eq "Running") {
        Write-Host "Servicio IIS FTP: " -NoNewline; Write-Host "ACTIVO Y CORRIENDO" -ForegroundColor Green
    } else {
        Write-Host "Servicio IIS FTP: " -NoNewline; Write-Host "INACTIVO / DETENIDO" -ForegroundColor Red
    }

    $ip_addr = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias Ethernet* -ErrorAction SilentlyContinue).IPAddress
    Write-Host "Direccion IP: " -NoNewline; Write-Host $ip_addr -ForegroundColor Cyan
}

function Menu-Principal {
    if (-not (Get-Service ftpsvc -ErrorAction SilentlyContinue)) {
        Preparar-EntornoFTP
    }

    while ($true) {
        Escribir-Titulo "PANEL DE ADMINISTRACION FTP (WINDOWS)"
        Write-Host " [1] Crear nuevos usuarios" -ForegroundColor Cyan
        Write-Host " [2] Ver lista de usuarios" -ForegroundColor Cyan
        Write-Host " [3] Cambiar grupo a un usuario" -ForegroundColor Cyan
        Write-Host " [4] Eliminar usuario del sistema" -ForegroundColor Cyan
        Write-Host " [5] Estado y Diagnostico" -ForegroundColor Cyan
        Write-Host " [6] Forzar reinstalacion/reseteo" -ForegroundColor Cyan
        Write-Host " [0] Salir del panel" -ForegroundColor Red
        Write-Host "---------------------------------------"
        $opt = Read-Host "Elige una opcion -> "

        switch ($opt) {
            "1" {
                Escribir-Titulo "CREACION DE USUARIOS"
                $totalStr = Read-Host "Cuantos usuarios deseas registrar?"
                if ([int]::TryParse($totalStr, [ref]$null) -and [int]$totalStr -gt 0) {
                    $total = [int]$totalStr
                    for ($i = 1; $i -le $total; $i++) {
                        Write-Host "`nUsuario [$i/$total]:"
                        $u_name = Read-Host "  Nombre de usuario"
                        
                        $u_pass = ""
                        while ($u_pass -eq "") {
                            $u_pass = Read-Host "  Contrasena" -AsSecureString
                            $u_pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($u_pass))
                            if ($u_pass -eq "") { Escribir-ErrorMsg "  La contrasena no puede estar vacia." }
                        }

                        $u_group = Read-Host "  Grupo (1: reprobados | 2: recursadores)"
                        if ($u_group -eq "1") { $grp = "reprobados" } else { $grp = "recursadores" }
                        
                        Dar-AltaUsuario -user $u_name -pass $u_pass -group $grp
                    }
                } else {
                    Escribir-ErrorMsg "Cantidad invalida."
                }
            }
            "2" { Mostrar-ResumenUsuarios }
            "3" {
                Escribir-Titulo "MODIFICAR GRUPO"
                $u_name = Read-Host "Nombre del usuario a modificar"
                $u_group = Read-Host "Nuevo Grupo (1: reprobados | 2: recursadores)"
                if ($u_group -eq "1") { $grp = "reprobados" } else { $grp = "recursadores" }
                Mover-UsuarioGrupo -user $u_name -n_group $grp
            }
            "4" {
                Escribir-Titulo "ELIMINAR USUARIO"
                $u_name = Read-Host "Nombre del usuario que deseas borrar"
                $confirmar = Read-Host "Estas seguro de eliminar a '$u_name'? (s/n)"
                if ($confirmar -eq "s" -or $confirmar -eq "S") {
                    Eliminar-Usuario -user $u_name
                } else {
                    Write-Host "Operacion cancelada."
                }
            }
            "5" { Diagnostico-Sistema }
            "6" { Preparar-EntornoFTP }
            "0" { 
                Escribir-Info "Saliendo..."
                exit 
            }
            default { Escribir-ErrorMsg "Opcion no valida. Intenta de nuevo." }
        }
        Write-Host ""
        cmd /c pause
    }
}

Menu-Principal

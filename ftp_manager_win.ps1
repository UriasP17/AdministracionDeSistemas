Import-Module ServerManager

$ftpSiteName = "ServidorFTP"
$basePath = "C:\SrvFTP"
$publicPath = "$basePath\Publico"
$gruposPath = "$basePath\Grupos"
$usersPath = "$basePath\LocalUser"

function Escribir-Titulo { param([string]$texto); Write-Host "`n=== $texto ===" -ForegroundColor Yellow }
function Escribir-Exito { param([string]$texto); Write-Host "[v] $texto" -ForegroundColor Green }
function Escribir-ErrorMsg { param([string]$texto); Write-Host "[!] Error: $texto" -ForegroundColor Red }
function Escribir-Info { param([string]$texto); Write-Host "[*] $texto" -ForegroundColor Cyan }

function Preparar-EntornoFTP {
    Escribir-Info "Configurando servidor FTP en IIS..."
    
    if (-not (Get-WindowsFeature Web-Ftp-Server).Installed) {
        Install-WindowsFeature Web-Ftp-Server, Web-Mgmt-Console -IncludeManagementTools | Out-Null
    }

    New-Item -ItemType Directory -Force -Path $publicPath, "$gruposPath\reprobados", "$gruposPath\recursadores", "$usersPath", "$usersPath\Public" | Out-Null
    
    $grupos = @("grupo-ftp", "reprobados", "recursadores")
    foreach ($grp in $grupos) {
        if (-not (Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grp -Description "Grupo FTP $grp" | Out-Null
        }
    }

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    if (-not (Test-Path "IIS:\Sites\$ftpSiteName")) {
        New-WebFtpSite -Name $ftpSiteName -Port 21 -PhysicalPath $basePath -Force | Out-Null
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.userIsolation.mode -Value "IsolateDirectory"
    }

    Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.ssl.controlChannelPolicy -Value "SslAllow"
    Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.ssl.dataChannelPolicy -Value "SslAllow"

    Set-WebConfigurationProperty -Filter "/system.ftpServer/security/authentication/anonymousAuthentication" -PSPath "IIS:\Sites\$ftpSiteName" -Name "enabled" -Value $true -ErrorAction SilentlyContinue
    Set-WebConfigurationProperty -Filter "/system.ftpServer/security/authentication/basicAuthentication" -PSPath "IIS:\Sites\$ftpSiteName" -Name "enabled" -Value $true -ErrorAction SilentlyContinue

    try {
        Add-WebConfigurationProperty -Filter "/system.ftpServer/security/authorization" -PSPath "IIS:\Sites\$ftpSiteName" -Name "." -Value @{accessType="Allow";users="*";permissions="Read,Write"} -ErrorAction SilentlyContinue
    } catch { }

    Enable-NetFirewallRule -DisplayGroup "FTP Server" -ErrorAction SilentlyContinue | Out-Null
    Start-Service ftpsvc -ErrorAction SilentlyContinue
    Escribir-Exito "Servidor FTP IIS configurado correctamente."
}

function Establecer-PuntosMontaje {
    param([string]$usuario, [string]$grupo)
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    
    New-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$usuario/General" -PhysicalPath $publicPath -Force | Out-Null
    New-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$usuario/$grupo" -PhysicalPath "$gruposPath\$grupo" -Force | Out-Null
}

function Dar-AltaUsuario {
    param([string]$user, [string]$pass, [string]$group)

    if (-not $user -or -not $pass) { return Escribir-ErrorMsg "Usuario y contrasena obligatorios." }
    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) { return Escribir-ErrorMsg "El usuario '$user' ya existe." }

    $securePass = ConvertTo-SecureString $pass -AsPlainText -Force
    try {
        New-LocalUser -Name $user -Password $securePass -PasswordNeverExpires -ErrorAction Stop | Out-Null
    } catch {
        return Escribir-ErrorMsg "La contrasena no cumple la politica (usa mayusculas, numeros, y simbolos)."
    }

    Add-LocalGroupMember -Group "grupo-ftp" -Member $user -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group $group -Member $user -ErrorAction SilentlyContinue

    $userHome = "$usersPath\$user"
    if (-not (Test-Path $userHome)) { New-Item -ItemType Directory -Force -Path $userHome | Out-Null }
    icacls $userHome /grant "${user}:(OI)(CI)(F)" /inheritance:r /Q | Out-Null

    Establecer-PuntosMontaje -usuario $user -grupo $group
    Escribir-Exito "Usuario '$user' creado en el grupo '$group'."
}

function Mover-UsuarioGrupo {
    param([string]$user, [string]$n_group)

    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) { return Escribir-ErrorMsg "Usuario no existe." }

    $gruposActuales = @()
    foreach ($g in Get-LocalGroup) {
        $members = Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        if ($members -match ".*\\$user$") { $gruposActuales += $g.Name }
    }

    if ($gruposActuales -contains "reprobados") { Remove-LocalGroupMember -Group "reprobados" -Member $user -ErrorAction SilentlyContinue }
    if ($gruposActuales -contains "recursadores") { Remove-LocalGroupMember -Group "recursadores" -Member $user -ErrorAction SilentlyContinue }
    Add-LocalGroupMember -Group $n_group -Member $user -ErrorAction SilentlyContinue

    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user/reprobados" -ErrorAction SilentlyContinue
    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user/recursadores" -ErrorAction SilentlyContinue

    Establecer-PuntosMontaje -usuario $user -grupo $n_group
    Escribir-Exito "Usuario '$user' movido al grupo '$n_group'."
}

function Eliminar-Usuario {
    param([string]$user)
    
    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) { return Escribir-ErrorMsg "Usuario no existe." }

    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Remove-WebVirtualDirectory -Site $ftpSiteName -Name "LocalUser/$user" -ErrorAction SilentlyContinue
    Remove-LocalUser -Name $user -ErrorAction SilentlyContinue

    $userHome = "$usersPath\$user"
    if (Test-Path $userHome) { Remove-Item -Path $userHome -Recurse -Force -ErrorAction SilentlyContinue }

    Escribir-Exito "Usuario '$user' eliminado."
}

function Mostrar-ResumenUsuarios {
    Escribir-Titulo "LISTADO DE USUARIOS FTP"
    Write-Host ("{0,-20} | {1,-15}" -f "NOMBRE DE USUARIO", "GRUPO ASIGNADO") -ForegroundColor Cyan
    Write-Host "----------------------------------------"
    
    $miembros = Get-LocalGroupMember -Group "grupo-ftp" -ErrorAction SilentlyContinue
    if (-not $miembros) { Write-Host "No hay usuarios." } else {
        foreach ($u in $miembros) {
            $nombre = $u.Name.Split('\')[-1]
            $userGroups = @()
            foreach ($g in Get-LocalGroup) {
                $m = Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                if ($m -match ".*\\$nombre$") { $userGroups += $g.Name }
            }
            if ($userGroups -contains "reprobados") { $gr = "reprobados" }
            elseif ($userGroups -contains "recursadores") { $gr = "recursadores" }
            else { $gr = "Sin asignar" }
            Write-Host ("{0,-20} | {1,-15}" -f $nombre, $gr)
        }
    }
    Write-Host "----------------------------------------"
}

function Diagnostico-Sistema {
    Escribir-Titulo "ESTADO DEL SERVIDOR FTP"
    $servicio = Get-Service ftpsvc -ErrorAction SilentlyContinue
    if ($servicio.Status -eq "Running") { Write-Host "Servicio IIS FTP: ACTIVO" -ForegroundColor Green } 
    else { Write-Host "Servicio IIS FTP: INACTIVO" -ForegroundColor Red }
    
    $ip_addr = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias Ethernet* -ErrorAction SilentlyContinue).IPAddress
    Write-Host "Direccion IP: $ip_addr" -ForegroundColor Cyan
}

function Menu-Principal {
    if (-not (Get-Service ftpsvc -ErrorAction SilentlyContinue)) { Preparar-EntornoFTP }

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
                $totalStr = Read-Host "Cuantos usuarios deseas registrar?"
                if ([int]::TryParse($totalStr, [ref]$null) -and [int]$totalStr -gt 0) {
                    for ($i = 1; $i -le [int]$totalStr; $i++) {
                        $u_name = Read-Host "Nombre de usuario"
                        $u_pass = Read-Host "Contrasena" -AsSecureString
                        $u_pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($u_pass))
                        $u_group = Read-Host "Grupo (1: reprobados | 2: recursadores)"
                        $grp = if ($u_group -eq "1") { "reprobados" } else { "recursadores" }
                        Dar-AltaUsuario -user $u_name -pass $u_pass -group $grp
                    }
                }
            }
            "2" { Mostrar-ResumenUsuarios }
            "3" {
                $u_name = Read-Host "Usuario a modificar"
                $u_group = Read-Host "Nuevo Grupo (1: reprobados | 2: recursadores)"
                $grp = if ($u_group -eq "1") { "reprobados" } else { "recursadores" }
                Mover-UsuarioGrupo -user $u_name -n_group $grp
            }
            "4" {
                $u_name = Read-Host "Usuario a borrar"
                $confirmar = Read-Host "Estas seguro? (s/n)"
                if ($confirmar -eq "s") { Eliminar-Usuario -user $u_name }
            }
            "5" { Diagnostico-Sistema }
            "6" { Preparar-EntornoFTP }
            "0" { exit }
        }
    }
}

Menu-Principal

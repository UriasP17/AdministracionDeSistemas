#Requires -RunAsAdministrator
Import-Module ServerManager

$ftpSiteName = "ServidorFTP"
$FTP_ROOT = "C:\inetpub\ftproot"
$FTP_ANON = "C:\inetpub\ftpanon"
$GRUPOS = @("reprobados", "recursadores")

# --- FUNCIONES DE INTERFAZ TIPO TUI ---
function Escribir-Titulo { 
    param([string]$texto)
    Write-Host "`n  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    
    $espaciosCount = 48 - $texto.Length
    if ($espaciosCount -lt 0) { $espaciosCount = 0 }
    $espacios = " " * $espaciosCount
    
    Write-Host "  ║ " -ForegroundColor Cyan -NoNewline
    Write-Host "$texto" -ForegroundColor White -NoNewline
    Write-Host "$espacios ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Escribir-Exito { 
    param([string]$texto)
    Write-Host "  [+] " -ForegroundColor Green -NoNewline
    Write-Host $texto -ForegroundColor Gray
}

function Escribir-ErrorMsg { 
    param([string]$texto)
    Write-Host "  [X] " -ForegroundColor Red -NoNewline
    Write-Host $texto -ForegroundColor Gray
}

function Escribir-Info { 
    param([string]$texto)
    Write-Host "  [i] " -ForegroundColor Yellow -NoNewline
    Write-Host $texto -ForegroundColor Gray
}

# --- FUNCIONES CORE DEL FTP ---
function Desactivar-ComplejidadPassword {
    $outfile = "$Env:TEMP\secpol.cfg"
    secedit /export /cfg $outfile /quiet
    (Get-Content $outfile) -replace 'PasswordComplexity = 1', 'PasswordComplexity = 0' | Out-File $outfile -Force
    secedit /configure /db c:\windows\security\local.sdb /cfg $outfile /areas SECURITYPOLICY /quiet
    Remove-Item $outfile -Force
}

function Remove-JunctionSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            cmd /c "rmdir `"$Path`"" | Out-Null
        } elseif ($item.PSIsContainer) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    } catch {
        cmd /c "rmdir /s /q `"$Path`"" | Out-Null
    }
}

function Obtener-GrupoUsuario {
    param([string]$Username)
    foreach ($grp in $GRUPOS) {
        $miembros = Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        if ($miembros -match ".*\\$Username$") { return $grp }
    }
    return $null
}

function Set-FolderACL {
    param([string]$Path, [array]$Rules)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($rule in $Rules) {
        $identity = $rule.Identity
        $accessType = if ($rule.Type) { $rule.Type } else { "Allow" }
        $inherit = if ($rule.Inherit) { $rule.Inherit } else { "ContainerInherit,ObjectInherit" }
        $propagate = if ($rule.Propagate) { $rule.Propagate } else { "None" }

        try {
            if ($identity -eq "Administrators") {
                $resolved = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")
            } elseif ($identity -in @("SYSTEM", "IUSR", "NETWORK SERVICE")) {
                $resolved = New-Object System.Security.Principal.NTAccount("NT AUTHORITY\$identity")
            } else {
                $resolved = New-Object System.Security.Principal.NTAccount("$env:COMPUTERNAME\$identity")
            }
            $resolved.Translate([System.Security.Principal.SecurityIdentifier]) | Out-Null
        } catch { continue }

        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $resolved,
            [System.Security.AccessControl.FileSystemRights]$rule.Rights,
            $inherit,
            $propagate,
            $accessType
        )
        $acl.AddAccessRule($ace)
    }
    try { Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop } catch { }
}

function Set-FtpAuthRules {
    param([string]$SiteName, [array]$Rules, [string]$Location = "")
    $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
    Stop-Service -Name "W3SVC", "FTPSVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    [xml]$config = Get-Content $configPath
    $locationAttr = if ($Location -eq "") { $SiteName } else { "$SiteName/$Location" }
    $locationNode = $config.configuration.SelectSingleNode("location[@path='$locationAttr']")

    if (-not $locationNode) {
        $locationNode = $config.CreateElement("location")
        $locationNode.SetAttribute("path", $locationAttr)
        $locationNode.SetAttribute("overrideMode", "Allow")
        $config.configuration.AppendChild($locationNode) | Out-Null
    }

    $ftpNode = $locationNode.SelectSingleNode("system.ftpServer")
    if (-not $ftpNode) {
        $ftpNode = $config.CreateElement("system.ftpServer")
        $locationNode.AppendChild($ftpNode) | Out-Null
    }

    $secNode = $ftpNode.SelectSingleNode("security")
    if (-not $secNode) {
        $secNode = $config.CreateElement("security")
        $ftpNode.AppendChild($secNode) | Out-Null
    }

    $authNode = $secNode.SelectSingleNode("authorization")
    if (-not $authNode) {
        $authNode = $config.CreateElement("authorization")
        $secNode.AppendChild($authNode) | Out-Null
    }
    $authNode.RemoveAll()

    foreach ($rule in $Rules) {
        $addNode = $config.CreateElement("add")
        $addNode.SetAttribute("accessType", "Allow")
        $addNode.SetAttribute("users", $rule.users)
        $addNode.SetAttribute("roles", $rule.roles)
        $addNode.SetAttribute("permissions", $rule.permissions)
        $authNode.AppendChild($addNode) | Out-Null
    }
    $config.Save($configPath)
    Start-Service -Name "W3SVC", "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Set-FtpUserIsolation {
    param([string]$SiteName, [string]$Mode)
    $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
    Stop-Service -Name "FTPSVC", "W3SVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    [xml]$config = Get-Content $configPath
    $site = $config.configuration.'system.applicationHost'.sites.site | Where-Object { $_.name -eq $SiteName }
    $ftpServer = $site.SelectSingleNode("ftpServer")

    if (-not $ftpServer) {
        $ftpServer = $config.CreateElement("ftpServer")
        $site.AppendChild($ftpServer) | Out-Null
    }
    $userIsolation = $ftpServer.SelectSingleNode("userIsolation")
    if (-not $userIsolation) {
        $userIsolation = $config.CreateElement("userIsolation")
        $ftpServer.AppendChild($userIsolation) | Out-Null
    }

    $userIsolation.SetAttribute("mode", $Mode)
    $config.Save($configPath)
    Start-Service -Name "W3SVC", "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Crear-Estructura-Base {
    foreach ($dir in @(
        "$FTP_ROOT\general",
        "$FTP_ROOT\reprobados",
        "$FTP_ROOT\recursadores",
        "$FTP_ROOT\personal",
        "$FTP_ANON\LocalUser",
        "$FTP_ANON\LocalUser\Public",
        "$FTP_ANON\$env:COMPUTERNAME"
    )) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    foreach ($grupo in $GRUPOS) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo | Out-Null
        }
    }

    Set-FolderACL -Path "$FTP_ROOT\general" -Rules @(
        @{ Identity = "SYSTEM"; Rights = "FullControl" },
        @{ Identity = "Administrators"; Rights = "FullControl" },
        @{ Identity = "IUSR"; Rights = "ReadAndExecute" },
        @{ Identity = "reprobados"; Rights = "Modify" },
        @{ Identity = "recursadores"; Rights = "Modify" },
        @{ Identity = "reprobados"; Rights = "Delete"; Type = "Deny"; Inherit = "None" },
        @{ Identity = "recursadores"; Rights = "Delete"; Type = "Deny"; Inherit = "None" }
    )

    foreach ($grupo in $GRUPOS) {
        Set-FolderACL -Path "$FTP_ROOT\$grupo" -Rules @(
            @{ Identity = "SYSTEM"; Rights = "FullControl" },
            @{ Identity = "Administrators"; Rights = "FullControl" },
            @{ Identity = $grupo; Rights = "Modify" },
            @{ Identity = $grupo; Rights = "Delete"; Type = "Deny"; Inherit = "None" }
        )
    }

    $publicAclRules = @(
        @{ Identity = "SYSTEM"; Rights = "FullControl" },
        @{ Identity = "Administrators"; Rights = "FullControl" },
        @{ Identity = "IUSR"; Rights = "ReadAndExecute" },
        @{ Identity = "NETWORK SERVICE"; Rights = "ReadAndExecute" }
    )

    Set-FolderACL -Path $FTP_ANON -Rules $publicAclRules
    Set-FolderACL -Path "$FTP_ANON\LocalUser" -Rules $publicAclRules
    Set-FolderACL -Path "$FTP_ANON\LocalUser\Public" -Rules $publicAclRules
    Set-FolderACL -Path "$FTP_ANON\$env:COMPUTERNAME" -Rules $publicAclRules

    $anonJunction = "$FTP_ANON\LocalUser\Public\general"
    Remove-JunctionSafe -Path $anonJunction
    cmd /c "mklink /J `"$anonJunction`" `"$FTP_ROOT\general`"" | Out-Null
}

# --- OPCIONES DEL MENU ---
function Opcion-Instalar-FTP {
    Escribir-Titulo "Instalar y configurar servidor FTP"
    Escribir-Info "Instalando componentes IIS..."
    Desactivar-ComplejidadPassword
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Mgmt-Console")
    foreach ($feature in $features) {
        if ((Get-WindowsFeature -Name $feature).InstallState -ne "Installed") {
            Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null
        }
    }
    Set-Service -Name "FTPSVC" -StartupType Automatic
    Escribir-Exito "Componentes IIS FTP instalados correctamente."
    
    Escribir-Info "Configurando estructura y permisos del sitio..."
    Import-Module WebAdministration -Force -ErrorAction SilentlyContinue
    if (Get-WebSite -Name $ftpSiteName -ErrorAction SilentlyContinue) {
        Stop-Service -Name "W3SVC", "FTPSVC" -Force -ErrorAction SilentlyContinue
        Remove-WebSite -Name $ftpSiteName
        if (Test-Path $FTP_ROOT) { Remove-Item $FTP_ROOT -Recurse -Force }
        if (Test-Path $FTP_ANON) { Remove-Item $FTP_ANON -Recurse -Force }
    }

    Crear-Estructura-Base
    Start-Service -Name "W3SVC" -ErrorAction SilentlyContinue
    New-WebFtpSite -Name $ftpSiteName -Port 21 -PhysicalPath $FTP_ANON | Out-Null

    Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.authentication.anonymousAuthentication.userName -Value "IUSR"
    Set-ItemProperty "IIS:\Sites\$ftpSiteName" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true

    Set-FtpUserIsolation -SiteName $ftpSiteName -Mode "IsolateAllDirectories"
    Set-FtpAuthRules -SiteName $ftpSiteName -Rules @(
        @{ users = "?"; roles = ""; permissions = "Read" },
        @{ users = "*"; roles = ""; permissions = "Read,Write" }
    )

    if (-not (Get-NetFirewallRule -DisplayName "FTP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
    }

    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Escribir-Exito "Servidor FTP configurado y en ejecucion."
}

function Opcion-Crear-Usuarios {
    Escribir-Titulo "Crear Nuevos Usuarios"
    Desactivar-ComplejidadPassword
    Write-Host "  > " -ForegroundColor Yellow -NoNewline
    $N = Read-Host "Cuantos usuarios deseas crear?"

    if ($N -notmatch "^\d+$" -or $N -eq "0") {
        Escribir-ErrorMsg "Cantidad invalida."
        return
    }

    for ($i = 1; $i -le [int]$N; $i++) {
        Write-Host "`n  --- Usuario $i de $N ---" -ForegroundColor DarkCyan
        Write-Host "  > " -ForegroundColor Yellow -NoNewline
        $USERNAME = Read-Host "Nombre de usuario"
        
        if (Get-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue) {
            Escribir-ErrorMsg "El usuario '$USERNAME' ya existe en el sistema operativo."
            continue
        }

        Write-Host "  > " -ForegroundColor Yellow -NoNewline
        $PASSWORD = Read-Host "Contrasena" -AsSecureString
        Write-Host "  > " -ForegroundColor Yellow -NoNewline
        $GRUPO_SEL = Read-Host "Grupo (1: reprobados | 2: recursadores)"
        $GRUPO = if ($GRUPO_SEL -eq "1") { "reprobados" } else { "recursadores" }

        Escribir-Info "Generando cuentas y carpetas..."
        try {
            New-LocalUser -Name $USERNAME -Password $PASSWORD -PasswordNeverExpires -ErrorAction Stop | Out-Null
            foreach ($grp in $GRUPOS) {
                Remove-LocalGroupMember -Group $grp -Member $USERNAME -ErrorAction SilentlyContinue
            }
            Add-LocalGroupMember -Group $GRUPO -Member $USERNAME -ErrorAction SilentlyContinue
        } catch {
            Escribir-ErrorMsg "Fallo al crear la cuenta. Verifica politicas de contrasena."
            continue
        }

        $USER_FTP_DIR = "$FTP_ANON\LocalUser\$USERNAME"
        $personalDir = "$FTP_ROOT\personal\$USERNAME"
        
        New-Item -ItemType Directory -Path $USER_FTP_DIR -Force | Out-Null
        New-Item -ItemType Directory -Path $personalDir -Force | Out-Null

        Set-FolderACL -Path $personalDir -Rules @(
            @{ Identity = "SYSTEM"; Rights = "FullControl" },
            @{ Identity = "Administrators"; Rights = "FullControl" },
            @{ Identity = $USERNAME; Rights = "Modify" },
            @{ Identity = $USERNAME; Rights = "Delete"; Type = "Deny"; Inherit = "None" }
        )

        Set-FolderACL -Path $USER_FTP_DIR -Rules @(
            @{ Identity = "SYSTEM"; Rights = "FullControl" },
            @{ Identity = "Administrators"; Rights = "FullControl" },
            @{ Identity = $USERNAME; Rights = "ReadAndExecute" }
        )

        Remove-JunctionSafe -Path "$USER_FTP_DIR\general"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\reprobados"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\recursadores"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\$USERNAME"

        cmd /c "mklink /J `"$USER_FTP_DIR\general`" `"$FTP_ROOT\general`"" | Out-Null
        cmd /c "mklink /J `"$USER_FTP_DIR\$GRUPO`" `"$FTP_ROOT\$GRUPO`"" | Out-Null
        cmd /c "mklink /J `"$USER_FTP_DIR\$USERNAME`" `"$FTP_ROOT\personal\$USERNAME`"" | Out-Null

        Escribir-Exito "Cuenta '$USERNAME' creada exitosamente en '$GRUPO'."
    }
}

function Opcion-Cambiar-Grupo {
    Escribir-Titulo "Reasignar Grupo de Usuario"
    Write-Host "  > " -ForegroundColor Yellow -NoNewline
    $USERNAME = Read-Host "Nombre del usuario a reasignar"

    if (-not (Get-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue)) {
        return Escribir-ErrorMsg "El usuario '$USERNAME' no existe."
    }

    $GRUPO_ACTUAL = Obtener-GrupoUsuario -Username $USERNAME
    if (-not $GRUPO_ACTUAL) {
        return Escribir-ErrorMsg "El usuario no pertenece a ningun grupo FTP manejado."
    }

    Write-Host "  >> Grupo actual: " -ForegroundColor DarkGray -NoNewline
    Write-Host $GRUPO_ACTUAL -ForegroundColor Cyan
    Write-Host "  > " -ForegroundColor Yellow -NoNewline
    $NUEVO_GRUPO_SEL = Read-Host "Selecciona nuevo grupo (1: reprobados | 2: recursadores)"
    $NUEVO_GRUPO = if ($NUEVO_GRUPO_SEL -eq "1") { "reprobados" } else { "recursadores" }

    if ($GRUPO_ACTUAL -eq $NUEVO_GRUPO) {
        return Escribir-ErrorMsg "'$USERNAME' ya forma parte del grupo '$NUEVO_GRUPO'."
    }

    Escribir-Info "Procesando migracion de enlaces..."
    Remove-LocalGroupMember -Group $GRUPO_ACTUAL -Member $USERNAME -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group $NUEVO_GRUPO -Member $USERNAME -ErrorAction SilentlyContinue

    $USER_FTP_DIR = "$FTP_ANON\LocalUser\$USERNAME"
    $oldJunction = "$USER_FTP_DIR\$GRUPO_ACTUAL"
    $newJunction = "$USER_FTP_DIR\$NUEVO_GRUPO"

    Remove-JunctionSafe -Path $oldJunction
    Remove-JunctionSafe -Path $newJunction
    cmd /c "mklink /J `"$newJunction`" `"$FTP_ROOT\$NUEVO_GRUPO`"" | Out-Null

    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue

    Escribir-Exito "Migracion completada: '$USERNAME' ahora es de '$NUEVO_GRUPO'."
}

function Opcion-Eliminar-Usuario {
    Escribir-Titulo "Borrar Usuario del Servidor"
    Write-Host "  > " -ForegroundColor Yellow -NoNewline
    $USERNAME = Read-Host "Nombre del usuario a eliminar"

    if (-not (Get-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue)) {
        return Escribir-ErrorMsg "El usuario '$USERNAME' no existe."
    }

    Write-Host "  > " -ForegroundColor Red -NoNewline
    $confirm = Read-Host "Seguro que deseas eliminar a '$USERNAME' permanentemente? (s/n)"
    if ($confirm -match "^[sS]$") {

        Escribir-Info "Limpiando archivos y configuraciones..."
        foreach ($grupo in $GRUPOS) {
            Remove-LocalGroupMember -Group $grupo -Member $USERNAME -ErrorAction SilentlyContinue
        }

        $USER_FTP_DIR = "$FTP_ANON\LocalUser\$USERNAME"
        $personalDir = "$FTP_ROOT\personal\$USERNAME"

        Remove-JunctionSafe -Path "$USER_FTP_DIR\general"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\reprobados"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\recursadores"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\$USERNAME"

        Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        if (Test-Path $USER_FTP_DIR) {
            cmd /c "rmdir /s /q `"$USER_FTP_DIR`"" | Out-Null
        }
        if (Test-Path $personalDir) {
            cmd /c "rmdir /s /q `"$personalDir`"" | Out-Null
        }

        Remove-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue
        Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue

        Escribir-Exito "El usuario '$USERNAME' ha sido borrado del sistema."
    } else {
        Escribir-Info "Operacion cancelada por el administrador."
    }
}

function Opcion-Ver-Usuarios {
    Escribir-Titulo "Directorio de Usuarios FTP"
    $usuariosEncontrados = @()

    foreach ($grupo in $GRUPOS) {
        $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue
        foreach ($miembro in $miembros) {
            $nombre = $miembro.Name.Split('\')[-1]
            $usuariosEncontrados += [PSCustomObject]@{
                Usuario = $nombre
                Grupo   = $grupo
            }
        }
    }

    if ($usuariosEncontrados.Count -eq 0) {
        Write-Host "`n  No se encontraron usuarios registrados en la base de datos." -ForegroundColor DarkGray
    } else {
        Write-Host "`n  ==================================================" -ForegroundColor DarkGray
        Write-Host "  | " -NoNewline -ForegroundColor DarkGray
        Write-Host "USUARIO".PadRight(25) -ForegroundColor Cyan -NoNewline
        Write-Host " | " -NoNewline -ForegroundColor DarkGray
        Write-Host "GRUPO ASIGNADO".PadRight(18) -ForegroundColor Cyan -NoNewline
        Write-Host " |" -ForegroundColor DarkGray
        Write-Host "  ==================================================" -ForegroundColor DarkGray
        
        foreach ($u in ($usuariosEncontrados | Sort-Object Usuario)) {
            $colorGrupo = if ($u.Grupo -eq "reprobados") { "Red" } else { "Yellow" }
            Write-Host "  | " -NoNewline -ForegroundColor DarkGray
            Write-Host $u.Usuario.PadRight(25) -ForegroundColor White -NoNewline
            Write-Host " | " -NoNewline -ForegroundColor DarkGray
            Write-Host $u.Grupo.PadRight(18) -ForegroundColor $colorGrupo -NoNewline
            Write-Host " |" -ForegroundColor DarkGray
        }
        Write-Host "  ==================================================" -ForegroundColor DarkGray
    }
}

function Menu-Principal {
    try { $Host.UI.RawUI.WindowTitle = "Panel de Administracion FTP - IIS" } catch {}
    
    while ($true) {
        Clear-Host
        Write-Host "`n"
        Write-Host "    ███████╗████████╗██████╗     " -ForegroundColor Cyan
        Write-Host "    ██╔════╝╚══██╔══╝██╔══██╗    " -ForegroundColor Cyan
        Write-Host "    █████╗     ██║   ██████╔╝    " -ForegroundColor Cyan
        Write-Host "    ██╔══╝     ██║   ██╔═══╝     " -ForegroundColor Cyan
        Write-Host "    ██║        ██║   ██║         " -ForegroundColor Cyan
        Write-Host "    ╚═╝        ╚═╝   ╚═╝         " -ForegroundColor Cyan
        Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "     ADMINISTRADOR FTP // IIS WINDOWS" -ForegroundColor Magenta
        Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        
        Write-Host "    [" -ForegroundColor DarkGray -NoNewline; Write-Host "1" -ForegroundColor Cyan -NoNewline; Write-Host "] " -ForegroundColor DarkGray -NoNewline; Write-Host "Instalar y configurar servidor"
        Write-Host "    [" -ForegroundColor DarkGray -NoNewline; Write-Host "2" -ForegroundColor Cyan -NoNewline; Write-Host "] " -ForegroundColor DarkGray -NoNewline; Write-Host "Agregar usuarios"
        Write-Host "    [" -ForegroundColor DarkGray -NoNewline; Write-Host "3" -ForegroundColor Cyan -NoNewline; Write-Host "] " -ForegroundColor DarkGray -NoNewline; Write-Host "Reasignar grupo a usuario"
        Write-Host "    [" -ForegroundColor DarkGray -NoNewline; Write-Host "4" -ForegroundColor Cyan -NoNewline; Write-Host "] " -ForegroundColor DarkGray -NoNewline; Write-Host "Borrar usuario"
        Write-Host "    [" -ForegroundColor DarkGray -NoNewline; Write-Host "5" -ForegroundColor Cyan -NoNewline; Write-Host "] " -ForegroundColor DarkGray -NoNewline; Write-Host "Directorio de usuarios"
        Write-Host ""
        Write-Host "    [" -ForegroundColor DarkGray -NoNewline; Write-Host "0" -ForegroundColor Red -NoNewline; Write-Host "] " -ForegroundColor DarkGray -NoNewline; Write-Host "Salir"
        Write-Host "`n  ──────────────────────────────────────────" -ForegroundColor DarkGray
        
        Write-Host "  > " -ForegroundColor Yellow -NoNewline
        $opt = Read-Host "Elige una opcion"

        switch ($opt) {
            "1" { Opcion-Instalar-FTP }
            "2" { Opcion-Crear-Usuarios }
            "3" { Opcion-Cambiar-Grupo }
            "4" { Opcion-Eliminar-Usuario }
            "5" { Opcion-Ver-Usuarios }
            "0" { 
                Write-Host "`n  Cerrando administrador..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 1
                exit 
            }
            default { Escribir-ErrorMsg "Opcion no valida." }
        }
        
        Write-Host ""
        $null = Read-Host "  Presiona ENTER para volver al menu principal..."
    }
}

Menu-Principal

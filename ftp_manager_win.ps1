#Requires -RunAsAdministrator
Import-Module ServerManager

$ftpSiteName = "ServidorFTP"
$FTP_ROOT = "C:\inetpub\ftproot"
$FTP_ANON = "C:\inetpub\ftpanon"
$GRUPOS = @("reprobados", "recursadores")

function Escribir-Titulo { param([string]$texto); Write-Host "`n=== $texto ===" -ForegroundColor Yellow }
function Escribir-Exito { param([string]$texto); Write-Host "[v] $texto" -ForegroundColor Green }
function Escribir-ErrorMsg { param([string]$texto); Write-Host "[!] Error: $texto" -ForegroundColor Red }
function Escribir-Info { param([string]$texto); Write-Host "[*] $texto" -ForegroundColor Cyan }

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
        @{ Identity = "reprobados"; Rights = "ReadAndExecute"; Inherit = "None" },
        @{ Identity = "recursadores"; Rights = "ReadAndExecute"; Inherit = "None" },
        @{ Identity = "reprobados"; Rights = "Modify"; Inherit = "ContainerInherit,ObjectInherit"; Propagate = "InheritOnly" },
        @{ Identity = "recursadores"; Rights = "Modify"; Inherit = "ContainerInherit,ObjectInherit"; Propagate = "InheritOnly" }
    )

    foreach ($grupo in $GRUPOS) {
        Set-FolderACL -Path "$FTP_ROOT\$grupo" -Rules @(
            @{ Identity = "SYSTEM"; Rights = "FullControl" },
            @{ Identity = "Administrators"; Rights = "FullControl" },
            @{ Identity = $grupo; Rights = "ReadAndExecute"; Inherit = "None" },
            @{ Identity = $grupo; Rights = "Modify"; Inherit = "ContainerInherit,ObjectInherit"; Propagate = "InheritOnly" }
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

function Opcion-Instalar-FTP {
    Escribir-Titulo "Instalando componentes IIS FTP..."
    Desactivar-ComplejidadPassword
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Mgmt-Console")
    foreach ($feature in $features) {
        if ((Get-WindowsFeature -Name $feature).InstallState -ne "Installed") {
            Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null
        }
    }
    Set-Service -Name "FTPSVC" -StartupType Automatic
    Escribir-Exito "Instalacion completada."
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Configurar-FTP {
    Escribir-Titulo "Configurando sitio FTP..."
    if (-not (Get-WindowsFeature -Name "Web-Ftp-Server").Installed) {
        return Escribir-ErrorMsg "IIS FTP no esta instalado. Usa la opcion 1 primero."
    }

    Import-Module WebAdministration -Force
    if (Get-WebSite -Name $ftpSiteName -ErrorAction SilentlyContinue) {
        $resp = Read-Host "Deseas rehacer la configuracion? (s/n)"
        if ($resp -notmatch "^[sS]$") { return }

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
    Escribir-Exito "Sitio FTP configurado."
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Crear-Usuarios {
    Escribir-Titulo "CREAR USUARIOS FTP"
    Desactivar-ComplejidadPassword
    $N = Read-Host "Cuantos usuarios deseas crear?"

    for ($i = 1; $i -le [int]$N; $i++) {
        $USERNAME = Read-Host "`nNombre de usuario $i"
        if (Get-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue) {
            Escribir-ErrorMsg "Usuario ya existe."
            continue
        }

        $PASSWORD = Read-Host "Contrasena" -AsSecureString
        $GRUPO_SEL = Read-Host "Grupo (1: reprobados | 2: recursadores)"
        $GRUPO = if ($GRUPO_SEL -eq "1") { "reprobados" } else { "recursadores" }

        try {
            New-LocalUser -Name $USERNAME -Password $PASSWORD -PasswordNeverExpires -ErrorAction Stop | Out-Null
            foreach ($grp in $GRUPOS) {
                Remove-LocalGroupMember -Group $grp -Member $USERNAME -ErrorAction SilentlyContinue
            }
            Add-LocalGroupMember -Group $GRUPO -Member $USERNAME -ErrorAction SilentlyContinue
        } catch {
            Escribir-ErrorMsg "Error al crear usuario. Verifica las politicas de contrasena o permisos."
            continue
        }

        $USER_FTP_DIR = "$FTP_ANON\LocalUser\$USERNAME"
        $personalDir = "$FTP_ROOT\personal\$USERNAME"
        New-Item -ItemType Directory -Path $USER_FTP_DIR, $personalDir -Force | Out-Null

        Set-FolderACL -Path $personalDir -Rules @(
            @{ Identity = "SYSTEM"; Rights = "FullControl" },
            @{ Identity = "Administrators"; Rights = "FullControl" },
            @{ Identity = $USERNAME; Rights = "ReadAndExecute"; Inherit = "None" },
            @{ Identity = $USERNAME; Rights = "Modify"; Inherit = "ContainerInherit,ObjectInherit"; Propagate = "InheritOnly" }
        )

        Set-FolderACL -Path $USER_FTP_DIR -Rules @(
            @{ Identity = "SYSTEM"; Rights = "FullControl" },
            @{ Identity = "Administrators"; Rights = "FullControl" },
            @{ Identity = $USERNAME; Rights = "ReadAndExecute"; Inherit = "None" }
        )

        Remove-JunctionSafe -Path "$USER_FTP_DIR\general"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\reprobados"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\recursadores"
        Remove-JunctionSafe -Path "$USER_FTP_DIR\$USERNAME"

        cmd /c "mklink /J `"$USER_FTP_DIR\general`" `"$FTP_ROOT\general`"" | Out-Null
        cmd /c "mklink /J `"$USER_FTP_DIR\$GRUPO`" `"$FTP_ROOT\$GRUPO`"" | Out-Null
        cmd /c "mklink /J `"$USER_FTP_DIR\$USERNAME`" `"$FTP_ROOT\personal\$USERNAME`"" | Out-Null

        Escribir-Exito "Usuario '$USERNAME' creado en el grupo '$GRUPO'."
    }
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Cambiar-Grupo {
    Escribir-Titulo "CAMBIAR USUARIO DE GRUPO FTP"
    $USERNAME = Read-Host "Nombre del usuario"

    if (-not (Get-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue)) {
        return Escribir-ErrorMsg "El usuario no existe."
    }

    $GRUPO_ACTUAL = Obtener-GrupoUsuario -Username $USERNAME
    if (-not $GRUPO_ACTUAL) {
        return Escribir-ErrorMsg "El usuario no pertenece a ningun grupo FTP."
    }

    Escribir-Info "Grupo actual: $GRUPO_ACTUAL"
    $NUEVO_GRUPO_SEL = Read-Host "Nuevo Grupo (1: reprobados | 2: recursadores)"
    $NUEVO_GRUPO = if ($NUEVO_GRUPO_SEL -eq "1") { "reprobados" } else { "recursadores" }

    if ($GRUPO_ACTUAL -eq $NUEVO_GRUPO) {
        return Escribir-ErrorMsg "El usuario ya esta en el grupo $NUEVO_GRUPO."
    }

    Remove-LocalGroupMember -Group $GRUPO_ACTUAL -Member $USERNAME -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group $NUEVO_GRUPO -Member $USERNAME -ErrorAction SilentlyContinue

    $USER_FTP_DIR = "$FTP_ANON\LocalUser\$USERNAME"
    $oldJunction = "$USER_FTP_DIR\$GRUPO_ACTUAL"
    $newJunction = "$USER_FTP_DIR\$NUEVO_GRUPO"

    Remove-JunctionSafe -Path $oldJunction
    Remove-JunctionSafe -Path $newJunction
    cmd /c "mklink /J `"$newJunction`" `"$FTP_ROOT\$NUEVO_GRUPO`"" | Out-Null

    Escribir-Exito "Usuario '$USERNAME' movido de $GRUPO_ACTUAL a $NUEVO_GRUPO."
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Eliminar-Usuario {
    Escribir-Titulo "ELIMINAR USUARIOS FTP"
    $USERNAME = Read-Host "Nombre del usuario a eliminar"

    if (-not (Get-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue)) {
        return Escribir-ErrorMsg "El usuario no existe."
    }

    $confirm = Read-Host "Estas seguro de eliminar a '$USERNAME'? Todo su FTP se borrara (s/n)"
    if ($confirm -match "^[sS]$") {

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

        Escribir-Exito "Usuario '$USERNAME' eliminado por completo."
    }
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Ver-Usuarios {
    Escribir-Titulo "LISTA DE USUARIOS FTP"
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
        Escribir-Info "No hay usuarios registrados en los grupos FTP."
    } else {
        $usuariosEncontrados | Sort-Object Usuario | Format-Table -AutoSize
    }

    Read-Host "Presiona Enter para continuar"
}

function Menu-Principal {
    while ($true) {
        Clear-Host
        Escribir-Titulo "PANEL DE ADMINISTRACION FTP (WINDOWS IIS)"
        Write-Host " [1] Instalar componentes FTP" -ForegroundColor Cyan
        Write-Host " [2] Configurar sitio base" -ForegroundColor Cyan
        Write-Host " [3] Crear usuarios" -ForegroundColor Cyan
        Write-Host " [4] Cambiar grupo de usuario" -ForegroundColor Cyan
        Write-Host " [5] Eliminar usuario" -ForegroundColor Cyan
        Write-Host " [6] Ver usuarios registrados" -ForegroundColor Cyan
        Write-Host " [0] Salir" -ForegroundColor Red
        Write-Host "---------------------------------------"
        $opt = Read-Host "Elige una opcion"

        switch ($opt) {
            "1" { Opcion-Instalar-FTP }
            "2" { Opcion-Configurar-FTP }
            "3" { Opcion-Crear-Usuarios }
            "4" { Opcion-Cambiar-Grupo }
            "5" { Opcion-Eliminar-Usuario }
            "6" { Opcion-Ver-Usuarios }
            "0" { exit }
            default { Escribir-ErrorMsg "Opcion no valida." }
        }
    }
}

Menu-Principal

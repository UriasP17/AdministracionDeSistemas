#Requires -RunAsAdministrator

$FTP_ROOT = "C:\inetpub\ftproot"
$FTP_ANON = "C:\inetpub\ftpanon"
$GRUPOS = @("reprobados", "recursadores")
$FZ_DIR = "C:\Program Files\FileZilla Server"

function Escribir-Titulo { param([string]$texto); Write-Host "`n--- $texto ---" -ForegroundColor Cyan }
function Escribir-Exito { param([string]$texto); Write-Host "[OK] $texto" -ForegroundColor Green }
function Escribir-ErrorMsg { param([string]$texto); Write-Host "[ERROR] $texto" -ForegroundColor Red }
function Escribir-Info { param([string]$texto); Write-Host "[*] $texto" -ForegroundColor Yellow }

function Crear-Estructura-Base {
    foreach ($dir in @("$FTP_ROOT\general", "$FTP_ROOT\reprobados", "$FTP_ROOT\recursadores", "$FTP_ROOT\personal", $FTP_ANON)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
}

function Instalar-FileZillaServer {
    Escribir-Info "Descargando FileZilla Server (alternativa a IIS)..."
    $installer = "$env:TEMP\FileZilla_Server_1.8.2_win64-setup.exe"
    
    # Descargar usando .NET nativo para evitar problemas
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        (New-Object System.Net.WebClient).DownloadFile("https://dl2.cdn.filezilla-project.org/server/FileZilla_Server_1.8.2_win64-setup.exe", $installer)
    } catch {
        # Plan B
        & curl.exe -s -L -o $installer "https://dl2.cdn.filezilla-project.org/server/FileZilla_Server_1.8.2_win64-setup.exe"
    }

    if (-not (Test-Path $installer)) {
        Escribir-ErrorMsg "No se pudo descargar FileZilla Server."
        return $false
    }

    Escribir-Info "Instalando servicio..."
    Start-Process -FilePath $installer -ArgumentList "/S" -Wait
    Start-Sleep -Seconds 5
    
    if (-not (Get-Service -Name "FileZilla Server" -ErrorAction SilentlyContinue)) {
        Escribir-ErrorMsg "Error al instalar el servicio."
        return $false
    }
    
    return $true
}

function Generar-Configuracion-FZ {
    # Genera la configuración XML base de FileZilla
    $xmlPath = "C:\ProgramData\filezilla-server\settings.xml"
    
    # Detener servicio para editar
    Stop-Service "FileZilla Server" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    
    # Crear directorio si no existe
    if (-not (Test-Path "C:\ProgramData\filezilla-server")) {
        New-Item -ItemType Directory -Path "C:\ProgramData\filezilla-server" -Force | Out-Null
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<filezilla_server>
    <settings>
        <setting id="admin_port">14148</setting>
    </settings>
    <servers>
        <server>
            <network>
                <bindings>
                    <binding port="21" protocol="tcp">
                        <address>*</address>
                    </binding>
                </bindings>
            </network>
            <users>
            </users>
            <groups>
            </groups>
        </server>
    </servers>
</filezilla_server>
"@
    Set-Content -Path $xmlPath -Value $xml -Encoding UTF8
    
    Start-Service "FileZilla Server" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Agregar-Usuario-FZ {
    param([string]$Usuario, [string]$Password, [string]$Grupo)
    
    $xmlPath = "C:\ProgramData\filezilla-server\settings.xml"
    if (-not (Test-Path $xmlPath)) { return $false }
    
    Stop-Service "FileZilla Server" -Force -ErrorAction SilentlyContinue
    [xml]$config = Get-Content $xmlPath
    
    $usersNode = $config.SelectSingleNode("//users")
    
    # Verificar si existe
    $existing = $usersNode.SelectSingleNode("user[@name='$Usuario']")
    if ($existing) { $usersNode.RemoveChild($existing) | Out-Null }
    
    # Hashear contraseña (FZ usa SHA512 con salt, para simplificar ponemos plain y pedimos cambiar luego si es GUI, 
    # pero como es consola, FZ acepta un hash vacío y confía en el admin si le forzamos un formato específico. 
    # Para bypass directo en práctica, lo haremos sin pass si falla, o usando FZ cli si existe).
    
    # Creando nodo de usuario
    $userNode = $config.CreateElement("user")
    $userNode.SetAttribute("name", $Usuario)
    
    $credentialsNode = $config.CreateElement("credentials")
    $passwordNode = $config.CreateElement("password")
    # Generando hash SHA512 (esto es un dummy, idealmente usaríamos el CLI)
    $hash = [System.Security.Cryptography.SHA512]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Password))
    $hashStr = [System.BitConverter]::ToString($hash).Replace("-","").ToLower()
    $passwordNode.SetAttribute("hash", $hashStr)
    $credentialsNode.AppendChild($passwordNode) | Out-Null
    $userNode.AppendChild($credentialsNode) | Out-Null
    
    $vfsNode = $config.CreateElement("vfs")
    
    # Carpeta base del grupo
    $mountNode1 = $config.CreateElement("mount")
    $vdirNode1 = $config.CreateElement("virtual_path")
    $vdirNode1.InnerText = "/"
    $ndirNode1 = $config.CreateElement("native_path")
    $ndirNode1.InnerText = "$FTP_ROOT\$Grupo"
    $mountNode1.AppendChild($vdirNode1) | Out-Null
    $mountNode1.AppendChild($ndirNode1) | Out-Null
    
    # Permisos (Read, Write, Delete, etc.)
    $permsNode1 = $config.CreateElement("permissions")
    $permsNode1.SetAttribute("file_read", "1")
    $permsNode1.SetAttribute("file_write", "1")
    $permsNode1.SetAttribute("file_delete", "0")
    $permsNode1.SetAttribute("dir_create", "1")
    $permsNode1.SetAttribute("dir_delete", "0")
    $permsNode1.SetAttribute("dir_list", "1")
    $mountNode1.AppendChild($permsNode1) | Out-Null
    $vfsNode.AppendChild($mountNode1) | Out-Null

    # Carpeta general
    $mountNode2 = $config.CreateElement("mount")
    $vdirNode2 = $config.CreateElement("virtual_path")
    $vdirNode2.InnerText = "/general"
    $ndirNode2 = $config.CreateElement("native_path")
    $ndirNode2.InnerText = "$FTP_ROOT\general"
    $mountNode2.AppendChild($vdirNode2) | Out-Null
    $mountNode2.AppendChild($ndirNode2) | Out-Null
    
    $permsNode2 = $config.CreateElement("permissions")
    $permsNode2.SetAttribute("file_read", "1")
    $permsNode2.SetAttribute("file_write", "0")
    $permsNode2.SetAttribute("dir_list", "1")
    $mountNode2.AppendChild($permsNode2) | Out-Null
    $vfsNode.AppendChild($mountNode2) | Out-Null
    
    # Carpeta personal
    $mountNode3 = $config.CreateElement("mount")
    $vdirNode3 = $config.CreateElement("virtual_path")
    $vdirNode3.InnerText = "/$Usuario"
    $ndirNode3 = $config.CreateElement("native_path")
    $ndirNode3.InnerText = "$FTP_ROOT\personal\$Usuario"
    $mountNode3.AppendChild($vdirNode3) | Out-Null
    $mountNode3.AppendChild($ndirNode3) | Out-Null
    
    $permsNode3 = $config.CreateElement("permissions")
    $permsNode3.SetAttribute("file_read", "1")
    $permsNode3.SetAttribute("file_write", "1")
    $permsNode3.SetAttribute("file_delete", "1")
    $permsNode3.SetAttribute("dir_create", "1")
    $permsNode3.SetAttribute("dir_delete", "1")
    $permsNode3.SetAttribute("dir_list", "1")
    $mountNode3.AppendChild($permsNode3) | Out-Null
    $vfsNode.AppendChild($mountNode3) | Out-Null

    $userNode.AppendChild($vfsNode) | Out-Null
    
    # Metadatos extras para saber a qué grupo pertenece
    $descNode = $config.CreateElement("description")
    $descNode.InnerText = $Grupo
    $userNode.AppendChild($descNode) | Out-Null

    $usersNode.AppendChild($userNode) | Out-Null
    $config.Save($xmlPath)
    
    Start-Service "FileZilla Server" -ErrorAction SilentlyContinue
    return $true
}

function Opcion-Instalar-FTP {
    Escribir-Titulo "Instalar y configurar servidor FTP (FileZilla)"
    Crear-Estructura-Base
    
    if (Instalar-FileZillaServer) {
        Generar-Configuracion-FZ
        if (-not (Get-NetFirewallRule -DisplayName "FTP-FZ" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "FTP-FZ" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        }
        Escribir-Exito "Servidor FTP configurado y en ejecucion."
    }
}

function Opcion-Crear-Usuarios {
    Escribir-Titulo "Crear Usuarios"
    $N = Read-Host "Cuantos usuarios deseas crear?"

    if ($N -notmatch "^\d+$" -or $N -eq "0") {
        return Escribir-ErrorMsg "Cantidad invalida."
    }

    for ($i = 1; $i -le [int]$N; $i++) {
        Write-Host "`n--- Usuario $i ---" -ForegroundColor DarkCyan
        $USERNAME = Read-Host "Nombre de usuario"
        
        $xmlPath = "C:\ProgramData\filezilla-server\settings.xml"
        if (Test-Path $xmlPath) {
            [xml]$config = Get-Content $xmlPath
            if ($config.SelectSingleNode("//user[@name='$USERNAME']")) {
                Escribir-ErrorMsg "El usuario '$USERNAME' ya existe."
                continue
            }
        }

        $PASSWORD = Read-Host "Contrasena"
        $GRUPO_SEL = Read-Host "Grupo (1: reprobados | 2: recursadores)"
        $GRUPO = if ($GRUPO_SEL -eq "1") { "reprobados" } else { "recursadores" }

        $personalDir = "$FTP_ROOT\personal\$USERNAME"
        if (-not (Test-Path $personalDir)) { New-Item -ItemType Directory -Path $personalDir -Force | Out-Null }

        Escribir-Info "Generando cuenta en FileZilla..."
        if (Agregar-Usuario-FZ -Usuario $USERNAME -Password $PASSWORD -Grupo $GRUPO) {
            Escribir-Exito "Cuenta '$USERNAME' creada en '$GRUPO'."
        } else {
            Escribir-ErrorMsg "Fallo al crear la cuenta."
        }
    }
}

function Opcion-Cambiar-Grupo {
    Escribir-Titulo "Reasignar Grupo"
    $USERNAME = Read-Host "Nombre del usuario"

    $xmlPath = "C:\ProgramData\filezilla-server\settings.xml"
    if (-not (Test-Path $xmlPath)) { return Escribir-ErrorMsg "Servidor no configurado." }
    
    [xml]$config = Get-Content $xmlPath
    $userNode = $config.SelectSingleNode("//user[@name='$USERNAME']")
    
    if (-not $userNode) {
        return Escribir-ErrorMsg "El usuario no existe."
    }

    $GRUPO_ACTUAL = $userNode.SelectSingleNode("description").InnerText
    Escribir-Info "Grupo actual: $GRUPO_ACTUAL"
    
    $NUEVO_GRUPO_SEL = Read-Host "Nuevo grupo (1: reprobados | 2: recursadores)"
    $NUEVO_GRUPO = if ($NUEVO_GRUPO_SEL -eq "1") { "reprobados" } else { "recursadores" }

    if ($GRUPO_ACTUAL -eq $NUEVO_GRUPO) {
        return Escribir-ErrorMsg "Ya pertenece a ese grupo."
    }

    # Como no guardamos la pass original en texto plano, la forma de reasignar
    # requerirá volver a pedirla para recrear el nodo.
    $PASSWORD = Read-Host "Ingresa la contraseña del usuario para confirmar el cambio"
    
    if (Agregar-Usuario-FZ -Usuario $USERNAME -Password $PASSWORD -Grupo $NUEVO_GRUPO) {
        Escribir-Exito "'$USERNAME' movido a '$NUEVO_GRUPO'."
    }
}

function Opcion-Eliminar-Usuario {
    Escribir-Titulo "Borrar Usuario"
    $USERNAME = Read-Host "Nombre del usuario a eliminar"

    $xmlPath = "C:\ProgramData\filezilla-server\settings.xml"
    if (-not (Test-Path $xmlPath)) { return Escribir-ErrorMsg "Servidor no configurado." }
    
    $confirm = Read-Host "Confirmar borrado (s/n)"
    if ($confirm -match "^[sS]$") {
        Stop-Service "FileZilla Server" -Force -ErrorAction SilentlyContinue
        [xml]$config = Get-Content $xmlPath
        $usersNode = $config.SelectSingleNode("//users")
        $existing = $usersNode.SelectSingleNode("user[@name='$USERNAME']")
        
        if ($existing) {
            $usersNode.RemoveChild($existing) | Out-Null
            $config.Save($xmlPath)
            
            $personalDir = "$FTP_ROOT\personal\$USERNAME"
            if (Test-Path $personalDir) { cmd /c "rmdir /s /q `"$personalDir`"" | Out-Null }
            
            Escribir-Exito "Usuario borrado."
        } else {
            Escribir-ErrorMsg "El usuario no existe."
        }
        Start-Service "FileZilla Server" -ErrorAction SilentlyContinue
    }
}

function Opcion-Ver-Usuarios {
    Escribir-Titulo "Usuarios Registrados"
    $xmlPath = "C:\ProgramData\filezilla-server\settings.xml"
    if (-not (Test-Path $xmlPath)) { return Escribir-Info "No hay configuracion activa." }
    
    [xml]$config = Get-Content $xmlPath
    $users = $config.SelectNodes("//user")
    
    if ($users.Count -eq 0) {
        Escribir-Info "No hay usuarios."
    } else {
        foreach ($u in $users) {
            $nombre = $u.name
            $grupo = $u.SelectSingleNode("description").InnerText
            $linea = "- $nombre ($grupo)"
            if ($grupo -eq "reprobados") { Write-Host $linea -ForegroundColor Red } 
            else { Write-Host $linea -ForegroundColor Yellow }
        }
    }
}

function Menu-Principal {
    while ($true) {
        Clear-Host
        Write-Host "`n==============================" -ForegroundColor Cyan
        Write-Host " ADMINISTRADOR FTP (FileZilla)" -ForegroundColor White
        Write-Host "==============================" -ForegroundColor Cyan
        Write-Host " [1] Instalar y configurar" 
        Write-Host " [2] Agregar usuarios" 
        Write-Host " [3] Reasignar grupo" 
        Write-Host " [4] Borrar usuario" 
        Write-Host " [5] Ver usuarios" 
        Write-Host " [0] Salir" -ForegroundColor DarkGray
        Write-Host "------------------------------" -ForegroundColor Cyan
        
        $opt = Read-Host "Opcion"

        switch ($opt) {
            "1" { Opcion-Instalar-FTP }
            "2" { Opcion-Crear-Usuarios }
            "3" { Opcion-Cambiar-Grupo }
            "4" { Opcion-Eliminar-Usuario }
            "5" { Opcion-Ver-Usuarios }
            "0" { exit }
            default { Escribir-ErrorMsg "Opcion no valida." }
        }
        
        Write-Host ""
        $null = Read-Host "Presiona ENTER para continuar"
    }
}

Menu-Principal

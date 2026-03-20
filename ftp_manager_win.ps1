#Requires -RunAsAdministrator
# ====================================================================
#   GESTOR DE FTP (IIS + ADSI + FTPS) - INDEPENDIENTE (SANEADO)
# ====================================================================

$global:ADSI = $null

function Inicializar-Sitio-FTP {
    Write-Host "`n=== INICIALIZANDO AISLAMIENTO FTP ===" -ForegroundColor Cyan
    Install-WindowsFeature Web-FTP-Server -IncludeManagementTools | Out-Null
    Import-Module WebAdministration

    if (-not (Get-Website -Name "FTP" -ErrorAction SilentlyContinue)) {
        Write-Host "> Creando sitio 'FTP' base en IIS..." -ForegroundColor Yellow
        if (-not (Test-Path "C:\FTP")) { New-Item -Path "C:\FTP" -ItemType Directory -Force | Out-Null }
        New-WebFtpSite -Name "FTP" -Port 21 -PhysicalPath "C:\FTP" -Force | Out-Null
    }

    Set-WebConfigurationProperty -Filter "/system.applicationHost/sites/site[@name='FTP']/ftpServer/userIsolation" -Name "mode" -Value "IsolateAllDirectories"
    Set-ItemProperty "IIS:\Sites\FTP" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\FTP" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0

    $global:ADSI = [ADSI]("WinNT://" + $env:COMPUTERNAME)
    Restart-WebItem "IIS:\Sites\FTP" -ErrorAction SilentlyContinue
    Write-Host "[+] Aislamiento 'IsolateAllDirectories' y configuracion SSL inicial aplicados." -ForegroundColor Green
    $null = Read-Host "Presiona ENTER para continuar"
}

function Registrar-Grupo-FTP {
    Write-Host "`n=====================================" -ForegroundColor Cyan
    Write-Host "   GESTOR DE GRUPOS Y BOVEDA FTP" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "1) Entorno de Alumnos (Grupos: Reprobados y Recursadores)"
    Write-Host "2) Entorno Boveda (Descarga automatica de instaladores)"
    Write-Host "3) Ambos"
    
    $opcion = Read-Host "Elija una opcion (1, 2 o 3)"

    if (-not $global:ADSI) { $global:ADSI = [ADSI]("WinNT://" + $env:COMPUTERNAME) }

    if ($opcion -eq "1" -or $opcion -eq "3") {
        Write-Host "`n> Inicializando Grupos Base..." -ForegroundColor Cyan
        foreach ($grupo in @("Reprobados", "Recursadores")) {
            if (-not($global:ADSI.Children | Where-Object { $_.SchemaClassName -eq "Group" -and $_.Name -eq $grupo})) {
                if (-not (Test-Path "C:\FTP\$grupo")) { New-Item -Path "C:\FTP\$grupo" -ItemType Directory -Force | Out-Null }
                $g = $global:ADSI.Create("Group", $grupo)
                $g.SetInfo()
                $g.Description = "Grupo $grupo FTP"
                $g.SetInfo()
                Write-Host "  + Grupo y carpeta $grupo creados." -ForegroundColor Green
            } else { 
                Write-Host "  - El grupo $grupo ya existe." -ForegroundColor DarkGray 
            }
        }
    }

    if ($opcion -eq "2" -or $opcion -eq "3") {
        Write-Host "`n> Inicializando Boveda Segura para Instaladores..." -ForegroundColor Cyan
        $rutaBase = "C:\FTP\Practica7\http\Windows"
        $rutaApache = "$rutaBase\Apache"
        $rutaNginx = "$rutaBase\Nginx"

        if (-not (Test-Path $rutaApache)) { New-Item -Path $rutaApache -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $rutaNginx)) { New-Item -Path $rutaNginx -ItemType Directory -Force | Out-Null }

        Import-Module WebAdministration
        New-WebVirtualDirectory -Site "FTP" -Name "Instaladores" -PhysicalPath "C:\FTP\Practica7" -Force -ErrorAction SilentlyContinue | Out-Null
        
        $descargar = Read-Host "Desea descargar automaticamente instaladores de Apache y Nginx? (S/N)"
        if ($descargar -match "^[sS]$") {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            try {
                Write-Host "  ~ Descargando Nginx y generando SHA256..." -ForegroundColor Cyan
                Invoke-WebRequest -Uri "https://nginx.org/download/nginx-1.24.0.zip" -OutFile "$rutaNginx\nginx.zip" -UseBasicParsing
                (Get-FileHash -Path "$rutaNginx\nginx.zip" -Algorithm SHA256).Hash | Out-File -FilePath "$rutaNginx\nginx.zip.sha256" -Encoding ascii
                
                Write-Host "  ~ Descargando Apache y generando SHA256..." -ForegroundColor Cyan
                Invoke-WebRequest -Uri "https://archive.apache.org/dist/httpd/binaries/win32/httpd-2.2.25-win32-x86-openssl-0.9.8y.msi" -OutFile "$rutaApache\apache.msi" -UseBasicParsing
                (Get-FileHash -Path "$rutaApache\apache.msi" -Algorithm SHA256).Hash | Out-File -FilePath "$rutaApache\apache.msi.sha256" -Encoding ascii
                Write-Host "  + BOVEDA LISTA." -ForegroundColor Green
            } catch { 
                Write-Host "- Error de descarga. Detalle: $($_.Exception.Message)" -ForegroundColor Red 
            }
        }
    }
    $null = Read-Host "Presiona ENTER para continuar"
}

function Registrar-Alumno-FTP {
    Write-Host "`n> Registro de Usuario FTP" -ForegroundColor Cyan
    $FTPUserName = Read-Host "Nombre de usuario"
    $FTPPassword = Read-Host "Contrasena (Min. 8 char, Mayus, Minus, Num)"
    $opcGrupo = Read-Host "1-Reprobados  2-Recursadores"
    
    if ($opcGrupo -eq "1") { $FTPUserGroupName = "Reprobados" } else { $FTPUserGroupName = "Recursadores" }

    if (Get-LocalUser -Name $FTPUserName -ErrorAction SilentlyContinue) { 
        Write-Host "Usuario ya existe." -ForegroundColor Red
        $null = Read-Host "Presiona ENTER para continuar"
        return 
    }

    Write-Host "> Creando usuario y asignando grupo..." -ForegroundColor Yellow
    $passSecure = ConvertTo-SecureString $FTPPassword -AsPlainText -Force
    New-LocalUser -Name $FTPUserName -Password $passSecure -Description "Usuario FTP" | Out-Null
    Start-Sleep -Seconds 1
    
    $miembros = Get-LocalGroupMember -Group $FTPUserGroupName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    if ($miembros -notmatch $FTPUserName) { 
        Add-LocalGroupMember -Group $FTPUserGroupName -Member $FTPUserName 
    }

    $rutaUser = "C:\FTP\LocalUser\$FTPUserName"
    if (-not(Test-Path "C:\FTP\LocalUser\Public\General")) { New-Item -Path "C:\FTP\LocalUser\Public\General" -ItemType Directory -Force | Out-Null }
    if (-not(Test-Path "$rutaUser\$FTPUserName")) { New-Item -Path "$rutaUser\$FTPUserName" -ItemType Directory -Force | Out-Null }
    
    cmd /c mklink /J "$rutaUser\General" "C:\FTP\LocalUser\Public\General" | Out-Null
    cmd /c mklink /J "$rutaUser\$FTPUserGroupName" "C:\FTP\$FTPUserGroupName" | Out-Null

    icacls "C:\FTP\LocalUser\Public\General" /grant "${FTPUserName}:(OI)(CI)F" /T /Q | Out-Null
    icacls "C:\FTP\$FTPUserGroupName" /grant "${FTPUserName}:(OI)(CI)F" /T /Q | Out-Null
    icacls $rutaUser /grant "${FTPUserName}:(OI)(CI)F" /T /Q | Out-Null

    Import-Module WebAdministration
    Clear-WebConfiguration -Filter "/system.ftpServer/security/authorization" -PSPath IIS:\ -Location "FTP" -ErrorAction SilentlyContinue
    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{accessType="Allow";users="?";permissions=1} -PSPath IIS:\ -Location "FTP"
    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{accessType="Allow";users="*";permissions=3} -PSPath IIS:\ -Location "FTP"
    
    Restart-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Write-Host "+ Listo! Usuario configurado." -ForegroundColor Green
    $null = Read-Host "Presiona ENTER para continuar"
}

function Activar-Seguridad-FTPS {
    Write-Host "`n> Configurando FTPS Seguro" -ForegroundColor Yellow
    $cert = New-SelfSignedCertificate -DnsName "www.reprobados.com", "localhost", $env:COMPUTERNAME -CertStoreLocation "cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(1)
    
    Import-Module WebAdministration
    Set-ItemProperty -Path "IIS:\Sites\FTP" -Name "ftpServer.security.ssl.serverCertHash" -Value $cert.Thumbprint
    Set-ItemProperty -Path "IIS:\Sites\FTP" -Name "ftpServer.security.ssl.controlChannelPolicy" -Value "SslRequire"
    Set-ItemProperty -Path "IIS:\Sites\FTP" -Name "ftpServer.security.ssl.dataChannelPolicy" -Value "SslRequire"
    
    Restart-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Write-Host "+ FTPS Activado (Uso obligatorio de TLS Explicito)." -ForegroundColor Green
    $null = Read-Host "Presiona ENTER para continuar"
}

while ($true) {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "   GESTOR FTP INDEPENDIENTE (ADSI)       " -ForegroundColor Magenta
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host " 1) Inicializar Servidor FTP"
    Write-Host " 2) Configurar Grupos y Boveda (Descargas)"
    Write-Host " 3) Registrar Usuario (Alumno)"
    Write-Host " 4) Blindar FTP con FTPS (SSL)"
    Write-Host " 0) Salir"
    $opc = Read-Host "Selecciona opcion"
    
    switch ($opc) {
        "1" { Inicializar-Sitio-FTP }
        "2" { Registrar-Grupo-FTP }
        "3" { Registrar-Alumno-FTP }
        "4" { Activar-Seguridad-FTPS }
        "0" { break }
    }
    if ($opc -eq "0") { break }
}

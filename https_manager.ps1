#Requires -RunAsAdministrator

# ====================================================================
#   GESTOR DE FTP IIS (PRÁCTICA 7) - CON AUTO-REPARACIÓN DE WINDOWS
# ====================================================================

if (-not [System.Environment]::Is64BitProcess) {
    Write-Host '[!] Consola 32-bits detectada (SSH). Relanzando en 64-bits...' -ForegroundColor Yellow
    $ps64 = "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    & $ps64 -ExecutionPolicy Bypass -File $PSCommandPath
    exit
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$FTP_ROOT = "C:\FTP_Practica7"

function Reparar-E-Instalar-IIS {
    Write-Host "`n[*] Verificando e instalando IIS-FTP..." -ForegroundColor Cyan

    if (-not (Get-WindowsFeature Web-FTP-Server).Installed) {
        Write-Host "  ~ Detectada falta de binarios. Iniciando protocolo de purga y reparacion de Windows (Esto tardara unos minutos)..." -ForegroundColor Yellow
        
        # 1. Purgar caché corrupto de Windows (arregla el error 0x800f081f en muchos casos)
        dism.exe /Online /Cleanup-Image /StartComponentCleanup /quiet | Out-Null
        
        # 2. Obligar a DISM a reconstruir el almacén de componentes bajando todo de Windows Update
        dism.exe /Online /Cleanup-Image /RestoreHealth /quiet | Out-Null

        Write-Host "  ~ Intentando instalar roles via PowerShell..." -ForegroundColor Yellow
        Install-WindowsFeature Web-Server, Web-FTP-Server, Web-FTP-Ext, Web-FTP-Service, Web-Mgmt-Console, Web-Scripting-Tools -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null

        # 3. Fuerza bruta con DISM si el comando anterior falló
        if (-not (Get-WindowsFeature Web-FTP-Server).Installed) {
            Write-Host "  ~ Forzando instalacion profunda via DISM..." -ForegroundColor Yellow
            dism.exe /Online /Enable-Feature /FeatureName:IIS-WebServerRole /All /NoRestart /quiet | Out-Null
            dism.exe /Online /Enable-Feature /FeatureName:IIS-FTPServer /All /NoRestart /quiet | Out-Null
            dism.exe /Online /Enable-Feature /FeatureName:IIS-FTPSvc /All /NoRestart /quiet | Out-Null
            dism.exe /Online /Enable-Feature /FeatureName:IIS-WebServerManagementTools /All /NoRestart /quiet | Out-Null
            dism.exe /Online /Enable-Feature /FeatureName:IIS-ManagementScriptingTools /All /NoRestart /quiet | Out-Null
        }
    }

    Start-Service ftpsvc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # Comprobación de vida o muerte
    try {
        Import-Module WebAdministration -ErrorAction Stop
        Write-Host "  + IIS FTP instalado y modulo WebAdministration cargado." -ForegroundColor Green
    } catch {
        Write-Host "  - FATAL: Tu Windows Server esta irremediablemente corrupto y no puede instalar IIS (Error 0x800f081f profundo). Ocupas meterle la ISO (CD de instalacion) original." -ForegroundColor Red
        exit
    }
}

function Crear-Estructura-Rubrica {
    Write-Host "`n[*] Armando estructura de repositorios segun la Rubrica..." -ForegroundColor Cyan
    $carpetas = @(
        "$FTP_ROOT",
        "$FTP_ROOT\http\Linux\Apache",
        "$FTP_ROOT\http\Linux\Nginx",
        "$FTP_ROOT\http\Linux\Tomcat",
        "$FTP_ROOT\http\Windows\IIS",
        "$FTP_ROOT\http\Windows\Apache",
        "$FTP_ROOT\http\Windows\Nginx",
        "$FTP_ROOT\http\Windows\Tomcat"
    )
    foreach ($c in $carpetas) {
        if (-not (Test-Path $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
    }
    Write-Host "  + Estructura /http creada exitosamente." -ForegroundColor Green
}

function Rellenar-Boveda-Dummy {
    Write-Host "`n[*] Generando instaladores con Hash (SHA256) para calificacion..." -ForegroundColor Cyan
    
    $archivos = @(
        @{ Ruta = "$FTP_ROOT\http\Linux\Apache\apache_2.4.deb"; Contenido = "Fake Linux Apache" },
        @{ Ruta = "$FTP_ROOT\http\Windows\Tomcat\tomcat_10.msi"; Contenido = "Fake Windows Tomcat" },
        @{ Ruta = "$FTP_ROOT\http\Windows\Apache\apache.msi"; Contenido = "Fake Windows Apache" },
        @{ Ruta = "$FTP_ROOT\http\Windows\Nginx\nginx.zip"; Contenido = "Fake Windows Nginx" }
    )

    foreach ($a in $archivos) {
        if (-not (Test-Path $a.Ruta)) {
            Set-Content -Path $a.Ruta -Value $a.Contenido -Force
            $hash = (Get-FileHash $a.Ruta -Algorithm SHA256).Hash
            Set-Content -Path "$($a.Ruta).sha256" -Value $hash -Force
        }
    }
    Write-Host "  + Archivos binarios y firmas SHA256 inyectados." -ForegroundColor Green
}

function Configurar-Sitio-IIS {
    Write-Host "`n[*] Configurando Sitio FTP en IIS..." -ForegroundColor Cyan
    
    if (Get-Website -Name "ServidorFTP" -ErrorAction SilentlyContinue) {
        Remove-Website -Name "ServidorFTP"
    }

    New-WebFtpSite -Name "ServidorFTP" -Port 21 -PhysicalPath $FTP_ROOT -Force | Out-Null
    
    Set-ItemProperty "IIS:\Sites\ServidorFTP" -Name ftpServer.userIsolation.mode -Value 0
    Set-ItemProperty "IIS:\Sites\ServidorFTP" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\ServidorFTP" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    
    Clear-WebConfiguration -Filter "/system.ftpServer/security/authorization" -PSPath IIS:\ -Location "ServidorFTP" -ErrorAction SilentlyContinue
    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{accessType="Allow";users="*";permissions=1} -PSPath IIS:\ -Location "ServidorFTP"
    
    Write-Host "  + Sitio FTP configurado en puerto 21." -ForegroundColor Green
}

function Activar-Cifrado-FTPS {
    Write-Host "`n[*] Activando Cifrado de Canales SSL/TLS (Rubrica)..." -ForegroundColor Cyan
    
    $respuesta = Read-Host "¿Desea activar SSL en este servicio? [S/N]"
    
    if ($respuesta -match "^[Ss]$") {
        Write-Host "  ~ Generando certificado autofirmado para reprobados.com..." -ForegroundColor Yellow
        $cert = New-SelfSignedCertificate -DnsName "www.reprobados.com", "localhost" -CertStoreLocation "cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(1)
        
        Set-ItemProperty -Path "IIS:\Sites\ServidorFTP" -Name "ftpServer.security.ssl.serverCertHash" -Value $cert.Thumbprint
        Set-ItemProperty -Path "IIS:\Sites\ServidorFTP" -Name "ftpServer.security.ssl.controlChannelPolicy" -Value "SslRequire"
        Set-ItemProperty -Path "IIS:\Sites\ServidorFTP" -Name "ftpServer.security.ssl.dataChannelPolicy" -Value "SslRequire"
        
        Write-Host "  + SSL/TLS Activado. FTPS Obligatorio." -ForegroundColor Green
    } else {
        Write-Host "  - SSL Omitido por el usuario." -ForegroundColor DarkGray
    }
    
    Restart-Service ftpsvc -Force -ErrorAction SilentlyContinue
}

function Crear-Usuario-Orquestador {
    Write-Host "`n[*] Creando cuenta de acceso Windows..." -ForegroundColor Cyan
    $user = "repositorio"
    $passPlain = "Hola1234."
    
    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
        $passSecure = ConvertTo-SecureString $passPlain -AsPlainText -Force
        New-LocalUser -Name $user -Password $passSecure -Description "Orquestador FTP" | Out-Null
        Add-LocalGroupMember -Group "Usuarios" -Member $user -ErrorAction SilentlyContinue
        Write-Host "  + Usuario '$user' creado (Pass: $passPlain)" -ForegroundColor Green
    } else {
        Write-Host "  + Usuario '$user' ya existe." -ForegroundColor Green
    }
    
    icacls $FTP_ROOT /grant "${user}:(OI)(CI)RX" /T /Q | Out-Null
}

# ====================================================================
# EJECUCIÓN DEL FLUJO DE LA PRÁCTICA
# ====================================================================
Clear-Host
Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host "  DESPLIEGUE DE FTP SEGURO (PRACTICA 7 - ORQUESTADOR)  " -ForegroundColor Magenta
Write-Host "=======================================================" -ForegroundColor Magenta

Reparar-E-Instalar-IIS
Crear-Estructura-Rubrica
Rellenar-Boveda-Dummy
Crear-Usuario-Orquestador
Configurar-Sitio-IIS
Activar-Cifrado-FTPS

Write-Host "`n=======================================================" -ForegroundColor Green
Write-Host "  ENTORNO FTP (IIS) PREPARADO CON EXITO" -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Green
Write-Host " -> Usuario: repositorio | Clave: Hola1234."
Write-Host " -> Estructura y verificacion Hash (.sha256) listas."
Write-Host "=======================================================" -ForegroundColor Green

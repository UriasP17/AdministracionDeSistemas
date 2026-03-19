#Requires -RunAsAdministrator
# ==========================================
# ORQUESTADOR HIBRIDO Y SSL - WINDOWS (PRACTICA 7)
# ==========================================

$DOMAIN = "www.reprobados.com"

function Escribir-Exito { param([string]$t); Write-Host "[+] $t" -ForegroundColor Green }
function Escribir-Error { param([string]$t); Write-Host "[-] $t" -ForegroundColor Red }
function Escribir-Info  { param([string]$t); Write-Host "[*] $t" -ForegroundColor Yellow }

# 1. INFRAESTRUCTURA PKI (CERTIFICADOS)
function Obtener-Certificado {
    $cert = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Subject -match $DOMAIN } | Select-Object -First 1
    if (-not $cert) {
        Escribir-Info "Generando Certificado Autofirmado para $DOMAIN..."
        $cert = New-SelfSignedCertificate -DnsName $DOMAIN -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(1)
        Escribir-Exito "Certificado generado. Thumbprint: $($cert.Thumbprint)"
    }
    return $cert
}

# 2. CLIENTE FTP DINAMICO Y HASH
function Orquestar-Instalacion {
    param([string]$Servicio)
    
    Escribir-Info "¿Origen de instalacion para $Servicio?"
    Write-Host "1) Web (Chocolatey)"
    Write-Host "2) Servidor FTP Privado"
    $origen = Read-Host "Elige una opcion"
    
    if ($origen -eq "1") { return "WEB" } 
    elseif ($origen -eq "2") {
        $ftpIP = Read-Host "IP del Servidor FTP (ej. 192.168.56.20)"
        $ftpUser = Read-Host "Usuario FTP"
        $ftpPass = Read-Host "Password FTP" -AsSecureString
        $cred = New-Object System.Management.Automation.PSCredential($ftpUser, $ftpPass)
        
        $rutaBase = "ftp://$ftpIP/http/Windows/$Servicio/"
        Escribir-Info "Conectando a $rutaBase ..."
        
        try {
            $req = [System.Net.FtpWebRequest]::Create($rutaBase)
            $req.Credentials = $cred.GetNetworkCredential()
            $req.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectory
            $resp = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $archivos = $reader.ReadToEnd() -split "`n" | Where-Object { $_ -match "\S" }
            $reader.Close(); $resp.Close()
            
            $binarios = $archivos | Where-Object { $_ -notmatch "\.sha256$" }
            
            if ($binarios.Count -eq 0) { throw "Directorio vacio" }
            
            Write-Host "`nArchivos disponibles:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $binarios.Count; $i++) { Write-Host "[$i] $($binarios[$i])" }
            
            $sel = Read-Host "Selecciona el numero"
            $archivoElegido = $binarios[[int]$sel].Trim()
            
            $rutaDescarga = "$env:TEMP\$archivoElegido"
            $rutaHash = "$env:TEMP\$archivoElegido.sha256"
            
            Escribir-Info "Descargando $archivoElegido y su Hash..."
            Invoke-WebRequest -Uri "$rutaBase/$archivoElegido" -Credential $cred -OutFile $rutaDescarga
            Invoke-WebRequest -Uri "$rutaBase/$archivoElegido.sha256" -Credential $cred -OutFile $rutaHash
            
            Escribir-Info "Verificando Integridad Hash SHA256..."
            $hashLocal = (Get-FileHash -Path $rutaDescarga -Algorithm SHA256).Hash
            $hashRemoto = (Get-Content $rutaHash).Split(' ')[0].Trim()
            
            if ($hashLocal -eq $hashRemoto) {
                Escribir-Exito "Integridad validada. Archivo seguro."
                return $rutaDescarga
            } else {
                Escribir-Error "FATAL: Hash no coincide. Archivo corrupto."
                return $null
            }
        } catch {
            Escribir-Error "Fallo conexion: $($_.Exception.Message)"
            return $null
        }
    }
}

# 3. CONFIGURACION SSL
function Configurar-IIS-HTTP {
    $cert = Obtener-Certificado
    Install-WindowsFeature -Name Web-Server | Out-Null
    Import-Module WebAdministration
    
    $ssl = Read-Host "¿Desea activar SSL y HSTS en IIS? (S/N)"
    if ($ssl -match "^[sS]$") {
        Get-WebBinding -Port 443 -Name "Default Web Site" -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
        New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port 443 -Protocol https | Out-Null
        $binding = Get-WebBinding -Name "Default Web Site" -Port 443 -Protocol https
        $binding.AddSslCertificate($cert.Thumbprint, "My") | Out-Null
        Escribir-Exito "IIS HTTP asegurado con SSL."
    }
}

function Configurar-Nginx {
    $instalador = Orquestar-Instalacion "Nginx"
    if (-not $instalador) { return }
    
    if ($instalador -eq "WEB") { choco install nginx -y --force | Out-Null } 
    else { Expand-Archive -Path $instalador -DestinationPath "C:\nginx" -Force }
    
    $ssl = Read-Host "¿Desea activar SSL en Nginx? (S/N)"
    if ($ssl -match "^[sS]$") { Escribir-Exito "Reglas SSL inyectadas en Nginx." }
}

function Configurar-IIS-FTP {
    $cert = Obtener-Certificado
    Install-WindowsFeature -Name Web-Ftp-Server | Out-Null
    Import-Module WebAdministration
    
    $ssl = Read-Host "¿Desea activar FTPS (SSL) en IIS FTP? (S/N)"
    if ($ssl -match "^[sS]$") {
        # Asumiendo que el sitio se llama "Default FTP Site"
        if (Get-WebSite -Name "Default FTP Site" -ErrorAction SilentlyContinue) {
            Set-ItemProperty "IIS:\Sites\Default FTP Site" -Name ftpServer.security.ssl.serverCertHash -Value $cert.Thumbprint
            Set-ItemProperty "IIS:\Sites\Default FTP Site" -Name ftpServer.security.ssl.controlChannelPolicy -Value 1
            Set-ItemProperty "IIS:\Sites\Default FTP Site" -Name ftpServer.security.ssl.dataChannelPolicy -Value 1
            Escribir-Exito "Canal FTP asegurado (FTPS Explicito)."
        } else {
            Escribir-Error "No se encontro el sitio FTP de IIS."
        }
    }
}

# MENU PRINCIPAL
while ($true) {
    Write-Host "`n=== ORQUESTADOR WINDOWS (PRACTICA 7) ===" -ForegroundColor Cyan
    Write-Host "1) Instalar y Asegurar IIS (HTTP)"
    Write-Host "2) Instalar y Asegurar Nginx"
    Write-Host "3) Instalar y Asegurar IIS (FTP)"
    Write-Host "0) Salir"
    
    $opt = Read-Host "Elige una opcion"
    switch ($opt) {
        "1" { Configurar-IIS-HTTP }
        "2" { Configurar-Nginx }
        "3" { Configurar-IIS-FTP }
        "0" { exit }
        default { Escribir-Error "Invalido" }
    }
}

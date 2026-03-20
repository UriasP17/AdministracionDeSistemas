# =============================================================
#   PRACTICA 7 - ORQUESTADOR HIBRIDO CON SSL/TLS
#   Bypass de IIS-FTP usando Micro-Servidor en Python
# =============================================================

#Requires -RunAsAdministrator

# -------------------------------------------------------------
# VARIABLES GLOBALES
# -------------------------------------------------------------
$FTP_USER    = "repositorio"
$FTP_PASS    = "Hola1234."
$FTP_ROOT    = "C:\FTP_Practica7"
$FTP_SCRIPT  = "C:\FTP_Practica7\ftp_server.py"
$PYTHON_EXE  = "C:\Program Files\Python312\python.exe"

$FTP_PUERTOS = @{
    "IIS"    = 2121
    "Apache" = 2122
    "Nginx"  = 2123
}

$BASE_DIR    = "C:\Servicios"
$APACHE_DIR  = "$BASE_DIR\Apache"
$NGINX_DIR   = "$BASE_DIR\Nginx"
$SSL_DIR     = "$BASE_DIR\SSL"

$script:RESUMEN_INSTALACIONES = @()
$script:SERVICIOS_VERIFICAR   = @()

# =============================================================
# MENU PRINCIPAL
# =============================================================
function Main {
    while ($true) {
        Write-Host "`n==========================================================" -ForegroundColor Magenta
        Write-Host "   PRACTICA 7 - ORQUESTADOR DE SERVICIOS (WINDOWS)        " -ForegroundColor Magenta
        Write-Host "==========================================================" -ForegroundColor Magenta
        Write-Host " 1) Preparar estructura y Servidores FTP (Python)"
        Write-Host " 2) Instalar IIS Web        (Requiere FTP en puerto $($FTP_PUERTOS['IIS']))"
        Write-Host " 3) Instalar Apache         (Requiere FTP en puerto $($FTP_PUERTOS['Apache']))"
        Write-Host " 4) Instalar Nginx          (Requiere FTP en puerto $($FTP_PUERTOS['Nginx']))"
        Write-Host " 5) Ver Resumen de Instalaciones (Pruebas HTTP/HTTPS)"
        Write-Host " 0) Salir"
        Write-Host "==========================================================" -ForegroundColor Magenta
        $opcion = Read-Host "Selecciona una opcion"

        if ($opcion -eq "0") {
            Mostrar-Resumen
            Write-Host "Saliendo..." -ForegroundColor Yellow
            return
        }
        elseif ($opcion -eq "1") {
            Preparar-Repositorios-FTP
        }
        elseif ($opcion -eq "5") {
            Mostrar-Resumen
        }
        elseif ($opcion -in @("2", "3", "4")) {
            $nombreServicio = switch ($opcion) {
                "2" { "IIS" }
                "3" { "Apache" }
                "4" { "Nginx" }
            }

            Write-Host "`n¿De donde deseas instalar $nombreServicio?"
            Write-Host " 1) WEB (descarga directa desde Internet)"
            Write-Host " 2) FTP (repositorio privado - puerto $($FTP_PUERTOS[$nombreServicio]))"
            Write-Host " 0) Regresar al

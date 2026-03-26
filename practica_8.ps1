# ==============================================================
# SCRIPT MAESTRO - WINDOWS SERVER 2019 CORE (SIN ACENTOS)
# DOMINIO: reprobados.com | MODO: Consola/SSH
# ==============================================================

function Mostrar-MenuCore {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "   PANEL DE CONTROL - WINDOWS SERVER CORE (CLI)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host " 1) Ver estado de red e IPs (Las 3 tarjetas)"
    Write-Host " 2) Ver estado de servicios (DNS, FSRM, IIS, FTP, SSH)"
    Write-Host " 3) Ejecutar script de Usuarios AD (ad_Ac8.ps1)"
    Write-Host " 4) Ejecutar script de FSRM (fsrm_Ac8.ps1)"
    Write-Host " 5) Forzar actualizacion de politicas (gpupdate /force)"
    Write-Host " 6) Ver quien esta conectado al servidor"
    Write-Host " 0) Salir"
    Write-Host "==========================================================" -ForegroundColor Cyan
}

do {
    Mostrar-MenuCore
    $opcion = Read-Host "Selecciona una opcion"

    switch ($opcion) {
        "1" {
            Write-Host "`n[+] Informacion de Red:" -ForegroundColor Yellow
            Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize
            Write-Host "[+] Hora actual del servidor: $(Get-Date)" -ForegroundColor Cyan
            pause
        }
        "2" {
            Write-Host "`n[+] Servicios clave de la practica:" -ForegroundColor Yellow
            Get-Service -Name dns, srmsvc, w3svc, ftpsvc, sshd -ErrorAction SilentlyContinue | Format-Table Name, DisplayName, Status -AutoSize
            pause
        }
        "3" {
            Write-Host "`n[+] Buscando y ejecutando ad_Ac8.ps1..." -ForegroundColor Yellow
            if (Test-Path ".\ad_Ac8.ps1") { 
                .\ad_Ac8.ps1 
            } else { 
                Write-Host "[X] No se encontro ad_Ac8.ps1 en la carpeta actual." -ForegroundColor Red 
            }
            pause
        }
        "4" {
            Write-Host "`n[+] Buscando y ejecutando fsrm_Ac8.ps1..." -ForegroundColor Yellow
            if (Test-Path ".\fsrm_Ac8.ps1") { 
                .\fsrm_Ac8.ps1 
            } else { 
                Write-Host "[X] No se encontro fsrm_Ac8.ps1 en la carpeta actual." -ForegroundColor Red 
            }
            pause
        }
        "5" {
            Write-Host "`n[+] Actualizando politicas del dominio..." -ForegroundColor Yellow
            gpupdate /force
            Write-Host "[OK] Politicas actualizadas. Los clientes (Win 11) deben reiniciar o hacer gpupdate para tomarlas." -ForegroundColor Green
            pause
        }
        "6" {
            Write-Host "`n[+] Usuarios conectados actualmente:" -ForegroundColor Yellow
            query user
            pause
        }
        "0" { Write-Host "`nCerrando panel maestro..." -ForegroundColor Yellow; break }
        default { Write-Host "`n[X] Opcion no valida." -ForegroundColor Red; pause }
    }
} while ($opcion -ne "0")

Import-Module ActiveDirectory

$dominio = "DC=reprobados,DC=com"

Write-Host "Creando Unidades Organizativas..." -ForegroundColor Cyan
# Crear las UO (con un try-catch por si ya existen, para que no te tire letras rojas)
try { New-ADOrganizationalUnit -Name "Cuates" -Path $dominio -ErrorAction Stop } catch {}
try { New-ADOrganizationalUnit -Name "No Cuates" -Path $dominio -ErrorAction Stop } catch {}

# Arreglos de Bytes para los horarios (Magia negra convertida a bytes)
[byte[]]$horasCuates = 0, 127, 0, 0, 127, 0, 0, 127, 0, 0, 127, 0, 0, 127, 0, 0, 127, 0, 0, 127, 0
[byte[]]$horasNoCuates = 3, 128, 255, 3, 128, 255, 3, 128, 255, 3, 128, 255, 3, 128, 255, 3, 128, 255, 3, 128, 255

# Contraseña genérica para todos los usuarios
$securePass = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force

# Leer el CSV
Write-Host "Leyendo usuarios del CSV..." -ForegroundColor Cyan
$usuarios = Import-Csv "C:\usuarios.csv" -Encoding UTF8

foreach ($usr in $usuarios) {
    # Decidir a dónde va y qué horario le toca según el CSV
    if ($usr.Departamento -eq "Cuates") {
        $ouPath = "OU=Cuates,$dominio"
        $horas = $horasCuates
    } else {
        $ouPath = "OU=No Cuates,$dominio"
        $horas = $horasNoCuates
    }

    # Revisar si el usuario ya existe para no duplicarlo
    $existe = Get-ADUser -Filter "SamAccountName -eq '$($usr.Usuario)'"
    if (-not $existe) {
        Write-Host "Creando a $($usr.Nombre) en $($usr.Departamento)..." -ForegroundColor Green
        New-ADUser -Name $usr.Nombre `
                   -SamAccountName $usr.Usuario `
                   -UserPrincipalName "$($usr.Usuario)@reprobados.com" `
                   -Path $ouPath `
                   -AccountPassword $securePass `
                   -Enabled $true `
                   -PasswordNeverExpires $true

        # Aplicarle las horas de logueo (el requisito pesado del profe)
        Set-ADUser -Identity $usr.Usuario -Replace @{logonhours = $horas}
    } else {
        Write-Host "El usuario $($usr.Usuario) ya existe, saltando..." -ForegroundColor Yellow
    }
}

Write-Host "¡Todos los usuarios y horarios fueron configurados al 100%!" -ForegroundColor DarkGreen

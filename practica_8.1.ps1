$RutaCSV = "C:\Practica8\usuarios.csv"
$RutaRaiz = "C:\Perfiles"

function Validar-CSV {
    if (-not (Test-Path $RutaCSV)) {
        Write-Host "[ERROR] No existe $RutaCSV" -ForegroundColor Red
        return $false
    }

    $fila = Import-Csv $RutaCSV | Select-Object -First 1
    if (-not $fila) {
        Write-Host "[ERROR] El CSV esta vacio" -ForegroundColor Red
        return $false
    }

    $cols = $fila.PSObject.Properties.Name
    if (($cols -notcontains "usuario") -or ($cols -notcontains "pass") -or ($cols -notcontains "departamento")) {
        Write-Host "[ERROR] El CSV debe tener: usuario, pass, departamento" -ForegroundColor Red
        return $false
    }

    Write-Host "[OK] CSV valido" -ForegroundColor Green
    return $true
}

function Generar-CSVEjemplo {
    New-Item -ItemType Directory -Path "C:\Practica8" -Force | Out-Null
    @(
        "usuario,pass,departamento",
        "carlos,Pass@1234,Cuates",
        "mario,Pass@1234,Cuates",
        "pedro,Pass@1234,Cuates",
        "juan,Pass@1234,Cuates",
        "luis,Pass@1234,Cuates",
        "rosa,Pass@1234,No Cuates",
        "lucia,Pass@1234,No Cuates",
        "diana,Pass@1234,No Cuates",
        "elena,Pass@1234,No Cuates",
        "ana,Pass@1234,No Cuates"
    ) | Set-Content -Path $RutaCSV -Encoding UTF8
    Write-Host "[OK] CSV generado en $RutaCSV" -ForegroundColor Green
}

function Instalar-Requisitos {
    Write-Host "[1] Instalando FSRM y GPMC..." -ForegroundColor Cyan
    Install-WindowsFeature -Name FS-Resource-Manager, GPMC -IncludeManagementTools
    Import-Module ActiveDirectory
    Import-Module GroupPolicy
    Write-Host "[OK] Requisitos instalados" -ForegroundColor Green
}

function Crear-EstructuraAD {
    Write-Host "[2] Creando OUs y grupos..." -ForegroundColor Cyan

    $servidor = "localhost"

    $dominioObj = Get-ADDomain -Server $servidor
    $dominioDN = $dominioObj.DistinguishedName

    foreach ($ou in @("Cuates","No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -Server $servidor -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $dominioDN -ProtectedFromAccidentalDeletion $false -Server $servidor
            Write-Host "OU creada: $ou" -ForegroundColor Green
        }
    }

    if (-not (Get-ADGroup -Filter "Name -eq 'Grupo_Cuates'" -Server $servidor -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name "Grupo_Cuates" -GroupScope Global -GroupCategory Security -Path "OU=Cuates,$dominioDN" -Server $servidor
    }

    if (-not (Get-ADGroup -Filter "Name -eq 'Grupo_NoCuates'" -Server $servidor -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name "Grupo_NoCuates" -GroupScope Global -GroupCategory Security -Path "OU=No Cuates,$dominioDN" -Server $servidor
    }

    Write-Host "[OK] OUs y grupos creados" -ForegroundColor Green
}

function Crear-HorarioBytes {
    param([int]$Inicio, [int]$Fin)

    [byte[]]$bytes = New-Object byte[] 21

    for ($dia = 0; $dia -lt 7; $dia++) {
        for ($hora = 0; $hora -lt 24; $hora++) {
            $permitido = $false

            if ($Inicio -lt $Fin) {
                if ($hora -ge $Inicio -and $hora -lt $Fin) { $permitido = $true }
            }
            else {
                if ($hora -ge $Inicio -or $hora -lt $Fin) { $permitido = $true }
            }

            if ($permitido) {
                $fechaLocal = (Get-Date -Year 2024 -Month 1 -Day 7 -Hour 0 -Minute 0 -Second 0).AddDays($dia).AddHours($hora)
                $fechaUTC = $fechaLocal.ToUniversalTime()
                $diaUTC = [int]$fechaUTC.DayOfWeek
                $horaUTC = $fechaUTC.Hour
                $byteIndex = ($diaUTC * 3) + [Math]::Floor($horaUTC / 8)
                $bitIndex = $horaUTC % 8
                $bytes[$byteIndex] = $bytes[$byteIndex] -bor (1 -shl $bitIndex)
            }
        }
    }

    return $bytes
}

function Importar-UsuariosCSV {
    Write-Host "[3] Importando usuarios..." -ForegroundColor Cyan
    if (-not (Validar-CSV)) { return }

    $servidor = "localhost"
    $dominioObj = Get-ADDomain -Server $servidor
    $dominioDN = $dominioObj.DistinguishedName
    $forest = $dominioObj.DNSRoot
    [byte[]]$horasCuates = Crear-HorarioBytes -Inicio 8 -Fin 15
    [byte[]]$horasNoCuates = Crear-HorarioBytes -Inicio 15 -Fin 2

    foreach ($u in (Import-Csv $RutaCSV)) {
        $usuario = $u.usuario.Trim()
        $pass = $u.pass.Trim()
        $depto = $u.departamento.Trim()

        if ($depto -eq "Cuates") {
            $ouPath = "OU=Cuates,$dominioDN"
            $grupo = "Grupo_Cuates"
            [byte[]]$horario = $horasCuates
        }
        else {
            $ouPath = "OU=No Cuates,$dominioDN"
            $grupo = "Grupo_NoCuates"
            [byte[]]$horario = $horasNoCuates
        }

        $securePass = ConvertTo-SecureString $pass -AsPlainText -Force

        if (Get-ADUser -Filter "SamAccountName -eq '$usuario'" -Server $servidor -ErrorAction SilentlyContinue) {
            Remove-ADUser -Identity $usuario -Server $servidor -Confirm:$false
            Start-Sleep -Milliseconds 500
        }

        New-ADUser `
            -Name $usuario `
            -SamAccountName $usuario `
            -UserPrincipalName "$usuario@$forest" `
            -AccountPassword $securePass `
            -Enabled $true `
            -Path $ouPath `
            -PasswordNeverExpires $true `
            -Server $servidor

        Set-ADUser -Identity $usuario -Replace @{logonhours = [byte[]]$horario} -Server $servidor
        Add-ADGroupMember -Identity $grupo -Members $usuario -Server $servidor

        Write-Host "Usuario creado: $usuario -> $depto" -ForegroundColor Green
    }
}

function Configurar-Carpetas {
    Write-Host "[4] Creando carpetas y permisos..." -ForegroundColor Cyan
    $servidor = "localhost"
    $dominio = (Get-ADDomain -Server $servidor).NetBIOSName

    foreach ($dep in @("Cuates","NoCuates")) {
        $rutaDep = Join-Path $RutaRaiz $dep
        $rutaGeneral = Join-Path $rutaDep "General"

        New-Item -ItemType Directory -Path $rutaGeneral -Force | Out-Null

        $acl = Get-Acl $rutaDep
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("$dominio\Grupo_$dep","Modify","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl $rutaDep $acl
    }

    foreach ($u in (Import-Csv $RutaCSV)) {
        $usuario = $u.usuario.Trim()
        $dep = $u.departamento.Trim() -replace " ",""
        $rutaPrivada = Join-Path $RutaRaiz "$dep\$usuario"

        New-Item -ItemType Directory -Path $rutaPrivada -Force | Out-Null

        $acl = Get-Acl $rutaPrivada
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("$dominio\$usuario","Modify","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl $rutaPrivada $acl
    }

    Write-Host "[OK] Carpetas y permisos listos" -ForegroundColor Green
}

function Configurar-GPOLogoff {
    Write-Host "[5] Configurando GPO cierre forzado..." -ForegroundColor Cyan
    $servidor = "localhost"
    $dominioDN = (Get-ADDomain -Server $servidor).DistinguishedName
    $gpoName = "Practica8_CierreForzado"

    if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
        New-GPO -Name $gpoName | Out-Null
    }

    $link = Get-GPInheritance -Target $dominioDN | Select-Object -ExpandProperty GpoLinks | Where-Object { $_.DisplayName -eq $gpoName }
    if (-not $link) {
        New-GPLink -Name $gpoName -Target $dominioDN | Out-Null
    }

    Set-GPRegistryValue -Name $gpoName -Key "HKLM\System\CurrentControlSet\Services\LanManServer\Parameters" -ValueName "enableforcedlogoff" -Type DWord -Value 1 | Out-Null
    Write-Host "[OK] GPO configurada" -ForegroundColor Green
}

function Configurar-FSRM {
    Write-Host "[6] Configurando FSRM..." -ForegroundColor Cyan

    $rutaCuates = "$RutaRaiz\Cuates"
    $rutaNoCuates = "$RutaRaiz\NoCuates"

    New-Item -ItemType Directory -Path $rutaCuates -Force | Out-Null
    New-Item -ItemType Directory -Path $rutaNoCuates -Force | Out-Null

    if (Get-FsrmQuotaTemplate -Name "P8_10MB" -ErrorAction SilentlyContinue) {
        Remove-FsrmQuotaTemplate -Name "P8_10MB" -Confirm:$false
    }
    if (Get-FsrmQuotaTemplate -Name "P8_5MB" -ErrorAction SilentlyContinue) {
        Remove-FsrmQuotaTemplate -Name "P8_5MB" -Confirm:$false
    }

    New-FsrmQuotaTemplate -Name "P8_10MB" -Size 10MB -SoftLimit $false
    New-FsrmQuotaTemplate -Name "P8_5MB" -Size 5MB -SoftLimit $false

    if (Get-FsrmAutoQuota -Path $rutaCuates -ErrorAction SilentlyContinue) {
        Remove-FsrmAutoQuota -Path $rutaCuates -Confirm:$false
    }
    if (Get-FsrmAutoQuota -Path $rutaNoCuates -ErrorAction SilentlyContinue) {
        Remove-FsrmAutoQuota -Path $rutaNoCuates -Confirm:$false
    }

    New-FsrmAutoQuota -Path $rutaCuates -Template "P8_10MB"
    New-FsrmAutoQuota -Path $rutaNoCuates -Template "P8_5MB"

    if (Get-FsrmFileGroup -Name "P8_Archivos_Prohibidos" -ErrorAction SilentlyContinue) {
        Remove-FsrmFileGroup -Name "P8_Archivos_Prohibidos" -Confirm:$false
    }

    New-FsrmFileGroup -Name "P8_Archivos_Prohibidos" -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi")

    if (Get-FsrmFileScreen -Path $RutaRaiz -ErrorAction SilentlyContinue) {
        Remove-FsrmFileScreen -Path $RutaRaiz -Confirm:$false
    }

    $accion = New-FsrmAction -Type EventLog -EventType Warning -Body "Archivo bloqueado por FSRM"

    New-FsrmFileScreen -Path $RutaRaiz -IncludeGroup "P8_Archivos_Prohibidos" -Active -Notification $accion

    Write-Host "[OK] FSRM configurado" -ForegroundColor Green
}

function Ejecutar-Todo {
    Generar-CSVEjemplo
    Instalar-Requisitos
    Crear-EstructuraAD
    Importar-UsuariosCSV
    Configurar-Carpetas
    Configurar-GPOLogoff
    Configurar-FSRM
    gpupdate /force | Out-Null
    Write-Host "[OK] PRACTICA 8 COMPLETA" -ForegroundColor Green
}

Write-Host "===================================" -ForegroundColor Yellow
Write-Host " PRACTICA 8 - SCRIPT PRINCIPAL " -ForegroundColor Yellow
Write-Host "===================================" -ForegroundColor Yellow
Write-Host "[1] Generar CSV"
Write-Host "[2] Instalar requisitos"
Write-Host "[3] Crear estructura AD"
Write-Host "[4] Importar usuarios"
Write-Host "[5] Crear carpetas"
Write-Host "[6] Configurar GPO"
Write-Host "[7] Configurar FSRM"
Write-Host "[8] Ejecutar todo"
Write-Host ""

$op = Read-Host "Selecciona una opcion"

switch ($op) {
    "1" { Generar-CSVEjemplo }
    "2" { Instalar-Requisitos }
    "3" { Crear-EstructuraAD }
    "4" { Importar-UsuariosCSV }
    "5" { Configurar-Carpetas }
    "6" { Configurar-GPOLogoff }
    "7" { Configurar-FSRM }
    "8" { Ejecutar-Todo }
    default { Write-Host "Opcion invalida" -ForegroundColor Red }
}

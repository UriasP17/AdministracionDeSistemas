#Requires -RunAsAdministrator
#  Practica8.ps1

Import-Module ActiveDirectory -ErrorAction Stop

$RutaCSV  = Join-Path -Path $PSScriptRoot -ChildPath "usuarios.csv"
$RutaRaiz = "C:\Perfiles"

# ============================================================
#  FUNCIONES
# ============================================================

function Instalar-Requisitos {
    Write-Host "`n[1/6] Instalando FSRM y GPMC..." -ForegroundColor Cyan
    Install-WindowsFeature -Name FS-Resource-Manager, GPMC -IncludeManagementTools | Out-Null
    Write-Host "      Requisitos instalados correctamente." -ForegroundColor Green
}

function Crear-EstructuraAD {
    Write-Host "`n[2/6] Creando OUs y Grupos en Active Directory..." -ForegroundColor Cyan
    $dominioDN = (Get-ADDomain).DistinguishedName

    foreach ($ou in @("Cuates", "No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -SearchBase $dominioDN -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $dominioDN -ProtectedFromAccidentalDeletion $false
            Write-Host "      OU '$ou' creada." -ForegroundColor Green
        }
    }

    $grupos = @(
        @{ Nombre = "Grupo_Cuates";    OU = "OU=Cuates,$dominioDN" },
        @{ Nombre = "Grupo_NoCuates";  OU = "OU=No Cuates,$dominioDN" }
    )
    foreach ($g in $grupos) {
        if (-not (Get-ADGroup -Filter "Name -eq '$($g.Nombre)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $g.Nombre -GroupCategory Security -GroupScope Global -Path $g.OU
            Write-Host "      Grupo '$($g.Nombre)' creado." -ForegroundColor Green
        }
    }
}

function Importar-UsuariosCSV {
    Write-Host "`n[3/6] Importando usuarios y configurando horarios..." -ForegroundColor Cyan

    function Crear-HorarioBytes {
        param([int]$Inicio, [int]$Fin)
        [byte[]]$bytes = New-Object byte[] 21
        $offsetHoras = [int][System.TimeZoneInfo]::Local.BaseUtcOffset.TotalHours

        for ($dia = 0; $dia -lt 7; $dia++) {
            for ($hora = 0; $hora -lt 24; $hora++) {
                $permitido = if ($Inicio -lt $Fin) { ($hora -ge $Inicio -and $hora -lt $Fin) } else { ($hora -ge $Inicio -or $hora -lt $Fin) }
                if ($permitido) {
                    $horaUTC  = ($hora - $offsetHoras + 24) % 24
                    $diaUTC   = ($dia + [Math]::Floor(($hora - $offsetHoras) / 24.0) + 7) % 7
                    $byteIdx  = ($diaUTC * 3) + [Math]::Floor($horaUTC / 8)
                    $bitIdx   = $horaUTC % 8
                    $bytes[$byteIdx] = $bytes[$byteIdx] -bor (1 -shl $bitIdx)
                }
            }
        }
        return $bytes
    }

    [byte[]]$horasCuates   = Crear-HorarioBytes -Inicio 8  -Fin 15
    [byte[]]$horasNoCuates = Crear-HorarioBytes -Inicio 15 -Fin 2
    $dominioDN = (Get-ADDomain).DistinguishedName
    $usuarios = Import-Csv $RutaCSV

    foreach ($u in $usuarios) {
        $nUsuario = $u.usuario.Trim()
        $nPass    = $u.pass.Trim()
        $nDepto   = $u.departamento.Trim()
        $ouPath  = if ($nDepto -eq "Cuates") { "OU=Cuates,$dominioDN" } else { "OU=No Cuates,$dominioDN" }
        $grupo   = if ($nDepto -eq "Cuates") { "Grupo_Cuates" } else { "Grupo_NoCuates" }
        [byte[]]$logonHours = if ($nDepto -eq "Cuates") { $horasCuates } else { $horasNoCuates }

        $securePass = ConvertTo-SecureString $nPass -AsPlainText -Force
        $upn = "$nUsuario@$((Get-ADDomain).Forest)"

        try {
            if (Get-ADUser -Filter {SamAccountName -eq $nUsuario} -ErrorAction SilentlyContinue) {
                Remove-ADUser -Identity $nUsuario -Confirm:$false
                Start-Sleep -Milliseconds 500
            }
            New-ADUser -Name $nUsuario -SamAccountName $nUsuario -UserPrincipalName $upn -AccountPassword $securePass -Enabled $true -Path $ouPath
            Set-ADUser -Identity $nUsuario -Replace @{ logonhours = [byte[]]$logonHours }
            Add-ADGroupMember -Identity $grupo -Members $nUsuario

            Write-Host "      [OK] Usuario creado: $nUsuario -> $nDepto" -ForegroundColor Green
        } catch {
            Write-Host "      [ERROR] $nUsuario : $_" -ForegroundColor Red
        }
    }
}

function Configurar-Carpetas {
    Write-Host "`n[4/6] Creando estructura de carpetas y permisos..." -ForegroundColor Cyan
    $Dominio = (Get-ADDomain).NetBIOSName
    $usuarios = Import-Csv $RutaCSV

    foreach ($u in $usuarios) {
        $nombre    = $u.usuario.Trim()
        $depLimpio = $u.departamento.Trim() -replace " ", ""
        $rutaPrivada = Join-Path $RutaRaiz "$depLimpio\$nombre"

        if (-not (Test-Path $rutaPrivada)) {
            New-Item -Path $rutaPrivada -ItemType Directory -Force | Out-Null
        }

        $aclP = Get-Acl $rutaPrivada
        $aclP.SetAccessRuleProtection($true, $false)
        $aclP.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administradores","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
        $aclP.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("$Dominio\$nombre","Modify","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl $rutaPrivada $aclP

        $shareName = $nombre
        if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $shareName -Path $rutaPrivada -FullAccess "$Dominio\$nombre" -ErrorAction SilentlyContinue
        }
    }
    Write-Host "      Carpetas creadas y compartidas en red." -ForegroundColor Green
}

function Configurar-GPO-Logoff {
    Write-Host "`n[5/6] Configurando GPO de cierre forzado de sesion..." -ForegroundColor Cyan
    $dominioDN = (Get-ADDomain).DistinguishedName
    $gpoName   = "Politicas_FIM_CierreForzado"

    if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
        New-GPO -Name $gpoName | Out-Null
    }
    $linkExiste = Get-GPInheritance -Target $dominioDN | Select-Object -ExpandProperty GpoLinks | Where-Object { $_.DisplayName -eq $gpoName }
    if (-not $linkExiste) { New-GPLink -Name $gpoName -Target $dominioDN | Out-Null }

    Set-GPRegistryValue -Name $gpoName -Key "HKLM\System\CurrentControlSet\Services\LanManServer\Parameters" -ValueName "enableforcedlogoff" -Type DWord -Value 1 | Out-Null
    Write-Host "      Cierre forzado activo y vinculado al dominio." -ForegroundColor Green
}

function Configurar-FSRM {
    Write-Host "`n[6a] Configurando FSRM (Cuotas y Apantallamiento)..." -ForegroundColor Cyan
    $rutaCuates   = "$RutaRaiz\Cuates"
    $rutaNoCuates = "$RutaRaiz\NoCuates"

    foreach ($plantilla in @("FIM_10MB","FIM_5MB")) {
        if (Get-FsrmQuotaTemplate -Name $plantilla -ErrorAction SilentlyContinue) { Remove-FsrmQuotaTemplate -Name $plantilla -Confirm:$false }
    }
    
    New-FsrmQuotaTemplate -Name "FIM_10MB" -Size 10MB
    New-FsrmQuotaTemplate -Name "FIM_5MB"  -Size 5MB

    Get-ChildItem $rutaCuates -Directory | ForEach-Object {
        if (Get-FsrmQuota -Path $_.FullName -ErrorAction SilentlyContinue) { Remove-FsrmQuota -Path $_.FullName -Confirm:$false }
        New-FsrmQuota -Path $_.FullName -Template "FIM_10MB"
    }
    Get-ChildItem $rutaNoCuates -Directory | ForEach-Object {
        if (Get-FsrmQuota -Path $_.FullName -ErrorAction SilentlyContinue) { Remove-FsrmQuota -Path $_.FullName -Confirm:$false }
        New-FsrmQuota -Path $_.FullName -Template "FIM_5MB"
    }

    if (Get-FsrmFileGroup -Name "Archivos_Prohibidos_FIM" -ErrorAction SilentlyContinue) { Remove-FsrmFileGroup -Name "Archivos_Prohibidos_FIM" -Confirm:$false }
    New-FsrmFileGroup -Name "Archivos_Prohibidos_FIM" -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi")
    
    if (Get-FsrmFileScreen -Path $RutaRaiz -ErrorAction SilentlyContinue) { Remove-FsrmFileScreen -Path $RutaRaiz -Confirm:$false }
    New-FsrmFileScreen -Path $RutaRaiz -IncludeGroup "Archivos_Prohibidos_FIM" -Active

    Write-Host "      FSRM Configurado: Cuotas y bloqueos listos." -ForegroundColor Green
}

function Configurar-AppLocker {
    Write-Host "`n[6b] Configurando AppLocker en GPO (SOLO PARA CLIENTES)..." -ForegroundColor Cyan

    $nombreGPO = "Bloqueo_Notepad"
    $dominioDN = (Get-ADDomain).DistinguishedName
    $ouTarget  = "OU=No Cuates,$dominioDN"

    # 1. Crear la GPO y vincularla EXCLUSIVAMENTE a los No Cuates
    if (-not (Get-GPO -Name $nombreGPO -ErrorAction SilentlyContinue)) {
        New-GPO -Name $nombreGPO | Out-Null
    }
    $linkExiste = Get-GPInheritance -Target $ouTarget | Select-Object -ExpandProperty GpoLinks | Where-Object { $_.DisplayName -eq $nombreGPO }
    if (-not $linkExiste) { New-GPLink -Name $nombreGPO -Target $ouTarget | Out-Null }

    # 2. Configurar la GPO para que los clientes inicien el servicio AppIDSvc automaticamente (Start = 2)
    Set-GPRegistryValue -Name $nombreGPO -Key "HKLM\System\CurrentControlSet\Services\AppIDSvc" -ValueName "Start" -Type DWord -Value 2 | Out-Null

    # 3. Generar las reglas en memoria
    $sidNoCuates = (Get-ADGroup "Grupo_NoCuates").SID.Value
    $reglaDefault = Get-AppLockerFileInformation -Directory "C:\Windows\" -Recurse -ErrorAction SilentlyContinue | New-AppLockerPolicy -RuleType Path -User "Todos" -Optimize
    $reglaApp = Get-AppLockerFileInformation -Path "C:\Windows\System32\notepad.exe" | New-AppLockerPolicy -RuleType Hash -User $sidNoCuates
    foreach($RC in $reglaApp.RuleCollections) { foreach($rule in $RC) { $rule.Action = 'Deny' } }

    # 4. Inyectar las reglas a la GPO usando LDAP (NUNCA mas local)
    $gpoInfo = Get-GPO -Name $nombreGPO
    $ldapPath = "LDAP://CN={$($gpoInfo.Id)},CN=Policies,CN=System,$dominioDN"

    Set-AppLockerPolicy -PolicyObject $reglaDefault -LDAP $ldapPath -Merge -ErrorAction SilentlyContinue
    Set-AppLockerPolicy -PolicyObject $reglaApp -LDAP $ldapPath -Merge -ErrorAction SilentlyContinue

    Write-Host "      GPO '$nombreGPO' creada y vinculada a la OU 'No Cuates'." -ForegroundColor Green
    Write-Host "      AppLocker NO afectara a este Servidor." -ForegroundColor Green
}

function Ejecutar-Todo {
    if (-not (Test-Path $RutaCSV)) { Write-Host "`n[X] Falta el archivo $RutaCSV" -ForegroundColor Red; return }
    Instalar-Requisitos
    Crear-EstructuraAD
    Importar-UsuariosCSV
    Configurar-Carpetas
    Configurar-GPO-Logoff
    Configurar-FSRM
    Configurar-AppLocker
    
    Write-Host "`n[+] Aplicando politicas de Dominio..." -ForegroundColor Cyan
    gpupdate /force
    Write-Host "`n¡PRACTICA CONFIGURADA CON EXITO!" -ForegroundColor Green
}

# ============================================================
#  MENU PRINCIPAL
# ============================================================
do {
    Clear-Host
    Write-Host '==========================================' -ForegroundColor Yellow
    Write-Host '       PRACTICA 8 - MENU PRINCIPAL        ' -ForegroundColor Yellow
    Write-Host '==========================================' -ForegroundColor Yellow
    Write-Host '  1) Instalar Requisitos (FSRM + GPMC)'
    Write-Host '  2) Crear Estructura AD (OUs + Grupos)'
    Write-Host '  3) Importar Usuarios del CSV'
    Write-Host '  4) Crear Carpetas y Permisos (SMB)'
    Write-Host '  5) Configurar GPO Cierre Forzado'
    Write-Host '  6) Configurar FSRM (Cuotas + Pantalla)'
    Write-Host '  7) Configurar AppLocker (GPO Clientes)'
    Write-Host '------------------------------------------'
    Write-Host '  A) EJECUTAR TODO' -ForegroundColor Green
    Write-Host '  S) Salir' -ForegroundColor Red
    Write-Host '=========================================='
    
    $opcion = Read-Host 'Selecciona una opcion'
    
    switch ($opcion.ToUpper()) {
        '1' { Instalar-Requisitos }
        '2' { Crear-EstructuraAD }
        '3' { Importar-UsuariosCSV }
        '4' { Configurar-Carpetas }
        '5' { Configurar-GPO-Logoff }
        '6' { Configurar-FSRM }
        '7' { Configurar-AppLocker }
        'A' { Ejecutar-Todo }
        'S' { break }
        default { Write-Host 'Opcion no valida.' -ForegroundColor Red }
    }
    if ($opcion.ToUpper() -ne 'S') { 
        Read-Host 'Presiona ENTER para continuar...' | Out-Null 
    }
} while ($opcion.ToUpper() -ne 'S')

$RutaCSV  = "C:\Practica8\usuarios.csv"
$RutaRaiz = "C:\Perfiles"

function Validar-CSV {
    if (-not (Test-Path $RutaCSV)) {
        Write-Host "[ERROR] No se encontro el CSV en: $RutaCSV" -ForegroundColor Red
        return $false
    }
    $fila = Import-Csv $RutaCSV | Select-Object -First 1
    $cols = $fila.PSObject.Properties.Name
    if (-not ($cols -contains "usuario" -and $cols -contains "pass" -and $cols -contains "departamento")) {
        Write-Host "[ERROR] El CSV debe tener columnas: usuario, pass, departamento" -ForegroundColor Red
        return $false
    }
    $total = (Import-Csv $RutaCSV).Count
    Write-Host "  [OK] CSV valido — $total usuarios encontrados." -ForegroundColor Green
    return $true
}

function Instalar-Requisitos {
    Write-Host "`n[1/6] Instalando FSRM y GPMC..." -ForegroundColor Cyan
    Install-WindowsFeature -Name FS-Resource-Manager, GPMC -IncludeManagementTools
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    Import-Module GroupPolicy -ErrorAction SilentlyContinue
    Write-Host "      Modulos cargados." -ForegroundColor Green
}

function Crear-EstructuraAD {
    Write-Host "`n[2/6] Creando OUs y Grupos en AD..." -ForegroundColor Cyan
    Import-Module ActiveDirectory
    $dominioDN = (Get-ADDomain).DistinguishedName
    foreach ($ou in @("Cuates", "No Cuates")) {
        $existe = Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -SearchBase $dominioDN -SearchScope OneLevel -ErrorAction SilentlyContinue
        if (-not $existe) {
            New-ADOrganizationalUnit -Name $ou -Path $dominioDN -ProtectedFromAccidentalDeletion $false
            Write-Host "      OU '$ou' creada." -ForegroundColor Green
        } else { Write-Host "      OU '$ou' ya existe." -ForegroundColor DarkGray }
    }
    $grupos = @(
        @{ Nombre = "Grupo_Cuates";   OU = "OU=Cuates,$dominioDN" },
        @{ Nombre = "Grupo_NoCuates"; OU = "OU=No Cuates,$dominioDN" }
    )
    foreach ($g in $grupos) {
        if (-not (Get-ADGroup -Filter "Name -eq '$($g.Nombre)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $g.Nombre -GroupCategory Security -GroupScope Global -Path $g.OU
            Write-Host "      Grupo '$($g.Nombre)' creado." -ForegroundColor Green
        } else { Write-Host "      Grupo '$($g.Nombre)' ya existe." -ForegroundColor DarkGray }
    }
}

function Importar-UsuariosCSV {
    Write-Host "`n[3/6] Importando usuarios y horarios..." -ForegroundColor Cyan
    Import-Module ActiveDirectory
    function Crear-HorarioBytes {
        param([int]$Inicio, [int]$Fin)
        [byte[]]$bytes = New-Object byte[] 21
        for ($dia = 0; $dia -lt 7; $dia++) {
            for ($hora = 0; $hora -lt 24; $hora++) {
                $permitido = if ($Inicio -lt $Fin) { ($hora -ge $Inicio -and $hora -lt $Fin) } else { ($hora -ge $Inicio -or $hora -lt $Fin) }
                if ($permitido) {
                    $fechaLocal = (Get-Date -Year 2024 -Month 1 -Day 7 -Hour 0 -Minute 0 -Second 0).AddDays($dia).AddHours($hora)
                    $fechaUTC   = $fechaLocal.ToUniversalTime()
                    $diaUTC     = [int]$fechaUTC.DayOfWeek
                    $horaUTC    = $fechaUTC.Hour
                    $byteIndex  = ($diaUTC * 3) + [Math]::Floor($horaUTC / 8)
                    $bitIndex   = $horaUTC % 8
                    $bytes[$byteIndex] = $bytes[$byteIndex] -bor (1 -shl $bitIndex)
                }
            }
        }
        return $bytes
    }
    [byte[]]$horasCuates   = Crear-HorarioBytes -Inicio 8  -Fin 15
    [byte[]]$horasNoCuates = Crear-HorarioBytes -Inicio 15 -Fin 2
    $dominioDN = (Get-ADDomain).DistinguishedName
    $forest    = (Get-ADDomain).Forest
    foreach ($u in (Import-Csv $RutaCSV)) {
        $nUsuario = $u.usuario.Trim(); $nPass = $u.pass.Trim(); $nDepto = $u.departamento.Trim()
        if ($nDepto -eq "Cuates") { $ouPath = "OU=Cuates,$dominioDN"; $grupo = "Grupo_Cuates"; [byte[]]$logonHours = $horasCuates }
        else { $ouPath = "OU=No Cuates,$dominioDN"; $grupo = "Grupo_NoCuates"; [byte[]]$logonHours = $horasNoCuates }
        $securePass = ConvertTo-SecureString $nPass -AsPlainText -Force
        try {
            if (Get-ADUser -Filter {SamAccountName -eq $nUsuario} -ErrorAction SilentlyContinue) {
                Remove-ADUser -Identity $nUsuario -Confirm:$false; Start-Sleep -Milliseconds 600
            }
            New-ADUser -Name $nUsuario -SamAccountName $nUsuario -UserPrincipalName "$nUsuario@$forest" -AccountPassword $securePass -Enabled $true -Path $ouPath -PasswordNeverExpires $true
            Set-ADUser -Identity $nUsuario -Replace @{ logonhours = [byte[]]$logonHours }
            Add-ADGroupMember -Identity $grupo -Members $nUsuario
            Write-Host "      [OK] $nUsuario -> $nDepto" -ForegroundColor Green
        } catch { Write-Host "      [ERROR] $nUsuario : $_" -ForegroundColor Red }
    }
}

function Configurar-Carpetas {
    Write-Host "`n[4a/6] Creando carpetas y permisos..." -ForegroundColor Cyan
    Import-Module ActiveDirectory
    $Dominio = (Get-ADDomain).NetBIOSName
    foreach ($dep in @("Cuates", "NoCuates")) {
        $rutaDep = Join-Path $RutaRaiz $dep
        $rutaGen = Join-Path $rutaDep "General"
        if (-not (Test-Path $rutaGen)) { New-Item -Path $rutaGen -ItemType Directory -Force | Out-Null }
        $acl = Get-Acl $rutaDep
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("$Dominio\Grupo_$dep","Modify","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl $rutaDep $acl
        Write-Host "      ACL aplicada: $rutaDep" -ForegroundColor Green
    }
    foreach ($u in (Import-Csv $RutaCSV)) {
        $nombre = $u.usuario.Trim(); $depLimpio = $u.departamento.Trim() -replace " ", ""
        $rutaPrivada = Join-Path $RutaRaiz "$depLimpio\$nombre"
        if (-not (Test-Path $rutaPrivada)) { New-Item -Path $rutaPrivada -ItemType Directory -Force | Out-Null }
        $aclP = Get-Acl $rutaPrivada
        $aclP.SetAccessRuleProtection($true, $false)
        $aclP.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
        $aclP.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("$Dominio\$nombre","Modify","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl $rutaPrivada $aclP
        Write-Host "      Carpeta privada: $rutaPrivada" -ForegroundColor Green
    }
}

function Configurar-GPO-Logoff {
    Write-Host "`n[4b/6] GPO cierre forzado..." -ForegroundColor Cyan
    Import-Module GroupPolicy
    $dominioDN = (Get-ADDomain).DistinguishedName
    $gpoName   = "Practica8_CierreForzado"
    if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) { New-GPO -Name $gpoName | Out-Null; Write-Host "      GPO creada." -ForegroundColor Green }
    $linkExiste = Get-GPInheritance -Target $dominioDN | Select-Object -ExpandProperty GpoLinks | Where-Object { $_.DisplayName -eq $gpoName }
    if (-not $linkExiste) { New-GPLink -Name $gpoName -Target $dominioDN | Out-Null; Write-Host "      GPO vinculada al dominio." -ForegroundColor Green }
    Set-GPRegistryValue -Name $gpoName -Key "HKLM\System\CurrentControlSet\Services\LanManServer\Parameters" -ValueName "enableforcedlogoff" -Type DWord -Value 1 | Out-Null
    Write-Host "      Cierre forzado ACTIVO." -ForegroundColor Green
}

function Configurar-FSRM {
    Write-Host "`n[5/6] Configurando FSRM..." -ForegroundColor Cyan
    $rutaCuates   = "$RutaRaiz\Cuates"
    $rutaNoCuates = "$RutaRaiz\NoCuates"
    foreach ($r in @($rutaCuates, $rutaNoCuates)) { if (-not (Test-Path $r)) { New-Item -Path $r -ItemType Directory -Force | Out-Null } }
    foreach ($p in @("P8_10MB","P8_5MB")) { if (Get-FsrmQuotaTemplate -Name $p -ErrorAction SilentlyContinue) { Remove-FsrmQuotaTemplate -Name $p -Confirm:$false } }
    New-FsrmQuotaTemplate -Name "P8_10MB" -Size 10MB -SoftLimit $false
    New-FsrmQuotaTemplate -Name "P8_5MB"  -Size 5MB  -SoftLimit $false
    Write-Host "      Plantillas creadas." -ForegroundColor Green
    foreach ($autoQ in @($rutaCuates,$rutaNoCuates)) { if (Get-FsrmAutoQuota -Path $autoQ -ErrorAction SilentlyContinue) { Remove-FsrmAutoQuota -Path $autoQ -Confirm:$false } }
    New-FsrmAutoQuota -Path $rutaCuates   -Template "P8_10MB"
    New-FsrmAutoQuota -Path $rutaNoCuates -Template "P8_5MB"
    Write-Host "      Auto-cuotas configuradas." -ForegroundColor Green
    Get-ChildItem $rutaCuates -Directory | ForEach-Object {
        if (Get-FsrmQuota -Path $_.FullName -ErrorAction SilentlyContinue) { Remove-FsrmQuota -Path $_.FullName -Confirm:$false }
        New-FsrmQuota -Path $_.FullName -Template "P8_10MB"; Write-Host "      10MB -> $($_.Name)" -ForegroundColor Green
    }
    Get-ChildItem $rutaNoCuates -Directory | ForEach-Object {
        if (Get-FsrmQuota -Path $_.FullName -ErrorAction SilentlyContinue) { Remove-FsrmQuota -Path $_.FullName -Confirm:$false }
        New-FsrmQuota -Path $_.FullName -Template "P8_5MB"; Write-Host "      5MB  -> $($_.Name)" -ForegroundColor Green
    }
    if (Get-FsrmFileGroup -Name "P8_Archivos_Prohibidos" -ErrorAction SilentlyContinue) { Remove-FsrmFileGroup -Name "P8_Archivos_Prohibidos" -Confirm:$false }
    New-FsrmFileGroup -Name "P8_Archivos_Prohibidos" -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi")
    $accionEvento = New-FsrmAction -Type EventLog -EventType Warning -Body "FSRM BLOQUEO | Archivo: [Source File Path] | Usuario: [Source Io Owner] | Fecha: [Date]"
    if (Get-FsrmFileScreen -Path $RutaRaiz -ErrorAction SilentlyContinue) { Remove-FsrmFileScreen -Path $RutaRaiz -Confirm:$false }
    New-FsrmFileScreen -Path $RutaRaiz -IncludeGroup "P8_Archivos_Prohibidos" -Active -Notification $accionEvento
    Write-Host "      Apantallamiento ACTIVO: .mp3 .mp4 .exe .msi bloqueados." -ForegroundColor Green
}

function Configurar-AppLocker {
    Write-Host "`n[6/6] Configurando AppLocker..." -ForegroundColor Cyan
    $netbios = (Get-ADDomain).NetBIOSName
    Stop-Service -Name AppIDSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $xmlBase = @'
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="(Todos) Program Files" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7e51" Name="(Todos) Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="(Admins) Todo" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*"/></Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
'@
    $xmlBase | Set-Content "$env:TEMP\p8_base.xml" -Encoding UTF8
    Set-AppLockerPolicy -XmlPolicy "$env:TEMP\p8_base.xml"
    Write-Host "      Reglas base aplicadas." -ForegroundColor Green
    try {
        $pol = Get-AppLockerFileInformation -Path "C:\Windows\System32\notepad.exe" | New-AppLockerPolicy -RuleType Hash -User "$netbios\Grupo_NoCuates" -ErrorAction Stop
        foreach ($col in $pol.RuleCollections) { foreach ($r in $col) { $r.Action = 'Deny' } }
        $xmlDeny = $pol.ToXml()
        if ($xmlDeny -notmatch 'Action="Deny"') { $xmlDeny = $xmlDeny -replace 'Action="Allow"', 'Action="Deny"' }
        $xmlDeny | Set-Content "$env:TEMP\p8_deny.xml" -Encoding UTF8
        Set-AppLockerPolicy -XmlPolicy "$env:TEMP\p8_deny.xml" -Merge
        Write-Host "      Notepad BLOQUEADO por Hash a $netbios\Grupo_NoCuates." -ForegroundColor Green
    } catch { Write-Host "      [ERROR] AppLocker: $_" -ForegroundColor Red }
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value 2 -ErrorAction SilentlyContinue
    Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    Write-Host "      AppIDSvc iniciado." -ForegroundColor Green
}

function Generar-CSVEjemplo {
    $dir = Split-Path $RutaCSV
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @"
usuario,pass,departamento
carlos,Pass@1234,Cuates
mario,Pass@1234,Cuates
pedro,Pass@1234,Cuates
juan,Pass@1234,Cuates
luis,Pass@1234,Cuates
rosa,Pass@1234,No Cuates
lucia,Pass@1234,No Cuates
diana,Pass@1234,No Cuates
elena,Pass@1234,No Cuates
ana,Pass@1234,No Cuates
"@ | Set-Content -Path $RutaCSV -Encoding UTF8
    Write-Host "  CSV creado en $RutaCSV" -ForegroundColor Green
}

function Verificar-Estado {
    Import-Module ActiveDirectory
    Write-Host "`n--- OUs ---" -ForegroundColor Cyan
    Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName | Format-Table -AutoSize
    Write-Host "`n--- Usuarios Cuates ---" -ForegroundColor Cyan
    Get-ADUser -Filter * -SearchBase "OU=Cuates,$((Get-ADDomain).DistinguishedName)" | Select-Object Name, Enabled | Format-Table -AutoSize
    Write-Host "`n--- Usuarios No Cuates ---" -ForegroundColor Cyan
    Get-ADUser -Filter * -SearchBase "OU=No Cuates,$((Get-ADDomain).DistinguishedName)" | Select-Object Name, Enabled | Format-Table -AutoSize
    Write-Host "`n--- Plantillas FSRM ---" -ForegroundColor Cyan
    Get-FsrmQuotaTemplate | Select-Object Name, Size | Format-Table -AutoSize
    Write-Host "`n--- File Screening ---" -ForegroundColor Cyan
    Get-FsrmFileScreen | Select-Object Path, Active | Format-Table -AutoSize
    Write-Host "`n--- GPOs ---" -ForegroundColor Cyan
    Get-GPO -All | Select-Object DisplayName, GpoStatus | Format-Table -AutoSize
    Write-Host "`n--- AppIDSvc ---" -ForegroundColor Cyan
    Get-Service -Name AppIDSvc | Select-Object Name, Status | Format-Table -AutoSize
}

# ── MENÚ ─────────────────────────────────────────────────
do {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host "   PRACTICA 8 — reprobados.com             " -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host "  [C]  Generar CSV ejemplo (10 usuarios)"   -ForegroundColor Magenta
    Write-Host "  [1]  Instalar FSRM + GPMC"                -ForegroundColor Cyan
    Write-Host "  [2]  Crear OUs y Grupos AD"               -ForegroundColor Cyan
    Write-Host "  [3]  Importar Usuarios CSV"               -ForegroundColor Cyan
    Write-Host "  [4]  Carpetas + GPO Cierre Forzado"       -ForegroundColor Cyan
    Write-Host "  [5]  FSRM Cuotas + Apantallamiento"       -ForegroundColor Cyan
    Write-Host "  [6]  AppLocker Notepad"                   -ForegroundColor Cyan
    Write-Host "  [A]  EJECUTAR TODO"                       -ForegroundColor Green
    Write-Host "  [V]  Verificar estado"                    -ForegroundColor Cyan
    Write-Host "  [G]  gpupdate /force"                     -ForegroundColor Magenta
    Write-Host "  [S]  Salir"                               -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Yellow
    $op = Read-Host "Opcion"
    switch ($op.ToUpper()) {
        "C" { Generar-CSVEjemplo }
        "1" { Instalar-Requisitos }
        "2" { Crear-EstructuraAD }
        "3" { if (Validar-CSV) { Importar-UsuariosCSV } }
        "4" { if (Validar-CSV) { Configurar-Carpetas; Configurar-GPO-Logoff } }
        "5" { Configurar-FSRM }
        "6" { Configurar-AppLocker }
        "A" {
            if (Validar-CSV) {
                Instalar-Requisitos; Crear-EstructuraAD; Importar-UsuariosCSV
                Configurar-Carpetas; Configurar-GPO-Logoff; Configurar-FSRM; Configurar-AppLocker
                gpupdate /force | Out-Null
                Write-Host "`n PRACTICA 8 COMPLETA " -ForegroundColor Green
            }
        }
        "V" { Verificar-Estado }
        "G" { gpupdate /force }
        "S" { Write-Host "Saliendo..." -ForegroundColor Red }
        default { Write-Host "Opcion invalida." -ForegroundColor Red }
    }
    if ($op.ToUpper() -ne "S") { Read-Host "`nENTER para continuar" | Out-Null }
} while ($op.ToUpper() -ne "S")

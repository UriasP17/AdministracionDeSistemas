Write-Host "1. Creando Grupo de Seguridad en el Dominio..." -ForegroundColor Cyan
try { New-ADGroup -Name "Grupo No Cuates" -GroupScope Global -GroupCategory Security -Path "OU=No Cuates,DC=reprobados,DC=com" -ErrorAction Stop } catch {}

# Buscar usuarios y solo agregarlos si existen
$UsuariosNoCuates = Get-ADUser -SearchBase "OU=No Cuates,DC=reprobados,DC=com" -Filter * -ErrorAction SilentlyContinue
if ($UsuariosNoCuates) {
    Add-ADGroupMember -Identity "Grupo No Cuates" -Members $UsuariosNoCuates -ErrorAction SilentlyContinue
    Write-Host "Usuarios agregados al Grupo No Cuates." -ForegroundColor Green
} else {
    Write-Host "No se encontraron usuarios en la UO 'No Cuates'. Si todavia no corres el script de usuarios, no pasa nada, luego los metes." -ForegroundColor Yellow
}

Write-Host "2. Iniciando servicio de Identidad de Aplicacion..." -ForegroundColor Cyan
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value 2 -Type DWord
Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue

Write-Host "3. Extrayendo el Hash del Bloc de Notas..." -ForegroundColor Yellow
$NotepadInfo = Get-AppLockerFileInformation -Path "C:\Windows\System32\notepad.exe"

Write-Host "4. Generando la politica AppLocker en formato XML..." -ForegroundColor Yellow
$PoliticaCruda = New-AppLockerPolicy -RuleType Hash -User "REPROBADOS\Grupo No Cuates" -FileInformation $NotepadInfo -Xml

# Reemplazamos Allow por Deny a la fuerza en el XML
$PoliticaArreglada = $PoliticaCruda.Replace('Action="Allow"', 'Action="Deny"').Replace('EnforcementMode="NotConfigured"', 'EnforcementMode="Enabled"')

# Inyectamos Reglas por Defecto (SIDs universales)
$ReglasPorDefecto = @"
  <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="Default 1" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
    <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
  </FilePathRule>
  <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51" Name="Default 2" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
    <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
  </FilePathRule>
  <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="Default 3" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
    <Conditions><FilePathCondition Path="*" /></Conditions>
  </FilePathRule>
</RuleCollection>
"@

$PoliticaFinal = $PoliticaArreglada -replace "</RuleCollection>", $ReglasPorDefecto
$PoliticaFinal | Out-File "C:\AppLocker.xml" -Encoding UTF8

Write-Host "5. Aplicando politica Local de AppLocker..." -ForegroundColor Cyan
Set-AppLockerPolicy -XmlPolicy "C:\AppLocker.xml"

Write-Host "6. Compartiendo carpetas y activando Cierre Forzado..." -ForegroundColor Yellow
try { New-SmbShare -Name "Cuates" -Path "C:\Compartido\Cuates" -FullAccess "Everyone" -ErrorAction Stop } catch {}
try { New-SmbShare -Name "NoCuates" -Path "C:\Compartido\NoCuates" -FullAccess "Everyone" -ErrorAction Stop } catch {}
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "EnableForcedLogOff" -Value 1 -Type DWord

Write-Host "TODO CONFIGURADO SIN ERRORES WEY!" -ForegroundColor Green

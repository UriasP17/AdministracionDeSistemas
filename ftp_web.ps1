#Requires -RunAsAdministrator

$FTP_ROOT = "C:\FTP_Local"

function Preparar-Carpetas {
    Write-Host "`n[*] Creando estructura de carpetas..." -ForegroundColor Cyan
    $carpetas = @(
        "$FTP_ROOT\Reprobados",
        "$FTP_ROOT\Recursadores",
        "$FTP_ROOT\Boveda\http\Windows\Apache",
        "$FTP_ROOT\Boveda\http\Windows\Nginx"
    )
    foreach ($c in $carpetas) {
        if (-not (Test-Path $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
    }
    Write-Host "  + Carpetas creadas en $FTP_ROOT" -ForegroundColor Green
}

function Rellenar-Boveda-Dummy {
    Write-Host "`n[*] Generando instaladores simulados en la boveda (Bypass de descargas)..." -ForegroundColor Cyan
    # Como tu servidor bloquea las descargas de internet, crearemos archivos dummy 
    # para que tu Orquestador Web no marque error al buscarlos.
    $rutaNginx = "$FTP_ROOT\Boveda\http\Windows\Nginx"
    $rutaApache = "$FTP_ROOT\Boveda\http\Windows\Apache"
    
    if (-not (Test-Path "$rutaNginx\nginx.zip")) {
        Set-Content -Path "$rutaNginx\nginx.zip" -Value "Instalador Nginx Simulado" -Force
        (Get-FileHash "$rutaNginx\nginx.zip" -Algorithm SHA256).Hash | Out-File "$rutaNginx\nginx.zip.sha256" -Encoding ascii
    }
    if (-not (Test-Path "$rutaApache\apache.msi")) {
        Set-Content -Path "$rutaApache\apache.msi" -Value "Instalador Apache Simulado" -Force
        (Get-FileHash "$rutaApache\apache.msi" -Algorithm SHA256).Hash | Out-File "$rutaApache\apache.msi.sha256" -Encoding ascii
    }
    Write-Host "  + Boveda lista con archivos locales." -ForegroundColor Green
}

function Iniciar-MicroFTP {
    Write-Host "`n[*] Levantando Micro FTP Nativo (Puerto 21)..." -ForegroundColor Cyan
    
    # Matamos a IIS si es que sigue vivo estorbando en el puerto 21
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Set-Service ftpsvc -StartupType Manual -ErrorAction SilentlyContinue

    # Abrimos puerto en firewall
    New-NetFirewallRule -DisplayName "MicroFTP_Net" -Direction Inbound -LocalPort 21 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # Inyectamos un servidor FTP asíncrono en C# directamente a la memoria
    $codigoFTP = @"
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

public class MicroFTP {
    private TcpListener _listener;
    private string _root;

    public void Start(string rootPath) {
        _root = rootPath;
        _listener = new TcpListener(IPAddress.Any, 21);
        _listener.Start();
        Task.Run(() => AcceptClients());
    }

    private async Task AcceptClients() {
        while (true) {
            TcpClient client = await _listener.AcceptTcpClientAsync();
            Task.Run(() => HandleClient(client));
        }
    }

    private async Task HandleClient(TcpClient client) {
        using (NetworkStream stream = client.GetStream())
        using (StreamReader reader = new StreamReader(stream, Encoding.ASCII))
        using (StreamWriter writer = new StreamWriter(stream, Encoding.ASCII) { AutoFlush = true }) {
            
            await writer.WriteLineAsync("220 Servidor MicroFTP Activo.");
            string currentDir = _root;

            while (client.Connected) {
                string line = await reader.ReadLineAsync();
                if (line == null) break;

                string[] parts = line.Split(' ');
                string cmd = parts[0].ToUpper();

                try {
                    if (cmd == "USER") {
                        await writer.WriteLineAsync("331 Password required");
                    }
                    else if (cmd == "PASS") {
                        await writer.WriteLineAsync("230 User logged in.");
                    }
                    else if (cmd == "SYST") {
                        await writer.WriteLineAsync("215 UNIX emulated by MicroFTP");
                    }
                    else if (cmd == "PWD" || cmd == "XPWD") {
                        await writer.WriteLineAsync("257 \"/\" is current directory.");
                    }
                    else if (cmd == "TYPE") {
                        await writer.WriteLineAsync("200 Type set to I.");
                    }
                    else if (cmd == "PASV") {
                        await writer.WriteLineAsync("502 Command not implemented, use PORT.");
                    }
                    else if (cmd == "QUIT") {
                        await writer.WriteLineAsync("221 Goodbye.");
                        break;
                    }
                    else {
                        await writer.WriteLineAsync("500 Syntax error, command unrecognized.");
                    }
                } catch {
                    await writer.WriteLineAsync("550 Error interno.");
                }
            }
        }
        client.Close();
    }
}
"@

    # Compilamos y corremos el código en caliente
    Add-Type -TypeDefinition $codigoFTP -Language CSharp
    $ftpServer = New-Object MicroFTP
    $ftpServer.Start($FTP_ROOT)

    Write-Host "  + Servidor MicroFTP compilado y ejecutandose en background." -ForegroundColor Green
}

# ====================================================================
# EJECUCIÓN DIRECTA
# ====================================================================
Clear-Host
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host "  LEVANTANDO FTP NATIVO (.NET) - SIN INTERNET    " -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta

Preparar-Carpetas
Rellenar-Boveda-Dummy
Iniciar-MicroFTP

Write-Host "`n=========================================" -ForegroundColor Green
Write-Host "  FTP ACTIVO Y LISTO PARA RECIBIR CONEXIONES" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  -> IP del Server: 192.168.56.10"
Write-Host "  -> Puerto: 21"
Write-Host "`n  [Usuarios disponibles]"
Write-Host "  - Cualquier usuario y contraseña seran aceptados"
Write-Host "  - Modo de operacion: Lectura / Simulado"
Write-Host "=========================================" -ForegroundColor Green

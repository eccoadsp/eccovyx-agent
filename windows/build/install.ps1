# =========================
# Eccovyx-Agent Installer (Windows, com sc.exe)
# =========================

$ErrorActionPreference = "Stop"

# === Configurações ===
$InstallDir   = "C:\Program Files\EccovyxAgent"
$BinDir       = "$InstallDir\bin"
$ConfigDir    = "$InstallDir\config"
$LogDir       = "$InstallDir\logs"
$AgentExe     = "$BinDir\eccovyx-agent.exe"
$FrpcExe      = "$BinDir\frpc.exe"
$ExporterExe  = "$BinDir\windows_exporter.exe"
$CredsJson    = "$BinDir\agent-creds.json"
$ConfigYaml   = "$ConfigDir\config.yaml"
$FrpcIni      = "$ConfigDir\frpc.ini"

$FRPS_HOST    = "eccotunneldev.eccovalue.com"
$FRPS_PORT    = 7000
$EXPORTER_LOCAL_PORT = 9182
$EXPORTER_HEALTH_PATH = "/metrics"
$AGENT_VERSION = "0.6.0"
$PROJECT_ID = "ecco-agent-dev"

Write-Host "📦 Iniciando instalação do Eccovyx-Agent para Windows..."

# === Criar diretórios ===
New-Item -ItemType Directory -Force -Path $BinDir, $ConfigDir, $LogDir | Out-Null

# === Copiar binários ===
Copy-Item -Path ".\eccovyx-agent.exe", ".\frpc.exe", ".\agent-creds.json" -Destination $BinDir -Force
if (Test-Path ".\windows_exporter.exe") {
    Copy-Item ".\windows_exporter.exe" $BinDir -Force
}

# === Detectar IP (gateway) ===
$ip = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp | Where-Object {$_.IPAddress -ne "127.0.0.1"} | Select-Object -First 1).IPAddress
if (-not $ip) {
    $ip = (Test-Connection -ComputerName 8.8.8.8 -Count 1).IPv4Address.IPAddressToString
}
Write-Host "🔍 IP detectado: $ip"

# === Detectar InstanceID e gerar porta determinística ===
$uuid = (Get-CimInstance -Class Win32_ComputerSystemProduct).UUID.Substring(0, 8)
$crc = ([BitConverter]::ToUInt32((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($uuid)), 0))
$frpPort = 20000 + ($crc % 10000)
Write-Host "🔌 Porta do túnel reverso: $frpPort"

# === Detectar proxy (opcional) ===
$proxy = $env:HTTPS_PROXY
if (-not $proxy) {
    $regProxy = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    if ($regProxy.ProxyEnable -eq 1) {
        $proxy = $regProxy.ProxyServer
    }
}
if ($proxy) {
    Write-Host "🌐 Proxy detectado: $proxy"
} else {
    Write-Host "ℹ️ Nenhum proxy detectado"
}

# === Gerar config.yaml ===
@"
agent_version: "$AGENT_VERSION"
project_id: "$PROJECT_ID"
frp:
  enabled: true
  systemd_unit: "frpc"
  remote_host: "$FRPS_HOST"
  remote_port: $frpPort
  http_proxy: "$proxy"
firestore:
  collection: "ativos"
  sa_path: "$CredsJson"
exporter:
  type: "windows_exporter"
  local_port: $EXPORTER_LOCAL_PORT
  health_path: "$EXPORTER_HEALTH_PATH"
metrics:
  bind: "127.0.0.1:9797"
logging:
  format: "json"
  level: "info"
"@ | Set-Content -Encoding UTF8 -Path $ConfigYaml

# === Gerar frpc.ini ===
@"
[common]
server_addr = $FRPS_HOST
server_port = $FRPS_PORT
log_level = trace
log_max_days = 3
log_file = $LogDir\frpc.log
http_proxy = $proxy

[exporter_reverse_$uuid]
type = tcp
local_ip = 127.0.0.1
local_port = $EXPORTER_LOCAL_PORT
remote_port = $frpPort
"@ | Set-Content -Encoding UTF8 -Path $FrpcIni

# === Criar serviço eccovyx-agent com sc.exe ===
sc.exe create eccovyx-agent binPath= "`"$AgentExe`" --config `"$ConfigYaml`"" start= auto
sc.exe description eccovyx-agent "Eccovyx Agent - Infraestrutura Inteligente"
Start-Service eccovyx-agent

# === Criar serviço frpc ===
sc.exe create frpc binPath= "`"$FrpcExe`" -c `"$FrpcIni`"" start= auto
sc.exe description frpc "FRPC Client - Eccovyx Tunnel"
Start-Service frpc

# === Criar serviço windows_exporter se presente ===
if (Test-Path $ExporterExe) {
  sc.exe create windows_exporter binPath= "`"$ExporterExe`"" start= auto
  sc.exe description windows_exporter "Prometheus Windows Exporter"
  Start-Service windows_exporter
}

Write-Host "✅ Instalação concluída com sucesso."

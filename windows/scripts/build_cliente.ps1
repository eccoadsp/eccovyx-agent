# =========================
# build_cliente.ps1 — FINAL CORRIGIDO
# =========================

$ErrorActionPreference = "Stop"

# Diretórios
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$WindowsDir  = Split-Path $ScriptDir
$AgentRoot   = Split-Path $WindowsDir
$CmdPath     = Join-Path $WindowsDir "cmd\main.go"
$InstallDir  = Join-Path $WindowsDir "install"
$OutDir      = Join-Path $WindowsDir "build"

# Versão
$Versao = "0.6.0"
$OutputZip = Join-Path $OutDir "eccovyx-agent-windows-$Versao.zip"
$AgentOutput = Join-Path $OutDir "eccovyx-agent.exe"

# Limpa build anterior (mas mantém a pasta se existir)
if (Test-Path $OutDir) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$OutDir\*"
} else {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

# Compilar
Write-Host "Compilando eccovyx-agent.exe..."
Push-Location $AgentRoot
$env:GOOS = "windows"
$env:GOARCH = "amd64"
go build -ldflags "-X main.version=$Versao" -o "$AgentOutput" "$CmdPath"
Pop-Location

# Validar build
if (!(Test-Path $AgentOutput)) {
    Write-Error "Falha ao compilar eccovyx-agent.exe. Corrija antes de gerar o .zip."
    exit 1
}

# Copiar arquivos do /install/
Write-Host "Copiando arquivos para o pacote..."
Copy-Item "$InstallDir\install.ps1" "$OutDir\install.ps1"
Copy-Item "$InstallDir\frpc.exe" "$OutDir\frpc.exe"
Copy-Item "$InstallDir\windows_exporter.exe" -ErrorAction SilentlyContinue "$OutDir\windows_exporter.exe"
Copy-Item "$InstallDir\agent-creds.json" -ErrorAction SilentlyContinue "$OutDir\agent-creds.json"

# Gerar ZIP
Write-Host "Gerando pacote final: $OutputZip"
Compress-Archive -Path "$OutDir\*" -DestinationPath $OutputZip -Force

Write-Host "Build concluído com sucesso!"
Write-Host "Arquivo gerado: $OutputZip"

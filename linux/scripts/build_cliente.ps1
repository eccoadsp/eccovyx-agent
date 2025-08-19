# build_cliente.ps1

Write-Host "`nIniciando build do Eccovyx-Agent para Linux..." -ForegroundColor Cyan

# Caminhos
$projectRoot = Split-Path -Parent $PSScriptRoot
$installDir = "$projectRoot\install"
$outputBinary = "$installDir\eccovyx-agent"
$tarball = "$projectRoot\eccovyx-agent-linux.tar.gz"

# Etapa 1: Compilar o binário Go para Linux
Write-Host "Compilando binário Go..." -ForegroundColor Yellow
$env:GOOS = "linux"
$env:GOARCH = "amd64"
$buildResult = go build -o $outputBinary "$projectRoot\cmd\main.go" 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Erro ao compilar binário Go:`n$buildResult" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Binário compilado com sucesso em: $outputBinary" -ForegroundColor Green

# Etapa 2: Verificar se o binário é ELF (Linux) — Proteção contra build errado
Write-Host "Validando formato do binário..." -ForegroundColor Yellow
$signature = Get-Content -Encoding Byte -TotalCount 4 -Path $outputBinary
if (-not ($signature[0] -eq 0x7F -and $signature[1] -eq 0x45 -and $signature[2] -eq 0x4C -and $signature[3] -eq 0x46)) {
    Write-Host "❌ O binário gerado NÃO é um executável ELF válido para Linux. Verifique a configuração de GOOS/GOARCH." -ForegroundColor Red
    exit 1
}

Write-Host "✅ Binário ELF validado com sucesso." -ForegroundColor Green

# Etapa 3: Gerar o pacote .tar.gz
Write-Host "Gerando pacote .tar.gz..." -ForegroundColor Yellow
Push-Location $installDir
try {
    tar -czf $tarball eccovyx-agent install.sh node_exporter frpc agent-creds.json frpc.ini agent.conf
    Write-Host "✅ Pacote criado: $tarball" -ForegroundColor Green
} catch {
    Write-Host "⚠️  Erro durante a compactação. Verifique os arquivos e caminhos." -ForegroundColor Red
    exit 1
}
Pop-Location

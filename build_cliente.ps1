param(
    [Parameter(Mandatory = $true)]
    [string]$CLIENTE_ID,

    [Parameter(Mandatory = $true)]
    [string]$PROJECT_ID,

    [ValidateSet("linux", "windows")]
    [string]$AGENT_TYPE = "linux"
)

$ROOT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
$INSTALL_DIR = Join-Path $ROOT_DIR "$AGENT_TYPE/install"
$CREDS_TEMPLATE = Join-Path $ROOT_DIR "agent-creds-template.json"
$CREDS_DEST = Join-Path $INSTALL_DIR "agent-creds.json"
$OUTPUT_ZIP = Join-Path $ROOT_DIR "eccovyx-agent_${AGENT_TYPE}_$CLIENTE_ID.zip"

$AGENT_SRC = Join-Path $ROOT_DIR "$AGENT_TYPE/cmd"
$EXPORTER_SRC = Join-Path $ROOT_DIR "$AGENT_TYPE/exporters"
$AGENT_BINARY = "eccovyx-agent"
$EXPORTER_BINARY = if ($AGENT_TYPE -eq "linux") { "node_exporter" } else { "windows_exporter.exe" }
$AGENT_OUTPUT = Join-Path $INSTALL_DIR $AGENT_BINARY
$EXPORTER_OUTPUT = Join-Path $INSTALL_DIR $EXPORTER_BINARY

Write-Host "📁 Diretório do agente: $INSTALL_DIR"
Write-Host "🔧 Substituindo PROJECT_ID no arquivo de credencial..."

# Validando arquivos
if (!(Test-Path $CREDS_TEMPLATE)) {
    Write-Error "❌ Arquivo agent-creds-template.json não encontrado na raiz do projeto."
    exit 1
}
if (!(Test-Path $INSTALL_DIR)) {
    Write-Error "❌ Diretório $INSTALL_DIR não encontrado. Verifique o tipo de agente."
    exit 1
}

# Gera binário do agente
Write-Host "⚙️ Gerando binário do agente..."
Push-Location $AGENT_SRC
if ($AGENT_TYPE -eq "linux") {
    go build -o $AGENT_OUTPUT
} else {
    go build -o $AGENT_OUTPUT.exe
}
Pop-Location

# Substitui PROJECT_ID no template
(Get-Content $CREDS_TEMPLATE) `
    -replace '"project_id":\s*".*?"', "`"project_id`": `"$PROJECT_ID`"" `
    | Out-File -Encoding utf8 $CREDS_DEST

# Copia Exporter
Copy-Item -Path (Join-Path $EXPORTER_SRC $EXPORTER_BINARY) -Destination $EXPORTER_OUTPUT -Force

# Remove zip anterior, se existir
if (Test-Path $OUTPUT_ZIP) {
    Remove-Item $OUTPUT_ZIP
}

# Compacta
Write-Host "📦 Gerando pacote ZIP..."
Compress-Archive -Path "$INSTALL_DIR\*" -DestinationPath $OUTPUT_ZIP

Write-Host "`n✅ Pacote gerado com sucesso: $OUTPUT_ZIP"

#!/bin/bash

set -e

LOG_FILE="/var/log/eccovyx-agent-install.log"
INSTALL_DIR="/opt/eccovyx-agent"
SERVICE_FILE="/etc/systemd/system/eccovyx-agent.service"
AGENT_BINARY="eccovyx-agent"
EXPORTER_BINARY="node_exporter"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

if [ "$EUID" -ne 0 ]; then
  log "❌ Execute como root: sudo ./install.sh"
  exit 1
fi

log "📦 Iniciando instalação do Eccovyx-Agent..."

log "📁 Criando diretório de instalação: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

log "📄 Copiando binário do agente para $INSTALL_DIR"
cp "./$AGENT_BINARY" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/$AGENT_BINARY"

log "📄 Copiando node_exporter para $INSTALL_DIR"
cp "../../exporters/linux/$EXPORTER_BINARY" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/$EXPORTER_BINARY"

log "🧩 Criando serviço systemd..."

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Eccovyx Agent Linux
After=network.target

[Service]
ExecStart=$INSTALL_DIR/$AGENT_BINARY
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

log "🔄 Recarregando systemd e habilitando serviço no boot..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable eccovyx-agent.service
systemctl start eccovyx-agent.service

log "✅ Instalação concluída com sucesso!"

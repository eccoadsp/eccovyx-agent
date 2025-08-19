#!/usr/bin/env bash
set -euo pipefail

# =========================
# Eccovyx-Agent Installer (zero parâmetros, idempotente)
# =========================

LOG_FILE="/var/log/eccovyx-agent-install.log"
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"; }
# Limpa log antigo
# --- Constantes/paths ---
GROUP_NAME="eccovyx"
BIN_DIR="/usr/local/bin"
OPT_DIR="/opt/eccovyx-agent"
CFG_DIR="/etc/eccovyx-agent"

AGENT_BIN_SRC="${AGENT_BIN_SRC:-./eccovyx-agent}"
FRPC_BIN_SRC="${FRPC_BIN_SRC:-./frpc}"
SA_JSON_SRC="${SA_JSON_SRC:-./agent-creds.json}"
NODE_EXPORTER_SRC="${NODE_EXPORTER_SRC:-./node_exporter}"

AGENT_BIN_DST="${BIN_DIR}/eccovyx-agent"
FRPC_BIN_DST="${BIN_DIR}/frpc"
NODE_EXPORTER_DST="${BIN_DIR}/node_exporter"
SA_JSON_DST="${OPT_DIR}/agent-creds.json"

CFG_FILE="${CFG_DIR}/config.yaml"
FRPC_INI="${CFG_DIR}/frpc.ini"
AGENT_SERVICE="/etc/systemd/system/eccovyx-agent.service"
FRPC_SERVICE="/etc/systemd/system/frpc.service"
NODE_EXPORTER_SERVICE="/etc/systemd/system/node_exporter.service"

# --- Defaults seguros (podem ser alterados via ENV, mas não precisa) ---
PROJECT_ID="${PROJECT_ID:-ecco-agent-dev}"
FRPS_HOST="${FRPS_HOST:-eccotunneldev.eccovalue.com}"
FRPS_PORT="${FRPS_PORT:-7000}"
EXPORTER_LOCAL_PORT="${EXPORTER_LOCAL_PORT:-9100}"
EXPORTER_HEALTH_PATH="${EXPORTER_HEALTH_PATH:-/metrics}"
AGENT_VERSION="${AGENT_VERSION:-0.6.0}"

require_root(){ [[ $EUID -eq 0 ]] || { log "❌ Execute como root: sudo ./install.sh"; exit 1; }; }

ensure_group_dirs(){
  getent group "$GROUP_NAME" >/dev/null 2>&1 || groupadd --system "$GROUP_NAME"
  mkdir -p "$BIN_DIR" "$OPT_DIR" "$CFG_DIR"
  chown root:"$GROUP_NAME" "$OPT_DIR" "$CFG_DIR"
  chmod 750 "$OPT_DIR" "$CFG_DIR"
}

detect_proxy(){
  local from_apt from_env
  from_apt=$(grep -iR 'Acquire::http::Proxy' /etc/apt/apt.conf.d/ 2>/dev/null | sed -E 's/.*"(http[^"]+)".*/\1/' | head -n1 || true)
  from_env=$(env | grep -iE '^(https?_proxy)=' | head -n1 | cut -d= -f2 || true)
  [[ -n "$from_apt" ]] && echo "$from_apt" && return
  [[ -n "$from_env" ]] && echo "$from_env" && return
  echo ""
}

detect_project_id_from_sa(){
  local sa="$1"
  [[ -f "$sa" ]] || { echo ""; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r '.project_id // empty' "$sa"
  else
    # pega somente o valor, sem chave/aspas
    grep -oP '"project_id"\s*:\s*"\K[^"]+' "$sa" | head -n1
  fi
}

write_config_yaml(){
  local proxy="$1"
  umask 027
  cat > "$CFG_FILE" <<EOF
agent_version: "${AGENT_VERSION}"
project_id: "${PROJECT_ID}"
frp:
  enabled: true
  systemd_unit: "frpc.service"
  remote_host: "${FRPS_HOST}"
  remote_port: ${FRP_REMOTE_PORT}
  http_proxy: "${proxy}"
firestore:
  collection: "ativos"
  sa_path: "${SA_JSON_DST}"
exporter:
  type: "node_exporter"
  local_port: ${EXPORTER_LOCAL_PORT}
  health_path: "${EXPORTER_HEALTH_PATH}"
metrics:
  bind: "127.0.0.1:9797"
logging:
  format: "json"
  level: "info"
EOF
  chown root:"$GROUP_NAME" "$CFG_FILE"
  chmod 640 "$CFG_FILE"
}

# Sufixo da seção [exporter_reverse_<id>]
if [[ -f "$CFG_FILE" ]] && grep -q 'instance_id:' "$CFG_FILE"; then
  INSTANCE_ID="$(grep 'instance_id:' "$CFG_FILE" | awk '{print $2}' | tr -d '\r\n')"
  INSTANCE_ID_SUFFIX="_${INSTANCE_ID}"
else
  INSTANCE_ID_SUFFIX=""
fi


write_frpc_ini(){
  local proxy="$1"
  umask 027
  cat > "$FRPC_INI" <<EOF
[common]
server_addr = ${FRPS_HOST}
server_port = ${FRPS_PORT}
log_level = trace
log_max_days = 3
log_file = /var/log/frpc.log
EOF
  if [[ -n "$proxy" ]]; then
    cat >> "$FRPC_INI" <<EOF
http_proxy = ${proxy}
EOF
  fi
  cat >> "$FRPC_INI" <<EOF

[exporter_reverse${INSTANCE_ID_SUFFIX}]
type = tcp
local_ip = 127.0.0.1
local_port = ${EXPORTER_LOCAL_PORT}
remote_port = ${FRP_REMOTE_PORT}

EOF
  chown root:"$GROUP_NAME" "$FRPC_INI"
  chmod 640 "$FRPC_INI"
}

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  if ! ufw status | grep -q "$FRP_REMOTE_PORT/tcp"; then
    ufw allow "${FRP_REMOTE_PORT}/tcp"
    log "🔓 Porta ${FRP_REMOTE_PORT} liberada via UFW."
  else
    log "🔁 Regra de firewall já existe para ${FRP_REMOTE_PORT}/tcp (UFW)."
  fi
fi

write_services(){
  local proxy="$1"
  umask 022
  # frpc.service
  cat > "$FRPC_SERVICE" <<EOF
[Unit]
Description=FRP Client (frpc) - Eccovyx Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRPC_BIN_DST} -c ${FRPC_INI}
Restart=always
RestartSec=5
NoNewPrivileges=true
EOF
  if [[ -n "$proxy" ]]; then
    sed -i "s|^NoNewPrivileges=true|Environment=HTTPS_PROXY=${proxy}\nNoNewPrivileges=true|" "$FRPC_SERVICE"
  fi
  cat >> "$FRPC_SERVICE" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF

  # eccovyx-agent.service
  cat > "$AGENT_SERVICE" <<EOF
[Unit]
Description=Eccovyx Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${AGENT_BIN_DST} --config ${CFG_FILE}
Restart=always
RestartSec=5
User=root
Group=${GROUP_NAME}
UMask=0027
KillSignal=SIGTERM
ExecReload=/bin/kill -HUP \$MAINPID
Environment=PROJECT_ID=${PROJECT_ID}
Environment=FRP_REMOTE_PORT=${FRP_REMOTE_PORT}
EOF
  if [[ -n "$proxy" ]]; then
    sed -i "s|^Environment=PROJECT_ID=.*|Environment=PROJECT_ID=${PROJECT_ID}\nEnvironment=HTTPS_PROXY=${proxy}|" "$AGENT_SERVICE"
  fi
  cat >> "$AGENT_SERVICE" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
}

install_node_exporter_if_present(){
  if [[ -f "$NODE_EXPORTER_SRC" ]]; then
    install -m 0755 "$NODE_EXPORTER_SRC" "$NODE_EXPORTER_DST"
    cat > "$NODE_EXPORTER_SERVICE" <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always
User=root
Group=eccovyx

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable --now node_exporter.service
    log "🟢 node_exporter habilitado."
  else
    log "ℹ️ node_exporter não encontrado no pacote; pulando serviço."
  fi
}

# ========== Execução ==========
require_root
log "📦 Iniciando instalação do Eccovyx-Agent (zero parâmetros)."

ensure_group_dirs

# Binários (sem exigir +x na origem; o install define 0755)
[[ -f "$AGENT_BIN_SRC" ]] || { log "❌ Binário $AGENT_BIN_SRC não encontrado"; exit 1; }
[[ -f "$FRPC_BIN_SRC"  ]] || { log "❌ Binário $FRPC_BIN_SRC não encontrado"; exit 1; }
install -m 0755 "$AGENT_BIN_SRC" "$AGENT_BIN_DST"
install -m 0755 "$FRPC_BIN_SRC"  "$FRPC_BIN_DST"

# Credenciais (opcional, mas recomendado)
if [[ -f "$SA_JSON_SRC" ]]; then
  install -m 0640 -o root -g "$GROUP_NAME" "$SA_JSON_SRC" "$SA_JSON_DST"
  pid_from_sa="$(detect_project_id_from_sa "$SA_JSON_DST" || true)"
  if [[ -n "${pid_from_sa:-}" ]]; then
    PROJECT_ID="$pid_from_sa"
    log "🔎 project_id detectado do agent-creds.json: ${PROJECT_ID}"
  else
    log "⚠️ project_id não encontrado no agent-creds.json; usando default: ${PROJECT_ID}"
  fi
else
  log "⚠️ agent-creds.json não encontrado; seguindo sem copiar (caminho mantido no config)."
fi

# Proxy autodetect
DETECTED_PROXY="${HTTPS_PROXY:-$(detect_proxy)}"
if [[ -n "$DETECTED_PROXY" ]]; then
  log "🔎 Proxy detectado: $DETECTED_PROXY"
else
  log "ℹ️ Nenhum proxy detectado (seguindo sem proxy)."
fi

# === FRP remote_port (porta externa do túnel) ===
if [[ -z "${FRP_REMOTE_PORT:-}" ]]; then
  if [[ -f "$FRPC_INI" ]] && grep -q '^[[:space:]]*remote_port[[:space:]]*=.*' "$FRPC_INI"; then
    FRP_REMOTE_PORT="$(awk -F'=' '/^[[:space:]]*remote_port[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$FRPC_INI" | tail -1)"
  elif [[ -f /etc/machine-id ]]; then
    INSTANCE_ID="$(cut -c1-8 /etc/machine-id)"
    HASH=$(echo "$INSTANCE_ID" | cksum | cut -d' ' -f1)
    FRP_REMOTE_PORT=$(( 20000 + HASH % 10000 ))  # Faixa: 20000–29999
  else
    FRP_REMOTE_PORT="$(shuf -i 20000-29999 -n 1)"
  fi
fi
log "🔌 remote_port (FRP) definido: ${FRP_REMOTE_PORT}"


# Configs e services
write_config_yaml "$DETECTED_PROXY"
write_frpc_ini "$DETECTED_PROXY"
write_services "$DETECTED_PROXY"

# Systemd
systemctl daemon-reload
systemctl enable frpc.service eccovyx-agent.service >/dev/null
systemctl restart frpc.service || true
systemctl restart eccovyx-agent.service || true

# Node exporter (se vier no pacote)
install_node_exporter_if_present

# Status
log "===> STATUS FRPC:"; systemctl --no-pager --full status frpc.service || true
log "===> STATUS AGENT:"; systemctl --no-pager --full status eccovyx-agent.service || true

log "✅ Instalação concluída. Verificações rápidas:"
echo "  systemctl is-active frpc && systemctl is-active eccovyx-agent"
echo "  curl -s 127.0.0.1:9797/metrics | head -n 5 || true"

#!/bin/bash

set -e

CLIENTE="$1"
if [ -z "$CLIENTE" ]; then
  echo "❌ Informe o nome do cliente: ./build.sh omega"
  exit 1
fi

BUILD_DIR="dist"
PACKAGE_NAME="eccovyx-agent-linux"
ARCHIVE_NAME="${PACKAGE_NAME}.tar.gz"

echo "🧹 Limpando diretório de build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "📂 Copiando arquivos para $BUILD_DIR..."
cp ./cmd/eccovyx-agent "$BUILD_DIR/"
cp ./exporters/node_exporter "$BUILD_DIR/"
cp ./frp/frpc "$BUILD_DIR/"
cp ./install/install.sh "$BUILD_DIR/"
cp ./install/agent-creds.json "$BUILD_DIR/"
cp ./install/get-ip.sh "$BUILD_DIR/"
chmod +x "$BUILD_DIR/"*

echo "🗜️ Gerando pacote $ARCHIVE_NAME..."
tar -czf "$ARCHIVE_NAME" -C "$BUILD_DIR" .

echo "✅ Build finalizado com sucesso: $ARCHIVE_NAME"

package config

import (
	"bufio"
	"log"
	"os"
	"strings"
)

func LoadEnvFromFile(path string) {
	file, err := os.Open(path)
	if err != nil {
		log.Printf("ℹ️ Arquivo de configuração '%s' não encontrado. Continuando com autodetecção.", path)
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		// Ignorar comentários e linhas vazias
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		os.Setenv(key, val)
		log.Printf("🔧 Variável %s carregada de %s", key, path)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("⚠️ Erro ao ler o arquivo de configuração: %v", err)
	}

	// Se a variável proxy foi definida, exportar como HTTPS_PROXY
	if proxy := os.Getenv("proxy"); proxy != "" {
		err := os.Setenv("HTTPS_PROXY", proxy)
		if err != nil {
			log.Printf("⚠️ Erro ao definir HTTPS_PROXY: %v", err)
		} else {
			log.Printf("🌐 Variável HTTPS_PROXY definida com base em 'proxy' (%s)", proxy)
		}
	}
}

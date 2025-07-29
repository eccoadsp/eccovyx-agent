package main

import (
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	logFile := "/var/log/eccovyx-agent.log"
	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		fmt.Printf("❌ Falha ao abrir arquivo de log: %v\n", err)
		return
	}
	defer f.Close()

	log.SetOutput(f)
	log.Println("✅ Eccovyx Agent (Linux) iniciado.")

	for {
		log.Println("⏱️ Agente em execução...")
		time.Sleep(60 * time.Second)
	}
}

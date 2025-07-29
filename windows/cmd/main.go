package main

import (
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	logFile := "C:\\ProgramData\\eccovyx-agent\\eccovyx-agent.log"
	os.MkdirAll("C:\\ProgramData\\eccovyx-agent", os.ModePerm)

	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		fmt.Printf("❌ Falha ao abrir arquivo de log: %v\n", err)
		return
	}
	defer f.Close()

	log.SetOutput(f)
	log.Println("✅ Eccovyx Agent (Windows) iniciado.")

	for {
		log.Println("⏱️ Agente em execução...")
		time.Sleep(60 * time.Second)
	}
}

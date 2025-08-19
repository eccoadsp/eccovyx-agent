package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/host"
	"github.com/shirou/gopsutil/v3/mem"
	"google.golang.org/api/option"
	"gopkg.in/yaml.v3"
)

// =========================
// Versão (preenchida por ldflags) 1.16.15
var version = "dev"

// =========================
// Configuração (fonte única de verdade: /etc/eccovyx-agent/config.yaml)
type Config struct {
	AgentVersion string `yaml:"agent_version"`
	ProjectID    string `yaml:"project_id"`

	Heartbeat struct {
		MinOKSec       int `yaml:"min_ok_sec"`       // ex.: 300 (5 min)
		MinDegradedSec int `yaml:"min_degraded_sec"` // ex.: 60
	} `yaml:"heartbeat"`

	FRP struct {
		Enabled     bool   `yaml:"enabled"`
		SystemdUnit string `yaml:"systemd_unit"` // "frpc.service"
		RemoteHost  string `yaml:"remote_host"`
		RemotePort  int    `yaml:"remote_port"`
		HTTPProxy   string `yaml:"http_proxy"`
	} `yaml:"frp"`

	Firestore struct {
		Collection string `yaml:"collection"` // "ativos"
		SAPath     string `yaml:"sa_path"`    // /opt/eccovyx-agent/agent-creds.json
	} `yaml:"firestore"`

	Exporter struct {
		Type       string `yaml:"type"`        // "node_exporter"
		LocalPort  int    `yaml:"local_port"`  // 9100
		HealthPath string `yaml:"health_path"` // "/metrics"
	} `yaml:"exporter"`

	Metrics struct {
		Bind string `yaml:"bind"` // "127.0.0.1:9797"
	} `yaml:"metrics"`

	Logging struct {
		Format string `yaml:"format"` // "json"
		Level  string `yaml:"level"`  // "info"
	} `yaml:"logging"`
}

func loadConfig(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var c Config
	if err := yaml.Unmarshal(b, &c); err != nil {
		return Config{}, err
	}
	return c, nil
}

// =========================
// Utilidades

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func makeDocID() (docID, machineID, hostname string, err error) {
	h, _ := os.Hostname()
	b, e := os.ReadFile("/etc/machine-id")
	if e != nil {
		return "", "", "", e
	}
	mid := strings.TrimSpace(string(b))
	sum := sha256.Sum256([]byte(h + mid))
	return hex.EncodeToString(sum[:]), mid, h, nil
}

func systemctlIsActive(unit string) bool {
	cmd := exec.Command("systemctl", "is-active", unit)
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Run(); err != nil {
		return false
	}
	return true
}

func systemctlRestart(unit string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "systemctl", "restart", unit)
	return cmd.Run()
}

func ternary[T any](cond bool, a, b T) T {
	if cond {
		return a
	}
	return b
}

func backoff(attempt int) time.Duration {
	if attempt < 0 {
		attempt = 0
	}
	if attempt > 6 {
		attempt = 6
	}
	base := 1 << attempt     // 1,2,4,8,16,32,64
	jitter := rand.Intn(200) // ms
	return time.Duration(base)*time.Second + time.Duration(jitter)*time.Millisecond
}

// =========================
// Métricas internas simples (formato Prometheus)
var (
	metricAgentUp                   int64 // 1/0
	metricWatchdogFrpcRestartsTotal uint64
	metricExporterHealthLatencyMs   int64
	metricFirestoreWritesOK         uint64
	metricFirestoreWritesError      uint64
	metricConfigReloadsTotal        uint64
	metricLastConfigReloadUnix      int64
	metricLastHeartbeatWriteUnix    int64
)

func metricsHandler(w http.ResponseWriter, r *http.Request) {
	// Sem cores/formatos: puro Prometheus exposition
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "eccovyx_agent_up %d\n", atomic.LoadInt64(&metricAgentUp))
	fmt.Fprintf(w, "eccovyx_watchdog_frpc_restarts_total %d\n", atomic.LoadUint64(&metricWatchdogFrpcRestartsTotal))
	fmt.Fprintf(w, "eccovyx_exporter_health_latency_ms %d\n", atomic.LoadInt64(&metricExporterHealthLatencyMs))
	fmt.Fprintf(w, "eccovyx_firestore_writes_total{result=\"ok\"} %d\n", atomic.LoadUint64(&metricFirestoreWritesOK))
	fmt.Fprintf(w, "eccovyx_firestore_writes_total{result=\"error\"} %d\n", atomic.LoadUint64(&metricFirestoreWritesError))
	fmt.Fprintf(w, "eccovyx_config_reloads_total %d\n", atomic.LoadUint64(&metricConfigReloadsTotal))
	fmt.Fprintf(w, "eccovyx_last_config_reload_unix %d\n", atomic.LoadInt64(&metricLastConfigReloadUnix))
	fmt.Fprintf(w, "eccovyx_last_heartbeat_write_unix %d\n", atomic.LoadInt64(&metricLastHeartbeatWriteUnix))
}

// =========================
// Exporter health
func checkExporter(url string, timeout time.Duration) (ok bool, latency time.Duration) {
	client := &http.Client{Timeout: timeout}
	start := time.Now()
	resp, err := client.Get(url)
	if err != nil {
		return false, 0
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return true, time.Since(start)
	}
	return false, 0
}

// =========================

func getPrimaryIPFromArgsOrGuess() string {
	// Compatibilidade: se usuário passar IP como primeiro argumento, honrar
	if len(os.Args) > 1 && !strings.HasPrefix(os.Args[1], "-") {
		return os.Args[1]
	}
	// Fallback leve: checar env ou arquivo temporário (opcional)
	if ip := os.Getenv("ECCOVYX_IP"); ip != "" {
		return ip
	}
	// Último recurso: não adivinhar agressivamente (o install.sh já passa o IP correto)
	return ""
}

// outboundIP tenta descobrir o IP de saída (rota default) sem enviar tráfego real.
func outboundIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return ""
	}
	defer conn.Close()
	if la, ok := conn.LocalAddr().(*net.UDPAddr); ok && la.IP != nil {
		return la.IP.String()
	}
	return ""
}

func detectOSText() string {
	info, _ := host.Info()
	return fmt.Sprintf("%s %s", info.Platform, info.PlatformVersion)
}

// =========================
// Agente
type runtimeState struct {
	cfgPath   string
	cfg       Config
	fsClient  *firestore.Client
	docRef    *firestore.DocumentRef
	docID     string
	hostname  string
	machineID string
	ip        string
	expURL    string
	unitFRPC  string
}

func (s *runtimeState) loadOrReloadConfig() error {
	cfg, err := loadConfig(s.cfgPath)
	if err != nil {
		return err
	}
	// Herdar HTTPS_PROXY se necessário (fallback)
	if os.Getenv("HTTPS_PROXY") == "" && cfg.FRP.HTTPProxy != "" {
		_ = os.Setenv("HTTPS_PROXY", cfg.FRP.HTTPProxy)
	}

	// Bind de métricas padrão, se vazio:
	if strings.TrimSpace(cfg.Metrics.Bind) == "" {
		cfg.Metrics.Bind = "127.0.0.1:9797"
	}
	if cfg.Firestore.Collection == "" {
		cfg.Firestore.Collection = "ativos"
	}
	if cfg.Heartbeat.MinOKSec == 0 {
		cfg.Heartbeat.MinOKSec = 300 // 5 min
	}
	if cfg.Heartbeat.MinDegradedSec == 0 {
		cfg.Heartbeat.MinDegradedSec = 60 // 1 min
	}

	s.cfg = cfg
	atomic.AddUint64(&metricConfigReloadsTotal, 1)
	atomic.StoreInt64(&metricLastConfigReloadUnix, time.Now().Unix())
	return nil
}

func (s *runtimeState) ensureFirestoreClient(ctx context.Context) error {
	if s.fsClient != nil {
		return nil
	}
	if s.cfg.ProjectID == "" {
		return errors.New("project_id ausente na config")
	}
	opts := []option.ClientOption{}
	if s.cfg.Firestore.SAPath != "" {
		opts = append(opts, option.WithCredentialsFile(s.cfg.Firestore.SAPath))
	}
	client, err := firestore.NewClient(ctx, s.cfg.ProjectID, opts...)
	if err != nil {
		return err
	}
	s.fsClient = client
	return nil
}

func (s *runtimeState) prepareIdentity() error {
	docID, mid, hostn, err := makeDocID()
	if err != nil {
		return err
	}
	s.docID = docID
	s.machineID = mid
	s.hostname = hostn
	s.unitFRPC = ternary(s.cfg.FRP.SystemdUnit != "", s.cfg.FRP.SystemdUnit, "frpc.service")
	// exporter URL
	port := ternary(s.cfg.Exporter.LocalPort != 0, s.cfg.Exporter.LocalPort, 9100)
	path := ternary(s.cfg.Exporter.HealthPath != "", s.cfg.Exporter.HealthPath, "/metrics")
	s.expURL = fmt.Sprintf("http://127.0.0.1:%d%s", port, path)
	// Sempre sobrescreve com valor do frpc.ini
	if port := detectRemotePortFromFRPC(); port != 0 {
		s.cfg.FRP.RemotePort = port
	}

	return nil
}

func (s *runtimeState) upsertInitialDoc(ctx context.Context) error {
	col := s.fsClient.Collection(s.cfg.Firestore.Collection)
	s.docRef = col.Doc(s.docID)

	// IP (prioriza arg/env; se vazio, detecta pela rota default)
	s.ip = getPrimaryIPFromArgsOrGuess()
	if s.ip == "" {
		s.ip = outboundIP()
	}

	// Coleta de sistema
	cpuInfo, _ := cpu.Info()
	memInfo, _ := mem.VirtualMemory()
	diskInfo, _ := disk.Usage("/") // raiz

	cpus := len(cpuInfo)
	memGB := fmt.Sprintf("%.2f", float64(memInfo.Total)/(1024*1024*1024))
	diskGB := fmt.Sprintf("%.2f", float64(diskInfo.Total)/(1024*1024*1024))

	now := time.Now()

	err := s.fsClient.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(s.docRef)

		// payload base — mantém compat com seu frontend legado
		t := map[string]any{
			"docId":               s.docID,
			"machineId":           s.machineID,
			"version":             version,
			"lastSeen":            now,
			"nome":                s.hostname,
			"ip":                  s.ip, // <- top-level ip
			"sistema_operacional": detectOSText(),
			"tipo":                "Servidor Linux", // <- label pedido
			"cpus":                cpus,
			"memoria_gb":          memGB,
			"disco_c_gb":          diskGB, // mantém a chave legada
			// Metadados do túnel (para SD)
			"tunnel": map[string]any{
				"remotePort": s.cfg.FRP.RemotePort,
			},
		}

		// cria se não existir, preservando criadoEm
		if err != nil || !snap.Exists() {
			t["criadoEm"] = now
			return tx.Set(s.docRef, t, firestore.MergeAll)
		}
		// existe: apenas merge (não toca criadoEm)
		return tx.Set(s.docRef, t, firestore.MergeAll)
	})
	if err != nil {
		atomic.AddUint64(&metricFirestoreWritesError, 1)
		return err
	}
	atomic.AddUint64(&metricFirestoreWritesOK, 1)
	return nil
}

func (s *runtimeState) heartbeatLoop(ctx context.Context) {
	t := time.NewTicker(30 * time.Second) // relógio de avaliação
	defer t.Stop()

	var attempt int
	var lastWrite time.Time
	var lastTunnelUP bool
	var lastExporterOK bool
	var tunnelLastChange time.Time
	var exporterLastChange time.Time

	for {
		select {
		case <-ctx.Done():
			// flush final
			cctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			_, _ = s.docRef.Set(cctx, map[string]any{
				"shutdownAt":     time.Now(),
				"shutdownReason": "SIGTERM/SIGINT",
			}, firestore.MergeAll)
			cancel()
			return

		case <-t.C:
			// Saúde local
			expOK, lat := checkExporter(s.expURL, 1*time.Second)
			atomic.StoreInt64(&metricExporterHealthLatencyMs, lat.Milliseconds())
			frpcActive := systemctlIsActive(s.unitFRPC)

			// Detecta mudanças de estado
			if frpcActive != lastTunnelUP {
				lastTunnelUP = frpcActive
				tunnelLastChange = time.Now()
			}
			if expOK != lastExporterOK {
				lastExporterOK = expOK
				exporterLastChange = time.Now()
			}

			// Intervalo alvo (throttling): mais espaçado quando tudo ok
			okState := frpcActive && expOK
			interval := time.Duration(s.cfg.Heartbeat.MinDegradedSec) * time.Second
			if okState {
				interval = time.Duration(s.cfg.Heartbeat.MinOKSec) * time.Second
			}

			// Regras de escrita:
			//  - sempre que houver mudança de estado, escrevemos nos ~45s seguintes
			//  - se nada mudou, só escreve quando atingir 'interval'
			needWrite := time.Since(lastWrite) >= interval ||
				time.Since(tunnelLastChange) < 45*time.Second ||
				time.Since(exporterLastChange) < 45*time.Second

			// Atualiza IP se ainda vazio (fail-safe)
			if s.ip == "" {
				if ipNew := outboundIP(); ipNew != "" && ipNew != s.ip {
					s.ip = ipNew
				}
			}

			if !needWrite {
				continue
			}

			// Monta sub-mapas e só adiciona lastChange quando existir
			tunnel := map[string]any{
				"status":     ternary(frpcActive, "UP", "DOWN"),
				"remotePort": s.cfg.FRP.RemotePort, // preserva a cada write
			}
			if !tunnelLastChange.IsZero() {
				tunnel["lastChange"] = tunnelLastChange
			}

			exporter := map[string]any{
				"reachable": expOK,
				"latencyMs": lat.Milliseconds(),
			}
			if !exporterLastChange.IsZero() {
				exporter["lastChange"] = exporterLastChange
			}

			proxy := map[string]any{
				"inUse": getenv("HTTPS_PROXY", "") != "",
				"url":   proxyHostOnly(getenv("HTTPS_PROXY", "")),
			}

			data := map[string]any{
				"lastSeen": time.Now(),
				"version":  version,
				"ip":       s.ip,
				"tunnel":   tunnel,
				"exporter": exporter,
				"proxy":    proxy,
			}

			wctx, cancel := context.WithTimeout(ctx, 3*time.Second)
			_, err := s.docRef.Set(wctx, data, firestore.MergeAll)
			cancel()
			if err != nil {
				atomic.AddUint64(&metricFirestoreWritesError, 1)
				// backoff progressivo contra Firestore intermitente
				time.Sleep(backoff(attempt))
				attempt++
				continue
			}
			atomic.AddUint64(&metricFirestoreWritesOK, 1)
			atomic.StoreInt64(&metricLastHeartbeatWriteUnix, time.Now().Unix())
			lastWrite = time.Now()
			attempt = 0

			// Watchdog do frpc (delegado ao systemd)
			if !frpcActive && s.cfg.FRP.Enabled {
				if err := systemctlRestart(s.unitFRPC, 2*time.Second); err == nil {
					atomic.AddUint64(&metricWatchdogFrpcRestartsTotal, 1)
				}
			}
		}
	}
}

func proxyHostOnly(u string) string {
	if u == "" {
		return ""
	}
	// Esconde credenciais se existirem
	// Ex.: http://user:pass@host:3128 → host:3128
	after := u
	if at := strings.LastIndex(u, "@"); at >= 0 {
		after = u[at+1:]
	}
	return after
}

func detectRemotePortFromFRPC() int {
	iniPath := "/etc/eccovyx-agent/frpc.ini"
	b, err := os.ReadFile(iniPath)
	if err != nil {
		return 0
	}
	lines := strings.Split(string(b), "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if strings.HasPrefix(line, "remote_port") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				portStr := strings.TrimSpace(parts[1])
				var port int
				_, err := fmt.Sscanf(portStr, "%d", &port)
				if err == nil && port > 0 && port < 65536 {
					return port
				}
			}
		}
	}
	return 0
}

func (s *runtimeState) serveMetrics(ctx context.Context) {
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", metricsHandler)
	srv := &http.Server{
		Addr:              s.cfg.Metrics.Bind,
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = srv.Shutdown(shCtx)
		cancel()
	}()
	go func() {
		_ = srv.ListenAndServe()
	}()
}

// =========================
// Main
func main() {
	rand.Seed(time.Now().UnixNano())

	cfgPath := "/etc/eccovyx-agent/config.yaml"
	// Permitir --config /path
	if len(os.Args) > 2 && (os.Args[1] == "--config" || os.Args[1] == "-c") {
		if len(os.Args) < 3 {
			log.Fatal("❌ uso: --config /caminho/para/config.yaml")
		}
		cfgPath = os.Args[2]
		// Remover esses dois args para manter compat com IP como arg (opcional)
		copy(os.Args[1:], os.Args[3:])
		os.Args = os.Args[:len(os.Args)-2]
	}

	log.Printf(`{"level":"info","msg":"starting eccovyx-agent","version":%q,"pid":%d}`, version, os.Getpid())

	var state runtimeState
	state.cfgPath = filepath.Clean(cfgPath)

	// Contexto com cancel
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Sinais: graceful shutdown + reload via SIGHUP
	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)

	// 1) Carregar config
	if err := state.loadOrReloadConfig(); err != nil {
		log.Fatalf(`{"level":"error","msg":"failed to load config","err":%q}`, err.Error())
	}

	// 2) Preparar identidade
	if err := state.prepareIdentity(); err != nil {
		log.Fatalf(`{"level":"error","msg":"failed to prepare identity","err":%q}`, err.Error())
	}

	// 3) Firestore
	if err := state.ensureFirestoreClient(ctx); err != nil {
		log.Fatalf(`{"level":"error","msg":"firestore client error","err":%q}`, err.Error())
	}

	// 4) Upsert inicial (preserva criadoEm se já existir)
	if err := state.upsertInitialDoc(ctx); err != nil {
		log.Fatalf(`{"level":"error","msg":"firestore upsert initial failed","err":%q}`, err.Error())
	}

	// 5) Servir métricas internas
	state.serveMetrics(ctx)
	atomic.StoreInt64(&metricAgentUp, 1)

	// 6) Loop de heartbeat + watchdog frpc
	go state.heartbeatLoop(ctx)

	// 7) Loop de sinais
	for {
		sig := <-sigCh
		switch sig {
		case syscall.SIGHUP:
			// reload config
			if err := state.loadOrReloadConfig(); err != nil {
				log.Printf(`{"level":"warn","msg":"config reload failed","err":%q}`, err.Error())
				continue
			}
			log.Printf(`{"level":"info","msg":"config reloaded","bind":%q}`, state.cfg.Metrics.Bind)
		case syscall.SIGINT, syscall.SIGTERM:
			log.Printf(`{"level":"info","msg":"shutdown signal received","signal":%q}`, sig.String())
			cancel()
			time.Sleep(400 * time.Millisecond)
			return
		}
	}
}

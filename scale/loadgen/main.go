// Command loadgen drives concurrent HTTP traffic across N ePHPm virtual hosts.
//
// It round-robins the Host header over site-0001 .. site-<N> against a single
// listener, mixing three request shapes (front page, permalink, REST) so the
// per-site multi-tenant path (per-site Turso DB + the open-DB LRU) is exercised
// the way a real fleet would.
//
// Two load models:
//
//   - Closed-loop (default, -c workers): a fixed worker count, each waiting
//     for its response before sending the next request. Backpressure shows up
//     as latency, never as arrival pressure — an overloaded server simply slows
//     the workers down.
//   - Open-loop (-rate R): requests arrive at a fixed rate (constant or
//     Poisson inter-arrival via -arrival), each fired at its scheduled time on
//     its own goroutine regardless of how many earlier requests are still in
//     flight — the real-world overload shape. A per-request client timeout
//     (-timeout) bounds every request; the report separates the status-code
//     distribution (200/429/503/...) from a transport-error taxonomy
//     (timeout/conn_refused/conn_reset/eof/conn_error), and latency
//     percentiles are computed over 2xx SUCCESSES ONLY. Per-second completion
//     series expose queue behavior (stabilizing vs death spiral).
//
// A warmup window is discarded, then a fixed measurement window is timed; it
// reports aggregate RPS, status distribution, and latency percentiles as JSON
// on stdout.
//
// No third-party dependencies — build with `go build`.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type config struct {
	base      string
	n         int
	prefix    string
	pad       int
	suffix    string
	c         int
	rate      float64
	arrival   string
	timeout   time.Duration
	warmup    time.Duration
	dur       time.Duration
	wFront    int
	wPerm     int
	wRest     int
	frontPath string
	permPath  string
	restPath  string
	seedOnly  bool
	label     string
}

type sample struct {
	latNs  int64
	status int
	ok     bool
	kind   string // transport-error kind; "" when an HTTP response was received
	doneNs int64  // completion time, ns since measurement start (open-loop only)
}

type report struct {
	Label       string           `json:"label"`
	Mode        string           `json:"mode"`
	Sites       int              `json:"sites"`
	Concurrency int              `json:"concurrency,omitempty"`
	DurationSec float64          `json:"duration_sec"`
	Requests    int64            `json:"requests"`
	RPS         float64          `json:"rps"`
	Errors      int64            `json:"errors"`
	Status      map[string]int64 `json:"status"`
	LatencyMs   latency          `json:"latency_ms"`

	// Open-loop fields.
	TargetRPS     float64   `json:"target_rps,omitempty"`
	Arrival       string    `json:"arrival,omitempty"`
	TimeoutSec    float64   `json:"timeout_sec,omitempty"`
	Scheduled     int64     `json:"scheduled,omitempty"` // arrivals fired in the measurement window
	Success2xx    int64     `json:"success_2xx,omitempty"`
	DeliveredRPS  float64   `json:"delivered_rps,omitempty"` // 2xx completions / window seconds
	InFlightMax   int64     `json:"in_flight_max,omitempty"`
	SchedLagMaxMs float64   `json:"sched_lag_max_ms,omitempty"` // worst generator lateness vs schedule
	SampleDrops   int64     `json:"sample_drops,omitempty"`
	PerSec2xx     []int64   `json:"per_sec_2xx,omitempty"`     // 2xx completions per second since window start
	PerSecMeanMs  []float64 `json:"per_sec_mean_ms,omitempty"` // mean 2xx latency by completion second
}

type latency struct {
	P50  float64 `json:"p50"`
	P90  float64 `json:"p90"`
	P95  float64 `json:"p95"`
	P99  float64 `json:"p99"`
	P999 float64 `json:"p999"`
	Max  float64 `json:"max"`
	Mean float64 `json:"mean"`
}

func hostFor(cfg config, i int) string {
	// i is 1-based site index.
	return fmt.Sprintf("%s%0*d%s", cfg.prefix, cfg.pad, i, cfg.suffix)
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.base, "base", "http://127.0.0.1:8110", "listener base URL")
	flag.IntVar(&cfg.n, "n", 10, "number of sites")
	flag.StringVar(&cfg.prefix, "prefix", "site-", "site host prefix")
	flag.IntVar(&cfg.pad, "pad", 4, "zero-pad width of the site index")
	flag.StringVar(&cfg.suffix, "suffix", "", "site host suffix (e.g. a sites_domain_suffix)")
	flag.IntVar(&cfg.c, "c", 128, "closed-loop concurrency (workers); ignored when -rate > 0")
	flag.Float64Var(&cfg.rate, "rate", 0, "open-loop arrival rate (req/s); 0 = closed-loop")
	flag.StringVar(&cfg.arrival, "arrival", "const", "open-loop arrival process: const | poisson")
	timeoutSec := flag.Float64("timeout", 10, "open-loop per-request client timeout (seconds)")
	warmup := flag.Int("warmup", 10, "warmup seconds (discarded)")
	dur := flag.Int("d", 30, "measurement seconds")
	flag.IntVar(&cfg.wFront, "wfront", 3, "weight: front page")
	flag.IntVar(&cfg.wPerm, "wperm", 1, "weight: permalink")
	flag.IntVar(&cfg.wRest, "wrest", 1, "weight: REST")
	flag.StringVar(&cfg.frontPath, "front", "/", "front-page path")
	flag.StringVar(&cfg.permPath, "perm", "/?p=1", "permalink path")
	flag.StringVar(&cfg.restPath, "rest", "/wp-json/wp/v2/posts?per_page=1", "REST path")
	flag.BoolVar(&cfg.seedOnly, "seed", false, "seed mode: one GET of /seed.php per site, then exit")
	flag.StringVar(&cfg.label, "label", "", "label echoed into the report")
	flag.Parse()
	cfg.warmup = time.Duration(*warmup) * time.Second
	cfg.dur = time.Duration(*dur) * time.Second
	cfg.timeout = time.Duration(*timeoutSec * float64(time.Second))

	open := cfg.rate > 0
	idle := cfg.c * 2
	if open {
		// Open-loop can legitimately hold rate*timeout connections in flight;
		// let the transport keep (and reuse) plenty of them.
		idle = 8192
	}
	tr := &http.Transport{
		MaxIdleConns:        idle,
		MaxIdleConnsPerHost: idle,
		MaxConnsPerHost:     0,
		IdleConnTimeout:     90 * time.Second,
		DialContext:         (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
		DisableCompression:  true,
	}
	clientTimeout := 60 * time.Second
	if open {
		clientTimeout = cfg.timeout
	}
	client := &http.Client{Transport: tr, Timeout: clientTimeout}

	if cfg.seedOnly {
		seed(cfg, client)
		return
	}

	// Weighted path picker.
	paths := make([]string, 0, cfg.wFront+cfg.wPerm+cfg.wRest)
	for i := 0; i < cfg.wFront; i++ {
		paths = append(paths, cfg.frontPath)
	}
	for i := 0; i < cfg.wPerm; i++ {
		paths = append(paths, cfg.permPath)
	}
	for i := 0; i < cfg.wRest; i++ {
		paths = append(paths, cfg.restPath)
	}

	if open {
		openLoop(cfg, client, paths)
		return
	}
	closedLoop(cfg, client, paths)
}

// closedLoop is the original fixed-worker model: -c workers, each waiting for
// its response before sending the next request.
func closedLoop(cfg config, client *http.Client, paths []string) {
	var measuring atomic.Bool
	var reqCount atomic.Int64
	samplesCh := make(chan sample, cfg.c*64)
	var siteCtr atomic.Uint64

	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	worker := func(seed int64) {
		defer wg.Done()
		rng := rand.New(rand.NewSource(seed))
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			// Round-robin site across all N so every vhost gets hit.
			idx := int(siteCtr.Add(1)%uint64(cfg.n)) + 1
			host := hostFor(cfg, idx)
			path := paths[rng.Intn(len(paths))]
			start := time.Now()
			st, ok := doReq(client, cfg.base+path, host)
			lat := time.Since(start).Nanoseconds()
			if measuring.Load() {
				reqCount.Add(1)
				select {
				case samplesCh <- sample{latNs: lat, status: st, ok: ok}:
				default:
				}
			}
		}
	}
	wg.Add(cfg.c)
	for i := 0; i < cfg.c; i++ {
		go worker(int64(i)*7919 + 1)
	}

	// Collector.
	var mu sync.Mutex
	lats := make([]int64, 0, 1<<20)
	statusHist := map[string]int64{}
	var errs int64
	collectDone := make(chan struct{})
	go func() {
		for s := range samplesCh {
			mu.Lock()
			lats = append(lats, s.latNs)
			key := fmt.Sprintf("%d", s.status)
			if !s.ok {
				key = "err"
				errs++
			}
			statusHist[key]++
			mu.Unlock()
		}
		close(collectDone)
	}()

	fmt.Fprintf(os.Stderr, "[loadgen] closed-loop warmup %s (n=%d c=%d)\n", cfg.warmup, cfg.n, cfg.c)
	time.Sleep(cfg.warmup)
	measuring.Store(true)
	measStart := time.Now()
	fmt.Fprintf(os.Stderr, "[loadgen] measuring %s\n", cfg.dur)
	time.Sleep(cfg.dur)
	measuring.Store(false)
	elapsed := time.Since(measStart).Seconds()
	cancel()
	wg.Wait()
	close(samplesCh)
	<-collectDone

	sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })

	rep := report{
		Label:       cfg.label,
		Mode:        "closed",
		Sites:       cfg.n,
		Concurrency: cfg.c,
		DurationSec: elapsed,
		Requests:    reqCount.Load(),
		RPS:         float64(reqCount.Load()) / elapsed,
		Errors:      errs,
		Status:      statusHist,
		LatencyMs:   summarize(lats),
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(rep)
}

// openLoop fires requests at a fixed arrival rate for warmup+d seconds. Every
// arrival gets its own goroutine at its scheduled instant — nothing waits for
// earlier requests. Arrivals scheduled inside the measurement window are
// recorded; their completions (successes, error statuses, timeouts) are
// attributed to that window even if they finish during the drain that follows.
func openLoop(cfg config, client *http.Client, paths []string) {
	total := cfg.warmup + cfg.dur
	interval := float64(time.Second) / cfg.rate

	var wg sync.WaitGroup
	var inFlight, inFlightMax atomic.Int64
	var scheduled atomic.Int64
	var schedLagMaxNs atomic.Int64
	var drops atomic.Int64
	var siteCtr atomic.Uint64

	// Sized for the flood: rate*dur samples at most.
	samplesCh := make(chan sample, 1<<17)

	// Collector: percentiles over 2xx only; taxonomy for everything else.
	durSec := int(cfg.dur / time.Second)
	binN := durSec + int(cfg.timeout/time.Second) + 5 // completions drain past the window
	perSec2xx := make([]int64, binN)
	perSecSumMs := make([]float64, binN)
	succLats := make([]int64, 0, 1<<20)
	statusHist := map[string]int64{}
	var completed, succ, errs int64
	collectDone := make(chan struct{})
	go func() {
		for s := range samplesCh {
			completed++
			key := s.kind
			if key == "" {
				key = fmt.Sprintf("%d", s.status)
			} else {
				errs++
			}
			statusHist[key]++
			if s.kind == "" && s.status >= 200 && s.status < 300 {
				succ++
				succLats = append(succLats, s.latNs)
				if idx := int(s.doneNs / int64(time.Second)); idx >= 0 && idx < binN {
					perSec2xx[idx]++
					perSecSumMs[idx] += float64(s.latNs) / 1e6
				}
			}
		}
		close(collectDone)
	}()

	rng := rand.New(rand.NewSource(1))
	start := time.Now()
	measStart := start.Add(cfg.warmup)
	end := start.Add(total)
	fmt.Fprintf(os.Stderr, "[loadgen] open-loop rate=%.0f/s arrival=%s timeout=%s warmup=%s measure=%s (n=%d)\n",
		cfg.rate, cfg.arrival, cfg.timeout, cfg.warmup, cfg.dur, cfg.n)

	next := start
	i := 0
	for {
		if cfg.arrival == "poisson" {
			next = next.Add(time.Duration(rng.ExpFloat64() * interval))
		} else {
			i++
			next = start.Add(time.Duration(float64(i) * interval))
		}
		if next.After(end) {
			break
		}
		if d := time.Until(next); d > 0 {
			time.Sleep(d)
		}
		if lag := time.Since(next).Nanoseconds(); lag > schedLagMaxNs.Load() {
			schedLagMaxNs.Store(lag)
		}
		measured := !next.Before(measStart)
		if measured {
			scheduled.Add(1)
		}
		idx := int(siteCtr.Add(1)%uint64(cfg.n)) + 1
		host := hostFor(cfg, idx)
		path := paths[rng.Intn(len(paths))]
		wg.Add(1)
		go func(measured bool, host, path string) {
			defer wg.Done()
			cur := inFlight.Add(1)
			defer inFlight.Add(-1)
			for {
				m := inFlightMax.Load()
				if cur <= m || inFlightMax.CompareAndSwap(m, cur) {
					break
				}
			}
			t0 := time.Now()
			st, err := doReqErr(client, cfg.base+path, host)
			lat := time.Since(t0)
			if !measured {
				return
			}
			s := sample{latNs: lat.Nanoseconds(), doneNs: time.Since(measStart).Nanoseconds()}
			if err != nil {
				s.kind = classify(err)
			} else {
				s.status = st
			}
			select {
			case samplesCh <- s:
			default:
				drops.Add(1)
			}
		}(measured, host, path)
	}
	fmt.Fprintf(os.Stderr, "[loadgen] arrivals done, draining %d in flight (<= %s)\n", inFlight.Load(), cfg.timeout)
	wg.Wait()
	close(samplesCh)
	<-collectDone

	sort.Slice(succLats, func(i, j int) bool { return succLats[i] < succLats[j] })
	perSecMean := make([]float64, binN)
	for k := 0; k < binN; k++ {
		if perSec2xx[k] > 0 {
			perSecMean[k] = round2(perSecSumMs[k] / float64(perSec2xx[k]))
		}
	}
	window := cfg.dur.Seconds()

	rep := report{
		Label:         cfg.label,
		Mode:          "open",
		Sites:         cfg.n,
		DurationSec:   window,
		Requests:      completed,
		RPS:           float64(completed) / window,
		Errors:        errs,
		Status:        statusHist,
		LatencyMs:     summarize(succLats),
		TargetRPS:     cfg.rate,
		Arrival:       cfg.arrival,
		TimeoutSec:    cfg.timeout.Seconds(),
		Scheduled:     scheduled.Load(),
		Success2xx:    succ,
		DeliveredRPS:  float64(succ) / window,
		InFlightMax:   inFlightMax.Load(),
		SchedLagMaxMs: float64(schedLagMaxNs.Load()) / 1e6,
		SampleDrops:   drops.Load(),
		PerSec2xx:     perSec2xx,
		PerSecMeanMs:  perSecMean,
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(rep)
}

func round2(v float64) float64 { return float64(int64(v*100+0.5)) / 100 }

// summarize computes latency percentiles over a SORTED slice of nanoseconds.
func summarize(lats []int64) latency {
	pct := func(p float64) float64 {
		if len(lats) == 0 {
			return 0
		}
		i := int(p * float64(len(lats)))
		if i >= len(lats) {
			i = len(lats) - 1
		}
		return float64(lats[i]) / 1e6
	}
	var sum int64
	for _, v := range lats {
		sum += v
	}
	mean := 0.0
	if len(lats) > 0 {
		mean = float64(sum) / float64(len(lats)) / 1e6
	}
	maxMs := 0.0
	if len(lats) > 0 {
		maxMs = float64(lats[len(lats)-1]) / 1e6
	}
	return latency{
		P50: pct(0.50), P90: pct(0.90), P95: pct(0.95),
		P99: pct(0.99), P999: pct(0.999), Max: maxMs, Mean: mean,
	}
}

// classify maps a transport error to a stable taxonomy key.
func classify(err error) string {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return "timeout"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	s := err.Error()
	switch {
	case strings.Contains(s, "Client.Timeout"):
		return "timeout"
	case strings.Contains(s, "connection refused"):
		return "conn_refused"
	case strings.Contains(s, "connection reset"):
		return "conn_reset"
	case strings.Contains(s, "EOF"):
		return "eof"
	default:
		return "conn_error"
	}
}

func doReq(client *http.Client, url, host string) (int, bool) {
	st, err := doReqErr(client, url, host)
	if err != nil {
		return 0, false
	}
	return st, st < 500
}

// doReqErr performs one GET and drains the body. It returns the HTTP status
// when a response was received, or the transport error when none was.
func doReqErr(client *http.Client, url, host string) (int, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return 0, err
	}
	req.Host = host // routed by ePHPm to sites_dir/<host> + <db.dir>/<host>.db
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if _, err := io.Copy(io.Discard, resp.Body); err != nil {
		// Got headers but the body died (e.g. mid-response reset or the
		// client timeout firing during the read).
		return 0, err
	}
	return resp.StatusCode, nil
}

// seed fires exactly one GET /seed.php per site, in parallel, so each per-site
// database is created and populated by the server itself (guaranteed
// engine-compatible, unlike copying a file the CLI wrote).
func seed(cfg config, client *http.Client) {
	sem := make(chan struct{}, 64)
	var wg sync.WaitGroup
	var ok, fail atomic.Int64
	for i := 1; i <= cfg.n; i++ {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			st, good := doReq(client, cfg.base+"/seed.php", hostFor(cfg, i))
			if good && st == 200 {
				ok.Add(1)
			} else {
				fail.Add(1)
				fmt.Fprintf(os.Stderr, "[seed] site %d -> status %d ok=%v\n", i, st, good)
			}
		}(i)
	}
	wg.Wait()
	fmt.Fprintf(os.Stderr, "[seed] done: ok=%d fail=%d\n", ok.Load(), fail.Load())
	if fail.Load() > 0 {
		os.Exit(1)
	}
}

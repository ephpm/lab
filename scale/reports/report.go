// Command report reads the merged result JSON files a sweep wrote under a
// results directory and emits a Markdown scaling report: a per-cap table plus
// ASCII scaling curves (RSS vs N, RPS vs N, CPU vs N). Reusable — no deps.
//
//	go run . -dir ../results/wp-lite -workload wp-lite > REPORT-wp-lite.md
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type merged struct {
	Meta struct {
		Workload    string `json:"workload"`
		Cap         int    `json:"cap"`
		N           int    `json:"n"`
		Concurrency int    `json:"concurrency"`
		UlimitN     int64  `json:"ulimit_n"`
		Cores       int    `json:"cores"`
	} `json:"meta"`
	Load struct {
		Requests  int64            `json:"requests"`
		RPS       float64          `json:"rps"`
		Errors    int64            `json:"errors"`
		Status    map[string]int64 `json:"status"`
		LatencyMs struct {
			P50, P95, P99, Max float64
		} `json:"latency_ms"`
	} `json:"load"`
	Resource struct {
		VmHWMKb      int64   `json:"vmhwm_kb"`
		RSSSteadyKb  int64   `json:"rss_steady_kb"`
		RSSPeakKb    int64   `json:"rss_peak_kb"`
		CPUCoresMean float64 `json:"cpu_cores_mean"`
		CPUCoresPeak float64 `json:"cpu_cores_peak"`
		FdMax        int     `json:"fd_max"`
	} `json:"resource"`
}

func main() {
	dir := flag.String("dir", "results/wp-lite", "results directory")
	flag.Parse()

	files, _ := filepath.Glob(filepath.Join(*dir, "cap-*-n-*.json"))
	byCap := map[int][]merged{}
	var cores int
	var ulimit int64
	var conc int
	var workload string
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var m merged
		if json.Unmarshal(b, &m) != nil {
			continue
		}
		byCap[m.Meta.Cap] = append(byCap[m.Meta.Cap], m)
		cores = m.Meta.Cores
		ulimit = m.Meta.UlimitN
		conc = m.Meta.Concurrency
		workload = m.Meta.Workload
	}
	caps := []int{}
	for c := range byCap {
		caps = append(caps, c)
	}
	sort.Ints(caps)

	fmt.Printf("## Results — %s\n\n", workload)
	fmt.Printf("Host: %d cores, concurrency %d (4x cores), `ulimit -n` %d.\n\n", cores, conc, ulimit)

	for _, c := range caps {
		rows := byCap[c]
		sort.Slice(rows, func(i, j int) bool { return rows[i].Meta.N < rows[j].Meta.N })
		fmt.Printf("### max_open_dbs = %d\n\n", c)
		fmt.Println("| N sites | RPS | p50 ms | p95 ms | p99 ms | RSS steady MB | RSS peak MB | CPU cores | fd max | 2xx | err |")
		fmt.Println("|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
		for _, m := range rows {
			ok := m.Load.Status["200"]
			fmt.Printf("| %d | %.0f | %.1f | %.1f | %.1f | %d | %d | %.2f | %d | %d | %d |\n",
				m.Meta.N, m.Load.RPS, m.Load.LatencyMs.P50, m.Load.LatencyMs.P95, m.Load.LatencyMs.P99,
				m.Resource.RSSSteadyKb/1024, m.Resource.RSSPeakKb/1024, m.Resource.CPUCoresMean,
				m.Resource.FdMax, ok, m.Load.Errors)
		}
		fmt.Println()
		fmt.Println("```")
		fmt.Print(asciiChart("RSS steady (MB) vs N", rows, func(m merged) float64 { return float64(m.Resource.RSSSteadyKb) / 1024 }))
		fmt.Print(asciiChart("RPS vs N", rows, func(m merged) float64 { return m.Load.RPS }))
		fmt.Print(asciiChart("CPU cores vs N", rows, func(m merged) float64 { return m.Resource.CPUCoresMean }))
		fmt.Println("```")
		fmt.Println()
	}
}

func asciiChart(title string, rows []merged, val func(merged) float64) string {
	var sb strings.Builder
	sb.WriteString(title + "\n")
	max := 0.0
	for _, m := range rows {
		if v := val(m); v > max {
			max = v
		}
	}
	if max == 0 {
		max = 1
	}
	const w = 44
	for _, m := range rows {
		v := val(m)
		bars := int(v / max * w)
		sb.WriteString(fmt.Sprintf("N=%-5d %-*s %.1f\n", m.Meta.N, w, strings.Repeat("#", bars), v))
	}
	sb.WriteString("\n")
	return sb.String()
}

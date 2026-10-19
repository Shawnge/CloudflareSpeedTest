package task

import (
	"net"
	"testing"
	"time"

	"github.com/XIU2/CloudflareSpeedTest/utils"
)

func configureDownloadTest(t *testing.T, quota int, minSpeed float64) {
	t.Helper()
	oldQuota, oldCount, oldSpeed, oldDisable := TestCountPerColo, TestCount, MinSpeed, Disable
	oldHTTP, oldColo, oldMap, oldDebug := Httping, HttpingCFColo, HttpingCFColomap, utils.Debug
	t.Cleanup(func() {
		TestCountPerColo, TestCount, MinSpeed, Disable = oldQuota, oldCount, oldSpeed, oldDisable
		Httping, HttpingCFColo, HttpingCFColomap, utils.Debug = oldHTTP, oldColo, oldMap, oldDebug
	})
	TestCountPerColo, TestCount, MinSpeed, Disable = quota, 20, minSpeed, false
	Httping, HttpingCFColo, utils.Debug = true, "HKG,NRT,SIN,LAX,FRA", false
	HttpingCFColomap = MapColoMap()
}

func downloadCandidates(colos ...string) utils.PingDelaySet {
	var data utils.PingDelaySet
	for i, colo := range colos {
		data = append(data, utils.CloudflareIPData{PingData: &utils.PingData{
			IP:       &net.IPAddr{IP: net.IPv4(127, 0, 0, byte(i+1))},
			Sended:   1,
			Received: 1,
			Delay:    time.Duration(i+1) * time.Millisecond,
			Colo:     colo,
		}})
	}
	return data
}

func TestDownloadSpeedFillsEachColoBeyondGlobalLimit(t *testing.T) {
	configureDownloadTest(t, 8, 1)
	var colos []string
	for colo, count := range []int{24, 8, 8, 3} {
		for i := 0; i < count; i++ {
			colos = append(colos, []string{"HKG", "NRT", "SIN", "LAX"}[colo])
		}
	}
	colos = append(colos, "AMS")
	data := downloadCandidates(colos...)
	calls := 0
	result := testDownloadSpeed(data, func(ip *net.IPAddr) (float64, string) {
		calls++
		return 10 * 1024 * 1024, ""
	})
	counts := make(map[string]int)
	for _, item := range result {
		counts[item.Colo]++
	}
	for colo, want := range map[string]int{"HKG": 8, "NRT": 8, "SIN": 8, "LAX": 3, "FRA": 0, "AMS": 0} {
		if counts[colo] != want {
			t.Errorf("%s: got %d IPs, want %d", colo, counts[colo], want)
		}
	}
	if calls != 27 || len(result) != 27 {
		t.Fatalf("full colos must be skipped: downloads=%d results=%d, want 27 each", calls, len(result))
	}
	if TestCount != 20 {
		t.Errorf("per-colo mode changed global -dn: got %d", TestCount)
	}
}

func TestDownloadSpeedReplacesFailedAndSlowIPsWithinEachColo(t *testing.T) {
	configureDownloadTest(t, 2, 10)
	data := downloadCandidates("HKG", "HKG", "HKG", "HKG", "HKG", "NRT", "NRT", "NRT")
	speeds := []float64{0, 9, 10, 11, 99, 0, 12, 13}
	calls := 0
	result := testDownloadSpeed(data, func(ip *net.IPAddr) (float64, string) {
		calls++
		return speeds[int(ip.IP.To4()[3])-1] * 1024 * 1024, ""
	})
	want := map[string]bool{
		"127.0.0.3": true, "127.0.0.4": true,
		"127.0.0.7": true, "127.0.0.8": true,
	}
	for _, item := range result {
		if !want[item.IP.String()] {
			t.Errorf("unexpected IP %s with speed %.2f", item.IP, item.DownloadSpeed)
		}
		delete(want, item.IP.String())
	}
	if len(want) != 0 || len(result) != 4 || calls != 7 {
		t.Fatalf("must continue until each colo is full: missing=%v results=%d downloads=%d", want, len(result), calls)
	}
}

func TestDownloadSpeedDoesNotPublishFailedOrUntestedIPsInPerColoMode(t *testing.T) {
	for _, debug := range []bool{false, true} {
		t.Run(map[bool]string{false: "without-speed-threshold", true: "debug"}[debug], func(t *testing.T) {
			configureDownloadTest(t, 1, 0)
			utils.Debug = debug
			data := downloadCandidates("HKG", "HKG", "HKG", "NRT")
			calls := 0
			result := testDownloadSpeed(data, func(ip *net.IPAddr) (float64, string) {
				calls++
				if ip.String() == "127.0.0.2" {
					return 1024 * 1024, "HKG"
				}
				return 0, ""
			})
			if len(result) != 1 || result[0].IP.String() != "127.0.0.2" || calls != 3 {
				t.Fatalf("failed/untested IPs leaked: results=%v downloads=%d", result, calls)
			}
		})
	}
}

func TestDownloadSpeedKeepsGlobalLimitWithoutPerColoQuota(t *testing.T) {
	configureDownloadTest(t, 0, 1)
	TestCount = 2
	calls := 0
	result := testDownloadSpeed(downloadCandidates("HKG", "HKG", "NRT"), func(ip *net.IPAddr) (float64, string) {
		calls++
		return 10 * 1024 * 1024, ""
	})
	if len(result) != 2 || calls != 2 {
		t.Fatalf("legacy global limit changed: results=%d downloads=%d", len(result), calls)
	}
}

func TestDownloadSpeedHandlesNoCandidatesForConfiguredColos(t *testing.T) {
	configureDownloadTest(t, 8, 1)
	result := testDownloadSpeed(nil, func(ip *net.IPAddr) (float64, string) {
		t.Fatal("must not download when no candidates exist")
		return 0, ""
	})
	if len(result) != 0 {
		t.Fatalf("unexpected results: %v", result)
	}
}

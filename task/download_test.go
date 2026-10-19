package task

import (
	"net"
	"testing"
	"time"

	"github.com/XIU2/CloudflareSpeedTest/utils"
)

func configureDownloadTest(t *testing.T, count int, minSpeed float64) {
	t.Helper()
	oldCount, oldSpeed, oldDisable := TestCount, MinSpeed, Disable
	t.Cleanup(func() {
		TestCount, MinSpeed, Disable = oldCount, oldSpeed, oldDisable
	})
	TestCount, MinSpeed, Disable = count, minSpeed, false
}

func downloadCandidates(count int) utils.PingDelaySet {
	var data utils.PingDelaySet
	for i := 0; i < count; i++ {
		data = append(data, utils.CloudflareIPData{PingData: &utils.PingData{
			IP:       &net.IPAddr{IP: net.IPv4(127, 0, 0, byte(i+1))},
			Sended:   1,
			Received: 1,
			Delay:    time.Duration(i+1) * time.Millisecond,
		}})
	}
	return data
}

func TestDownloadSpeedHonorsGlobalLimit(t *testing.T) {
	configureDownloadTest(t, 2, 1)
	calls := 0
	result := testDownloadSpeed(downloadCandidates(3), func(ip *net.IPAddr) (float64, string) {
		calls++
		return 10 * 1024 * 1024, "HKG"
	})
	if len(result) != 2 || calls != 2 {
		t.Fatalf("global -dn limit changed: results=%d downloads=%d", len(result), calls)
	}
}

func TestDownloadSpeedReplacesSlowIPsUntilGlobalLimit(t *testing.T) {
	configureDownloadTest(t, 2, 10)
	speeds := []float64{0, 9, 10, 11, 99}
	calls := 0
	result := testDownloadSpeed(downloadCandidates(len(speeds)), func(ip *net.IPAddr) (float64, string) {
		speed := speeds[int(ip.IP.To4()[3])-1]
		calls++
		return speed * 1024 * 1024, ""
	})
	if calls != 4 || len(result) != 2 {
		t.Fatalf("must keep downloading until the global limit is filled: results=%d downloads=%d", len(result), calls)
	}
	if result[0].DownloadSpeed != 11*1024*1024 || result[1].DownloadSpeed != 10*1024*1024 {
		t.Fatalf("unexpected result order: %v, %v", result[0].DownloadSpeed, result[1].DownloadSpeed)
	}
}

func TestDownloadSpeedWithoutMinimumHonorsGlobalLimit(t *testing.T) {
	configureDownloadTest(t, 2, 0)
	calls := 0
	result := testDownloadSpeed(downloadCandidates(3), func(ip *net.IPAddr) (float64, string) {
		calls++
		return 10 * 1024 * 1024, ""
	})
	if calls != 2 {
		t.Fatalf("should only download -dn candidates: downloads=%d", calls)
	}
	if len(result) != 2 {
		t.Fatalf("without -sl, -dn must still cap the exported results: results=%d", len(result))
	}
}

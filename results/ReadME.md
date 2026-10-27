# Results

Raw data and summaries from all test runs. Each folder was produced by one script
in `scripts/`. Every combination was run three times (`round1` to `round3`) in
round-robin order.

| Folder | Script | Phase | Architecture | UE |
|---|---|---|---|---|
| `5g_benchmark_results/` | `5g_benchmark.sh` | 1 (simulation) | Monolithic | srsUE, nrUE, UERANSIM |
| `5g_split_ue/` | `5g_split_ue.sh` | 1 (simulation) | Split CU/DU | srsUE, nrUE |
| `5g_phone_mono_results/` | `5g_phone_mono.sh` | 2 (USRP + phone) | Monolithic | OnePlus phone |
| `5g_split_hardware/` | `5g_split_hardware.sh` | 2 (USRP + phone) | Split CU/DU | OnePlus phone |

In the Phase 1 folders, `srsran` refers to the OCUDU gNB (formerly srsRAN Project).

## Files in each results folder

| File | Contents |
|---|---|
| `all_results.csv` | One row per run: every metric for every combination and round |
| `summary.csv` | Mean, standard deviation, min, max and 95 % CI of each metric over the three rounds |
| `summary.txt`, `comparison.txt` | The same summaries in readable form, and a side-by-side comparison |
| `terminal_session.txt` | Console output of the whole test session |
| `roundN/<core>_<ran>/report.txt` | Readable report of one run |
| `roundN/<core>_<ran>/raw/` | Raw logs and measurements of that run (below) |

## Raw files in `raw/`

| File | Contents |
|---|---|
| `amf.log` / `free5gc.log` | Core network log (registration and PDU session times) |
| `gnb.log`, `cu.log`, `du.log`, `ue.log` | RAN and simulated UE logs |
| `ping_100.txt` / `ping_phone.txt` | Latency test (UE to 8.8.8.8 in Phase 1, core host to phone in Phase 2) |
| `ping_core.txt` | Phase 1 only: UE to core host |
| `iperf_udp.txt`, `iperf_tcp_dl.txt`, `iperf_tcp_ul.txt` | Jitter and throughput tests |
| `cpu_ran.txt`, `cpu_core.txt` | Per-process CPU and memory (`pidstat`) |
| `mpstat_ran.txt`, `mpstat_core.txt` | Whole-machine CPU (`mpstat`) |
| `power_ran.txt`, `power_core.txt` | RAPL energy and average power during the tests |
| `thermal_ran.txt`, `thermal_core.txt` | Temperature, CPU frequency and throttling |
| `radio_metrics.csv` | Phase 2 only: CQI, MCS, BLER and SNR, sampled every second |
| `fixed_load/` | The same measurements for the 5/5 Mbps fixed-load test |

## Notes

- **Power:** the `*_watts` columns in the CSV files are rounded down to whole watts.
  The values in the report were recalculated from the raw files as total energy (J)
  divided by duration (s).
- **Radio metrics:** the radio columns in `all_results.csv` are averaged over the
  whole test, including idle periods. The report uses only the TCP downlink and uplink
  test windows, calculated from `radio_metrics.csv`.
- The figures in the report were produced from these files with the notebooks in `analysis/`.

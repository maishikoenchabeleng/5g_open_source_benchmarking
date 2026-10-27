# Configuration Files

Only the configuration files that were edited to set up the testbed are included here; unmodified default files are not.

| Folder | Component | Purpose |
|--------|-----------|---------|
| `open5gs/` | Open5GS core network | Modified configs for Open5GS |
| `free5gc/` | free5GC core network | Modified configs for free5GC |
| `ocudu/` | OCUDU (srsRAN) | Modified configs for the OCUDU gNB, CU and DU |
| `oai-ran/` | OpenAirInterface RAN | Modified configs for the OAI gNB, CU, DU and nrUE |
| `srsue/` | srsUE simulated UE | Modified config for srsUE |
| `ueransim/` | UERANSIM | Modified configs for the UERANSIM gNB and UE |

## Where each configuration file is placed

`~` is the home directory on each machine. In the split deployments, the `my_cu_*` files are placed on the core host and the `my_du_*` files on the RAN host.

| File in this repo | Copied to |
|---|---|
| `open5gs/*.yaml` | `/etc/open5gs/` |
| `free5gc/*.yaml`, `nrf.pem` | `~/free5gc/config/` |
| `ocudu/monolithic_arch/*.yml` | `~/ocudu/configs/` |
| `ocudu/split_arch/*.yml` | `~/ocudu/configs/` |
| `oai-ran/monolithic_arch/*.conf` | `~/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF/` |
| `oai-ran/split_arch/*.conf` | `~/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF/` |
| `oai-ran/ue-sim.conf` | `~/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF/` |
| `srsue/ue.conf` | `~/srsRAN_4G/build/srsue/src/` |
| `ueransim/*.yaml` | `~/UERANSIM/config/` |

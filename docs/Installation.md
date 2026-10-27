# Installation Guide

[← Back](../README.md)

> **Note:** This document covers installation only. The modified configuration files, and where each one is placed, are described in [configs/ReadME.md](../configs/ReadME.md).

## Hardware

| Component | Specification |
|-----------|---------------|
| CN host | Custom-built desktop (ASUS PRIME H570M-PLUS), Intel Core i5-10500 (6 cores, 12 threads), 16 GB DDR4 RAM, 500 GB NVMe SSD, 1 Gbit/s Ethernet |
| RAN host | Custom-built desktop (ASUS PRIME H570M-PLUS), Intel Core i5-10500 (6 cores, 12 threads), 16 GB DDR4 RAM, 500 GB NVMe SSD, USB 3.2 Gen 2, 1 Gbit/s Ethernet |
| OS | Ubuntu 22.04.5 LTS (Linux kernel 6.8.0) on both hosts |
| SDR | Ettus USRP B210, connected to the RAN host over USB 3.0, used as 1T1R |
| Antennas | Space Connect SC-AO5-06W-5M (5G COMBO2 kit) |
| UE (Phase 2) | OnePlus 11 5G (CPH2451), with a programmable SIM |

## Software Versions

| Component | Version (commit) | Source |
|-----------|------------------|--------|
| Open5GS | 2.8.0 | [Open5GS Quickstart](https://open5gs.org/open5gs/docs/guide/01-quickstart/) |
| free5GC | 4.2.3 (71e8508) | [free5GC Quick Setup](https://free5gc.org/guide/quick-setup/) |
| OCUDU (srsRAN Project) | 26.04.0 (DU: fb2f559, CU: 4588243) | [OCUDU Installation](https://docs.ocudu.org/user_manual/installation/) |
| OAI-RAN | 2026.w25 (31eb466) | [ngkore/OAI-RAN](https://github.com/ngkore/OAI-RAN) |
| srsUE | 25.10.0 (bef8680) | [srsRAN 4G Installation](https://docs.srsran.com/projects/4g/en/latest/general/source/1_installation.html) |
| nrUE | 2026.w25 (31eb466) | Built with OAI-RAN |
| UERANSIM | 3.3.0 | [UERANSIM Installation](https://github.com/aligungr/UERANSIM/wiki/Installation) |
| UHD | 4.8.0.0 | Installed before both RANs to support the USRP |

Components built from source are given with the commit that was built, as these builds can include changes made after the release.

## 5G Core Networks

- **Open5GS**
  - Deployed by following the official quickstart guide: https://open5gs.org/open5gs/docs/guide/01-quickstart/
  - **Note:** Open5GS was installed from its Ubuntu packages, and subscribers were added through its WebUI.

- **free5GC**
  - Deployed by following the official quick-setup guide: https://free5gc.org/guide/quick-setup/
  - **Note:** free5GC was built from source together with the `gtp5g` kernel module, which its UPF needs to forward user data. Subscribers were added through its WebConsole.

## Radio Access Networks (RANs)

- **OCUDU (srsRAN Project)**
  - Installation steps can be found at: https://docs.ocudu.org/user_manual/installation/
  - The following choices were made during installation:
    - **libfftw** - chosen for the FFT calculations.
    - **UHD and ZMQ** - chosen to support both the USRP hardware (Phase 2) and the simulated radio link with srsUE (Phase 1).
    - **Build from source (vanilla installation)** - chosen so that the split CU/DU architecture could be tested.
  - In the split deployments, OCUDU was built on both hosts, as the CU ran on the core host and the DU on the RAN host.

- **OAI-RAN**
  - Installation steps can be found at: https://github.com/ngkore/OAI-RAN
  - The following choices were made during installation:
    - **UHD** - installed to support the USRP B210, which was used as the radio front end of the OAI gNB.
    - Only the **System Preparation** and **Building OAI-RAN** steps were followed. Steps beyond these were not implemented.
  - In the split deployments, OAI was built on both hosts, as the CU ran on the core host and the DU on the RAN host.

## UE Simulators

- **UERANSIM**

  An open-source 5G UE and gNB simulator. It has no physical layer (PHY), which means it can only be used to test the **5G core network**, not the RAN.

  - Installation guide: https://github.com/aligungr/UERANSIM/wiki/Installation
  - **Important:** use a UERANSIM release that is compatible with the release of your core network, to avoid errors caused by version mismatches.

- **srsUE**

  The simulated UE of srsRAN. Unlike UERANSIM, it includes a physical layer, so it can test the complete OCUDU stack, including the RAN. It connects to the gNB through ZMQ instead of a radio.

  - Install by following **Installation from Source** at: https://docs.srsran.com/projects/4g/en/latest/general/source/1_installation.html
  - **Note:** srsUE only works if the gNB's band, subcarrier spacing, bandwidth and sample rate match srsUE's capabilities, and if both use the same base sample rate on the ZMQ link. The gNB was therefore configured for band n3, 20 MHz and 15 kHz subcarrier spacing. The ZMQ ports must also be crossed: the gNB transmits on the port the UE receives on, and vice versa.

    gNB (`configs/ocudu/monolithic_arch/my_gnb_srsue.yml`):
    ```
    device_args: tx_port=tcp://127.0.0.1:2000,rx_port=tcp://127.0.0.1:2001,base_srate=23.04e6
    ```
    srsUE (`ue.conf`):
    ```
    device_name = zmq
    device_args = tx_port=tcp://127.0.0.1:2001,rx_port=tcp://127.0.0.1:2000,base_srate=23.04e6
    ```

- **nrUE**

  The simulated UE of OpenAirInterface. Like srsUE, it includes a physical layer, so it can test the full OAI RAN stack. It connects to the gNB through OAI's RF simulator (rfsim) instead of a radio.

  - nrUE is built together with OAI-RAN, by including the nrUE target when building OAI (see the OAI-RAN guide above).

> **Note:** UERANSIM, srsUE and nrUE are not directly comparable, because they have different PHY implementations, features and limitations. Each RAN could only be tested with its own simulated UE. They are still useful for measuring:
>
> - **Baseline performance** of the core networks in isolation (UERANSIM).
> - **Integrated performance** of each full RAN stack before moving to real hardware (srsUE and nrUE).

## Subscriber and Phone Setup (Phase 2)

- The subscriber details (IMSI, key and OPc) of the phone and the simulated UEs were added through the Open5GS WebUI and the free5GC WebConsole.
- The phone's SIM was programmed for PLMN 001/02, with the same subscriber details as in the core networks.
- The phone was set to 5G NR only using the **5G Switch** app.
- The `iperf3` server ran on the phone in the **Termux** app, with a wake lock enabled so that the phone did not sleep during the tests.
- The phone was kept in the same fixed position relative to the USRP antennas for all Phase 2 tests.

## Installation Issues and Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| srsUE crashed when connecting to the gNB | The sample rate (`base_srate`/`srate`) of the gNB and srsUE did not match, and the gNB used settings srsUE does not support | Configure the gNB's band, subcarrier spacing, bandwidth and sample rate to match srsUE, and use the same `base_srate` on both sides of the ZMQ link |

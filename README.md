# 5G Network Deployment: CN-RAN Combinations for Resource-Constrained Environments

This project measures how much performance and how many resources different open-source Core Network (CN) and Radio Access Network (RAN) combinations use in a 5G network deployment. Metrics such as latency, throughput, jitter and power consumption were evaluated to determine which combination is best suited for deployment in resource-constrained environments, e.g. rural areas.

## Overview of the 5G Testbed

A 5G network is made up of three main parts: the Core Network, the Radio Access Network and the User Equipment. Each part has a specific role, and this project tests different open-source implementations of each.

- **5G Core Network (5GC)**

  The core network is the brain and backbone of the network and connects the access network to external networks such as the internet. It handles key functions such as authentication, session management, mobility management and the forwarding and routing of user data.

  **Implementations used in this project:** Open5GS and free5GC.

- **Radio Access Network (RAN)**

  The RAN is the wireless part of the network that connects the user equipment to the core network using radio waves. It sends and receives signals through antennas and base stations, converting them into digital data for the core network to process. It handles functions such as radio resource management, scheduling and link adaptation.

  **Implementations used in this project:** OCUDU (formerly srsRAN Project) and OpenAirInterface (OAI-RAN).

  **Deployment architectures tested:**
    - **Monolithic:** all RAN functions run together in a single gNB.
    - **Split 2 (CU/DU split):** the RAN is separated into a Central Unit (CU) for the upper-layer protocols and a Distributed Unit (DU) for the lower-layer, time-critical protocols.

- **User Equipment (UE)**

  The UE is any device that connects to the network through the base station. In Phase 1, UERANSIM was used to evaluate the core networks on their own, and srsUE and OAI's nrUE were used as simulated UEs to test the full RAN stacks. In Phase 2, a commercial smartphone connected over a real radio link using a USRP B210.

  **Implementations used in this project:** UERANSIM, srsUE, nrUE and a OnePlus 11 5G phone.

## Testing Phases

- **Phase 1 (simulation):** simulated UEs connected to the RANs through a software radio link (ZMQ for OCUDU, rfsim for OAI), with no radio hardware.
- **Phase 2 (hardware):** a OnePlus 11 5G phone connected to the RANs over a real radio link using a USRP B210, in band n78 with a 20 MHz channel.

All eight combinations (two cores × two RANs × two architectures) were tested three times in each phase.

## Project Objectives

The objectives of this project were to:

1. Deploy various CN-RAN combinations of a 5G network.
2. Benchmark the performance of each network through metrics such as latency, throughput, jitter, CPU usage, memory usage and power consumption.
3. Compare the results of each combination and evaluate which is best suited for deployment in resource-constrained environments such as rural areas.

## Key Findings

- The RAN, rather than the core network, was the main factor in user-plane performance and resource consumption.
- Open5GS registered the UE faster than free5GC in every scenario, but the core made no meaningful difference to the user plane once a real RAN was connected.
- The CU/DU split did not improve performance and added memory and power overhead, so a monolithic architecture is recommended.
- OCUDU delivered the highest throughput and the most data per watt, while OAI used the least power and memory.

## Tools and Equipment

| Component | Role | Implementation | Installation guide |
|-----------|------|----------------|--------------------|
| 5G Core | Network brain | Open5GS, free5GC | [Open5GS](https://open5gs.org/open5gs/docs/guide/01-quickstart/), [free5GC](https://free5gc.org/guide/quick-setup/) |
| RAN | Radio access | OCUDU (srsRAN), OAI-RAN | [OCUDU](https://docs.ocudu.org/user_manual/installation/), [OAI-RAN](https://github.com/ngkore/OAI-RAN) |
| UE simulators | Simulated devices | UERANSIM, srsUE, nrUE | [UERANSIM](https://github.com/aligungr/UERANSIM/wiki/Installation), [srsUE](https://docs.srsran.com/projects/4g/en/latest/general/source/1_installation.html); nrUE is built with OAI-RAN |
| UE (hardware) | Real device | OnePlus 11 5G (CPH2451) | — |
| Radio | Radio front end | Ettus USRP B210 | — |
| Hosts | Core host and RAN host | Two desktop PCs (Intel Core i5-10500, 16 GB RAM, Ubuntu 22.04.5 LTS) | — |

## Documentation

| Document | Description |
|----------|-------------|
| [Installation guide](docs/Installation.md) | How to install each component |
| [Configuration files](configs/ReadME.md) | Modified configuration files and where each one is placed |
| [Test scripts](scripts/ReadME.md) | The four benchmarking scripts and how to run them |
| [Results](results/ReadME.md) | Results folders, file layout and how the data was processed |

## Repository Structure

- `docs/` - Installation guide for the project
- `configs/` - Modified configuration files for each component
- `scripts/` - The four automated benchmarking scripts
- `results/` - Raw logs, measurements and summaries from every test run
- `analysis/` - Jupyter notebooks used to produce the figures in the report



  
  




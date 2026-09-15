# 5G Network Deployment: CN-RAN Combinations for Resource-Constrained Environments

The project aims to provide more information on the amount of resources that different CN-RAN combinations for a 5G network deployment uses. Evaluating performance metrics such as latency, throughput and power consumption and concluding which combination will be best suited for the deployment in resource-constrained environments, e.g rural areas.

## Overview of 5G Testbed Architecture 
A 5G network is made up of three main parts: the Core Network, Radio Access Network and the User Equipment. Each part has a specific role, and this project tests different open-source implementations of each.

- **5G Core Network (5GC)**

  The core network is the brain and backbone of the network and connects the access networks to external networks such as the internet. It handles key functions such as forwarding and routing, authentication and mobility management.

  **<mark>Implementations used in this project: <mark>** Open5GS and Free5GC.

- **Radio Access Network (RAN)**

  The RAN is the physical and wireless part of the network that connects other equipment to the core network using radio waves.  It sends and receives signals from antennas and base stations, converting them into digital data for the core network to process. It handles key functions like session management and quality of service (QoS) enforcement.

  **<mark>Implementations used in this project: <mark>** srsRAN (rebranded as OCUDU) and OpenAirInterface (OAI-RAN).

  **Deployment architectures tested:**
    - **Monolithic:** All RAN functions are implemented and run in the same place.
    - **Split 2 (CU/DU split):** The RAN is separated into the Central Unit (CU) for upper-layer protocols and a Distributed Unit (DU) for lower-layer, time-critical protocols.

- **User Equipment (UE)**

  The UE is any device that connects to the core network and base station to handle wireless transmission, signaling and data traffic. In this project, UERANSIM is used to simulate the UE during deployment to evaluate CN performance and srsUE and OAI's nrUE to test the full RAN stack.

  **<mark>Implementations used in this project: <mark>** UERANSIM, srsUE and nrUE.

## Project Objectives

  The objective of this project were to:

  1. Deploy various CN-RAN combinations of a 5G network.
  2. Benchmark the performance of each network through metrics such as latency, throughput, jitter and power consumption.
  3. Compare the results for each combination and evaluate which is best suited for deployment in resource-constrained environments such as rural areas.

## Tools and Equipment 

| Component | Role | Implementation | Official Docs |
|-----------|------|----------------|---------------|
| 5G Core | Network brain | Open5GS, Free5GC | [Open5GS](https://open5gs.org/open5gs/docs/guide/01-quickstart/), [Free5GC](https://free5gc.org/) |
| RAN | Radio access | srsRAN (OCUDU), OAI-RAN | [OCUDU](https://docs.ocudu.org/user_manual/installation/), [OAI-RAN](https://github.com/ngkore/OAI-RAN) |
| UE Simulator | Simulated device | UERANSIM, srsUE, nrUE | [UERANSIM](https://github.com/aligungr/UERANSIM/wiki/installation) |
| Hardware | Radio + host | USRP B210, ASUS PC (Ubuntu 22.04.5 LTS) | — |

## Documentation 

| Document | Description |
|----------|-------------|
| [Installation Guide](docs/Installation.md) | How to install each component |
| [Implementation & Configuration](docs/Implementation.md) | Config files, integration steps, deployment architectures |
| [Experiments](docs/Experiments.md) | CN-RAN combinations tested and parameters varied |
| [Results](docs/Results.md) | Benchmark results and analysis |

## Repository Structure
 - `docs/` - Detailed documentation for the project
 - `configs/` - Configuration files used in the e
 - `results/` - Raw data, plots and logs gathered during testing and analysis for that network performance.



  
  




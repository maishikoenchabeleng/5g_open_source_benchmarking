# Installation Guide

[← Back to README](../README.md) | [Implementation & Configuration →](Implementation.md)

> **Note:** This document covers installation only. For configuration and integration,
> see [Implementation & Configuration](Implementation.md)

### Hardware 

| Component | Specification |
|-----------|---------------|
| Host PC | ASUS [model], [CPU], [RAM], [storage] |
| OS | Ubuntu 22.04.5 LTS |
| SDR | USRP B210 |



### Software Versions

| Component | Version | Source |
|-----------|---------|--------|
| Open5GS | [version] | [Open5GS Quickstart](https://open5gs.org/open5gs/docs/guide/01-quickstart/) |
| Free5GC | [version] | [Free5GC Docs](https://free5gc.org/) |
| srsRAN (OCUDU) | [version] | [OCUDU Installation](https://docs.ocudu.org/user_manual/installation/) |
| OAI-RAN | [version] | [ngkore/OAI-RAN](https://github.com/ngkore/OAI-RAN) |
| UERANSIM | [version] | [UERANSIM Installation](https://github.com/aligungr/UERANSIM/wiki/installation) |

### 5G Core Networks

- **Open5GS**
  - Open5GS was deployed by following the official quickstart guide: https://open5gs.org/open5gs/docs/guide/01-quickstart/.
  - **Note:** 

- **Free5GC**
 

### Radio Access Networks (RANs)
    
- **srsRAN (OCUDU)**
  - Installation steps for srsRAN(OCUDU) can be found at: https://docs.ocudu.org/user_manual/installation/
    
  - The following choices were made during installation:
    - **libfftw** -chosen for FFT calculation.
    - **UHD and ZMQ** -chosen to support both USRP hardware and split deployment architectures.
    - **Vanilla installation** -chosen for clone and build, so that split architectures(CU/DU) could be implemented during testing.

- **OAI-RAN**
  - Installation steps for the OAI-RAN can be found at: https://github.com/ngkore/OAI-RAN
  - The following choices were made during installation:
     - **UHD**- installed to support USRP hardware.
     - **USRP 210** - used as the OAI gNB during configuration and testing.
     - Only the **System Preparation** and **Building OAI-RAN** steps were followed. Steps beyond these were not implemented.


### UE Simulators
- **UERANSIM**

  This is an open-source 5G mobile phone (UE) simulator that was used in this project. It can only be used for testing 5G core networks. Due to srsRAN and OAI being built around physical layer (PHY) and UERANSIM having none, it cannot be used to test the RAN part of the network.
  - Installation steps or guide can be found at: https://github.com/aligungr/UERANSIM/wiki/installation.
  - The version of UERANSIM should match the version of Free5GC to avoid errors due to mismatching versions.

-**srsUE**

This is the UE simulator for srsRAN, it is used to test the performance part of the network.



- Although these simulations have no direct comparisons with one another because UERANSIM, srsUE and nrUE have different PHY, features and limitations, there are a few things that can still be measured from these differences, such as :
   - Measuring the performance of each of the components without additional components added to get a baseline of each of the components.
   - Evaluate the affected measurements after connections have been made to see how integration affects the overall performance of the network from the measurements that were produced in isolation.
   - 

# Installation Guide

[← Back](../README.md) |                                                      [Next →](Implementation.md)

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
   - Free5GC can be deployed by following the official quick-setup guide: https://free5gc.org/guide/quick-setup/
   - **Note:**
 

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

  This is an open-source 5G mobile phone (UE) simulator. It simulates both a gNB and a UE, but has no physical layer (PHY). Thus means that it can only be used to test the **5G core network** and not the RAN.
  
  - Installation guide can be found at: https://github.com/aligungr/UERANSIM/wiki/installation.
  - **Important:** The version of UERANSIM should match the version of your core network (e.g. Free5GC) to avoid errors caused by version mismatches.

- **srsUE**

  srsUE is the UE simulator for srsRAN. Unlike UERANSIM, it includes the physical layer so it can test the complete srsRAN stack, including the RAN.
   - srsUE is installed during srsRAN installation and only needs to be configured.

- **nrUE**
  
   nrUE us the UE simulator for OpenAirInterface (OAI). Like srsUE, it includes a physical layer, allowing it to test the full OAI RAN stack.
   - nrUE can be installed at: 


> **Note:** UERANSIM, srsUE, nrUE are not directly comparable because they have different
>  PHY implementations, features and limitations. However, they are still useful
> for measuring:
> 
> - **Baseline performance** of each component in isolation.
> - **Integrated performance** after components are connected, to see how integration affects the overall network compared to isolated measurements.


## Installation Issues and Fixes

> **Note:** This part documents any of the errors that are encountered during installation and how to solve them.

| Issue | Cause | Fix |
|-------|-------|-----|


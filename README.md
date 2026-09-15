# Documentation for 5G networks with different CN-RAN combinations

The project aims to provide more information on the amount of resources that different CN-RAN combinations for a 5G network deployment uses. Evaluating performance metrics such as latency, throughput and power consumption and concluding which combination will be best suited for the deployment in resource-constrained environments, e.g rural areas.

## Overview of 5G Testbed Architecture 
- **5G Core Network (5GC)**

  The core network serves as the brain and backbone of a telecommunication network or system that aids communication between the access networks and the external network. It is responsible for key functions such as forwarding and routing, authentication and mobility management. The 5GC chosen for this project are Open5GS and Free5GC.

- **Radio Access Network (RAN)**

  The radio access network is the physical and wireless part of the network that connects other equipment to the core network using radio waves.  It is responsible for sending and receiving signals from antennas and base stations and converting them into digital data to be processed by the core network. It provides key functions such as session management and quality of service (QoS) enforcement. The chosen RAN for this project was srsRAN (rebranded as OCUDU) and OpenAirInterface (OAI-RAN).

  The RAN architectures that were used for this deployment were the monolithic architecture and the split 2 (CU/DU split). The monolithic architecture has all the services and functions happening in the same place whilst Split 2 separates the RAN into the CU and DU, with the CU handles the upper-layer protocols and the DU handles the lower-layers protocols and is time-critical.

- **User Equipment (UE)**

  The user equipment is any device that connects to the core network and base station to handle wireless transmission, signaling and data traffic. The UE equipment used in this project were ....... during real-world deployment. For simulation, UERANSIM was used to simulate a UE during deployment to get more information on the performance of the network.

- **Objectives**

  The objective of this project were to:
  
  - to deploy various CN-RAN combinations of a 5G network.
  - benchmark the performance of that network through evaluating performance metrics such as latency, throughput, jitter and power consumption.
  - compare of the network performance metrics for each network combination and evaluating which one will be suitable for deployment in resource-constrained environments, e.g in rural areas.
  
        
## Software tools and equipment used

- **Open5GS**
  - Open5GS was deployment was implemented by following this setup guide on: https://open5gs.org/open5gs/docs/guide/01-quickstart/.
  - It was implemented on an ASUS PC running Ubuntu 22.04.5 LTS with
    
- **srsRAN**
  - Installation steps for srsRAN(OCUDU) can be found on the website: https://docs.ocudu.org/user_manual/installation/
  - The dependencies were installed first and the following choices were made during installation:
    - libfftw -chosen for FFT calculation.
    - UHD and ZMQ -chosen for split deployment architectures.
    - Vanilla installation -for clone and build, so that split architectures could be implemented during testing.

- **OAI-RAN**
  - Installation steps for the OAI-RAN can be found at: https://github.com/ngkore/OAI-RAN
  - The dependencies were installed first, basically followed the steps, and the following choices were made during installation:
     - UHD- was installed for USRP hardware to be used.
     - USRP 210: This was the OAI gNB that was used during configuration and tests.
     - Only the System Preparation and building OAI-RAN steps were followed. The other steps beyond these were not implemented.

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

  
  




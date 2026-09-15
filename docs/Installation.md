## Tools and Equipment used

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

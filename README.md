# Documentation for 5G networks with different CN-RAN combinations

The project aims to provide more information on the amount of resources that different CN-RAN combinations for a 5G network deployment uses. Evaluating performance metrics such as latency, throughput and power consumption and concluding which combination will be best suited for the deployment in resource-constrained environments, e.g rural areas.

## Overview of 5G Testbed Architecture 
- **5G Core Network (5GC)**

  The core network serves as the brain and backbone of a telecommunication network or system that aids communication between the access networks and the external network. It is responsible for key functions such as forwarding and routing, authentication and mobility management. The 5GC chosen for this project are Open5GS and Free5GC.

- **Radio Access Network (RAN)**

  The radio access network is the physical and wireless part of the network that connects other equipment to the core network using radio waves.  It is responsible for sending and receiving signals from antennas and base stations and converting them into digital data to be processed by the core network. It provides key functions such as session management and quality of service (QoS) enforcement. The chosen RAN for this project was srsRAN (rebranded as OCUDU) and OpenAirInterface (OAI-RAN).

  The RAN architectures that were used for this deployment were the monolithic architecture and the split 2 (CU/DU split). The monolithic architecture has all the services and functions happening in the same place whilst Split 2 separates the RAN into the CU and DU, with the CU handles the upper-layer protocols and the DU handles the lower-layers protocols and is time-critical.

- **User Equipment (UE)**

  The user equipment is any device that connects to the core network and base station to handle wireless transmission, signaling and data traffic. The UE equipment used in this project were......



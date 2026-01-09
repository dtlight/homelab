# Home Lab
A place to document the things I set up in my homelab environment. Also to show my thinking process as an engineer, how I might go about things in a production environment. My primary motivation is to learn/refresh my understanding by experimenting with new (and old) tools, above all I find it enjoyable.

## Resource Planning
My five node cluster currently consists of:
1. Three control plane nodes (cp1, cp2 and cp3: 16GB ram Raspberry Pi 5s): all running Raspberry Pi OS (Debian 13) in headless mode so are lightweight and Pi optimised. Etcd requires the most RAM (3GB for small clusters like mine with <100 pods), while other components should typically stay under 1GB each (with Prometheus at roughly 3gb as an exception) with my multi-node control plane set up which distributes load, so 16GB handles 20-50 pods across nodes without OOM issues.
2. Two worker nodes (wn1, wn2), wn1 is an 8GB Raspberry Pi 4 running Debian and the other is wn2, a 36GB ThinkPad running Ubuntu. 

I have mixed 8GB and 36GB worker nodes which work fine for my Kubernetes home lab, as schedulers automatically balance pods based on allocatable resources (node taints/labels also help). 8GB should handle 20-40 pods (e.g., Prometheus targets, Home Assistant), while 36GB can take heavier workloads like databases or future AI experiments without OOM issues.​

Having three control plane nodes promotes H.A for the things I run on my cluster, which would be frustrating to have offline:
* [HomeAssistant](https://hub.docker.com/r/homeassistant/home-assistant) 
* [AdGuard ](https://hub.docker.com/r/adguard/adguardhome) (home dns server)

To achieve H.A in a real world production environment using a hybrid cloud/on premise or cloud/cloud (eg aws/gcp) setup would be obviously more sensible than a cluster of raspberry pis. Also, my control plane nodes share the same ip via kube-virtual-ip which is owned by one of my control plane nodes. In a production environment this would be its own dedicated machine or better still a load balancer instead of kube-vip. In order to achieve High Availability (H.A) the minimum number of nodes in an etcd cluster is 3. This is to achieve quorum which cannot be achieved with less than 3 nodes and to obtain a failure tolerance of 1. You can read more here: https://etcd.io/docs/v3.3/faq/#why-an-odd-number-of-cluster-members

I have created two namespaced environments, dev and prod. No pod in either environment runs on a control plane node.

| Node / Type | RAM Allocatable | Pod Capacity | Example Workloads |
|-----------|-----------------|--------------|------------------|
| **16GB** / CP1 | ~14GB | 50-80 pods | Etcd, Prometheus |
| **16GB** / CP2 | ~14GB | 50-80 pods | Same as CP1 |
| **16GB** / CP3 | ~14GB | 50-80 pods | Same as CP1 |
| **8GB** / Worker 1 (arm) | 6GB | 20-40 pods | Pi-hole, Home Assistant monitoring agents, lightweight apps|
| **36GB** / Worker 2 (x86)| 36GB | 100-200 pods  | StatefulSets, Postgresql, heavy services|

# Setting Up
All necessary scripts or manifests are stored under k8sSetup or manifests. If you want to install kubernetes on your own raspberry pi cluster I have a set of instructions in [this readme](./runbooks/k8sSetup/README.md)

<!-- 
## Home Network Layout
Here's how I have my home devices, switches and routers laid out: -->




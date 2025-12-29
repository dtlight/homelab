
# Installing Kubernetes with kubeadm 

## Features
**What works:**
* CNI Choice: Flannel (simple) or Cilium (advanced networking)
​* Auto-detection: Node type based on IP matching env vars
* Raspberry Pi 5 optimized: containerd + systemd cgroups

**What doesn't:**
For now the script is Debian/Ubuntu-specific and won't work on non-Debian systems but at a later stage I will change this as I plan to replace Debian running on worker node 2 with NixOS.

## Usage Instructions

### 1. Set Environment Variables

```bash
# Required for all nodes
export MASTER_IP="192.168.8.205"

# Choose CNI and CIDR
export CNI="cilium"           # or "flannel" (default)
export POD_CIDR="192.168.0.0/16"  # Required for Cilium, Flannel expects 10.244.0.0/16 [web:36][web:47]

# choose node type and kubernetes version
export NODE_TYPE="" # master | additional-cp | worker
export KUBE_VERSION="1.34"

# Optional: List additional nodes by IP
export ADDITIONAL_CP_IPS="192.168.8.201"
export WORKER_IPS="192.168.1.103 192.168.1.104"
```

### 2. Run on Each Node Type

#### Master Node:

```bash
chmod +x install-k8s.sh && ./install-k8s.sh
```
Additional Control Plane Nodes:

Copy `join-controlplane.sh` from master

Run `./install-k8s.sh`

#### Worker Nodes:

Copy `join-worker.sh` from master

Run `./install-k8s.sh`

### 3. Verify Cluster
```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

**NOTE:** on the Pi5 cgroup2 needs to be enabled, the script takes care of that but for the changes to take effect a reboot is needed. The scrip will pause to ask if it is the first time you are enabling cgroup2, if you haven't run the script before just say yes with `y` and after rebooting re-run the script and respond with 'n' to continue installation.

# Installing Talos OS
In my usecase Talos is the OS for a single worker node and not my control plane nodes. If you wish to do this then you'll need to abandon the steps in `Installing Kubernetes with kubeadm ` and do things differently to what's below.

On your local machine install talosctl, for mac this can be done with homebrew: `brew install siderolabs/tap/talosctl` and on linux machines (eg my control plane node) it's `curl -sL https://talos.dev/install | sh`. Installing talosctl on the control plane node is not necessary but gives me an additional option if my mac is unavailable.

Talos workers enforce joining only Talos control planes by default, requiring config patches or kubeadm join with manual TLS bootstrapping.

On the master control plane node, reference the content of join-worker.sh (contains the join commands generated above) or generate a join token: `kubeadm token create --print-join-command`.

On the Talos machine directly (no ssh) boot Talos worker node interactively (talosctl apply-config --insecure --interactive), patch worker config to allow non-Talos CP (remove cluster.kubernetesNetworkConfig restrictions or use custom machine config).

Run kubeadm join on worker node via talosctl, handling TLS bootstrap by copying CA certs and creating kubelet ConfigMap in the Talos cluster namespace.





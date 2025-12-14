This concerns setting up the control plane nodes which run a fresh installation of Pi OS. I've already reserved IPs for all Raspberry Pis on my router. For my homelab static IPs will ensure stable Kubernetes node communication, ExternalDNS updates, and Harbor registry access without lease expiration disruptions.

## Create staic IPs for CP node + kube vip:

```bash
# Set primary + VIP and gateway
sudo nmcli connection modify "Wired connection 1" \
  ipv4.addresses "192.168.8.201/24,192.168.8.205/32" \
  ipv4.gateway "192.168.8.1" \
  ipv4.method manual

# Apply immediately
sudo nmcli connection down "Wired connection 1"
sudo nmcli connection up "Wired connection 1"
```

## Disable swap and set cgroup drivers for kubelet compatibility.
Kubernetes requires swap disabled by default (NoSwap behavior) for predictable pod scheduling and to avoid OOM issues.
Disable swap and configure the kubelet cgroup driver to systemd on control plane nodes to ensure kubelet compatibility and prevent preflight errors during kubeadm init or kubeadm join

Disable Swap:
```bash
#Temporarily disable all swap
sudo swapoff -a

# Make it permanent by commenting out swap entries in /etc/fstab: 
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Verify 
free -h #(should show 0 swap)
swapon --show #(no output).​

```


## Installing kube packages on Debian
 ```bash
### 1. Update package list and install required dependencies
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl 

### 2. Download and add the Kubernetes public signing key 
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

### 3. Add the Kubernetes apt repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
 
### 4. Update package index and install kubeadm, kubelet, and kubectl
sudo apt-get update
sudo apt-get install -y kubeadm kubelet kubectl
 
### 5. Pin the installed packages to prevent unintended upgrades
```

This one's optional but personally i'd recommend it to avoid any of the installed k8s packages being upgraded automatically, where bad things like breaking changes can happen. Kubernetes components require careful version management because upgrading them could cause compatibility issues or disrupt cluster stability.

```bash
sudo apt-mark hold kubeadm kubelet kubectl
 ```

## Install container runtime (containerd).
Match the kubelet cgroup driver to the container runtime. After deliberating between CRI-O and containerd I went with the latter, there isn't a massive difference between the two as both adhere to the Open Container Initiative. 

Add Containerd Repository
```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl gpg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
```

The sudo install -m 0755 -d /etc/apt/keyrings command creates the APT keyrings directory securely with specific permissions.​

`sudo install` uses install (instead of mkdir) to create directories atomically (avoids race conditions) and set ownership/permissions in one step.​

It's also more reliable than mkdir -p for package manager scripts.​

`-m 0755` sets permissions: owner (root) rwx (7), group rx (5), others rx (5).​

Directory executable (x) needed for traversal; readable (r) for APT to access GPG keys inside.​

`-d` Creates directory (not a file)—equivalent to mkdir -p but with permissions.​

`/etc/apt/keyrings` Standard Debian/Ubuntu location for modern GPG keys (APT 1.4+ secure keyring format).

`chmod a+r` makes the generated docker.gpg world-readable for APT

If no errors then install containerd with:

```bash
sudo apt-get install -y containerd.io
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

The `sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml` command edits the containerd config file to enable systemd cgroup support.​

`sudo sed` Runs sed (stream editor) with root privileges to modify system config.​

`-i` In-place edit: Modifies the file directly.​

`s/old/new/g` Substitute command: s = substitute, first `/` delimits pattern/replacement. `SystemdCgroup = false` is the search pattern (exact match from default config.toml) and

`SystemdCgroup = true` the replacement text.

`g` global flag (replace ALL occurrences, though there's only one).​

`/etc/containerd/config.toml` Target file generated by containerd config default.​

Why This Change?
Default config: SystemdCgroup = false (uses legacy cgroupfs).​
Kubernetes requires: SystemdCgroup = true to match kubelet's --cgroup-driver=systemd.​
Mismatch causes: Kubelet startup failures with "cgroup driver mismatch" errors.

Verify:

```bash
david@cp1:~ $ sudo ctr version
Client:
  Version:  v2.2.0
  Revision: 1c4457e00facac03ce1d75f7b6777a7a851e5c41
  Go version: go1.24.9

Server:
  Version:  v2.2.0
  Revision: 1c4457e00facac03ce1d75f7b6777a7a851e5c41
  UUID: 5027141d-e52c-4f81-afac-bed17eee3546

david@cp1:~ $ sudo systemctl status containerd
● containerd.service - containerd container runtime
     Loaded: loaded (/usr/lib/systemd/system/containerd.service; enabled; preset: enabled)
     Active: active (running) since Wed 2025-11-12 13:22:35 GMT; 2min 25s ago
 Invocation: b1677e14c9234950ba6965c33d006730
       Docs: https://containerd.io
   Main PID: 2777 (containerd)
      Tasks: 10
        CPU: 117ms
     CGroup: /system.slice/containerd.service
```


## Setup kube-vip
For high availability with multiple control planes, I will use kube-vip for virtual IP. I've opted for this over an external load balancer because I don't need strict separation between control plane and load blanacer. Also I want to avoid cloud loadbalancer costs and so prefer a free, open‑source solution I can implement on prem. I also don't want to dedicate a whole raspberry pi to act as a loadbalancer as I prioritise keeping my remaining Pis for worker nodes.

Following [kube-vip documentation](https://kube-vip.io/docs/installation/static/):

Static Pods are Kubernetes Pods that are run by the kubelet on a single node and are not managed by the Kubernetes cluster itself. This means that whilst the Pod can appear within Kubernetes, it can't make use of a variety of Kubernetes functionality (such as the Kubernetes token or ConfigMap resources). The static Pod approach is primarily required for kubeadm as this is due to the sequence of actions performed by kubeadm. Ideally, we want kube-vip to be part of the Kubernetes cluster, but for various bits of functionality we also need kube-vip to provide a HA virtual IP as part of the installation.

#### On cp1:

1. Set kube-vip variables
```bash
export VIP=192.168.8.205
export INTERFACE=eth0
```

2. Set kube-vip version and alias for containerd:

Then:
```bash
export KVVERSION=v1.0.2 
```

Now define the containerd alias:

```bash
alias kube-vip="sudo ctr image pull ghcr.io/kube-vip/kube-vip:${KVVERSION}; sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${KVVERSION} vip /kube-vip"
```

3. Generate the static pod manifest (ARP mode)

**ARP vs BGP (Quick Comparison)**

| Mode | Network Req       | Router Config | Use Case              |
|------|-------------------|---------------|-----------------------|
| **ARP** | Same L2 (VLAN) | None          | Pi cluster, homelab   |
| **BGP** | L3 routing      | BGP peering   | Multi-subnet, data center |


So or my setup (eth0, single subnet 192.168.8.0/24), ARP is right. The --arp flag in the manifest command enables this mode.


```bash
sudo mkdir -p /etc/kubernetes/manifests

kube-vip manifest pod \
  --interface $INTERFACE \
  --address $VIP \
  --controlplane \
  --services \
  --arp \
  --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

**Kubelet will:**
* Read /etc/kubernetes/manifests/kube-vip.yaml.
* Start the kube-vip pod.
* kube-vip will announce 192.168.8.205 on eth0 via ARP.

After init:
```bash
ip addr show eth0 | grep 192.168.8.205   # VIP present
```

Then proceed to `kubeadm init --control-plane-endpoint "192.168.8.205:6443"`

```bash
david@cp1:/ $ sudo kubeadm init --control-plane-endpoint "192.168.8.205:6443"
[init] Using Kubernetes version: v1.34.3
[preflight] Running pre-flight checks
	[WARNING Swap]: swap is supported for cgroup v2 only. The kubelet must be properly configured to use swap. Please refer to https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory, or disable swap on the node
[preflight] The system verification failed. Printing the output from the verification:
KERNEL_VERSION: 6.12.47+rpt-rpi-2712
CONFIG_NAMESPACES: enabled
CONFIG_NET_NS: enabled
CONFIG_PID_NS: enabled
CONFIG_IPC_NS: enabled
CONFIG_UTS_NS: enabled
CONFIG_CGROUPS: enabled
CONFIG_CPUSETS: enabled
CONFIG_MEMCG: enabled
CONFIG_INET: enabled
CONFIG_EXT4_FS: enabled
CONFIG_PROC_FS: enabled
CONFIG_NETFILTER_XT_TARGET_REDIRECT: enabled (as module)
CONFIG_NETFILTER_XT_MATCH_COMMENT: enabled (as module)
CONFIG_FAIR_GROUP_SCHED: enabled
CONFIG_OVERLAY_FS: enabled (as module)
CONFIG_AUFS_FS: not set - Required for aufs.
CONFIG_BLK_DEV_DM: enabled (as module)
CONFIG_CFS_BANDWIDTH: enabled
CONFIG_SECCOMP: enabled
CONFIG_SECCOMP_FILTER: enabled
OS: Linux
CGROUPS_CPU: enabled
CGROUPS_CPUSET: enabled
CGROUPS_DEVICES: enabled
CGROUPS_FREEZER: enabled
CGROUPS_MEMORY: missing
CGROUPS_PIDS: enabled
CGROUPS_HUGETLB: missing
CGROUPS_IO: enabled
	[WARNING SystemVerification]: missing optional cgroups: hugetlb
[preflight] Some fatal errors occurred:
	[ERROR SystemVerification]: missing required cgroups: memory
	[ERROR FileContent--proc-sys-net-ipv4-ip_forward]: /proc/sys/net/ipv4/ip_forward contents are not set to 1
[preflight] If you know what you are doing, you can make a check non-fatal with `--ignore-preflight-errors=...`
error: error execution phase preflight: preflight checks failed
```

From the terminal output clearly several things are broken. 
✅ CGROUPS_MEMORY: missing ← FIXED by cmdline.txt
✅ CGROUPS_PIDS: enabled
✅ CGROUPS_CPUSET: enabled  
❌ aufs: not set ← Warning only
❌ hugetlb: missing ← Warning only

Note: Warnings (aufs, hugetlb) are non-fatal errors. In my Raspberry Pi cluster, overlayfs handles container storage and I'm not targeting hugepage workloads, so missing aufs and hugetlb is practically harmless and correctly reported as warnings, not fatal errors.

To fix the remaining errors:​

1. Enabling IP Forwarding fixes [ERROR FileContent--proc-sys-net-ipv4-ip_forward]
```bash
sudo sysctl net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf

#Create a dedicated override in /etc/sysctl.d which is applied after the base files:
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ipforward.conf
sudo sysctl --system
```

`cat /proc/sys/net/ipv4/ip_forward` should show: 1

2. Enable Required Cgroups (Memory + Hugepages)
```bash
sudo vi /boot/firmware/cmdline.txt
```

Append these parametes:
```bash
systemd.unified_cgroup_hierarchy=1 cgroup_enable=memory cgroup_memory=1 cgroup_enable=hugetlb
```

Reboot

Confirm c group is active:
```bash
mount | grep cgroup
```

On many modern Pi OS builds, enabling systemd.unified_cgroup_hierarchy=1 gives you cgroup v2 only, and the old /proc/cgroups interface does not list memory the way kubeadm expects, even though memory accounting works via v2. Kubeadm’s SystemVerification preflight is written with cgroup v1 in mind; on cgroup v2 it can wrongly report CGROUPS_MEMORY: missing even if memory cgroups are actually in place via v2. Kubernetes documentation explicitly allows bypassing such checks with: `--ignore-preflight-errors=SystemVerification`

Now to try kubeadm init again
```bash
sudo kubeadm init \
  --control-plane-endpoint "192.168.8.205:6443" \
  --ignore-preflight-errors=SystemVerification \
  --pod-network-cidr=10.244.0.0/16
```

Which gives:

```bash
david@cp1:~ $ sudo kubeadm init \
  --control-plane-endpoint "192.168.8.205:6443" \
  --ignore-preflight-errors=SystemVerification \
  --pod-network-cidr=10.244.0.0/16
W1214 23:40:13.425104    2040 version.go:108] could not fetch a Kubernetes version from the internet: unable to get URL "https://dl.k8s.io/release/stable-1.txt": Get "https://dl.k8s.io/release/stable-1.txt": dial tcp: lookup dl.k8s.io on [::1]:53: read udp [::1]:59902->[::1]:53: read: connection refused
W1214 23:40:13.425168    2040 version.go:109] falling back to the local client version: v1.34.3
[init] Using Kubernetes version: v1.34.3
[preflight] Running pre-flight checks
	[WARNING Swap]: swap is supported for cgroup v2 only. The kubelet must be properly configured to use swap. Please refer to https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory, or disable swap on the node
	[WARNING SystemVerification]: missing optional cgroups: hugetlb
[preflight] Pulling images required for setting up a Kubernetes cluster
[preflight] This might take a minute or two, depending on the speed of your internet connection
[preflight] You can also perform this action beforehand using 'kubeadm config images pull'
[preflight] Some fatal errors occurred:
	[ERROR ImagePull]: failed to pull image registry.k8s.io/kube-apiserver:v1.34.3: failed to pull image registry.k8s.io/kube-apiserver:v1.34.3: failed to pull and unpack image "registry.k8s.io/kube-apiserver:v1.34.3": failed to resolve image: failed to do request: Head "https://registry.k8s.io/v2/kube-apiserver/manifests/v1.34.3": dial tcp: lookup registry.k8s.io on [::1]:53: read udp [::1]:55114->[::1]:53: read: connection refused
	[ERROR ImagePull]: failed to pull image registry.k8s.io/kube-controller-manager:v1.34.3: failed to pull image registry.k8s.io/kube-controller-manager:v1.34.3: failed to pull and unpack image "registry.k8s.io/kube-controller-manager:v1.34.3": failed to resolve image: failed to do request: Head "https://registry.k8s.io/v2/kube-controller-manager/manifests/v1.34.3": dial tcp: lookup registry.k8s.io on [::1]:53: read udp [::1]:32852->[::1]:53: read: connection refused
	[ERROR ImagePull]: failed to pull image registry.k8s.io/kube-scheduler:v1.34.3: failed to pull image registry.k8s.io/kube-scheduler:v1.34.3: failed to pull and unpack image "registry.k8s.io/kube-scheduler:v1.34.3": failed to resolve image: failed to do request: Head "https://registry.k8s.io/v2/kube-scheduler/manifests/v1.34.3": dial tcp: lookup registry.k8s.io on [::1]:53: read udp [::1]:37547->[::1]:53: read: connection refused
	[ERROR ImagePull]: failed to pull image registry.k8s.io/kube-proxy:v1.34.3: failed to pull image registry.k8s.io/kube-proxy:v1.34.3: failed to pull and unpack image "registry.k8s.io/kube-proxy:v1.34.3": failed to resolve image: failed to do request: Head "https://registry.k8s.io/v2/kube-proxy/manifests/v1.34.3": dial tcp: lookup registry.k8s.io on [::1]:53: read udp [::1]:51662->[::1]:53: read: connection refused
	[ERROR ImagePull]: failed to pull image registry.k8s.io/coredns/coredns:v1.12.1: failed to pull image registry.k8s.io/coredns/coredns:v1.12.1: failed to pull and unpack image "registry.k8s.io/coredns/coredns:v1.12.1": failed to resolve image: failed to do request: Head "https://registry.k8s.io/v2/coredns/coredns/manifests/v1.12.1": dial tcp: lookup registry.k8s.io on [::1]:53: read udp [::1]:58416->[::1]:53: read: connection refused
	[ERROR ImagePull]: failed to pull image registry.k8s.io/pause:3.10.1: failed to pull image registry.k8s.io/pause:3.10.1: failed to pull and unpack image "registry.k8s.io/pause:3.10.1": failed to resolve image: failed to do request: Head "https://registry.k8s.io/v2/pause/manifests/3.10.1": dial tcp: lookup registry.k8s.io on [::1]:53: read udp [::1]:44725->[::1]:53: read: connection refused
	[ERROR ImagePull]: failed to pull image registry.k8s.io/etcd:3.6.5-0: failed to pull image registry.k8s.io/etcd:3.6.5-0: failed to pull and unpack image "registry.k8s.io/etcd:3.6.5-0": failed to resolve image: failed to do request: Head "https://registry.k8s.io/v2/etcd/manifests/3.6.5-0": dial tcp: lookup registry.k8s.io on [::1]:53: read udp [::1]:54479->[::1]:53: read: connection refused
[preflight] If you know what you are doing, you can make a check non-fatal with `--ignore-preflight-errors=...`
error: error execution phase preflight: preflight checks failed
To see the stack trace of this error execute with --v=5 or higher
```

The good news is all of those new errors are DNS / network, not Kubernetes itself 🙌🏾. So now my problem is cp1 can’t resolve external hostnames, so it can’t pull images.
Key clue: `lookup registry.k8s.io on [::1]:53: read udp [::1]:...: connection refused` which means something on my Pi configured 127.0.0.1 / ::1 as DNS, but there is no DNS server listening locally.

### Trouble shooting DNS issues:
I've decided to add my trouble shooting issues and solutions as they happened so you can see that it doesn't always go smoothly but more importantly if you have similar issues you know what might work for you.

First I try:

```bash
ping -c 3 8.8.8.8
ping -c 3 registry.k8s.io
cat /etc/resolv.conf
```

ping 8.8.8.8 works but ping registry.k8s.io fails so routing OK, DNS broken.

```bash
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=114 time=3.92 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=114 time=3.63 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=114 time=3.48 ms

--- 8.8.8.8 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2004ms
rtt min/avg/max/mdev = 3.477/3.676/3.922/0.184 ms
ping: registry.k8s.io: Temporary failure in name resolution
# Generated by NetworkManager
```
DNS is completely unset: /etc/resolv.conf only has the comment “# Generated by NetworkManager”, with no nameserver lines. That’s why my name resolution fails.

To resolve I'll tell “Wired connection 1” to use real DNS servers and not rely on auto-DNS:

```bash
# Set router + Google DNS, and ignore DHCP-provided DNS
sudo nmcli connection modify "Wired connection 1" \
  ipv4.dns "192.168.8.1,8.8.8.8" \
  ipv4.ignore-auto-dns yes

sudo nmcli connection down "Wired connection 1"
sudo nmcli connection up "Wired connection 1"
```
running cat /etc/resolv.conf returns:
```bash
david@cp1:~ $ cat /etc/resolv.conf
# Generated by NetworkManager
nameserver 192.168.8.1
nameserver 8.8.8.8```
```

and pinging registry.k8s.io gives

```bash
david@cp1:~ $ ping -c 3 registry.k8s.io
PING registry.k8s.io (34.96.108.209) 56(84) bytes of data.
64 bytes from 209.108.96.34.bc.googleusercontent.com (34.96.108.209): icmp_seq=1 ttl=114 time=3.15 ms
64 bytes from 209.108.96.34.bc.googleusercontent.com (34.96.108.209): icmp_seq=2 ttl=114 time=2.72 ms
64 bytes from 209.108.96.34.bc.googleusercontent.com (34.96.108.209): icmp_seq=3 ttl=114 time=3.08 ms

--- registry.k8s.io ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 2.723/2.986/3.151/0.187 ms
```
Problem solved 👍🏾 Now to retry initialising kubeadm

```bash
sudo kubeadm init \
  --control-plane-endpoint "192.168.8.205:6443" \
  --pod-network-cidr=10.244.0.0/16 \
  --ignore-preflight-errors=SystemVerification
```

after 4 minutes i get the following error mesage explaining the kublet is not healthy, so kubeadm times out waiting on its health endpoint at port 10248. (truncated):

```bash
[kubelet-check] Waiting for a healthy kubelet at http://127.0.0.1:10248/healthz. This can take up to 4m0s
[kubelet-check] The kubelet is not healthy after 4m0.000580205s

Unfortunately, an error has occurred, likely caused by:
	- The kubelet is not running
	- The kubelet is unhealthy due to a misconfiguration of the node in some way (required cgroups disabled)

If you are on a systemd-powered system, you can try to troubleshoot the error with the following commands:
	- 'systemctl status kubelet'
	- 'journalctl -xeu kubelet'

error: error execution phase wait-control-plane: failed while waiting for the kubelet to start: The HTTP call equal to 'curl -sSL http://127.0.0.1:10248/healthz' returned error: Get "http://127.0.0.1:10248/healthz": context deadline exceeded
```

Running `sudo systemctl status kubelet --no-pager` and `sudo journalctl -xeu kubelet --no-pager` will print logs.
These logs will show whether kubelet is failing due to swap, cgroup configuration, or container runtime issues.

```bash
Dec 15 01:35:15 cp1 systemd[1]: Started kubelet.service - kubelet: The Kubernetes Node Agent.
░░ Subject: A start job for unit kubelet.service has finished successfully
░░ Defined-By: systemd
░░ Support: https://www.debian.org/support
░░
░░ A start job for unit kubelet.service has finished successfully.
░░
░░ The job identifier is 93209.
Dec 15 01:35:15 cp1 kubelet[8470]: Flag --pod-infra-container-image has been deprecated, will be removed in 1.35. Image garbage collector will get sandbox image information from CRI.
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.897376    8470 server.go:213] "--pod-infra-container-image will not be pruned by the image garbage collector in kubelet and should also be set in the remote runtime"
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.905303    8470 server.go:529] "Kubelet version" kubeletVersion="v1.34.3"
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.905334    8470 server.go:531] "Golang settings" GOGC="" GOMAXPROCS="" GOTRACEBACK=""
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.905371    8470 watchdog_linux.go:95] "Systemd watchdog is not enabled"
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.905382    8470 watchdog_linux.go:137] "Systemd watchdog is not enabled or the interval is invalid, so health checking will not be started."
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.905727    8470 server.go:956] "Client rotation is on, will bootstrap in background"
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.908229    8470 certificate_store.go:147] "Loading cert/key pair from a file" filePath="/var/lib/kubelet/pki/kubelet-client-current.pem"
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.911028    8470 dynamic_cafile_content.go:161] "Starting controller" name="client-ca-bundle::/etc/kubernetes/pki/ca.crt"
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.913870    8470 server.go:1423] "Using cgroup driver setting received from the CRI runtime" cgroupDriver="systemd"
Dec 15 01:35:15 cp1 kubelet[8470]: W1215 01:35:15.917363    8470 sysinfo.go:227] Found node without any CPU, nodeDir: /sys/devices/system/node/node1, number of cpuDirs 0, err: <nil>
Dec 15 01:35:15 cp1 kubelet[8470]: W1215 01:35:15.917575    8470 sysinfo.go:227] Found node without any CPU, nodeDir: /sys/devices/system/node/node2, number of cpuDirs 0, err: <nil>
Dec 15 01:35:15 cp1 kubelet[8470]: W1215 01:35:15.917707    8470 sysinfo.go:227] Found node without any CPU, nodeDir: /sys/devices/system/node/node3, number of cpuDirs 0, err: <nil>
Dec 15 01:35:15 cp1 kubelet[8470]: W1215 01:35:15.917902    8470 sysinfo.go:227] Found node without any CPU, nodeDir: /sys/devices/system/node/node4, number of cpuDirs 0, err: <nil>
Dec 15 01:35:15 cp1 kubelet[8470]: W1215 01:35:15.918031    8470 sysinfo.go:227] Found node without any CPU, nodeDir: /sys/devices/system/node/node5, number of cpuDirs 0, err: <nil>
Dec 15 01:35:15 cp1 kubelet[8470]: W1215 01:35:15.918158    8470 sysinfo.go:227] Found node without any CPU, nodeDir: /sys/devices/system/node/node6, number of cpuDirs 0, err: <nil>
Dec 15 01:35:15 cp1 kubelet[8470]: W1215 01:35:15.918279    8470 sysinfo.go:227] Found node without any CPU, nodeDir: /sys/devices/system/node/node7, number of cpuDirs 0, err: <nil>
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.919039    8470 server.go:781] "--cgroups-per-qos enabled, but --cgroup-root was not specified.  Defaulting to /"
Dec 15 01:35:15 cp1 kubelet[8470]: I1215 01:35:15.919190    8470 swap_util.go:115] "Swap is on" /proc/swaps contents=<
Dec 15 01:35:15 cp1 kubelet[8470]:         Filename                                Type                Size                Used                Priority
Dec 15 01:35:15 cp1 kubelet[8470]:         /dev/zram0                              partition        2097136                0                100
Dec 15 01:35:15 cp1 kubelet[8470]:  >
Dec 15 01:35:15 cp1 kubelet[8470]: E1215 01:35:15.919309    8470 run.go:72] "command failed" err="failed to run Kubelet: running with swap on is not supported, please disable swap or set --fail-swap-on flag to false"
Dec 15 01:35:15 cp1 systemd[1]: kubelet.service: Main process exited, code=exited, status=1/FAILURE
░░ Subject: Unit process exited
░░ Defined-By: systemd
░░ Support: https://www.debian.org/support
░░
░░ An ExecStart= process belonging to unit kubelet.service has exited.
░░
░░ The process' exit code is 'exited' and its exit status is 1.
Dec 15 01:35:15 cp1 systemd[1]: kubelet.service: Failed with result 'exit-code'.
░░ Subject: Unit failed
░░ Defined-By: systemd
░░ Support: https://www.debian.org/support
░░
░░ The unit kubelet.service has entered the 'failed' state with result 'exit-code'.
```
Kubelet is crashing because swap is enabled (on /dev/zram0), and this Kubernetes version is configured to fail if any swap is on.

To disable zram swap so it does not come back after reboot I need to find which unit manages it:

```bash
david@cp1:~ $ systemctl list-units '*zram*' --no-pager
systemctl list-units '*swap*' --no-pager
  UNIT                                   LOAD   ACTIVE SUB     DESCRIPTION
  sys-devices-virtual-block-zram0.device loaded active plugged /sys/devices/virtual/block/zram0
  systemd-zram-setup@zram0.service       loaded active exited  Create swap on /dev/zram0
  system-systemd\x2dzram\x2dsetup.slice  loaded active active  Slice /system/systemd-zram-setup
  dev-zram0.swap                         loaded active active  rpi-swap managed swap device (zram+file)
  rpi-zram-writeback.timer               loaded active waiting zram writeback timer

Legend: LOAD   → Reflects whether the unit definition was properly loaded.
        ACTIVE → The high-level unit activation state, i.e. generalization of SUB.
        SUB    → The low-level unit activation state, values depend on unit type.

5 loaded units listed. Pass --all to see loaded but inactive units, too.
To show all installed unit files use 'systemctl list-unit-files'.
  UNIT                            LOAD   ACTIVE SUB    DESCRIPTION
  rpi-setup-loop@var-swap.service loaded active exited rpi-setup-loop - set up file on loop device
  dev-zram0.swap                  loaded active active rpi-swap managed swap device (zram+file)
  swap.target                     loaded active active Swaps

Legend: LOAD   → Reflects whether the unit definition was properly loaded.
        ACTIVE → The high-level unit activation state, i.e. generalization of SUB.
        SUB    → The low-level unit activation state, values depend on unit type.

3 loaded units listed. Pass --all to see loaded but inactive units, too.
To show all installed unit files use 'systemctl list-unit-files'.
```

Disable by running:

```bash
sudo swapoff /dev/zram0

sudo systemctl stop dev-zram0.swap
sudo systemctl stop systemd-zram-setup@zram0.service
sudo systemctl stop rpi-zram-writeback.timer
sudo systemctl stop rpi-setup-loop@var-swap.service
```

On newer Raspberry Pi OS, the the rpi-swap package is responsible so to make it persistantly disabled I will remove it with `sudo apt-get purge rpi-swap` followed by `sudo apt remove systemd-zram-generator`. After a reboot (to ensure it's truly fixed) I run `free -h` and `swapon --show`:

```bash
david@cp1:~ $ free -h
swapon --show
               total        used        free      shared  buff/cache   available
Mem:            15Gi       504Mi        14Gi        15Mi       557Mi        15Gi
Swap:             0B          0B          0B
```

Since swap stayed at zero, kubelet will stop failing with “running with swap on is not supported” so I can re-run kubeadm init:

```bash
sudo systemctl restart kubelet
sudo kubeadm reset -f
sudo kubeadm init \
  --control-plane-endpoint "192.168.8.205:6443" \
  --pod-network-cidr=10.244.0.0/16 \
  --ignore-preflight-errors=SystemVerification
```

Kubelet is now healthy but i have issues during cluster role binding creation

```bash
david@cp1:~ $ sudo systemctl restart kubelet
sudo kubeadm reset -f
sudo kubeadm init \
  --control-plane-endpoint "192.168.8.205:6443" \
  --pod-network-cidr=10.244.0.0/16 \
  --ignore-preflight-errors=SystemVerification
[reset] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[reset] Use 'kubeadm init phase upload-config kubeadm --config your-config-file' to re-upload it.
W1215 01:56:30.996269    1395 reset.go:141] [reset] Unable to fetch the kubeadm-config ConfigMap from cluster: failed to get config map: Get "https://192.168.8.205:6443/api/v1/namespaces/kube-system/configmaps/kubeadm-config?timeout=10s": dial tcp 192.168.8.205:6443: connect: no route to host
[preflight] Running pre-flight checks
W1215 01:56:30.996370    1395 removeetcdmember.go:105] [reset] No kubeadm config, using etcd pod spec to get data directory
[reset] Deleted contents of the etcd data directory: /var/lib/etcd
[reset] Stopping the kubelet service
[reset] Unmounting mounted directories in "/var/lib/kubelet"
[reset] Deleting contents of directories: [/etc/kubernetes/manifests /var/lib/kubelet /etc/kubernetes/pki]
[reset] Deleting files: [/etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf]

...truncated...

[kubelet-start] Starting the kubelet
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods from directory "/etc/kubernetes/manifests"
[kubelet-check] Waiting for a healthy kubelet at http://127.0.0.1:10248/healthz. This can take up to 4m0s
[kubelet-check] The kubelet is healthy after 1.001453205s
[control-plane-check] Waiting for healthy control plane components. This can take up to 4m0s
[control-plane-check] Checking kube-apiserver at https://192.168.8.201:6443/livez
[control-plane-check] Checking kube-controller-manager at https://127.0.0.1:10257/healthz
[control-plane-check] Checking kube-scheduler at https://127.0.0.1:10259/livez
[control-plane-check] kube-scheduler is healthy after 3.332824469s
[control-plane-check] kube-controller-manager is healthy after 4.201678899s
[control-plane-check] kube-apiserver is healthy after 5.002082661s
error: error execution phase upload-config/kubeadm: could not bootstrap the admin user in file admin.conf: unable to create ClusterRoleBinding: Post "https://192.168.8.205:6443/apis/rbac.authorization.k8s.io/v1/clusterrolebindings?timeout=10s": context deadline exceeded
To see the stack trace of this error execute with --v=5 or higher
```

I try to debug with curl to verify both ips work:

```bash
[control-plane-check] kube-apiserver is healthy after 5.002082661s
error: error execution phase upload-config/kubeadm: could not bootstrap the admin user in file admin.conf: unable to create ClusterRoleBinding: Post "https://192.168.8.205:6443/apis/rbac.authorization.k8s.io/v1/clusterrolebindings?timeout=10s": context deadline exceeded
To see the stack trace of this error execute with --v=5 or higher
```

To check the IP is actually assigned on cp1 when kubeadm runs is use `ip addr show eth0` and see it hasn't persisted after an earlier reboot (previously it had).

I re-run `sudo nmcli connection modify "Wired connection 1" +ipv4.addresses "192.168.8.205/24"` and reboot then check with `ip addr show eth0`:

```bash
david@cp1:~ $ ip addr show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 2c:cf:67:f0:0a:a9 brd ff:ff:ff:ff:ff:ff
    inet 192.168.8.201/24 brd 192.168.8.255 scope global noprefixroute eth0
       valid_lft forever preferred_lft forever
    inet 192.168.8.205/32 scope global noprefixroute eth0
       valid_lft forever preferred_lft forever
    inet 192.168.8.205/24 brd 192.168.8.255 scope global secondary noprefixroute eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::4354:5179:5ea:cb89/64 scope link noprefixroute
       valid_lft forever preferred_lft forever
```

Things are working as expected so once again I re-run kubeadm init:

```bash
david@cp1: sudo kubeadm reset -f

sudo kubeadm init \
  --control-plane-endpoint "192.168.8.205:6443" \
  --pod-network-cidr=10.244.0.0/16 \
  --ignore-preflight-errors=SystemVerification
[reset] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[reset] Use 'kubeadm init phase upload-config kubeadm --config your-config-file' to re-upload it.
W1215 02:20:58.770796    1278 reset.go:141] [reset] Unable to fetch the kubeadm-config ConfigMap from cluster: failed to get config map: configmaps "kubeadm-config" is forbidden: User "kubernetes-admin" cannot get resource "configmaps" in API group "" in the namespace "kube-system"
[preflight] Running pre-flight checks
W1215 02:20:58.770985    1278 removeetcdmember.go:105] [reset] No kubeadm config, using etcd pod spec to get data directory
[reset] Deleted contents of the etcd data directory: /var/lib/etcd
[reset] Stopping the kubelet service
[reset] Unmounting mounted directories in "/var/lib/kubelet"
[reset] Deleting contents of directories: [/etc/kubernetes/manifests /var/lib/kubelet /etc/kubernetes/pki]
[reset] Deleting files: [/etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf]

The reset process does not perform cleanup of CNI plugin configuration,
network filtering rules and kubeconfig files.

For information on how to perform this cleanup manually, please see:
    https://k8s.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/

[init] Using Kubernetes version: v1.34.3
[preflight] Running pre-flight checks
	[WARNING SystemVerification]: missing optional cgroups: hugetlb
[preflight] Pulling images required for setting up a Kubernetes cluster
[preflight] This might take a minute or two, depending on the speed of your internet connection
[preflight] You can also perform this action beforehand using 'kubeadm config images pull'
[certs] Using certificateDir folder "/etc/kubernetes/pki"
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [cp1 kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local] and IPs [10.96.0.1 192.168.8.201 192.168.8.205]
[certs] Generating "apiserver-kubelet-client" certificate and key
[certs] Generating "front-proxy-ca" certificate and key
[certs] Generating "front-proxy-client" certificate and key
[certs] Generating "etcd/ca" certificate and key
[certs] Generating "etcd/server" certificate and key
[certs] etcd/server serving cert is signed for DNS names [cp1 localhost] and IPs [192.168.8.201 127.0.0.1 ::1]
[certs] Generating "etcd/peer" certificate and key
[certs] etcd/peer serving cert is signed for DNS names [cp1 localhost] and IPs [192.168.8.201 127.0.0.1 ::1]
[certs] Generating "etcd/healthcheck-client" certificate and key
[certs] Generating "apiserver-etcd-client" certificate and key
[certs] Generating "sa" key and public key
[kubeconfig] Using kubeconfig folder "/etc/kubernetes"
[kubeconfig] Writing "admin.conf" kubeconfig file
[kubeconfig] Writing "super-admin.conf" kubeconfig file
[kubeconfig] Writing "kubelet.conf" kubeconfig file
[kubeconfig] Writing "controller-manager.conf" kubeconfig file
[kubeconfig] Writing "scheduler.conf" kubeconfig file
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
[control-plane] Using manifest folder "/etc/kubernetes/manifests"
[control-plane] Creating static Pod manifest for "kube-apiserver"
[control-plane] Creating static Pod manifest for "kube-controller-manager"
[control-plane] Creating static Pod manifest for "kube-scheduler"
[kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/instance-config.yaml"
[patches] Applied patch of type "application/strategic-merge-patch+json" to target "kubeletconfiguration"
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[kubelet-start] Starting the kubelet
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods from directory "/etc/kubernetes/manifests"
[kubelet-check] Waiting for a healthy kubelet at http://127.0.0.1:10248/healthz. This can take up to 4m0s
[kubelet-check] The kubelet is healthy after 1.001154215s
[control-plane-check] Waiting for healthy control plane components. This can take up to 4m0s
[control-plane-check] Checking kube-apiserver at https://192.168.8.201:6443/livez
[control-plane-check] Checking kube-controller-manager at https://127.0.0.1:10257/healthz
[control-plane-check] Checking kube-scheduler at https://127.0.0.1:10259/livez
[control-plane-check] kube-controller-manager is healthy after 4.051910865s
[control-plane-check] kube-scheduler is healthy after 4.105297996s
[control-plane-check] kube-apiserver is healthy after 5.501911182s
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
[kubelet] Creating a ConfigMap "kubelet-config" in namespace kube-system with the configuration for the kubelets in the cluster
[upload-certs] Skipping phase. Please see --upload-certs
[mark-control-plane] Marking the node cp1 as control-plane by adding the labels: [node-role.kubernetes.io/control-plane node.kubernetes.io/exclude-from-external-load-balancers]
[mark-control-plane] Marking the node cp1 as control-plane by adding the taints [node-role.kubernetes.io/control-plane:NoSchedule]
[bootstrap-token] Using token: <redacted>
[bootstrap-token] Configuring bootstrap tokens, cluster-info ConfigMap, RBAC Roles
[bootstrap-token] Configured RBAC rules to allow Node Bootstrap tokens to get nodes
[bootstrap-token] Configured RBAC rules to allow Node Bootstrap tokens to post CSRs in order for nodes to get long term certificate credentials
[bootstrap-token] Configured RBAC rules to allow the csrapprover controller automatically approve CSRs from a Node Bootstrap Token
[bootstrap-token] Configured RBAC rules to allow certificate rotation for all node client certificates in the cluster
[bootstrap-token] Creating the "cluster-info" ConfigMap in the "kube-public" namespace
[kubelet-finalize] Updating "/etc/kubernetes/kubelet.conf" to point to a rotatable kubelet client certificate and key
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

You can now join any number of control-plane nodes by copying certificate authorities
and service account keys on each node and then running the following as root:

  kubeadm join 192.168.8.205:6443 --token <redacted> \
	--discovery-token-ca-cert-hash sha256: <redacted> \
	--control-plane

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.8.205:6443 --token <redacted> \
	--discovery-token-ca-cert-hash sha256: <redacted>
```

and we're back in business! It's good security hygeine to keep the join token secret but if ever it's exposed you can generate a new one with `kubeadm token create --print-join-command`

## Finishing up

Now to run

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown "$(id -u):$(id -g)" $HOME/.kube/config
```

and install the pod network. For the 10.244.0.0/16 pod CIDR I used, Flannel is a straightforward choice:

`kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml`

```bash
david@cp1:~ $ kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
namespace/kube-flannel created
clusterrole.rbac.authorization.k8s.io/flannel created
clusterrolebinding.rbac.authorization.k8s.io/flannel created
serviceaccount/flannel created
configmap/kube-flannel-cfg created
daemonset.apps/kube-flannel-ds created
```

Now to check the state of my pods:

```bash
david@cp1:~ $ kubectl get pods -A
NAMESPACE      NAME                          READY   STATUS              RESTARTS      AGE
kube-flannel   kube-flannel-ds-f4zbc         0/1     CrashLoopBackOff    4 (54s ago)   2m34s
kube-system    coredns-66bc5c9577-lbdjl      0/1     ContainerCreating   0             26m
kube-system    coredns-66bc5c9577-zzl5h      0/1     ContainerCreating   0             26m
kube-system    etcd-cp1                      1/1     Running             6             26m
kube-system    kube-apiserver-cp1            1/1     Running             6             26m
kube-system    kube-controller-manager-cp1   1/1     Running             4             26m
kube-system    kube-proxy-lr2xt              1/1     Running             0             26m
kube-system    kube-scheduler-cp1            1/1     Running             4             26m
```

Further investigation

```bash
david@cp1:~ $ kubectl -n kube-flannel logs kube-flannel-ds-f4zbc -c kube-flannel
I1215 02:48:22.230761       1 main.go:215] CLI flags config: {etcdEndpoints:http://127.0.0.1:4001,http://127.0.0.1:2379 etcdPrefix:/coreos.com/network etcdKeyfile: etcdCertfile: etcdCAFile: etcdUsername: etcdPassword: version:false kubeSubnetMgr:true kubeApiUrl: kubeAnnotationPrefix:flannel.alpha.coreos.com kubeConfigFile: iface:[] ifaceRegex:[] ipMasq:true ipMasqRandomFullyDisable:false ifaceCanReach: subnetFile:/run/flannel/subnet.env publicIP: publicIPv6: subnetLeaseRenewMargin:60 healthzIP:0.0.0.0 healthzPort:0 iptablesResyncSeconds:5 iptablesForwardRules:true blackholeRoute:false netConfPath:/etc/kube-flannel/net-conf.json setNodeNetworkUnavailable:true}
W1215 02:48:22.230989       1 client_config.go:659] Neither --kubeconfig nor --master was specified.  Using the inClusterConfig.  This might not work.
I1215 02:48:22.248728       1 kube.go:139] Waiting 10m0s for node controller to sync
I1215 02:48:22.248932       1 kube.go:537] Starting kube subnet manager
I1215 02:48:23.248917       1 kube.go:163] Node controller sync successful
I1215 02:48:23.248976       1 main.go:241] Created subnet manager: Kubernetes Subnet Manager - cp1
I1215 02:48:23.248988       1 main.go:244] Installing signal handlers
I1215 02:48:23.249333       1 main.go:523] Found network config - Backend type: vxlan
E1215 02:48:23.249419       1 main.go:278] Failed to check br_netfilter: stat /proc/sys/net/bridge/bridge-nf-call-iptables: no such file or directory
```

The kernel is missing the br_netfilter module that Flannel expects for iptables on bridged traffic

```bash
sudo modprobe br_netfilter

echo "net.bridge.bridge-nf-call-iptables = 1" | sudo tee /etc/sysctl.d/99-bridge.conf
echo "net.bridge.bridge-nf-call-ip6tables = 1" | sudo tee -a /etc/sysctl.d/99-bridge.conf
echo "net.bridge.bridge-nf-call-arptables = 1" | sudo tee -a /etc/sysctl.d/99-bridge.conf

sudo sysctl --system
```

This loads the kernel module and ensures the bridge sysctls are set on boot. Restart flannel by deleting its pod (so that the deamon set recreates it):

```bash
kubectl -n kube-flannel delete pod kube-flannel-ds-f4zbc
```
Lastly, to verify all pods are running and the node is in Ready state:

```bash
david@cp1:~ $ kubectl get nodes
kubectl get pods -A
NAME   STATUS   ROLES           AGE   VERSION
cp1    Ready    control-plane   33m   v1.34.3
NAMESPACE      NAME                          READY   STATUS    RESTARTS   AGE
kube-flannel   kube-flannel-ds-wklmw         1/1     Running   0          77s
kube-system    coredns-66bc5c9577-lbdjl      1/1     Running   0          33m
kube-system    coredns-66bc5c9577-zzl5h      1/1     Running   0          33m
kube-system    etcd-cp1                      1/1     Running   6          33m
kube-system    kube-apiserver-cp1            1/1     Running   6          33m
kube-system    kube-controller-manager-cp1   1/1     Running   4          33m
kube-system    kube-proxy-lr2xt              1/1     Running   0          33m
kube-system    kube-scheduler-cp1            1/1     Running   4          33m
```

## Shutting down safely

Before powering off
```bash
# Stop scheduling new pods on cp1
kubectl cordon cp1

# Evict existing workloads (ignoring DaemonSets like flannel, kube-proxy)
kubectl drain cp1 --ignore-daemonsets --delete-emptydir-data
```
This lets pods receive SIGTERM and exit cleanly instead of being killed mid‑request.​

Then shut down the Pi:

```bash
sudo shutdown -h now
```

Wait until LEDs indicate it is fully off before unpluging.

To start it up again, after boot up has finished Check that the node and pods recovered:

```bash
kubectl get nodes
kubectl get pods -A
```
If node is Ready, it can be made schedulable again:

```bash
kubectl uncordon cp1
```

#### On cp2:
* Same export VIP and INTERFACE.
* Same KVVERSION and alias kube-vip=....
* Same kube-vip manifest pod ... | sudo tee /etc/kubernetes/manifests/kube-vip.yaml.
* Then use the kubeadm join --control-plane ... command from cp1.
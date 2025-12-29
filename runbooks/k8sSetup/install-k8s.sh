#!/bin/bash

# Kubernetes Installation Script for Raspberry Pi 5 (Debian/Ubuntu)
# Author: David Light
# Supports:
#   - NODE_TYPE=master        (control plane)
#   - NODE_TYPE=additional-cp (extra control plane nodes)
#   - NODE_TYPE=worker        (worker nodes)
#
# MANDATORY ENV VARS (must be set before running):
#   MASTER_IP     -> IP address of the primary control plane node
#   KUBE_VERSION  -> Kubernetes major.minor version (e.g. 1.34)
#   NODE_TYPE     -> "master" | "additional-cp" | "worker"
#
# OPTIONAL ENV VARS:
#   CNI                 -> "flannel" (default) or "cilium"
#   POD_CIDR            -> Pod network CIDR (default 10.244.0.0/16)
#   ADDITIONAL_CP_IPS   -> Space-separated IPs of extra control-plane nodes
#   WORKER_IPS          -> Space-separated IPs of worker nodes

set -e

##########################
# Environment validation #
##########################
check_env() {
    echo "=== Kubernetes Raspberry Pi install: environment check ==="
    echo
    echo "Mandatory environment variables:"
    echo "  MASTER_IP     -> e.g. 192.168.8.201"
    echo "  KUBE_VERSION  -> e.g. 1.34"
    echo "  NODE_TYPE     -> master | additional-cp | worker"
    echo
    echo "Optional environment variables:"
    echo "  CNI                 -> flannel (default) or cilium"
    echo "  POD_CIDR            -> e.g. 10.244.0.0/16 or 192.168.0.0/16"
    echo "  ADDITIONAL_CP_IPS   -> e.g. \"192.168.8.202 192.168.8.203\""
    echo "  WORKER_IPS          -> e.g. \"192.168.8.211 192.168.8.212\""
    echo

    MISSING=0

    if [[ -z "${MASTER_IP}" ]]; then
        echo "ERROR: MASTER_IP is not set."
        MISSING=1
    fi

    if [[ -z "${KUBE_VERSION}" ]]; then
        echo "ERROR: KUBE_VERSION is not set."
        MISSING=1
    fi

    if [[ -z "${NODE_TYPE}" ]]; then
        echo "ERROR: NODE_TYPE is not set."
        MISSING=1
    else
        case "${NODE_TYPE}" in
            master|additional-cp|worker)
                ;;
            *)
                echo "ERROR: NODE_TYPE must be one of: master | additional-cp | worker"
                MISSING=1
                ;;
        esac
    fi

    if [[ "${MISSING}" -ne 0 ]]; then
        echo
        echo "One or more mandatory environment variables are missing or invalid."
        echo "Example:"
        echo "  export MASTER_IP=\"192.168.8.201\""
        echo "  export KUBE_VERSION=\"1.34\""
        echo "  export NODE_TYPE=\"master\"           # or additional-cp | worker"
        echo "  export CNI=\"cilium\"                 # optional"
        echo "  export POD_CIDR=\"192.168.0.0/16\"    # optional"
        echo
        echo "Aborting before making any changes."
        exit 1
    fi

    echo "Environment looks good. Continuing..."
    echo
}

check_env

##########################
# Defaults and detection #
##########################

POD_CIDR=${POD_CIDR:-10.244.0.0/16}
CNI=${CNI:-flannel}

HOST_IP=$(hostname -I | awk '{print $1}')
echo "Detected node IP: ${HOST_IP}"
echo "Configured MASTER_IP: ${MASTER_IP}"
echo "KUBE_VERSION: ${KUBE_VERSION}"
echo "NODE_TYPE: ${NODE_TYPE}"
echo "CNI: ${CNI}"
echo "POD_CIDR: ${POD_CIDR}"
echo

#########################################
# Disable ALL swap, including zram swap #
#########################################
disable_swap_completely() {
    echo "Disabling swap (including Raspberry Pi zram swap)..."

    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab

    if systemctl list-units 'dev-zram0.swap' --no-legend 2>/dev/null | grep -q dev-zram0.swap; then
        sudo systemctl stop dev-zram0.swap || true
    fi
    if systemctl list-units 'systemd-zram-setup@zram0.service' --no-legend 2>/dev/null | grep -q systemd-zram-setup@zram0.service; then
        sudo systemctl stop systemd-zram-setup@zram0.service || true
    fi
    if systemctl list-units 'rpi-zram-writeback.timer' --no-legend 2>/dev/null | grep -q rpi-zram-writeback.timer; then
        sudo systemctl stop rpi-zram-writeback.timer || true
    fi
    if systemctl list-units 'rpi-setup-loop@var-swap.service' --no-legend 2>/dev/null | grep -q rpi-setup-loop@var-swap.service; then
        sudo systemctl stop rpi-setup-loop@var-swap.service || true
    fi

    if dpkg -l | grep -q rpi-swap; then
        sudo apt-get purge -y rpi-swap || true
    fi
    if dpkg -l | grep -q systemd-zram-generator; then
        sudo apt-get remove -y systemd-zram-generator || true
    fi

    echo "Current swap status (should show 0B / no devices):"
    free -h
    swapon --show || true
    echo
}

#################################
# Cgroup configuration (v2 fix) #
#################################
configure_cgroups() {
    echo "Configuring cgroups for kubeadm on Raspberry Pi OS..."

    # Ensure IP forwarding.[page:0]
    sudo sysctl net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ipforward.conf >/dev/null
    sudo sysctl --system

    CMDLINE_FILE="/boot/firmware/cmdline.txt"
    if [[ -f "${CMDLINE_FILE}" ]]; then
        echo "Updating ${CMDLINE_FILE} for unified cgroup hierarchy and memory/hugetlb controllers..."
        CURRENT_CMDLINE=$(sudo cat "${CMDLINE_FILE}")

        for arg in systemd.unified_cgroup_hierarchy=1 cgroup_enable=memory cgroup_memory=1 cgroup_enable=hugetlb; do
            if ! grep -q "${arg}" <<< "${CURRENT_CMDLINE}"; then
                CURRENT_CMDLINE="${CURRENT_CMDLINE} ${arg}"
            fi
        done

        echo "${CURRENT_CMDLINE}" | sudo tee "${CMDLINE_FILE}" >/dev/null

        echo
        read -r -p "Is this the first time you are enabling cgroup v2 memory/hugetlb on this node? (y/n): " FIRST_TIME
        case "${FIRST_TIME}" in
            y|Y)
                echo "Rebooting now so cgroup changes take effect. Re-run this script after the system comes back up."
                sleep 3
                sudo reboot
                ;;
            n|N)
                echo "Continuing without reboot; assuming cgroup changes are already active from a previous boot."
                ;;
            *)
                echo "Unrecognized answer. Continuing without reboot; if this was the first time, please reboot manually."
                ;;
        esac
    else
        echo "WARNING: ${CMDLINE_FILE} not found; cannot enforce cgroup parameters automatically."
        echo "Manually add: systemd.unified_cgroup_hierarchy=1 cgroup_enable=memory cgroup_memory=1 cgroup_enable=hugetlb"
    fi

    echo
    echo "Current cgroup mounts:"
    mount | grep cgroup || true
    echo
}

###############################
# Common prerequisites (ALL) #
###############################

install_prerequisites() {
    sudo apt-get update && sudo apt-get upgrade -y
    sudo apt-get install -y curl apt-transport-https ca-certificates gnupg lsb-release

    disable_swap_completely
    configure_cgroups

    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter

    cat <<EOF | sudo tee /etc/sysctl.d/k8s-kernel.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sudo sysctl --system
}

###################
# containerd setup #
###################

install_containerd() {
    sudo apt-get update && sudo apt-get install -y ca-certificates curl gpg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y containerd.io

    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo systemctl restart containerd
    sudo systemctl enable containerd
}

###########################
# Kubernetes components   #
###########################

install_kubernetes() {
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list

    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
}

###########################
# Master node setup       #
###########################

setup_master() {
    echo "Setting up Master Node (Control Plane) with CNI=${CNI} ..."
    echo

    # Ignore SystemVerification because of cgroup v2 memory/hugetlb behavior on Pi OS.[page:0][web:88]
    sudo kubeadm init \
        --control-plane-endpoint="${MASTER_IP}:6443" \
        --pod-network-cidr="${POD_CIDR}" \
        --ignore-preflight-errors=SystemVerification \
        --cri-socket unix:///run/containerd/containerd.sock

    mkdir -p "${HOME}/.kube"
    sudo cp -i /etc/kubernetes/admin.conf "${HOME}/.kube/config"
    sudo chown "$(id -u)":"$(id -g)" "${HOME}/.kube/config"

    kubeadm token create --print-join-command > join-worker.sh

    CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -1)
    kubeadm token create --print-join-command --certificate-key "${CERT_KEY}" > join-controlplane.sh

    chmod +x join-worker.sh join-controlplane.sh

    echo "Generated join scripts in current directory:"
    echo "  ./join-worker.sh"
    echo "  ./join-controlplane.sh"
    echo

    case "${CNI}" in
        "cilium")
            echo "Installing Cilium..."
            curl -LO "https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-arm64.tar.gz"
            sudo tar xzvfC cilium-linux-arm64.tar.gz /usr/local/bin
            rm cilium-linux-arm64.tar.gz

            cilium install \
                --version 1.17 \
                --set kubeProxyReplacement=strict \
                --set ipam.operator.clusterPoolIPv4PodCIDR="${POD_CIDR}"
            ;;
        "flannel")
            echo "Installing Flannel..."
            kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
            ;;
        *)
            echo "ERROR: Unsupported CNI '${CNI}'. Use 'flannel' or 'cilium'."
            exit 1
            ;;
    esac

    echo "Master setup complete."
}

##################################
# Additional control plane setup #
##################################

setup_additional_cp() {
    echo "Setting up Additional Control Plane Node..."
    if [[ ! -f "./join-controlplane.sh" ]]; then
        echo "ERROR: join-controlplane.sh not found in current directory."
        echo "Copy it from the master node first."
        exit 1
    fi
    sudo bash ./join-controlplane.sh
}

#####################
# Worker node setup #
#####################

setup_worker() {
    echo "Setting up Worker Node..."
    if [[ ! -f "./join-worker.sh" ]]; then
        echo "ERROR: join-worker.sh not found in current directory."
        echo "Copy it from the master node first."
        exit 1
    fi
    sudo bash ./join-worker.sh
}

########
# Main #
########

main() {
    install_prerequisites
    install_containerd
    install_kubernetes

    case "${NODE_TYPE}" in
        "master")
            setup_master
            ;;
        "additional-cp")
            setup_additional_cp
            ;;
        "worker")
            setup_worker
            ;;
        *)
            echo "ERROR: Invalid NODE_TYPE '${NODE_TYPE}'."
            exit 1
            ;;
    esac

    echo
    echo "Done. On the master node, run:"
    echo "  kubectl get nodes -o wide"
}

main "$@"

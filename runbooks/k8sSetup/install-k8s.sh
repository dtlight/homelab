#!/bin/bash

# Kubernetes Installation Script for Raspberry Pi 5 (Debian) and Ubuntu on X86_64 machines
# Author: David Light
# Version: 2.0.0
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

set -uo pipefail #catch hidden pipeline errors

##########################
# Environment validation #
##########################

# required env vars
REQUIRED_ENV_VARS=(
    KUBE_VERSION
    NODE_TYPE
    MASTER_IP
)

# Function to fail without killing the parent shell when sourced over SSH
env_check() {
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
    
    local missing=0

    for v in "${REQUIRED_ENV_VARS[@]}"; do
        if [[ -z "${!v:-}" ]]; then
        echo "ERROR: Required environment variable '$v' is not set." >&2
        missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        echo "Aborting install-k8s.sh due to missing environment variables." >&2.
        return 1
    fi
}


##########################
# OS / Distro detection #
##########################

source /etc/os-release

OS_ID="${ID}"
OS_VERSION="${VERSION_ID}"
OS_CODENAME="${VERSION_CODENAME:-}"
ARCH="$(dpkg --print-architecture)"

IS_UBUNTU=false
IS_DEBIAN=false
IS_RPI=false

case "${OS_ID}" in
    ubuntu)
        IS_UBUNTU=true
        ;;
    debian|raspbian)
        IS_DEBIAN=true
        ;;
esac

if [[ -f /proc/device-tree/model ]] && grep -qi "raspberry pi" /proc/device-tree/model; then
    IS_RPI=true
fi

if ! $IS_UBUNTU && ! $IS_DEBIAN; then
    echo "ERROR: Unsupported OS (${OS_ID}). Only Ubuntu and Debian-based systems are supported."
    exit 1
fi

echo "Detected system:"
echo "  OS        : ${OS_ID}"
echo "  Version   : ${OS_VERSION}"
echo "  Codename  : ${OS_CODENAME}"
echo "  Arch      : ${ARCH}"
echo "  Raspberry Pi: ${IS_RPI}"
echo

##########################
# Defaults               #
##########################

POD_CIDR=${POD_CIDR:-10.244.0.0/16}
CNI=${CNI:-flannel}
HOST_IP=$(hostname -I | awk '{print $1}')

##########################
# Swap handling          #
##########################

disable_swap_completely() {
    echo "Disabling swap..."

    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab

    if $IS_RPI; then
        echo "Disabling Raspberry Pi zram swap"
        systemctl stop dev-zram0.swap 2>/dev/null || true
        systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
        systemctl stop rpi-zram-writeback.timer 2>/dev/null || true
        systemctl stop rpi-setup-loop@var-swap.service 2>/dev/null || true
        apt-get purge -y rpi-swap 2>/dev/null || true
        apt-get remove -y systemd-zram-generator 2>/dev/null || true
    fi

    swapon --show || true
    echo
}

##########################
# Cgroup configuration  #
##########################

configure_cgroups() {
    echo "Configuring cgroups..."

    sudo sysctl net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ipforward.conf >/dev/null
    sudo sysctl --system

    if $IS_RPI; then
        echo "Raspberry Pi detected — configuring boot cmdline"

        CMDLINE_FILE="/boot/firmware/cmdline.txt"
        if [[ -f "${CMDLINE_FILE}" ]]; then
            CURRENT_CMDLINE=$(sudo cat "${CMDLINE_FILE}")
            for arg in systemd.unified_cgroup_hierarchy=1 cgroup_enable=memory cgroup_memory=1; do
                grep -q "${arg}" <<< "${CURRENT_CMDLINE}" || CURRENT_CMDLINE="${CURRENT_CMDLINE} ${arg}"
            done
            echo "${CURRENT_CMDLINE}" | sudo tee "${CMDLINE_FILE}" >/dev/null
            echo "NOTE: Reboot required for cgroup changes."
        fi

    elif $IS_UBUNTU; then
        echo "Ubuntu detected — verifying cgroup v2"
        if ! mount | grep -q cgroup2; then
            echo "ERROR: cgroup v2 is not enabled. Ubuntu 22.04+ should enable it by default."
            exit 1
        fi
    fi

    mount | grep cgroup || true
    echo
}

##########################
# Common prerequisites  #
##########################

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

##########################
# containerd setup      #
##########################

install_containerd() {
    DOCKER_OS="debian"
    $IS_UBUNTU && DOCKER_OS="ubuntu"

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${DOCKER_OS}/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/${DOCKER_OS} ${OS_CODENAME} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y containerd.io

    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    sudo systemctl restart containerd
    sudo systemctl enable containerd
}

##########################
# Kubernetes components #
##########################

install_kubernetes() {
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list

    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
}

##########################
# Master setup          #
##########################

setup_master() {
    echo "Setting up control plane..."

    KUBEADM_EXTRA_ARGS=()
    $IS_RPI && KUBEADM_EXTRA_ARGS+=(--ignore-preflight-errors=SystemVerification)

    sudo kubeadm init \
        --control-plane-endpoint="${MASTER_IP}:6443" \
        --pod-network-cidr="${POD_CIDR}" \
        --cri-socket unix:///run/containerd/containerd.sock \
        "${KUBEADM_EXTRA_ARGS[@]}"

    mkdir -p "${HOME}/.kube"
    sudo cp /etc/kubernetes/admin.conf "${HOME}/.kube/config"
    sudo chown "$(id -u)":"$(id -g)" "${HOME}/.kube/config"

    kubeadm token create --print-join-command > join-worker.sh
    CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -1)
    kubeadm token create --print-join-command --certificate-key "${CERT_KEY}" > join-controlplane.sh
    chmod +x join-*.sh

    case "${CNI}" in
        flannel)
            kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
            ;;
        cilium)
            curl -LO https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-${ARCH}.tar.gz
            sudo tar xzvfC cilium-linux-${ARCH}.tar.gz /usr/local/bin
            cilium install --version 1.17
            ;;
        *)
            echo "Unsupported CNI: ${CNI}"
            exit 1
            ;;
    esac
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

##########################
# Main                  #
##########################

main() {
    if ! env_check; then
        echo "Fix the errors above and re-run the script."
        return 1 2>/dev/null || exit 1
    fi

    echo "Environment looks good. Continuing..."
    echo

    install_prerequisites
    install_containerd
    install_kubernetes

    case "${NODE_TYPE}" in
        master) setup_master ;;
        additional-cp) setup_additional_cp ;;
        worker) setup_worker ;;
        *) echo "Invalid NODE_TYPE"; exit 1 ;;
    esac

    echo "Installation complete."
}

main "$@"

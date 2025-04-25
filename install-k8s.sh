#!/usr/bin/env bash
set -euo pipefail

# ─── 1. Prereqs: install Multipass via Homebrew if needed ──────────────────────
if ! command -v multipass &> /dev/null; then
  echo "🔄 Installing Multipass..."
  brew install --cask multipass
fi

# ─── 2. VM names and specs ─────────────────────────────────────────────────────
# Adjust these to the names you prefer for your Multipass VMs
MASTER=k8s-master
WORKER1=k8s-worker1
WORKER2=k8s-worker2

echo "🚀 Launching VMs..."
multipass launch --name $MASTER   --cpus 4 --memory 8G  --disk 20G 22.04
multipass launch --name $WORKER1  --cpus 2 --memory 4G  --disk 10G 22.04
multipass launch --name $WORKER2  --cpus 2 --memory 4G  --disk 10G 22.04

echo "⏳ Waiting for VMs to boot..."
sleep 10

# ─── 3. Prepare each node: disable swap, load modules, sysctl, containerd, kubeadm/kubelet ──
for NODE in $MASTER $WORKER1 $WORKER2; do
  echo "🔧 Configuring $NODE..."
  multipass exec $NODE -- bash -s << 'EOF'
set -eux

# Disable swap
sudo swapoff -a
sudo sed -i '/ swap /s/^/#/' /etc/fstab

# Load Kubernetes kernel modules
cat <<MODS | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
MODS
sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl params for networking
cat <<SYSCTL | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                = 1
SYSCTL
sudo sysctl --system

# Install containerd
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Install Kubernetes components
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
  | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
EOF
done

# ─── 4. Initialize the master ──────────────────────────────────────────────────
MASTER_IP=$(multipass info $MASTER | awk '/IPv4/ {print $2}')
echo "🎯 Pre-pulling control-plane images on master..."
multipass exec $MASTER -- sudo kubeadm config images pull --kubernetes-version=v1.32.4

echo "🎯 Initializing master (API at $MASTER_IP)..."
multipass exec $MASTER -- bash -s <<EOF
set -eux
sudo kubeadm init \
  --kubernetes-version v1.32.4 \
  --apiserver-advertise-address $MASTER_IP \
  --pod-network-cidr 10.244.0.0/16

# Set up kubectl for ubuntu user
mkdir -p \$HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
EOF

# ─── 5. Copy kubeconfig locally ───────────────────────────────────────────────
echo "📋 Copying kubeconfig to ~/.kube/multipass-k8s.conf"
mkdir -p ~/.kube
multipass transfer $MASTER:/home/ubuntu/.kube/config ~/.kube/multipass-k8s.conf
export KUBECONFIG=~/.kube/multipass-k8s.conf

# ─── 6. Install Calico Operator & CRDs ─────────────────────────────────────────
echo "📥 Installing Calico operator and CRDs..."
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/tigera-operator.yaml

# ─── 6a. Wait for the Installation CRD to be Established ───────────────────────
echo "⏳ Waiting for CRD installations.operator.tigera.io to be Established..."
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s

# ─── 7. Apply Calico Installation & APIServer CRs ───────────────────────────────
echo "🔨 Applying Calico Installation & APIServer resources..."
kubectl apply -f - <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - cidr: 10.244.0.0/16
      blockSize: 26
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

# ─── 8. Join the worker nodes ───────────────────────────────────────────────────
JOIN_CMD=$(multipass exec $MASTER -- sudo kubeadm token create --print-join-command)
echo "🔑 Join command: $JOIN_CMD"
for NODE in $WORKER1 $WORKER2; do
  echo "✋ Joining $NODE..."
  multipass exec $NODE -- sudo $JOIN_CMD
done

# ─── 9. Wait for all nodes to be Ready ─────────────────────────────────────────
echo "⏳ Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=2m

echo
kubectl get nodes
echo
kubectl get pods -A | grep -E "calico|tigera|csi-node-driver"

echo "✅ Kubernetes v1.32 cluster with Calico is up and Ready!"

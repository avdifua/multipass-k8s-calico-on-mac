# multipass-k8s-calico-on-mac

_Automated Kubernetes (v1.32) cluster provisioning on macOS with Multipass & Calico_

**Short Description:** A fully automated local Kubernetes (v1.32) cluster setup on macOS using Multipass and Calico CNI.

This repository contains a Bash script (`install-k8s.sh`) that automates the provisioning of a three-node Kubernetes (v1.32) cluster on an Apple Silicon MacBook (M1 Pro) using Multipass and Calico CNI.

---

## Table of Contents

- [Overview](#overview)  
- [Prerequisites](#prerequisites)  
- [VM Configuration](#vm-configuration)  
- [Usage](#usage)  
- [Script Breakdown](#script-breakdown)  
- [Validation](#validation)  
- [Cleanup](#cleanup)  
- [Troubleshooting](#troubleshooting)  
- [License](#license)  

---

## Overview

The `install-k8s.sh` script:

1. Installs Multipass (if not already present).  
2. Launches three Ubuntu 22.04 VMs (1 master, 2 workers).  
3. Prepares each VM for Kubernetes (disables swap, loads kernel modules, configures sysctl, installs containerd).  
4. Installs `kubeadm`, `kubelet`, and `kubectl` (v1.32.x) on each VM.  
5. Initializes the master node and pre-pulls control-plane images.  
6. Installs the Tigera Calico operator via server-side apply (avoiding CRD annotation errors).  
7. Waits for CRD establishment, then applies the Calico `Installation` and `APIServer` custom resources.  
8. Joins the two worker nodes automatically.  
9. Waits for all nodes to become **Ready** and verifies system pods.

---

## Prerequisites

- **macOS** with Homebrew installed.  
- **Multipass** (will be installed by the script if missing).  
- **Internet access** to pull Ubuntu images and Kubernetes/Calico manifests.

---

## VM Configuration

By default, the script uses the following names and specs (all tunable via environment variables at the top of the script):

| VM Name            | CPUs | RAM   | Disk  | Ubuntu Release |
|--------------------|:----:|:-----:|:-----:|:---------------|
| `k8s-master`   | 4    | 8 GB  | 20 GB | 22.04 LTS      |
| `k8s-worker1`  | 2    | 4 GB  | 10 GB | 22.04 LTS      |
| `k8s-worker2`  | 2    | 4 GB  | 10 GB | 22.04 LTS      |

Modify these at the top of `install-k8s.sh` if you prefer different names or resources.

---

## Usage

1. **Make the script executable**:

   ```bash
   chmod +x install-k8s.sh
   ```

2. **Run the script**:

   ```bash
   ./install-k8s.sh
   ```

   You will see progress logs as Multipass VMs are launched, configured, and the cluster is built.

3. **Point your `kubectl` to the new cluster**:

   ```bash
   export KUBECONFIG=~/.kube/multipass-k8s.conf
   kubectl get nodes
   ```

---

## Script Breakdown

- **Sections 1–2**: Verify/install Multipass and define VM names.  
- **Section 3**: Configures each VM:
  - Disables swap  
  - Loads `overlay` & `br_netfilter`  
  - Applies sysctl settings  
  - Installs and configures `containerd`  
  - Installs `kubeadm`, `kubelet`, `kubectl`  
- **Section 4**: On the master:
  - Pre-pull control-plane images  
  - Run `kubeadm init`  
  - Set up kubeconfig for the `ubuntu` user  
- **Section 5**: Copies kubeconfig locally, installs Tigera operator CRDs server-side, waits for the CRD to be established.  
- **Section 6**: Applies the Calico CNI `Installation` and `APIServer` custom resources.  
- **Section 7**: Joins the worker nodes via the generated `kubeadm join` command.  
- **Section 8**: Waits for all nodes to be **Ready** (using a generic wait) and prints final status.

---

## Validation

After the script completes, verify the cluster health:

```bash
export KUBECONFIG=~/.kube/multipass-k8s.conf
kubectl get nodes
kubectl get pods -A | grep -E "calico|tigera|csi-node-driver"
```

All nodes should be **Ready** and Calico/Tigera pods **Running**.

---

## Cleanup

- **Remove only this cluster’s VMs** (named in the script):

  ```bash
  multipass delete k8s-master k8s-worker1 k8s-worker2
  multipass purge
  ```

- **Remove all Multipass VMs** (if you want a fully clean slate):

  ```bash
  multipass stop --all
  multipass delete --all
  multipass purge
  ```

---

## Troubleshooting

- **`Installation` CRD not found**:

  ```bash
  kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s
  ```

- **Pause image warnings**: Resolved by the pre-pull step.  
- **Network or registry issues**: Ensure host internet connectivity to `registry.k8s.io` and GitHub.  
- **Node join hangs**: Verify the master’s advertise-address matches the IP reachable by workers.

---

## License

This project is licensed under the [MIT License](LICENSE).


# GCE Worker Configuration and Troubleshooting Reference

This document provides in-depth technical details on how the GCE worker skill operates, configuration options, network security, and recovery procedures.

---

## Architecture Overview

```
 ┌───────────────────────────────────────────────────────────────┐
 │ Google Cloud Platform (VPC: default / 10.0.0.0/8)             │
 │                                                               │
 │   ┌───────────────────────┐         ┌───────────────────────┐ │
 │   │ Primary VM            │         │ Worker VM (Preemptible│ │
 │   │ (agy-server)          │         │ agy-worker)           │ │
 │   │ Machine: e2-micro     │         │ Machine: e2-standard-4│ │
 │   │ IP: 10.128.15.197     │         │ IP: 10.128.x.x        │ │
 │   │                       │         │ (4 vCPU, 16 GiB RAM)  │ │
 │   │ ┌───────────────────┐ │ NFSv4.2 │ ┌───────────────────┐ │ │
 │   │ │ NFS Server        │◄├─────────┤ │ NFS Client        │ │ │
 │   │ │ (/home/user)      │ │Private IP│ │ Mount: /home/user │ │ │
 │   │ └───────────────────┘ │ (TCP2049)│ └───────────────────┘ │ │
 │   │                       │         │                       │ │
 │   │ ┌───────────────────┐ │   SSH   │ ┌───────────────────┐ │ │
 │   │ │ SSH Client / agy  ├─┼────────►│ │ sshd daemon       │ │ │
 │   │ └───────────────────┘ │Private IP│ └───────────────────┘ │ │
 │   └───────────────────────┘         └───────────────────────┘ │
 └───────────────────────────────────────────────────────────────┘
```

---

## Network & Security Restrictions

1. **Private Network Binding**:
   - The NFS server exports are restricted strictly to `10.0.0.0/8` in `/etc/exports.d/agy-home.exports`:
     ```text
     /home/<user> 10.0.0.0/8(rw,sync,no_subtree_check,no_root_squash)
     ```
   - Firewall rules in `iptables` drop any incoming traffic on ports `111` and `2049` not originating from `10.0.0.0/8` or `127.0.0.1`.
   - GCP VPC firewall rule `default-allow-internal` permits traffic between instances on the private network while public internet ingress to NFS ports is blocked by default.

2. **SSH Key Synchronization**:
   - The user's public key (`~/.ssh/google_compute_engine.pub` or `~/.ssh/id_rsa.pub`) is registered in instance metadata upon creation.
   - When `/home/<user>` is mounted from NFS, the worker's home directory immediately contains the same `~/.ssh/authorized_keys`.
   - The startup script also installs a copy into `/etc/ssh/authorized_keys/<user>` to allow SSH even before the NFS mount loop completes.

---

## Machine Types and Customization

You can customize the worker VM by supplying environment variables:

```bash
# Example: 8 vCPUs, 32 GiB RAM, 2 hours lifetime
MACHINE_TYPE=e2-standard-8 MAX_DURATION=2h LIFETIME_MINS=120 bash /home/khakimaroon/agy-off-site-skills/skills/gce-worker/scripts/worker.sh up
```

Common machine types in `us-central1-a`:

Machine Type | vCPUs | Memory | Spot Price (approx) | Best For
:--- | :--- | :--- | :--- | :---
`e2-standard-4` | 4 | 16 GiB | ~\$0.04/hr | Default for most builds & tests
`e2-standard-8` | 8 | 32 GiB | ~\$0.08/hr | Large parallel C++/Rust builds
`c2-standard-4` | 4 | 16 GiB | ~\$0.05/hr | Compute-heavy tasks, benchmarks
`n2-standard-4` | 4 | 16 GiB | ~\$0.05/hr | High-performance memory workloads

---

## Preemption & Crash Handling

Preemptible (SPOT) instances can be reclaimed by Google Cloud if capacity is constrained.

1. **Detection**:
   - `worker.sh run <cmd>` verifies instance state before executing.
   - If the instance is terminated or SSH fails to respond within 5 seconds, it marks the worker as crashed and reprovisions it.
   - If preemption occurs mid-execution (SSH exits with code 255 and VM transitions out of RUNNING), a warning is printed so you know the job was interrupted by preemption.
2. **Recovery**:
   - It automatically invokes `cmd_up` to delete the terminated VM and launch a new one.
   - All workspace files and git repositories reside on the primary VM's NFS export, so no code or modifications are lost during a preemption event.

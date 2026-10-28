---
name: gce-worker
description: Offload heavy build, compilation, test, or training tasks to a preemptible high-spec GCE worker VM in the same zone, sharing the home directory via private NFS. Use this skill when the local VM is low on memory or CPU, crashes due to out-of-memory (OOM) errors, or when running resource-intensive jobs.
---

# GCE Worker (Offsite High-Spec Preemptible VM)

This skill allows Antigravity to seamlessly offload memory-intensive and compute-heavy commands (such as large compilations, test suites, or ML training) to a high-capacity preemptible GCE virtual machine in the same Google Cloud zone.

The local home directory (`$HOME`) is shared with the worker VM over private NFS within the `10.0.0.0/8` VPC network. Files, git checkouts, build outputs, and SSH configurations remain immediately synchronized between machines.

--------------------------------------------------------------------------------

## Key Specifications & Defaults

- **Machine Shape**: `e2-standard-4` (4 vCPUs, 16 GiB RAM).
- **Provisioning Model**: Preemptible / SPOT (low-cost, terminates automatically).
- **Default Lifetime**: 6 hours (`--max-run-duration=6h` with `--instance-termination-action=DELETE` plus in-guest safety shutdown timer).
- **Network & Storage**: Private NFS server hosted on the primary VM, restricted strictly to `10.0.0.0/8`.
- **Fault Tolerance**: Automatic crash detection and replacement. If the VM is preempted or crashes, `worker.sh run` or `worker.sh up` recreates it automatically.

--------------------------------------------------------------------------------

## Quick Commands Reference

All helper scripts are located in [scripts/](./scripts/):

Command | Description
:--- | :---
`./scripts/worker.sh up` | Start or ensure the worker VM is running and ready.
`./scripts/worker.sh run <cmd>` | Execute a command on the worker VM in the current directory. Auto-restarts worker if crashed.
`./scripts/worker.sh ssh` | Open an interactive SSH session to the worker VM.
`./scripts/worker.sh status` | Check worker VM status, CPU count, RAM, uptime, and NFS mount.
`./scripts/worker.sh down` | Terminate and delete the worker VM when finished to avoid costs.
`./scripts/worker.sh ensure` | Verify worker VM health; reprovision if unresponsive or stopped.

*(Tip: You can invoke `bash /home/khakimaroon/agy-off-site-skills/skills/gce-worker/scripts/worker.sh <cmd>` from any directory).*

--------------------------------------------------------------------------------

## Step-by-Step Procedure

### 1. Launch / Ensure Worker VM

Before launching long-running or memory-heavy tasks:

```bash
bash /home/khakimaroon/agy-off-site-skills/skills/gce-worker/scripts/worker.sh up
```

This command automatically:
1. Verifies local SSH key setup (`~/.ssh/google_compute_engine`).
2. Configures the host's NFS server strictly for `10.0.0.0/8` via [setup-nfs.sh](./scripts/setup-nfs.sh).
3. Launches the preemptible GCE VM in the same zone as the current instance.
4. Waits for the worker VM to boot, mount `$HOME` via NFS, and signal readiness.

### 2. Execute Heavy Commands

Run any heavy command directly through `worker.sh run`:

```bash
bash /home/khakimaroon/agy-off-site-skills/skills/gce-worker/scripts/worker.sh run cargo build --release
```

Or for test suites and package builds:

```bash
bash /home/khakimaroon/agy-off-site-skills/skills/gce-worker/scripts/worker.sh run pytest -v
bash /home/khakimaroon/agy-off-site-skills/skills/gce-worker/scripts/worker.sh run npm run build
```

Because `$HOME` is mounted across both machines at the identical path, relative paths, workspace files, git repositories, and dependencies (like `~/.cargo`, `~/.cache`, or node modules) remain in sync.

### 3. Handling Crashes & Preemption

Worker VMs are preemptible (SPOT). If GCP preempts the VM or if it crashes:
- `worker.sh run` automatically detects that SSH is unresponsive or the instance is terminated.
- It spins up a fresh replacement instance with the exact same parameters.
- Because all files live on the host's persistent home directory, zero state is lost!

### 4. Teardown

When work is finished, delete the worker VM:

```bash
bash /home/khakimaroon/agy-off-site-skills/skills/gce-worker/scripts/worker.sh down
```

*(Note: Even if not deleted manually, the VM automatically self-destructs after 6 hours).*

--------------------------------------------------------------------------------

## Workflows, Customization & Troubleshooting

- For real-world workflows and tutorials (Cargo, PyTorch, Docker), see [examples/workflow.md](./examples/workflow.md).
- For detailed architecture, machine types, firewall settings, and troubleshooting, see [references/configuration.md](./references/configuration.md).

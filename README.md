# Antigravity Off-Site Skills

A collection of skills for [Google Antigravity](https://github.com/google/antigravity) that extend agent capabilities with cloud infrastructure automation.

---

## Skills Included

### 🚀 `gce-worker`
Offloads heavy build, compilation, test, or machine learning workloads to a high-capacity, low-cost preemptible (SPOT) Google Compute Engine VM in the same zone.

- **Specs**: Default 4 vCPUs, 16 GiB RAM (`e2-standard-4`), 6-hour automatic lifetime (`--max-run-duration=6h` with auto-deletion).
- **Private Storage**: Shares `$HOME` over private NFS (restricted strictly to `10.0.0.0/8`).
- **Zero Configuration Drift**: Changes, source files, and build outputs are instantaneously synchronized.
- **Fault-Tolerant**: Automatically restarts a fresh worker if preempted or stopped.

See the full skill documentation in [skills/gce-worker/SKILL.md](./skills/gce-worker/SKILL.md).

---

## Installation

Clone this repository and link the skill to your global Antigravity configuration or workspace:

```bash
# Global configuration (available across all projects on this machine)
mkdir -p ~/.gemini/config/skills
ln -sfn "$(pwd)/skills/gce-worker" ~/.gemini/config/skills/gce-worker

# Optional: Add the CLI helper to /usr/local/bin
sudo ln -sfn "$(pwd)/skills/gce-worker/scripts/worker.sh" /usr/local/bin/worker
```

---

## Quick Usage

```bash
# Start or verify worker VM
worker up

# Run any memory-intensive command on the worker VM
worker run cargo build --release
worker run pytest -v

# Check status
worker status

# Terminate worker VM when finished
worker down
```

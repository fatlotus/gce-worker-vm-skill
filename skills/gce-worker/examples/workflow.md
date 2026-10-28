# Example Workflows with GCE Worker

This guide illustrates real-world scenarios where Antigravity uses the GCE worker to avoid out-of-memory (OOM) crashes and speed up builds.

---

## 1. Building a Rust Project with Cargo

Rust builds often consume several gigabytes of RAM during macro expansion and linking. On an `e2-micro` (1 GB RAM), `cargo build` frequently gets killed by the Linux kernel OOM killer (`Signal 9`).

### Running via Worker

```bash
# In your project directory:
cd ~/onimath

# Run cargo build on the 16 GiB worker VM:
bash ~/agy-off-site-skills/skills/gce-worker/scripts/worker.sh run cargo build --release
```

- Cargo uses the shared `~/.cargo` cache across both machines.
- Target binaries are written to `./target/release/` which is immediately visible on the primary VM.

---

## 2. Running a Python Test Suite with Large Models or PyTorch

When evaluating machine learning benchmarks or processing large datasets:

```bash
bash ~/agy-off-site-skills/skills/gce-worker/scripts/worker.sh run pytest tests/ -n auto
```

The 4 vCPUs and 16 GiB memory allow pytest-xdist to parallelize test suites across all 4 cores without running out of RAM.

---

## 3. Interactive Debugging Session

If you need an interactive bash shell directly on the worker:

```bash
bash ~/agy-off-site-skills/skills/gce-worker/scripts/worker.sh ssh
```

Once connected:
- You are logged in as `khakimaroon` with matching UID/GID.
- Full passwordless `sudo` is available (`sudo apt-get install -y ...`).
- `$HOME` is mounted at `/home/khakimaroon`.
- Exit with `exit` or `Ctrl-D`.

---

## 4. Recreating After Crash or Preemption

If a preemptible worker is preempted or crashes during a long job:

```bash
# Check status:
bash ~/agy-off-site-skills/skills/gce-worker/scripts/worker.sh status

# Automatically restart worker:
bash ~/agy-off-site-skills/skills/gce-worker/scripts/worker.sh ensure
```

Because all source files and git commits reside on the primary machine, the new worker instantly mounts the identical workspace state.

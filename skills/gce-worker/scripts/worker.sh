#!/usr/bin/env bash
# worker.sh - Lifecycle manager for the GCE Offsite Worker VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration with defaults
WORKER_NAME="${WORKER_NAME:-agy-worker}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"       # 4 vCPUs, 16 GiB RAM
MAX_DURATION="${MAX_DURATION:-6h}"                  # 6 hours
LIFETIME_MINS="${LIFETIME_MINS:-360}"               # 360 minutes
DISK_SIZE="${DISK_SIZE:-30GB}"
IMAGE_FAMILY="${IMAGE_FAMILY:-debian-13}"
IMAGE_PROJECT="${IMAGE_PROJECT:-debian-cloud}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/google_compute_engine}"

# Auto-detect current GCE zone if not explicitly set
if [ -z "${ZONE:-}" ]; then
  ZONE=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null | awk -F/ '{print $NF}' || echo "us-central1-a")
fi

# Detect local private IP
detect_local_ip() {
  local ip
  ip=$(ip -4 -o addr show to 10.0.0.0/8 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true)
  if [ -z "${ip}" ]; then
    ip=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip 2>/dev/null || true)
  fi
  echo "${ip}"
}

# Get worker internal IP
get_worker_ip() {
  gcloud compute instances describe "${WORKER_NAME}" \
    --zone="${ZONE}" \
    --format="value(networkInterfaces[0].networkIP)" 2>/dev/null || echo ""
}

# Get worker instance status
get_worker_status() {
  gcloud compute instances describe "${WORKER_NAME}" \
    --zone="${ZONE}" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND"
}

# Test SSH connectivity to worker
test_ssh() {
  local ip="$1"
  [ -z "${ip}" ] && return 1
  ssh -q -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "${SSH_KEY}" "$(id -un)@${ip}" "true" 2>/dev/null
}

# Ensure NFS server is running on host
ensure_nfs() {
  if ! systemctl is-active --quiet nfs-kernel-server 2>/dev/null || ! sudo exportfs -v | grep -q "$HOME"; then
    echo "NFS server not active or home not exported. Running setup-nfs.sh..."
    bash "${SCRIPT_DIR}/setup-nfs.sh" "$HOME"
  fi
}

# Ensure SSH key exists
ensure_ssh_key() {
  if [ ! -f "${SSH_KEY}" ]; then
    if [ -f "$HOME/.ssh/id_rsa" ]; then
      SSH_KEY="$HOME/.ssh/id_rsa"
    elif [ -f "$HOME/.ssh/id_ed25519" ]; then
      SSH_KEY="$HOME/.ssh/id_ed25519"
    else
      echo "Generating SSH key pair at ${SSH_KEY}..."
      ssh-keygen -t rsa -b 3072 -f "${SSH_KEY}" -N "" -C "$(id -un)@$(hostname)"
    fi
  fi
  if [ ! -f "${SSH_KEY}.pub" ]; then
    ssh-keygen -y -f "${SSH_KEY}" > "${SSH_KEY}.pub"
  fi
  # Ensure local authorized_keys contains this key so mounting home authorizes it
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  local pubkey
  pubkey=$(cat "${SSH_KEY}.pub")
  if ! grep -qF "${pubkey}" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    echo "${pubkey}" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
  fi
}

cmd_up() {
  echo "=== Ensuring worker VM '${WORKER_NAME}' in zone '${ZONE}' ==="
  ensure_ssh_key
  ensure_nfs

  local local_ip
  local_ip=$(detect_local_ip)
  if [ -z "${local_ip}" ]; then
    echo "ERROR: Failed to detect local private 10.x.x.x IP for NFS export." >&2
    exit 1
  fi

  local current_status
  current_status=$(get_worker_status)
  local worker_ip
  worker_ip=$(get_worker_ip)

  if [ "${current_status}" = "RUNNING" ]; then
    echo "Worker instance exists and status is RUNNING (IP: ${worker_ip}). Testing health..."
    if test_ssh "${worker_ip}"; then
      echo "Worker is healthy and reachable over SSH."
      return 0
    else
      echo "Worker is RUNNING but unreachable over SSH. Recreating to recover..."
      cmd_down
    fi
  elif [ "${current_status}" != "NOT_FOUND" ]; then
    echo "Worker instance is in state '${current_status}'. Deleting and recreating..."
    cmd_down
  fi

  echo "Creating preemptible worker VM '${WORKER_NAME}'..."
  echo "  Machine Type:      ${MACHINE_TYPE}"
  echo "  Zone:              ${ZONE}"
  echo "  Lifetime:          ${MAX_DURATION}"
  echo "  NFS Server:        ${local_ip}:$HOME"

  local ssh_pubkey
  ssh_pubkey=$(cat "${SSH_KEY}.pub")

  gcloud compute instances create "${WORKER_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --provisioning-model=SPOT \
    --instance-termination-action=DELETE \
    --max-run-duration="${MAX_DURATION}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --boot-disk-size="${DISK_SIZE}" \
    --metadata="nfs-server-ip=${local_ip},nfs-export-path=${HOME},remote-user=$(id -un),remote-uid=$(id -u),remote-gid=$(id -g),lifetime-minutes=${LIFETIME_MINS},ssh-keys=$(id -un):${ssh_pubkey}" \
    --metadata-from-file="startup-script=${SCRIPT_DIR}/worker-startup.sh"

  cmd_wait
}

cmd_wait() {
  echo "Waiting for worker VM to finish booting, start SSH, and mount NFS..."
  local worker_ip=""
  for i in $(seq 1 30); do
    worker_ip=$(get_worker_ip)
    if [ -n "${worker_ip}" ]; then
      break
    fi
    sleep 2
  done

  if [ -z "${worker_ip}" ]; then
    echo "ERROR: Could not get worker IP address." >&2
    exit 1
  fi
  echo "Worker IP is ${worker_ip}. Waiting for SSH and startup readiness..."

  local ready=0
  for attempt in $(seq 1 60); do
    if ssh -q -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "${SSH_KEY}" "$(id -un)@${worker_ip}" "test -f /var/run/worker-ready && mountpoint -q '$HOME'" 2>/dev/null; then
      ready=1
      break
    fi
    printf "."
    sleep 3
  done
  echo ""

  if [ "${ready}" -eq 1 ]; then
    echo "=== Worker VM '${WORKER_NAME}' is ready! ==="
    cmd_status
  else
    echo "WARNING: Worker VM responded or took longer than expected to report ready."
    echo "Checking startup log on worker..."
    ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY}" "$(id -un)@${worker_ip}" "sudo cat /var/log/worker-startup.log 2>/dev/null || true" || true
  fi
}

cmd_down() {
  echo "Deleting worker VM '${WORKER_NAME}' in zone '${ZONE}'..."
  gcloud compute instances delete "${WORKER_NAME}" --zone="${ZONE}" --quiet 2>/dev/null || true
  echo "Worker VM deleted."
}

cmd_status() {
  local status
  status=$(get_worker_status)
  local ip
  ip=$(get_worker_ip)

  echo "=== Worker VM Status ==="
  echo "Name:     ${WORKER_NAME}"
  echo "Zone:     ${ZONE}"
  echo "Status:   ${status}"
  echo "IP:       ${ip:-N/A}"

  if [ "${status}" = "RUNNING" ] && [ -n "${ip}" ]; then
    ensure_ssh_key
    if test_ssh "${ip}"; then
      echo "SSH:      Accessible"
      ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY}" "$(id -un)@${ip}" bash -s << 'EOF'
        echo "CPUs:     $(nproc)"
        echo "Memory:   $(free -h | awk '/^Mem:/ {print $2 " total, " $3 " used, " $7 " available"}')"
        echo "NFS:      $(mountpoint -q "$HOME" && echo "Mounted at $HOME (NFS)" || echo "NOT mounted")"
        echo "Uptime:   $(uptime -p 2>/dev/null || uptime)"
EOF
    else
      echo "SSH:      UNREACHABLE (VM may be crashed or booting)"
    fi
  fi
}

cmd_ssh() {
  ensure_ssh_key
  local ip
  ip=$(get_worker_ip)
  if [ -z "${ip}" ] || [ "$(get_worker_status)" != "RUNNING" ]; then
    echo "Worker is not running. Starting worker first..."
    cmd_up
    ip=$(get_worker_ip)
  fi

  exec ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY}" "$(id -un)@${ip}" "$@"
}

cmd_run() {
  ensure_ssh_key
  local ip
  ip=$(get_worker_ip)
  local current_status
  current_status=$(get_worker_status)

  # Check if alive and healthy. If crashed/preempted, automatically restart!
  if [ "${current_status}" != "RUNNING" ] || [ -z "${ip}" ] || ! test_ssh "${ip}"; then
    echo "Worker VM is not running or crashed. Automatically restarting replacement VM..."
    cmd_up
    ip=$(get_worker_ip)
  fi

  local cwd="${PWD}"
  echo "[Worker (${ip})] Executing in ${cwd}: $*"

  # Properly quote every individual argument so flags, quotes, and strings survive SSH
  local remote_cmd
  remote_cmd=$(printf '%q ' "$@")

  # Execute command in the matching current working directory on worker
  set +e
  ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY}" \
    "$(id -un)@${ip}" "cd $(printf '%q' "${cwd}") 2>/dev/null || cd; ${remote_cmd}"
  local exit_code=$?
  set -e

  # Detect if SSH disconnected due to VM preemption during execution
  if [ ${exit_code} -eq 255 ]; then
    local new_status
    new_status=$(get_worker_status)
    if [ "${new_status}" != "RUNNING" ]; then
      echo "WARNING: Worker VM '${WORKER_NAME}' was preempted or terminated (state: ${new_status}) during execution." >&2
      echo "Your files on the primary machine remain safe. Run the command again to relaunch." >&2
    fi
  fi

  return ${exit_code}
}

cmd_ensure() {
  local ip
  ip=$(get_worker_ip)
  if [ "$(get_worker_status)" != "RUNNING" ] || [ -z "${ip}" ] || ! test_ssh "${ip}"; then
    cmd_up
  else
    echo "Worker is up and healthy (IP: ${ip})."
  fi
}

# Main entrypoint
case "${1:-}" in
  up)
    cmd_up
    ;;
  down)
    cmd_down
    ;;
  wait)
    cmd_wait
    ;;
  status)
    cmd_status
    ;;
  ssh)
    shift
    cmd_ssh "$@"
    ;;
  run)
    shift
    cmd_run "$@"
    ;;
  ensure)
    cmd_ensure
    ;;
  *)
    echo "Usage: $0 {up|down|wait|status|ssh|run|ensure} [args...]"
    echo ""
    echo "Commands:"
    echo "  up       Ensure NFS is running and start the preemptible worker VM"
    echo "  down     Terminate and delete the worker VM"
    echo "  wait     Wait for the worker VM to finish booting and mount NFS"
    echo "  status   Show current status, resources, and mount state of worker"
    echo "  ssh      Open SSH shell or run interactive SSH command on worker"
    echo "  run      Run a command on the worker VM (auto-restarts worker if crashed)"
    echo "  ensure   Verify worker is running and healthy; recreate if needed"
    exit 1
    ;;
esac

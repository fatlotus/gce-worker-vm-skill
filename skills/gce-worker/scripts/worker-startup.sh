#!/usr/bin/env bash
# worker-startup.sh - Executed by GCE on worker VM boot
set -euo pipefail

LOG_FILE="/var/log/worker-startup.log"
exec > >(tee -a "${LOG_FILE}" /dev/console) 2>&1
echo "=== Worker startup initialized at $(date -u) ==="

get_meta() {
  local key="$1"
  curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}" || echo ""
}

NFS_SERVER=$(get_meta "nfs-server-ip")
NFS_EXPORT=$(get_meta "nfs-export-path")
REMOTE_USER=$(get_meta "remote-user")
REMOTE_UID=$(get_meta "remote-uid")
REMOTE_GID=$(get_meta "remote-gid")
LIFETIME_MINS=$(get_meta "lifetime-minutes")
[ -z "${LIFETIME_MINS}" ] && LIFETIME_MINS=360

echo "Configuration:"
echo "  NFS_SERVER:    ${NFS_SERVER}"
echo "  NFS_EXPORT:    ${NFS_EXPORT}"
echo "  REMOTE_USER:   ${REMOTE_USER}"
echo "  REMOTE_UID:    ${REMOTE_UID}"
echo "  REMOTE_GID:    ${REMOTE_GID}"
echo "  LIFETIME_MINS: ${LIFETIME_MINS}"

# Set OS-level shutdown timer as safety guard (defaults to 6 hours = 360 mins)
if [ "${LIFETIME_MINS}" -gt 0 ] 2>/dev/null; then
  echo "Scheduling self-destruct shutdown in ${LIFETIME_MINS} minutes..."
  shutdown -h "+${LIFETIME_MINS}" "Preemptible worker lifetime expired (${LIFETIME_MINS} mins)" || true
fi

# Pre-configure SSH daemon settings for smooth authentication
mkdir -p /etc/ssh/sshd_config.d /etc/ssh/authorized_keys
cat << 'EOF' > /etc/ssh/sshd_config.d/99-worker.conf
StrictModes no
AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys/%u
EOF
systemctl restart ssh

# Install prerequisites
echo "Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends nfs-common rpcbind ca-certificates curl git build-essential

# Reconcile user and group to match host UID & GID exactly
if [ -n "${REMOTE_USER}" ] && [ -n "${REMOTE_UID}" ] && [ -n "${REMOTE_GID}" ]; then
  echo "Reconciling UID ${REMOTE_UID} and GID ${REMOTE_GID} for ${REMOTE_USER}..."

  # Stop any conflicting user sessions
  systemctl stop "user@*.service" 2>/dev/null || true

  # If another user holds REMOTE_UID, move them to 2000+
  CURRENT_HOLDER=$(getent passwd "${REMOTE_UID}" | cut -d: -f1 || true)
  if [ -n "${CURRENT_HOLDER}" ] && [ "${CURRENT_HOLDER}" != "${REMOTE_USER}" ]; then
    echo "Relocating existing UID ${REMOTE_UID} holder '${CURRENT_HOLDER}' to UID 2099..."
    pkill -9 -u "${CURRENT_HOLDER}" 2>/dev/null || true
    usermod -u 2099 "${CURRENT_HOLDER}" 2>/dev/null || true
  fi

  # If another group holds REMOTE_GID, move them to 2000+
  CURRENT_GHOLDER=$(getent group "${REMOTE_GID}" | cut -d: -f1 || true)
  if [ -n "${CURRENT_GHOLDER}" ] && [ "${CURRENT_GHOLDER}" != "${REMOTE_USER}" ]; then
    echo "Relocating existing GID ${REMOTE_GID} holder '${CURRENT_GHOLDER}' to GID 2099..."
    groupmod -g 2099 "${CURRENT_GHOLDER}" 2>/dev/null || true
  fi

  # Kill any process of REMOTE_USER and wait for clean termination
  pkill -9 -u "${REMOTE_USER}" 2>/dev/null || true
  for _ in $(seq 1 10); do
    pgrep -u "${REMOTE_USER}" >/dev/null 2>&1 || break
    sleep 0.2
  done

  # Ensure group exists with REMOTE_GID
  if getent group "${REMOTE_USER}" >/dev/null 2>&1; then
    groupmod -g "${REMOTE_GID}" "${REMOTE_USER}" 2>/dev/null || true
  else
    groupadd -g "${REMOTE_GID}" "${REMOTE_USER}" 2>/dev/null || true
  fi

  # Ensure user exists with REMOTE_UID and REMOTE_GID, with unlocked password
  if id -u "${REMOTE_USER}" >/dev/null 2>&1; then
    usermod -u "${REMOTE_UID}" -g "${REMOTE_GID}" -p '*' -s /bin/bash "${REMOTE_USER}" 2>/dev/null || true
  else
    useradd -u "${REMOTE_UID}" -g "${REMOTE_GID}" -m -s /bin/bash -p '*' "${REMOTE_USER}" 2>/dev/null || true
  fi

  # Verify UID configuration
  ACTIVE_UID=$(id -u "${REMOTE_USER}" 2>/dev/null || echo "")
  if [ "${ACTIVE_UID}" != "${REMOTE_UID}" ]; then
    echo "WARNING: User UID is ${ACTIVE_UID}, expected ${REMOTE_UID}. Retrying forced adjustment..."
    sed -i "s/^${REMOTE_USER}:x:[0-9]*:[0-9]*/${REMOTE_USER}:x:${REMOTE_UID}:${REMOTE_GID}/" /etc/passwd
  fi

  # Add to sudoers
  usermod -aG sudo "${REMOTE_USER}" 2>/dev/null || true
  echo "${REMOTE_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-${REMOTE_USER}"
  chmod 0440 "/etc/sudoers.d/99-${REMOTE_USER}"
fi

# Mount NFS share using NFSv4.2 with robust hard mount options
if [ -n "${NFS_SERVER}" ] && [ -n "${NFS_EXPORT}" ]; then
  echo "Mounting NFS ${NFS_SERVER}:${NFS_EXPORT} at ${NFS_EXPORT} (NFSv4.2, hard)..."
  mkdir -p "${NFS_EXPORT}"

  if ! mountpoint -q "${NFS_EXPORT}"; then
    MOUNT_SUCCESS=0
    # Try NFSv4.2 first, falling back to standard v4
    for attempt in $(seq 1 25); do
      if mount -t nfs -o vers=4.2,rw,hard,timeo=600,retrans=5,_netdev "${NFS_SERVER}:${NFS_EXPORT}" "${NFS_EXPORT}" 2>/dev/null || \
         mount -t nfs -o vers=4,rw,hard,timeo=600,retrans=5,_netdev "${NFS_SERVER}:${NFS_EXPORT}" "${NFS_EXPORT}" 2>/dev/null || \
         mount -t nfs -o rw,hard,timeo=600,retrans=5,_netdev "${NFS_SERVER}:${NFS_EXPORT}" "${NFS_EXPORT}"; then
        echo "Successfully mounted ${NFS_EXPORT} (attempt ${attempt})"
        MOUNT_SUCCESS=1
        break
      fi
      echo "Mount attempt ${attempt}/25 failed; retrying in 2s..."
      sleep 2
    done

    if [ "${MOUNT_SUCCESS}" -ne 1 ]; then
      echo "ERROR: Failed to mount NFS share after 25 attempts." >&2
      exit 1
    fi
  else
    echo "${NFS_EXPORT} is already mounted."
  fi

  # Persist mount in fstab
  FSTAB_LINE="${NFS_SERVER}:${NFS_EXPORT} ${NFS_EXPORT} nfs vers=4.2,rw,hard,timeo=600,retrans=5,_netdev 0 0"
  if ! grep -qF "${NFS_SERVER}:${NFS_EXPORT}" /etc/fstab; then
    echo "${FSTAB_LINE}" >> /etc/fstab
  fi

  # Copy authorized_keys to local fallback directory if present
  if [ -f "${NFS_EXPORT}/.ssh/authorized_keys" ]; then
    cp "${NFS_EXPORT}/.ssh/authorized_keys" "/etc/ssh/authorized_keys/${REMOTE_USER}" 2>/dev/null || true
    chmod 644 "/etc/ssh/authorized_keys/${REMOTE_USER}" 2>/dev/null || true
  fi
fi

# Signal completion
touch /var/run/worker-ready
echo "=== Worker startup finished successfully at $(date -u) ==="

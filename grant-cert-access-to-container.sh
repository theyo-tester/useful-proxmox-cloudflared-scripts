#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <container-id> <full-path-to-lineage-directory>" >&2
  echo "Example: $0 111 /mnt/npm-certbot/live/npm-55" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage

ctid="$1"
lineage_dir="$2"

[[ "$ctid" =~ ^[0-9]+$ ]] || {
  echo "Invalid container ID: $ctid" >&2
  exit 2
}
[[ "$lineage_dir" = /* ]] || {
  echo "The lineage path must be absolute." >&2
  exit 2
}
[[ -d "$lineage_dir" ]] || {
  echo "Lineage directory not found: $lineage_dir" >&2
  exit 1
}

command -v pct >/dev/null || {
  echo "pct not found; run this on the Proxmox host." >&2
  exit 1
}
command -v setfacl >/dev/null || {
  echo "setfacl not found. Install ACL utilities with:" >&2
  echo "  apt update && apt install -y acl" >&2
  exit 1
}

# Determine the host UID to which container root maps.
uid_map="$(pct exec "$ctid" -- cat /proc/self/uid_map)"
host_uid="$(awk '$1 == 0 { print $2; exit }' <<< "$uid_map")"
[[ "$host_uid" =~ ^[0-9]+$ ]] || {
  echo "Could not determine the host UID mapped from container root." >&2
  exit 1
}

# Allow traversal through ancestors without changing their existing mode bits.
grant_traverse_ancestors() {
  local path="$1"
  local dir

  dir="$(dirname "$path")"
  while [[ "$dir" != "/" ]]; do
    setfacl -m "u:$host_uid:--x" "$dir"
    dir="$(dirname "$dir")"
  done
}

grant_traverse_ancestors "$lineage_dir"
setfacl -m "u:$host_uid:rx" "$lineage_dir"

for name in cert.pem chain.pem fullchain.pem privkey.pem; do
  link="$lineage_dir/$name"
  [[ -e "$link" ]] || {
    echo "Missing certificate file or broken symlink: $link" >&2
    exit 1
  }

  target="$(readlink -f -- "$link")"
  [[ -f "$target" ]] || {
    echo "Target is not a regular file: $target" >&2
    exit 1
  }

  grant_traverse_ancestors "$target"
  setfacl -m "u:$host_uid:r--" "$target"
done

echo "Granted container $ctid (mapped host UID $host_uid) access to $lineage_dir."

# Docker Data Migration Script

[简体中文说明请点这里 👉](README.zh.md)

---

## Overview
This script helps you **safely migrate Docker data directory** (default: `/var/lib/docker`) to a new location.  
It performs strict pre-checks, ensures sufficient disk space, validates configuration files, and automatically stops/starts Docker.

- **Project homepage**: [reshub-cn/docker-data-move.sh](https://github.com/reshub-cn/docker-data-move.sh)  
- **Official website**: [www.reshub.cn](https://www.reshub.cn)

---

## Features
- Preflight safety checks (root, commands, SELinux, disk space, JSON config validity).
- Supports Debian/Ubuntu, CentOS/RHEL, Alpine.
- Uses `rsync -aHAX --numeric-ids --delete` to preserve all data (including permissions, extended attributes, hard links).
- Automatic backup of the old Docker data directory.
- Automatically updates `/etc/docker/daemon.json` with the new `data-root`.
- Auto-installation of `jq` and `rsync` (if possible).

---

## Usage

```bash
# Download the script
curl -sSL https://raw.githubusercontent.com/reshub-cn/docker-data-move.sh/main/docker-move.sh -o docker-move.sh
chmod +x docker-move.sh

# Run (example: migrate to /data1/docker)
sudo ./docker-move.sh /data1/docker
```

### Optional: allow non-empty target directory
By default, the new directory must be empty.  
If you want to allow migrating into a non-empty directory, set:

```bash
ALLOW_NONEMPTY=1 sudo ./docker-move.sh /data1/docker
```

---

## Notes
- Always run as **root** (`sudo` required).
- Ensure target disk has **enough space**. The script checks if at least `max(used*110%, used+2GiB)` is available.
- If SELinux is enforcing, you must relabel the new directory:
  ```bash
  semanage fcontext -a -t container_var_lib_t "/data1/docker(/.*)?"
  restorecon -Rv /data1/docker
  ```
- Old data is backed up as `/var/lib/docker.bak.TIMESTAMP`.

---

## Verify After Migration
After Docker restarts, check:

```bash
docker info | grep "Docker Root Dir"
```

Output should point to your new path.

---

## License
MIT License © 2025 ResHub

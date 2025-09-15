#!/bin/bash
# ==========================================================
# Docker 数据迁移脚本（通用版，含严格检测）
# 用法: sudo ./docker-move.sh /data1/docker
#
# 项目主页: https://github.com/reshub-cn/docker-data-move.sh
# 官网: https://www.reshub.cn
# ==========================================================

set -euo pipefail


NEW_PATH=${1:-}
DOCKER_SERVICE="docker"
DOCKER_DIR="/var/lib/docker"
CONFIG_FILE="/etc/docker/daemon.json"

# 允许迁移到非空目录（默认 0=不允许）。需要时可临时：ALLOW_NONEMPTY=1 sudo ./docker-move.sh /path
ALLOW_NONEMPTY="${ALLOW_NONEMPTY:-0}"

# ----------- 通用输出/失败处理 -----------
die() { echo -e "\n[ERROR] $*\n" >&2; exit 1; }
info(){ echo "[INFO]  $*"; }
warn(){ echo "[WARN]  $*"; }

# ----------- 检测函数 -----------
require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行（sudo）。"
}

require_new_path() {
  [[ -n "$NEW_PATH" ]] || die "请输入新的 Docker 数据目录路径。用法: sudo $0 /data1/docker"
  [[ "$NEW_PATH" == /* ]] || die "新目录必须使用绝对路径：$NEW_PATH"
  [[ -d "$DOCKER_DIR" ]] || die "旧目录不存在：$DOCKER_DIR，未检测到常规 Docker 安装。"

  # 不允许相同或互相包含，防止递归/覆盖
  if [[ "$NEW_PATH" == "$DOCKER_DIR" ]]; then
    die "新目录不能与当前目录相同：$NEW_PATH"
  fi
  if [[ "$NEW_PATH" == "$DOCKER_DIR"* ]]; then
    die "新目录不能放在旧目录内部：$NEW_PATH 在 $DOCKER_DIR 内"
  fi
  if [[ "$DOCKER_DIR" == "$NEW_PATH"* ]]; then
    die "旧目录不能位于新目录内部：$DOCKER_DIR 在 $NEW_PATH 内"
  fi

  # 新目录存在性与是否空目录
  mkdir -p "$NEW_PATH" || die "无法创建新目录：$NEW_PATH"
  chown root:root "$NEW_PATH" || die "无法设置新目录属主：$NEW_PATH"
  if [[ "$ALLOW_NONEMPTY" != "1" ]]; then
    if [[ -d "$NEW_PATH" ]] && [[ -n "$(ls -A "$NEW_PATH" 2>/dev/null || true)" ]]; then
      die "新目录必须为空（或设置 ALLOW_NONEMPTY=1 跳过）：$NEW_PATH"
    fi
  fi
}

require_cmds() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker 命令，请先安装 Docker。"
  if ! command -v rsync >/dev/null 2>&1; then
    warn "未找到 rsync，尝试安装..."
    if [[ -f /etc/debian_version ]]; then
      apt update && apt install -y rsync || true
    elif [[ -f /etc/redhat-release ]]; then
      yum install -y rsync || dnf install -y rsync || true
    elif [[ -f /etc/alpine-release ]]; then
      apk add --no-cache rsync || true
    fi
  fi
  command -v rsync >/dev/null 2>&1 || die "无法安装 rsync，请手动安装后重试。"
}

check_space() {
  # 计算旧目录占用（字节）
  local used avail need parent
  used=$(du -sb "$DOCKER_DIR" 2>/dev/null | awk '{print $1}')
  [[ -n "$used" && "$used" -gt 0 ]] || die "无法获取 $DOCKER_DIR 占用空间。"

  # 目标路径未挂载时，df 也会找其所在分区
  parent="$NEW_PATH"
  [[ -d "$parent" ]] || parent="$(dirname "$NEW_PATH")"

  avail=$(df -P -B1 "$parent" 2>/dev/null | awk 'NR==2{print $4}')
  [[ -n "$avail" && "$avail" -gt 0 ]] || die "无法获取 $parent 所在分区可用空间。"

  # 需要空间 = max(used*1.10, used+2GiB)
  local need1 need2 GiB2
  GiB2=$((2*1024*1024*1024))
  need1=$(( (used * 110 + 99) / 100 ))   # 向上取整 110%
  need2=$(( used + GiB2 ))
  need=$(( need1 > need2 ? need1 : need2 ))

  info "旧目录占用：$used 字节；目标可用：$avail 字节；需要至少：$need 字节"
  [[ "$avail" -ge "$need" ]] || die "目标磁盘空间不足（需要：$need，可用：$avail）。请更换更大的磁盘/路径。"
}

check_selinux() {
  if command -v getenforce >/dev/null 2>&1; then
    local mode
    mode=$(getenforce 2>/dev/null || echo "")
    if [[ "$mode" == "Enforcing" ]]; then
      cat >&2 <<'EOF'

[ERROR] 检测到 SELinux 处于 Enforcing。为避免迁移后 Docker 无法读写新目录，请先为新目录添加正确标签：
  semanage fcontext -a -t container_var_lib_t "/新路径(/.*)?"
  restorecon -Rv /新路径
或临时将 SELinux 调整为 Permissive 后再执行。处理完毕后重试本脚本。

EOF
      exit 1
    fi
  fi
}

check_daemon_json() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # 如安装了 jq，校验 JSON；非法则备份并退出
    if command -v jq >/dev/null 2>&1; then
      if ! jq -e '.' "$CONFIG_FILE" >/dev/null 2>&1; then
        local bak="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$bak" || true
        die "检测到 $CONFIG_FILE 不是合法 JSON，已备份到：$bak，请修复后重试。"
      fi
    else
      warn "未安装 jq，无法校验 $CONFIG_FILE 的 JSON 合法性。"
    fi
  fi
}

preflight_checks() {
  info "开始进行安全预检..."
  require_root
  require_cmds
  require_new_path
  check_space
  check_selinux
  check_daemon_json
  info "预检通过 ✅"
}

# ----------- 停止/启动 Docker 的函数（原样保留） -----------
stop_docker() {
  if command -v systemctl &>/dev/null; then
    systemctl stop "$DOCKER_SERVICE" || true
    systemctl stop "${DOCKER_SERVICE}.socket" || true
  elif command -v service &>/dev/null; then
    service "$DOCKER_SERVICE" stop || true
  else
    die "未检测到 systemctl 或 service，无法自动停止 Docker。"
  fi
}

start_docker() {
  if command -v systemctl &>/dev/null; then
    systemctl daemon-reexec || true
    systemctl start "$DOCKER_SERVICE"
  elif command -v service &>/dev/null; then
    service "$DOCKER_SERVICE" start
  else
    die "未检测到 systemctl 或 service，无法自动启动 Docker。"
  fi
}


# ----------- 主流程 -----------
echo "开始迁移 Docker 数据目录到: $NEW_PATH"

# 自动安装 jq（保持你原有逻辑）
if ! command -v jq &>/dev/null; then
  echo "jq 未安装，正在尝试安装..."
  if [[ -f /etc/debian_version ]]; then
    apt update && apt install -y jq || true
  elif [[ -f /etc/redhat-release ]]; then
    yum install -y jq || dnf install -y jq || true
  elif [[ -f /etc/alpine-release ]]; then
    apk add --no-cache jq || true
  fi
fi

# 0. 预检
preflight_checks

# 1. 停止 Docker
echo "停止 Docker 服务..."
stop_docker

# 2. 再次确保新路径存在并权限正确
echo "检查新目录..."
mkdir -p "$NEW_PATH"
chown root:root "$NEW_PATH"

# 3. 迁移数据（严格失败即退出）
echo "迁移数据..."
rsync -aHAX --numeric-ids --delete --info=progress2 "$DOCKER_DIR/" "$NEW_PATH/"

# 4. 备份旧目录（避免重复执行时报错）
if [[ -d "$DOCKER_DIR" ]]; then
  echo "备份旧目录..."
  mv "$DOCKER_DIR" "${DOCKER_DIR}.bak.$(date +%Y%m%d%H%M%S)"
else
  echo "旧目录不存在，跳过备份步骤。"
fi

# 5. 修改配置文件
echo "修改 Docker 配置..."
mkdir -p "$(dirname "$CONFIG_FILE")"
if [[ -f "$CONFIG_FILE" && command -v jq >/dev/null 2>&1 ]]; then
  tmp="${CONFIG_FILE}.tmp"
  # 将 data-root 写入（保留其他字段）
  jq '.["data-root"]="'$NEW_PATH'"' "$CONFIG_FILE" > "$tmp" 2>/dev/null || {
    # jq 失败则回退为仅包含 data-root 的最小 JSON，但不覆盖原文件
    bak="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONFIG_FILE" "$bak" || true
    echo '{"data-root":"'$NEW_PATH'"}' > "$tmp"
    warn "原 $CONFIG_FILE 写入失败，已备份到 $bak，并用最小配置覆盖。"
  }
  mv "$tmp" "$CONFIG_FILE"
else
  echo '{"data-root":"'$NEW_PATH'"}' > "$CONFIG_FILE"
fi

# 6. 启动 Docker
echo "启动 Docker..."
start_docker

# 7. 验证
echo "验证 Docker 数据目录..."
if docker info >/dev/null 2>&1; then
  docker info | grep -E "Docker Root Dir:\s+$NEW_PATH" >/dev/null 2>&1 \
    && echo "验证通过：Docker Root Dir 已是 $NEW_PATH" \
    || die "验证失败：Docker Root Dir 未切换到 $NEW_PATH，请检查。"
else
  die "docker info 执行失败，请检查 Docker 是否正常运行。"
fi

echo "迁移完成！旧数据已备份（如存在）到: ${DOCKER_DIR}.bak.*"

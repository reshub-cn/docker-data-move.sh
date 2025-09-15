# Docker 数据迁移脚本

[English Version 👉](README.md)

该脚本用于 **安全迁移 Docker 数据目录**（默认 `/var/lib/docker`）到新的路径。  
它包含严格的预检步骤，自动停止和启动 Docker，确保迁移过程安全可靠。

- **项目主页**: [reshub-cn/docker-data-move.sh](https://github.com/reshub-cn/docker-data-move.sh)  
- **官网**: [www.reshub.cn](https://www.reshub.cn)

---

## 功能特性
- 自动进行安全预检（root 权限、命令依赖、SELinux、磁盘空间、JSON 配置合法性）。
- 支持 Debian/Ubuntu、CentOS/RHEL、Alpine。
- 使用 `rsync -aHAX --numeric-ids --delete`，完整保留文件权限、扩展属性、硬链接等。
- 自动备份旧目录，避免误删除。
- 自动修改 `/etc/docker/daemon.json` 的 `data-root`。
- 自动安装 `jq` 和 `rsync`（如果缺失）。

---

## 使用方法

```bash
# 下载脚本
curl -sSL https://raw.githubusercontent.com/reshub-cn/docker-data-move.sh/main/docker-move.sh -o docker-move.sh
chmod +x docker-move.sh

# 执行迁移（示例：迁移到 /data1/docker）
sudo ./docker-move.sh /data1/docker
```

### 可选参数：允许非空目录
默认要求新目录为空。  
如果需要迁移到非空目录，可使用：

```bash
ALLOW_NONEMPTY=1 sudo ./docker-move.sh /data1/docker
```

---

## 注意事项
- 必须以 **root 用户**（sudo）运行。
- 确认目标磁盘有足够空间（至少原占用的 **110% 或 +2GiB**）。
- 如果 SELinux 处于 Enforcing 模式，需要为新目录设置正确标签：
  ```bash
  semanage fcontext -a -t container_var_lib_t "/data1/docker(/.*)?"
  restorecon -Rv /data1/docker
  ```
- 旧目录会自动备份到 `/var/lib/docker.bak.TIMESTAMP`。

---

## 验证迁移结果
迁移完成后，执行：

```bash
docker info | grep "Docker Root Dir"
```

应显示为新的目录路径。

---

## 许可证
MIT License © 2025 ResHub

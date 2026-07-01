# PXE & HTTP Boot 多系统自动部署服务器

一键配置 PXE Server 和 UEFI HTTP Boot Server，支持同时部署多种 Linux 发行版。

## 功能特性

- **三种引导方式**：BIOS PXE / UEFI TFTP / UEFI HTTP Boot
- **多系统支持**：RHEL / AlmaLinux / Rocky Linux / Ubuntu / SLES / openSUSE
- **自动检测 ISO 类型**：根据 ISO 内核路径自动识别发行版并生成对应引导配置
- **Web 服务**：通过 HTTP 提供安装源，支持大文件传输
- **持久化挂载**：自动写入 fstab，重启后 ISO 自动挂载

## 前置要求

- RHEL 8/9 或 AlmaLinux 8/9 系统（作为 PXE 服务器）
- root 权限
- 已下载的目标系统 ISO 文件
- 服务器 IP：`192.168.1.100`（可在脚本顶部修改 `HTTP_IP`）

### 依赖包（脚本自动安装）

| 包名 | 用途 |
|------|------|
| dhcp-server | DHCP 服务 |
| tftp-server | TFTP 服务（BIOS PXE / UEFI TFTP） |
| httpd | HTTP 服务（安装源 / HTTP Boot） |
| syslinux-tftpboot | BIOS PXE 引导文件 |
| grub2-efi-x64 | UEFI GRUB 引导 |
| shim-x64 | UEFI Secure Boot shim |

## 快速开始

### 1. 基础部署

```bash
# 赋予执行权限
chmod +x auto-pxe-setup.sh

# 运行脚本（自动安装依赖、配置服务）
sudo ./auto-pxe-setup.sh
```

### 2. 添加操作系统

```bash
# 添加 RHEL / AlmaLinux
sudo ./auto-pxe-setup.sh add-version /path/to/AlmaLinux-9.4-x86_64-dvd.iso alma9

# 添加 Ubuntu
sudo ./auto-pxe-setup.sh add-version /path/to/ubuntu-24.04-live-server-amd64.iso ubuntu24

# 添加 SLES / openSUSE
sudo ./auto-pxe-setup.sh add-version /path/to/SLES-16-DVD-x86_64.iso sles16
```

### 3. 常用命令

```bash
# 查看已添加的版本
sudo ./auto-pxe-setup.sh list-versions

# 移除某个版本
sudo ./auto-pxe-setup.sh remove-version sles16

# 重新挂载所有 ISO
sudo ./auto-pxe-setup.sh remount
```

## 目录结构

```
/var/www/html/
├── iso-mounts/              # ISO 挂载点（即安装源）
│   ├── alma9/
│   ├── ubuntu24/
│   └── sles16/
├── boot/                    # HTTP Boot 根目录
│   ├── EFI/BOOT/
│   │   ├── BOOTX64.EFI     # shim 引导程序
│   │   ├── grubx64.efi     # GRUB EFI
│   │   └── grub.cfg        # GRUB 配置（自动生成）
│   └── images/             # HTTP Boot 内核/initrd
│       ├── alma9/
│       ├── ubuntu24/
│       └── sles16/
└── isos/                   # Ubuntu ISO 符号链接目录

/var/lib/tftpboot/
├── pxelinux/               # BIOS PXE 引导
│   ├── pxelinux.0
│   ├── pxelinux.cfg/default  # BIOS 菜单（自动生成）
│   └── vesamenu.c32
├── alma/efi/BOOT/
│   ├── BOOTX64.EFI
│   └── grub.cfg            # UEFI TFTP 菜单（自动生成）
└── images/                 # TFTP 内核/initrd
    ├── alma9/
    ├── ubuntu24/
    └── sles16/

/var/isos/                  # ISO 文件存储
    ├── alma9.iso
    ├── ubuntu24.iso
    └── sles16.iso
```

## 支持的系统及引导参数

| 系统 | 检测方式 | 内核路径 | 安装源参数 |
|------|----------|----------|------------|
| RHEL / Alma / Rocky | `images/pxeboot/vmlinuz` | `vmlinuz` + `initrd.img` | `inst.repo=http://...` |
| Ubuntu | `casper/vmlinuz` | `vmlinuz` + `initrd` | `url=http://.../<ver>.iso autoinstall` |
| SLES / openSUSE | `boot/x86_64/loader/linux` | `linux` + `initrd` | `inst.install_url=http://.../install` |

## 网络拓扑

```
┌─────────────┐       ┌──────────────────┐       ┌──────────────────┐
│  DHCP 客户端  │◄─────►│   PXE/HTTP 服务器  │       │   已安装系统       │
│  (目标机器)   │ DHCP  │ 192.168.1.100    │       │ 192.168.1.101-200 │
└─────────────┘       └────────┬─────────┘       └──────────────────┘
                               │
                    ┌──────────┼──────────┐
                    │          │          │
               TFTP:69    HTTP:80    DHCP:67
```

## DHCP 配置说明

脚本会自动生成 `/etc/dhcp/dhcpd.conf`，支持以下引导方式：

- **BIOS PXE**（架构 `00:00`）→ 通过 TFTP 加载 `pxelinux.0`
- **UEFI HTTP Boot**（架构 `00:07` / `00:09`）→ 通过 HTTP 加载 `BOOTX64.EFI`

DHCP 地址池：`192.168.1.101` ~ `192.168.1.200`

## 防火墙端口

| 端口 | 协议 | 用途 |
|------|------|------|
| 67/68 | UDP | DHCP |
| 69 | UDP | TFTP |
| 80 | TCP | HTTP 安装源 / HTTP Boot |

## 添加新系统类型

如需支持新发行版（如 Debian、Fedora CoreOS 等），需修改脚本中以下函数：

1. `detect_iso_type()` — 添加 ISO 类型检测逻辑
2. `add_os_version()` — 添加引导文件复制逻辑
3. `generate_bios_menu_entries()` — 添加 BIOS PXE 菜单项
4. `generate_uefi_menu_entries()` — 添加 UEFI TFTP 菜单项
5. `generate_http_boot_entries()` — 添加 HTTP Boot 菜单项

详见 `.mimocode/skills/add-os-to-pxe-script/SKILL.md`。

## 常见问题

**Q: UEFI HTTP Boot 无法获取 DHCP 地址？**
A: 确保客户端 BIOS 设置中启用了 HTTP Boot，并将引导 URL 设置为 `http://192.168.1.100/boot/EFI/BOOT/BOOTX64.EFI`。

**Q: SLES 安装时提示找不到安装源？**
A: 确认 `inst.install_url` 指向 `/install` 子目录，即 `http://192.168.1.100/iso-mounts/sles16/install`。

**Q: Ubuntu autoinstall 不生效？**
A: 需要配合 `user-data` 和 `meta-data` 文件使用 cloud-init autoinstall 机制，或移除 `autoinstall` 参数改为手动安装。

**Q: 添加版本后重启失效？**
A: 脚本已自动将 ISO 挂载写入 `/etc/fstab`，重启后应自动挂载。若未生效，运行 `sudo ./auto-pxe-setup.sh remount` 手动重新挂载。

## License

MIT

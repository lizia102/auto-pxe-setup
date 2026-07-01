#!/bin/bash
# PXE Server Auto Configuration Script for RHEL/AlmaLinux
# Supports PXE and HTTP Boot for multiple versions
# Scriptwriter: lizia102

set -e

# Configuration variables
HTTP_IP="192.168.1.100"
HTTP_ROOT="/var/www/html"
TFTP_ROOT="/var/lib/tftpboot"
ISO_STORAGE="/var/isos"
LOG_FILE="/var/log/pxe-setup.log"
# 新增HTTP Boot相关目录
HTTP_BOOT_ROOT="${HTTP_ROOT}/boot"  # HTTP Boot根目录
GRUB_EFI_DIR="${HTTP_BOOT_ROOT}/EFI/BOOT"  # GRUB EFI目录

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Error handling function
error_exit() {
    log "${RED}ERROR: $1${NC}"
    exit 1
}

# 检测 ISO 类型 (rhel 或 ubuntu)
detect_iso_type() {
    local mount_point="$1"
    if [[ -f "${mount_point}/casper/vmlinuz" ]] || [[ -f "${mount_point}/casper/filesystem.squashfs" ]]; then
        echo "ubuntu"
    elif [[ -f "${mount_point}/boot/x86_64/loader/linux" ]]; then
        echo "sles"
    elif [[ -f "${mount_point}/images/pxeboot/vmlinuz" ]]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

# Install required packages (新增httpd-tools和grub2-efi-x64)
install_packages() {
    log "${YELLOW}Installing required packages...${NC}"
    dnf install -y dhcp-server tftp-server httpd syslinux-tftpboot \
        grub2-efi-x64-modules grub2-efi-x64 httpd-tools shim-x64 >> "$LOG_FILE" 2>&1 || \
        error_exit "Failed to install packages"
}

# Configure firewall (新增80端口允许)
configure_firewall() {
    log "${YELLOW}Configuring firewall...${NC}"
    firewall-cmd --add-service=dhcp --permanent >> "$LOG_FILE" 2>&1
    firewall-cmd --add-service=tftp --permanent >> "$LOG_FILE" 2>&1
    firewall-cmd --add-service=http --permanent >> "$LOG_FILE" 2>&1
    firewall-cmd --add-port=80/tcp --permanent >> "$LOG_FILE" 2>&1  # HTTP Boot需要
    firewall-cmd --reload >> "$LOG_FILE" 2>&1
}

# Configure DHCP server (新增HTTP Boot支持)
configure_dhcp() {
    log "${YELLOW}Configuring DHCP server...${NC}"
    cat > /etc/dhcp/dhcpd.conf << EOF
option architecture-type code 93 = unsigned integer 16;
option vendor-class-identifier code 60 = string;

subnet 192.168.1.0 netmask 255.255.255.0 {
  option routers 192.168.1.1;
  option domain-name-servers 114.114.114.114;
  range 192.168.1.101 192.168.1.200;
  default-lease-time 600;
  max-lease-time 7200;

  class "pxeclients" {
    match if substring (option vendor-class-identifier, 0, 9) = "PXEClient";
    next-server ${HTTP_IP};

    # BIOS PXE
    if option architecture-type = 00:00 {
      filename "pxelinux/pxelinux.0";
    }
    # UEFI HTTP Boot (新增)
    elsif option architecture-type = 00:07 {
      option vendor-class-identifier "HTTPClient";
      filename "http://${HTTP_IP}/boot/EFI/BOOT/BOOTX64.EFI";
    }
    # 其他架构支持
    elsif option architecture-type = 00:09 {
      option vendor-class-identifier "HTTPClient";
      filename "http://${HTTP_IP}/boot/EFI/BOOT/BOOTX64.EFI";
    }
  }
}
EOF

    systemctl enable --now dhcpd >> "$LOG_FILE" 2>&1 || error_exit "Failed to start DHCP service"
}

# Prepare directory structure (新增HTTP Boot目录)
prepare_directories() {
    log "${YELLOW}Creating directory structure...${NC}"
    # 原有目录
    mkdir -p "${TFTP_ROOT}/pxelinux/pxelinux.cfg"
    mkdir -p "${TFTP_ROOT}/images"
    mkdir -p "${TFTP_ROOT}/alma/efi/BOOT"
    mkdir -p "${ISO_STORAGE}"
    mkdir -p "${HTTP_ROOT}/iso-mounts"
    
    # 新增HTTP Boot目录结构
    mkdir -p "${GRUB_EFI_DIR}"
    mkdir -p "${HTTP_BOOT_ROOT}/images"  # HTTP Boot镜像目录
    mkdir -p "${HTTP_ROOT}/isos"  # Ubuntu ISO 文件目录
    chown -R apache:apache "${HTTP_ROOT}"
    chmod -R 755 "${HTTP_ROOT}"
}

# Copy BIOS boot files
copy_bios_boot_files() {
    log "${YELLOW}Copying BIOS boot files...${NC}"
    cp /usr/share/syslinux/pxelinux.0 "${TFTP_ROOT}/pxelinux/" >> "$LOG_FILE" 2>&1
    cp /usr/share/syslinux/vesamenu.c32 "${TFTP_ROOT}/pxelinux/" >> "$LOG_FILE" 2>&1
    cp /usr/share/syslinux/ldlinux.c32 "${TFTP_ROOT}/pxelinux/" >> "$LOG_FILE" 2>&1
    cp /usr/share/syslinux/libutil.c32 "${TFTP_ROOT}/pxelinux/" >> "$LOG_FILE" 2>&1
}

# 新增: 配置HTTP Boot引导文件
configure_http_boot() {
    log "${YELLOW}Configuring HTTP Boot files...${NC}"
    
    # 复制GRUB EFI文件
    if [[ -f /boot/efi/EFI/redhat/grubx64.efi ]]; then
        cp /boot/efi/EFI/redhat/grubx64.efi "${GRUB_EFI_DIR}/" >> "$LOG_FILE" 2>&1
    else
        cp /usr/lib/grub/x86_64-efi/grub.efi "${GRUB_EFI_DIR}/grubx64.efi" >> "$LOG_FILE" 2>&1
    fi
    
    # 复制shim引导程序
    cp /boot/efi/EFI/redhat/shimx64.efi "${GRUB_EFI_DIR}/BOOTX64.EFI" >> "$LOG_FILE" 2>&1 || \
        error_exit "Failed to copy shimx64.efi"
    
    # 创建GRUB配置目录
    mkdir -p "${GRUB_EFI_DIR}/grub.cfg"
}

# 新增: 更新HTTP Boot的GRUB配置
update_http_boot_menu() {
    log "${YELLOW}Updating HTTP Boot menu...${NC}"
    
    cat > "${GRUB_EFI_DIR}/grub.cfg" << EOF
set default=0
set timeout=30
set hiddentimeout=0
set hiddenmenu

menuentry 'Boot from local drive' {
    exit
}

$(generate_http_boot_entries)

menuentry 'Reboot' {
    reboot
}

menuentry 'Shutdown' {
    halt
}
EOF
}

# 生成HTTP Boot菜单条目
generate_http_boot_entries() {
    local entries=""
    local count=1

    for version_dir in "${HTTP_BOOT_ROOT}/images"/*; do
        if [[ -d "$version_dir" ]]; then
            local version=$(basename "$version_dir")
            local mount_point="${HTTP_ROOT}/iso-mounts/${version}"
            local iso_type_file="${TFTP_ROOT}/images/${version}/.iso_type"
            local iso_type="rhel"
            [[ -f "$iso_type_file" ]] && iso_type=$(cat "$iso_type_file")

            if [[ -d "$mount_point" ]]; then
                entries+="menuentry 'Install ${version} (HTTP Boot)' --hotkey=${count} {\n"
                if [[ "$iso_type" == "ubuntu" ]]; then
                    entries+="  linuxefi /boot/images/${version}/vmlinuz ip=dhcp url=http://${HTTP_IP}/isos/${version}.iso autoinstall\n"
                    entries+="  initrdefi /boot/images/${version}/initrd\n"
                elif [[ "$iso_type" == "sles" ]]; then
                    entries+="  linuxefi /boot/images/${version}/linux \\\\\n"
                    entries+="      inst.install_url=http://${HTTP_IP}/iso-mounts/${version}/install \\\\\n"
                    entries+="      ifcfg=*=dhcp dhcptimout=120 \\\\\n"
                    entries+="      root=live:http://${HTTP_IP}/iso-mounts/${version}/LiveOS/squashfs.img\n"
                    entries+="  initrdefi /boot/images/${version}/initrd\n"
                else
                    entries+="  linuxefi /boot/images/${version}/vmlinuz ip=dhcp inst.repo=http://${HTTP_IP}/iso-mounts/${version} quiet\n"
                    entries+="  initrdefi /boot/images/${version}/initrd.img\n"
                fi
                entries+="}\n"
                ((count++))
            fi
        fi
    done

    echo -e "$entries"
}

# Function to add a new OS version (增强HTTP Boot支持)
add_os_version() {
    local iso_path="$1"
    local version="$2"
    
    if [[ ! -f "$iso_path" ]]; then
        error_exit "ISO file not found: $iso_path"
    fi

    log "${YELLOW}Adding OS version: $version${NC}"

    # 复制ISO到存储目录
    local iso_dest="${ISO_STORAGE}/${version}.iso"
    if [[ ! -f "$iso_dest" ]]; then
        log "Copying ISO to storage directory..."
        cp "$iso_path" "$iso_dest" >> "$LOG_FILE" 2>&1 || error_exit "Failed to copy ISO file"
    fi

    # 创建挂载点
    local mount_point="${HTTP_ROOT}/iso-mounts/${version}"
    mkdir -p "$mount_point"

    # 挂载ISO到HTTP目录
    log "Mounting ISO to HTTP directory..."
    umount "$mount_point" 2>/dev/null || true
    mount -o loop,ro -t iso9660 "$iso_dest" "$mount_point" >> "$LOG_FILE" 2>&1 || error_exit "Failed to mount ISO"

    # 检测 ISO 类型
    local iso_type=$(detect_iso_type "$mount_point")
    log "Detected ISO type: ${iso_type}"

    # 为TFTP和HTTP Boot创建版本目录
    local tftp_version_dir="${TFTP_ROOT}/images/${version}"
    local http_version_dir="${HTTP_BOOT_ROOT}/images/${version}"
    mkdir -p "$tftp_version_dir"
    mkdir -p "$http_version_dir"

    # 根据 ISO 类型复制引导文件
    log "Copying boot files for ${version}..."
    if [[ "$iso_type" == "ubuntu" ]]; then
        # Ubuntu: 内核和 initrd 在 casper 目录
        cp "${mount_point}/casper/vmlinuz" "$tftp_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/casper/initrd" "$tftp_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/casper/vmlinuz" "$http_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/casper/initrd" "$http_version_dir/" >> "$LOG_FILE" 2>&1
        # Ubuntu url= 参数需要直接访问 ISO 文件，创建符号链接到 HTTP 目录
        mkdir -p "${HTTP_ROOT}/isos"
        ln -sf "$iso_dest" "${HTTP_ROOT}/isos/${version}.iso"
    elif [[ "$iso_type" == "sles" ]]; then
        # SLES: 内核和 initrd 在 boot/x86_64/loader 目录
        cp "${mount_point}/boot/x86_64/loader/linux" "$tftp_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/boot/x86_64/loader/initrd" "$tftp_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/boot/x86_64/loader/linux" "$http_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/boot/x86_64/loader/initrd" "$http_version_dir/" >> "$LOG_FILE" 2>&1
    else
        # RHEL/AlmaLinux: 内核和 initrd 在 images/pxeboot 目录
        cp "${mount_point}/images/pxeboot/vmlinuz" "$tftp_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/images/pxeboot/initrd.img" "$tftp_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/images/pxeboot/vmlinuz" "$http_version_dir/" >> "$LOG_FILE" 2>&1
        cp "${mount_point}/images/pxeboot/initrd.img" "$http_version_dir/" >> "$LOG_FILE" 2>&1
    fi

    # 保存 ISO 类型信息
    echo "$iso_type" > "${tftp_version_dir}/.iso_type"

    # 更新所有菜单
    update_bios_menu
    update_uefi_menu
    update_http_boot_menu  # 新增HTTP Boot菜单更新

    # 添加到fstab自动挂载
    if ! grep -q "$iso_dest" /etc/fstab; then
        echo "$iso_dest $mount_point iso9660 loop,ro,auto 0 0" >> /etc/fstab
    fi

    log "${GREEN}Successfully added ${version}${NC}"
    log "${YELLOW}Installation source: http://${HTTP_IP}/iso-mounts/${version}${NC}"
}

# Update BIOS PXE menu (保持原有)
update_bios_menu() {
    cat > "${TFTP_ROOT}/pxelinux/pxelinux.cfg/default" << EOF
default vesamenu.c32
prompt 1
timeout 600

menu title PXE Boot Menu
menu tabmsg Press Tab to edit options

$(generate_bios_menu_entries)

menu separator
label local
  menu label Boot from ^local drive
  localboot 0xffff
EOF
}

# Generate BIOS menu entries
generate_bios_menu_entries() {
    local entries=""

    for version_dir in "${TFTP_ROOT}/images"/*; do
        if [[ -d "$version_dir" ]]; then
            local version=$(basename "$version_dir")
            local mount_point="${HTTP_ROOT}/iso-mounts/${version}"
            local iso_type_file="${version_dir}/.iso_type"
            local iso_type="rhel"
            [[ -f "$iso_type_file" ]] && iso_type=$(cat "$iso_type_file")

            if [[ -d "$mount_point" ]]; then
                entries+="label install-${version}\n"
                entries+="  menu label ^Install ${version}\n"
                if [[ "$iso_type" == "ubuntu" ]]; then
                    entries+="  kernel images/${version}/vmlinuz\n"
                    entries+="  append initrd=images/${version}/initrd ip=dhcp url=http://${HTTP_IP}/isos/${version}.iso autoinstall\n"
                elif [[ "$iso_type" == "sles" ]]; then
                    entries+="  kernel images/${version}/linux\n"
                    entries+="  append initrd=images/${version}/initrd ip=dhcp inst.install_url=http://${HTTP_IP}/iso-mounts/${version}/install root=live:http://${HTTP_IP}/iso-mounts/${version}/LiveOS/squashfs.img\n"
                else
                    entries+="  kernel images/${version}/vmlinuz\n"
                    entries+="  append initrd=images/${version}/initrd.img ip=dhcp inst.repo=http://${HTTP_IP}/iso-mounts/${version} quiet\n"
                fi
                entries+="\n"
            fi
        fi
    done

    echo -e "$entries"
}

# Update UEFI boot menu (保持原有)
update_uefi_menu() {
    # 查找可用ISO复制UEFI引导程序
    for version_dir in "${TFTP_ROOT}/images"/*; do
        if [[ -d "$version_dir" ]]; then
            local version=$(basename "$version_dir")
            local mount_point="${HTTP_ROOT}/iso-mounts/${version}"
            
            if [[ -d "$mount_point" ]]; then
                if [[ ! -f "${TFTP_ROOT}/alma/efi/BOOT/BOOTX64.EFI" ]]; then
                    cp -r "${mount_point}/EFI/BOOT/"* "${TFTP_ROOT}/alma/efi/BOOT/" >> "$LOG_FILE" 2>&1
                fi
                break
            fi
        fi
    done

    # 创建UEFI grub.cfg
    cat > "${TFTP_ROOT}/alma/efi/BOOT/grub.cfg" << EOF
set timeout=60

$(generate_uefi_menu_entries)

menuentry 'Reboot' {
    reboot
}
menuentry 'Shutdown' {
    halt
}
EOF
}

# Generate UEFI menu entries
generate_uefi_menu_entries() {
    local entries=""
    local count=1

    for version_dir in "${TFTP_ROOT}/images"/*; do
        if [[ -d "$version_dir" ]]; then
            local version=$(basename "$version_dir")
            local mount_point="${HTTP_ROOT}/iso-mounts/${version}"
            local iso_type_file="${version_dir}/.iso_type"
            local iso_type="rhel"
            [[ -f "$iso_type_file" ]] && iso_type=$(cat "$iso_type_file")

            if [[ -d "$mount_point" ]]; then
                entries+="menuentry 'Install ${version}' --hotkey=${count} {\n"
                if [[ "$iso_type" == "ubuntu" ]]; then
                    entries+="  linuxefi /images/${version}/vmlinuz ip=dhcp url=http://${HTTP_IP}/isos/${version}.iso autoinstall\n"
                    entries+="  initrdefi /images/${version}/initrd\n"
                elif [[ "$iso_type" == "sles" ]]; then
                    entries+="  linuxefi /images/${version}/linux \\\\\n"
                    entries+="      inst.install_url=http://${HTTP_IP}/iso-mounts/${version}/install \\\\\n"
                    entries+="      ifcfg=*=dhcp dhcptimout=120 \\\\\n"
                    entries+="      root=live:http://${HTTP_IP}/iso-mounts/${version}/LiveOS/squashfs.img\n"
                    entries+="  initrdefi /images/${version}/initrd\n"
                else
                    entries+="  linuxefi /images/${version}/vmlinuz ip=dhcp inst.repo=http://${HTTP_IP}/iso-mounts/${version} quiet\n"
                    entries+="  initrdefi /images/${version}/initrd.img\n"
                fi
                entries+="}\n"
                ((count++))
            fi
        fi
    done

    echo -e "$entries"
}

# Mount all ISO files from fstab (保持原有)
mount_all_isos() {
    log "${YELLOW}Mounting all ISO files...${NC}"
    for mount_point in "${HTTP_ROOT}/iso-mounts"/*; do
        if [[ -d "$mount_point" ]]; then
            mountpoint -q "$mount_point" || mount "$mount_point" >> "$LOG_FILE" 2>&1
        fi
    done
}

# Start services (增强HTTP服务配置)
start_services() {
    log "${YELLOW}Starting services...${NC}"
    # 配置HTTP服务支持大型文件
    cat > /etc/httpd/conf.d/pxe-boot.conf << EOF
<Directory "${HTTP_ROOT}">
    Options Indexes FollowSymLinks
    Require all granted
</Directory>
LimitRequestBody 0
EOF
    
    systemctl enable --now httpd >> "$LOG_FILE" 2>&1 || error_exit "Failed to start HTTP service"
    systemctl enable --now tftp.socket >> "$LOG_FILE" 2>&1 || error_exit "Failed to start TFTP service"
    systemctl enable --now dhcpd >> "$LOG_FILE" 2>&1 || error_exit "Failed to start DHCP service"
    
    # 重启HTTP服务使配置生效
    systemctl restart httpd >> "$LOG_FILE" 2>&1
    
    # 挂载所有ISO
    mount_all_isos
}

# Main function (新增HTTP Boot配置调用)
main() {
    check_root
    log "${GREEN}Starting PXE server configuration...${NC}"
    
    install_packages
    configure_firewall
    prepare_directories
    copy_bios_boot_files
    configure_dhcp
    configure_http_boot  # 新增HTTP Boot配置
    
    # 示例: 添加初始OS版本
    # 取消注释并修改以下行以添加操作系统版本
    # add_os_version "/path/to/AlmaLinux-9.4-x86_64-dvd.iso" "alma9"
    # add_os_version "/path/to/RHEL-10.0-x86_64-dvd.iso" "rhel10"
    # add_os_version "/path/to/SLES-16-DVD-x86_64.iso" "sles16"
    
    start_services
    
    log "${GREEN}PXE and HTTP Boot server configuration completed successfully!${NC}"
    log "${YELLOW}To add new OS versions, run:${NC}"
    log "${YELLOW}  ./auto-pxe-setup.sh add-version /path/to/iso.iso version_name${NC}"
    log "${YELLOW}Examples:${NC}"
    log "${YELLOW}  ./auto-pxe-setup.sh add-version /path/to/AlmaLinux-9.4-x86_64-dvd.iso alma9${NC}"
    log "${YELLOW}  ./auto-pxe-setup.sh add-version /path/to/ubuntu-24.04-live-server-amd64.iso ubuntu24${NC}"
    log "${YELLOW}  ./auto-pxe-setup.sh add-version /path/to/SLES-16-DVD-x86_64.iso sles16${NC}"
}

# 以下函数保持不变
add_version() {
    check_root
    if [[ $# -ne 2 ]]; then
        echo "Usage: $0 add-version /path/to/iso.iso version_name"
        exit 1
    fi
    
    local iso_path="$1"
    local version_name="$2"
    
    add_os_version "$iso_path" "$version_name"
    start_services
    
    log "${GREEN}Successfully added version: ${version_name}${NC}"
}

list_versions() {
    echo -e "${YELLOW}Available PXE boot versions:${NC}"
    for version_dir in "${TFTP_ROOT}/images"/*; do
        if [[ -d "$version_dir" ]]; then
            local version=$(basename "$version_dir")
            local mount_point="${HTTP_ROOT}/iso-mounts/${version}"
            local iso_type_file="${version_dir}/.iso_type"
            local iso_type="rhel"
            [[ -f "$iso_type_file" ]] && iso_type=$(cat "$iso_type_file")
            local status="${GREEN}(mounted)${NC}"

            if ! mountpoint -q "$mount_point"; then
                status="${RED}(not mounted)${NC}"
            fi

            echo -e "  ${GREEN}${version}${NC} [${iso_type}] ${status}"
            echo -e "    HTTP Path: http://${HTTP_IP}/iso-mounts/${version}"
        fi
    done
}

remove_version() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 remove-version version_name"
        exit 1
    fi
    
    local version="$1"
    local tftp_dir="${TFTP_ROOT}/images/${version}"
    local http_dir="${HTTP_BOOT_ROOT}/images/${version}"  # 新增HTTP目录清理
    local mount_point="${HTTP_ROOT}/iso-mounts/${version}"
    local iso_file="${ISO_STORAGE}/${version}.iso"
    
    if [[ ! -d "$tftp_dir" ]]; then
        error_exit "Version ${version} not found"
    fi
    
    # 卸载并移除
    umount "$mount_point" 2>/dev/null || true
    rm -rf "$tftp_dir"
    rm -rf "$http_dir"  # 清理HTTP Boot文件
    rm -rf "$mount_point"
    rm -f "$iso_file"
    rm -f "${HTTP_ROOT}/isos/${version}.iso"  # 清理Ubuntu ISO符号链接
    
    # 从fstab移除
    sed -i "\|${iso_file}|d" /etc/fstab
    
    # 更新菜单
    update_bios_menu
    update_uefi_menu
    update_http_boot_menu  # 更新HTTP Boot菜单
    
    log "${GREEN}Successfully removed version: ${version}${NC}"
}

remount_isos() {
    log "${YELLOW}Remounting all ISO files...${NC}"
    for mount_point in "${HTTP_ROOT}/iso-mounts"/*; do
        if [[ -d "$mount_point" ]]; then
            umount "$mount_point" 2>/dev/null || true
            mount "$mount_point" >> "$LOG_FILE" 2>&1
        fi
    done
    log "${GREEN}All ISOs remounted successfully${NC}"
}

# Handle command line arguments
case "${1:-}" in
    "add-version")
        shift
        add_version "$@"
        ;;
    "list-versions")
        list_versions
        ;;
    "remove-version")
        shift
        remove_version "$@"
        ;;
    "remount")
        remount_isos
        ;;
    "")
        main
        ;;
    *)
        echo "Usage: $0 [add-version|list-versions|remove-version|remount]"
        echo "  add-version /path/to/iso.iso version_name"
        echo "  list-versions"
        echo "  remove-version version_name"
        echo "  remount"
        exit 1
        ;;
esac
#!/bin/bash

set -x
set -e

GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
UCYAN="\033[4;36m"
NOCOLOR="\033[0m"
REVERSECOLOR="\e[7m"

function error_exit() {
	error "$@"
	exit 1
}

function info() {
	echo
	echo -e "${GREEN}$@${NOCOLOR}"
	echo
}

function warn() {
	echo
	echo -e "${YELLOW}$@${NOCOLOR}"
	echo
}

function error() {
	echo
	echo -e "${RED}$@${NOCOLOR}"
	echo
}

VFIO_PCI_OVERRIDE_TOOL=/usr/bin/vfio-pci-override.sh

declare -A NEW_KERNEL_PARAMS=(
    [crashkernel]=auto
    [intel_iommu]=on
    [iommu]=pt
    [vfio_iommu_type1.allow_unsafe_interrupts]=1
    [rdblacklist]=nouveau
    [nouveau.modeset]=0
)

declare -A OLD_KERNEL_PARAMS

export LC_CTYPE="en_US.UTF-8"
################################################

ensure_file_exist() {
    local file="$1"

    if [ ! -e "$file" ]; then
        error_exit "$file not exists"
    fi
}

ensure_file_writable() {
    local file="$1"

    ensure_file_exist "$file"

    if [ ! -w "$file" ]; then
        error_exit "$file not writable"
    fi
}

ensure_file_readable() {
    local file="$1"

    ensure_file_exist "$file"

    if [ ! -r "$file" ]; then
        error_exit "$file not readable"
    fi
}

refresh_pciids() {
    info "Refresh PCI ids..."
    update-pciids
}

_fill_old_kernel_params() {
    local cmdline_param=$*
    for param in $cmdline_param; do
        local key
        local val
        key=${param%=*}
        val=${param#*=}
        if [[ "$key" == "$val" ]]; then
            OLD_KERNEL_PARAMS["$key"]=''
        else
            OLD_KERNEL_PARAMS["$key"]="$val"
        fi
    done
}

_merge_new_kernel_params() {
    local new_tmp_val
    local old_tmp_val
	for key in "${!NEW_KERNEL_PARAMS[@]}"; do
        new_tmp_val="${NEW_KERNEL_PARAMS[$key]}"
        old_tmp_val="${OLD_KERNEL_PARAMS[$key]}"
        if [ "$new_tmp_val" != "$old_tmp_val" ]; then
            OLD_KERNEL_PARAMS[$key]="$new_tmp_val"
        fi
    done
}

_generate_kernel_cmdline() {
    local cmdline=""
    local val=""
    for key in "${!OLD_KERNEL_PARAMS[@]}"; do
        val="${OLD_KERNEL_PARAMS[$key]}"
        if [ -z "$val" ]; then
            cmdline="$cmdline $key"
        else
            cmdline="$cmdline $key=$val"
        fi
    done
    echo "$cmdline" | cut -c2-
}

grub_setup() {
    info "Configure grub option..."
    local grub_cfg="/etc/default/grub"
    local cmdline_param

    ensure_file_writable "$grub_cfg"

    cmdline_param=$(grep GRUB_CMDLINE_LINUX $grub_cfg | cut -d'"' -f2)
    _fill_old_kernel_params $cmdline_param
    _merge_new_kernel_params
    cmdline_param=$(_generate_kernel_cmdline)

    sed -i "s|GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$cmdline_param\"|g" $grub_cfg
    # 删掉 rd.lvm.lv(含)之后，空格之前的所有字符
    # 以便解决重启后因未加载 lvm 驱动而卡住的问题
    sed -i -e 's#rd.lvm.lv=[^ ]*##gi' $grub_cfg

    grub2-mkconfig -o /boot/grub2/grub.cfg
}

vfio_override_script_setup() {
    local vfio_override_file="/usr/bin/vfio-pci-override.sh"

    info "Add script: ${UCYAN}$vfio_override_file"

    cat <<EOF >"$vfio_override_file"
#!/bin/sh

CODE_VGA=0x030000
CODE_3D=0x030200

for i in \$(/usr/bin/find /sys/devices/pci* -name class); do
    CLS_CODE=\$(cat "\$i")
    if [ \$CLS_CODE == \$CODE_VGA ] || [ \$CLS_CODE == \$CODE_3D ]; then
        GPU="\${i%/class}"
        BOOT_VGA="\$GPU/boot_vga"
        if [ -f "\$BOOT_VGA" ]; then
            if [ \$(cat "\$BOOT_VGA") -eq 1 ]; then
                continue
            fi
        fi
        AUDIO="\$(echo "\$GPU" | sed -e "s/0$/1/")"
        echo "vfio-pci" > "\$GPU/driver_override"
        if [ -d "\$AUDIO" ]; then
            echo "vfio-pci" > "\$AUDIO/driver_override"
        fi
    fi
done

modprobe -i vfio-pci
EOF

    chmod a+x "$vfio_override_file"
}

modules_setup() {
    info "Configure kernel modules..."

    local vfio_load_file="/etc/modules-load.d/vfio.conf"
    local vfio_conf_file="/etc/modprobe.d/vfio.conf"
    local mod_blacklist_file="/etc/modprobe.d/blacklist-gpu.conf"
    local kvm_conf_file="/etc/modprobe.d/kvm.conf"

    cat <<EOF >"$vfio_load_file"
vfio
vfio_iommu_type1
vfio_pci
EOF

	cat <<EOF >"$vfio_conf_file"
install vfio-pci $VFIO_PCI_OVERRIDE_TOOL
EOF

	cat <<EOF >"$mod_blacklist_file"
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
EOF

    local kvm_options="options kvm ignore_msrs=1"
    if grep -xq "$kvm_options" "$kvm_conf_file"; then
        return
    else
        cat <<EOF >>"$kvm_conf_file"
options kvm ignore_msrs=1
EOF
    fi

    modprobe vfio
    modprobe vfio_pci
}

get_distro() {
    awk '/^ID=/' /etc/*-release | awk -F'=' '{ print tolower($2)  }' | tr -d \"
}

env_check() {
    distro=$(get_distro)
    if [ "$distro" != "centos" ]; then
        error_exit "Linux Distribution: \"$distro\" not support, only \"centos\" support!"
    fi
    if [[ $EUID -ne 0 ]]; then
        error_exit "You need sudo or root to run this script."
    fi
}

dracut_ramfs() {
    info "Use dracut rebuild initramfs..."
    local dracut_vfio_file="/etc/dracut.conf.d/vfio.conf"
	cat <<EOF >"$dracut_vfio_file"
add_drivers+=" vfio vfio_iommu_type1 vfio_pci"
EOF
    local yn_kernel=$(ls /boot/vmlinuz-* | grep yn.*x86_64 | sort -r | head -n 1)
    if [ -z "$yn_kernel" ]; then
        error_exit "Not found yunion customize kernel"
    fi
    local kernel_release=$(basename $yn_kernel | sed 's/vmlinuz-//g')
    dracut -f --kver $kernel_release --install find --install $VFIO_PCI_OVERRIDE_TOOL
}

main() {
    env_check
    grub_setup
    vfio_override_script_setup
    modules_setup
    refresh_pciids
    dracut_ramfs
    info "All done, ${UCYAN}REBOOT to make it work"
}

main

# shellcheck source=./scripts/protection.sh
source "$LIBERO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1
# shellcheck source=./scripts/functions.sh
source "$LIBERO_INSTALL_REPO_DIR/scripts/functions.sh" || exit 1


################################################
# Functions

function install_stage3() {
	prepare_installation_environment
	apply_disk_configuration
	download_stage3
	extract_stage3
}

function configure_base_system() {
	if [[ $MUSL == "true" ]]; then
		einfo "Installing musl-locales"
		try emerge --verbose sys-apps/musl-locales
		echo 'MUSL_LOCPATH="/usr/share/i18n/locales/musl"' >> /etc/env.d/00local \
			|| die "Could not write to /etc/env.d/00local"
	else
		einfo "Generating locales"
		echo "$LOCALES" > /etc/locale.gen \
			|| die "Could not write /etc/locale.gen"
		locale-gen \
			|| die "Could not generate locales"
	fi

	if [[ $SYSTEMD == "true" ]]; then
		einfo "Setting machine-id"
		systemd-machine-id-setup \
			|| die "Could not setup systemd machine id"

		# Set hostname
		einfo "Selecting hostname"
		echo "$HOSTNAME" > /etc/hostname \
			|| die "Could not write /etc/hostname"

		# Set keymap
		einfo "Selecting keymap"
		echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf \
			|| die "Could not write /etc/vconsole.conf"

		# Set locale
		einfo "Selecting locale"
		echo "LANG=$LOCALE" > /etc/locale.conf \
			|| die "Could not write /etc/locale.conf"

		einfo "Selecting timezone"
		ln -sfn "../usr/share/zoneinfo/$TIMEZONE" /etc/localtime \
			|| die "Could not change /etc/localtime link"
	else
		# Set hostname
		einfo "Selecting hostname"
		sed -i "/hostname=/c\\hostname=\"$HOSTNAME\"" /etc/conf.d/hostname \
			|| die "Could not sed replace in /etc/conf.d/hostname"

		# Set timezone
		if [[ $MUSL == "true" ]]; then
			try emerge -v sys-libs/timezone-data
			einfo "Selecting timezone"
			echo -e "TZ=\"$TIMEZONE\"" >> /etc/env.d/00local \
				|| die "Could not write to /etc/env.d/00local"
		else
			einfo "Selecting timezone"
			echo "$TIMEZONE" > /etc/timezone \
				|| die "Could not write /etc/timezone"
			chmod 644 /etc/timezone \
				|| die "Could not set correct permissions for /etc/timezone"
			try emerge -v --config sys-libs/timezone-data
		fi

		# Set keymap
		einfo "Selecting keymap"
		sed -i "/keymap=/c\\keymap=\"$KEYMAP\"" /etc/conf.d/keymaps \
			|| die "Could not sed replace in /etc/conf.d/keymaps"

		# Set locale
		einfo "Selecting locale"
		try eselect locale set "$LOCALE"
	fi

	# Update environment
	env_update
}

function configure_portage() {
	# Prepare /etc/portage for autounmask
	mkdir_or_die 0755 "/etc/portage/package.use"
	touch_or_die 0644 "/etc/portage/package.use/zz-autounmask"
	mkdir_or_die 0755 "/etc/portage/package.keywords"
	touch_or_die 0644 "/etc/portage/package.keywords/zz-autounmask"
	touch_or_die 0644 "/etc/portage/package.license"

	if [[ $SELECT_MIRRORS == "true" ]]; then
		einfo "Temporarily installing mirrorselect"
		try emerge --verbose --oneshot app-portage/mirrorselect

		einfo "Selecting fastest portage mirrors"
		mirrorselect_params=("-s" "4" "-b" "10")
		[[ $SELECT_MIRRORS_LARGE_FILE == "true" ]] \
			&& mirrorselect_params+=("-D")
		try mirrorselect "${mirrorselect_params[@]}"
	fi

	if [[ $ENABLE_BINPKG == "true" ]]; then
		echo 'FEATURES="getbinpkg binpkg-request-signature"' >> /etc/portage/make.conf
		getuto
		chmod 644 /etc/portage/gnupg/pubring.kbx
	fi

	chmod 644 /etc/portage/make.conf \
		|| die "Could not chmod 644 /etc/portage/make.conf"
}

function enable_sshd() {
	einfo "Installing and enabling sshd"
	install -m0600 -o root -g root "/tmp/libero-install/contrib/sshd_config" /etc/ssh/sshd_config \
		|| die "Could not install /etc/ssh/sshd_config"
	enable_service sshd
}

function install_authorized_keys() {
	mkdir_or_die 0700 "/root/"
	mkdir_or_die 0700 "/root/.ssh"

	if [[ -n "$ROOT_SSH_AUTHORIZED_KEYS" ]]; then
		einfo "Adding authorized keys for root"
		touch_or_die 0600 "/root/.ssh/authorized_keys"
		echo "$ROOT_SSH_AUTHORIZED_KEYS" > "/root/.ssh/authorized_keys" \
			|| die "Could not add ssh key to /root/.ssh/authorized_keys"
	fi
}

function generate_initramfs() {
	local output="$1"

	# Generate initramfs
	einfo "Generating initramfs"

	local modules=()
	[[ $USED_RAID == "true" ]] \
		&& modules+=("mdraid")
	[[ $USED_LUKS == "true" ]] \
		&& modules+=("crypt crypt-gpg")
	[[ $USED_BTRFS == "true" ]] \
		&& modules+=("btrfs")
	[[ $USED_ZFS == "true" ]] \
		&& modules+=("zfs")

	local kver
	kver="$(readlink /usr/src/linux)" \
		|| die "Could not figure out kernel version from /usr/src/linux symlink."
	kver="${kver#linux-}"

	dracut_opts=()
	if [[ $SYSTEMD == "true" && $SYSTEMD_INITRAMFS_SSHD == "true" ]]; then
		# Use disk-based temporary directory for git operations to conserve RAM
		local git_tmpdir="/var/tmp/dracut-sshd-$$"
		mkdir -p "$git_tmpdir" || die "Could not create git temporary directory '$git_tmpdir'"
		cd "$git_tmpdir" || die "Could not change into '$git_tmpdir'"
		try git clone https://github.com/gsauthof/dracut-sshd
		try cp -r dracut-sshd/46sshd /usr/lib/dracut/modules.d
		sed -e 's/^Type=notify/Type=simple/' \
			-e 's@^\(ExecStart=/usr/sbin/sshd\) -D@\1 -e -D@' \
			-i /usr/lib/dracut/modules.d/46sshd/sshd.service \
			|| die "Could not replace sshd options in service file"
		rm -rf "$git_tmpdir" || die "Could not cleanup git temporary directory '$git_tmpdir'"
		dracut_opts+=("--install" "/etc/systemd/network/20-wired.network")
		modules+=("systemd-networkd")
	fi

	# Generate initramfs
	# TODO --conf          "/dev/null" \
	# TODO --confdir       "/dev/null" \
	try dracut \
		--kver          "$kver" \
		--zstd \
		--no-hostonly \
		--ro-mnt \
		--add           "bash ${modules[*]}" \
		"${dracut_opts[@]}" \
		--force \
		"$output"

	# Create script to repeat initramfs generation
	cat > "$(dirname "$output")/generate_initramfs.sh" <<EOF
#!/bin/bash
kver="\$1"
output="\$2" # At setup time, this was "$output"
[[ -n "\$kver" ]] || { echo "usage \$0 <kernel_version> <output>" >&2; exit 1; }
dracut \\
	--kver          "\$kver" \\
	--zstd \\
	--no-hostonly \\
	--ro-mnt \\
	--add           "bash ${modules[*]}" \\
	${dracut_opts[@]@Q} \\
	--force \\
	"\$output"
EOF
}

function get_cmdline() {
	local cmdline=("rd.vconsole.keymap=$KEYMAP_INITRAMFS")
	cmdline+=("${DISK_DRACUT_CMDLINE[@]}")

	if [[ $USED_ZFS != "true" ]]; then
		cmdline+=("root=UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")")
	fi

	echo -n "${cmdline[*]}"
}

function install_kernel_efi() {
	try emerge --verbose sys-boot/efibootmgr

	# Copy kernel to EFI
	local kernel_file
	kernel_file="$(find "/boot" \( -name "vmlinuz-*" -or -name 'kernel-*' \) -printf '%f\n' | sort -V | tail -n 1)" \
		|| die "Could not list newest kernel file"

	try cp "/boot/$kernel_file" "/boot/efi/vmlinuz.efi"

	# Generate initramfs
	generate_initramfs "/boot/efi/initramfs.img"

	# Create boot entry
	einfo "Creating EFI boot entry"
	local efipartdev
	efipartdev="$(resolve_device_by_id "$DISK_ID_EFI")" \
		|| die "Could not resolve device with id=$DISK_ID_EFI"
	efipartdev="$(realpath "$efipartdev")" \
		|| die "Error in realpath '$efipartdev'"

	# Get the sysfs path to EFI partition
	local sys_efipart
	sys_efipart="/sys/class/block/$(basename "$efipartdev")" \
		|| die "Could not construct /sys path to EFI partition"

	# Extract partition number, handling both standard and RAID cases
	local efipartnum
	if [[ -e "$sys_efipart/partition" ]]; then
		efipartnum="$(cat "$sys_efipart/partition")" \
			|| die "Failed to find partition number for EFI partition $efipartdev"
	else
		efipartnum="1" # Assume partition 1 if not found, common for RAID-based EFI
		einfo "Assuming partition 1 for RAID-based EFI on device $efipartdev"
	fi

	# Identify the parent block device and create EFI boot entry
	local gptdev
	if mdadm --detail --scan "$efipartdev" | grep -qE "^ARRAY $efipartdev " && [[ "$efipartdev" =~ ^/dev/md[0-9]+$ ]]; then
		# RAID 1 case: Create EFI boot entries for each RAID member
		local raid_members
		raid_members=($(mdadm --detail "$efipartdev" | sed -n 's|.*active sync[^/]*\(/dev/[^ ]*\).*|\1|p' | sort))

		if [[ ${#raid_members[@]} -eq 0 ]]; then
			die "RAID setup detected, but no valid member disks found for $efipartdev"
		fi

		einfo "RAID detected. RAID members: ${raid_members[*]}"

		for disk in "${raid_members[@]}"; do
			gptdev="$disk"
			einfo "Adding EFI boot entry for RAID member: $gptdev"
			try efibootmgr --verbose --create --disk "$gptdev" --part "$efipartnum" --label "libero" --loader '\vmlinuz.efi' --unicode "initrd=\\initramfs.img $(get_cmdline)"
		done
	else
		# Non-RAID case: Create a single EFI boot entry
		gptdev="/dev/$(basename "$(readlink -f "$sys_efipart/..")")" \
			|| die "Failed to find parent device for EFI partition $efipartdev"
		if [[ ! -e "$gptdev" ]] || [[ -z "$gptdev" ]]; then
			gptdev="$(resolve_device_by_id "${DISK_ID_PART_TO_GPT_ID[$DISK_ID_EFI]}")" \
				|| die "Could not resolve device with id=${DISK_ID_PART_TO_GPT_ID[$DISK_ID_EFI]}"
		fi
		try efibootmgr --verbose --create --disk "$gptdev" --part "$efipartnum" --label "libero" --loader '\vmlinuz.efi' --unicode 'initrd=\initramfs.img'" $(get_cmdline)"
	fi

	# Create script to repeat adding efibootmgr entry
	cat > "/boot/efi/efibootmgr_add_entry.sh" <<EOF
#!/bin/bash
# This is the command that was used to create the efibootmgr entry when the
# system was installed using libero-install.
efibootmgr --verbose --create --disk "$gptdev" --part "$efipartnum" --label "libero" --loader '\\vmlinuz.efi' --unicode 'initrd=\\initramfs.img'" $(get_cmdline)"
EOF
}

function generate_syslinux_cfg() {
	cat <<EOF
DEFAULT libero
PROMPT 0
TIMEOUT 0

LABEL libero
	LINUX ../vmlinuz-current
	APPEND initrd=../initramfs.img $(get_cmdline)
EOF
}

function install_kernel_bios() {
	try emerge --verbose sys-boot/syslinux

	# Link kernel to known name
	local kernel_file
	kernel_file="$(find "/boot" \( -name "vmlinuz-*" -or -name 'kernel-*' \) -printf '%f\n' | sort -V | tail -n 1)" \
		|| die "Could not list newest kernel file"

	try cp "/boot/$kernel_file" "/boot/bios/vmlinuz-current"

	# Generate initramfs
	generate_initramfs "/boot/bios/initramfs.img"

	# Install syslinux
	einfo "Installing syslinux"
	local biosdev
	biosdev="$(resolve_device_by_id "$DISK_ID_BIOS")" \
		|| die "Could not resolve device with id=$DISK_ID_BIOS"
	mkdir_or_die 0700 "/boot/bios/syslinux"
	try syslinux --directory syslinux --install "$biosdev"

	# Create syslinux.cfg
	generate_syslinux_cfg > /boot/bios/syslinux/syslinux.cfg \
		|| die "Could save generated syslinux.cfg"

	# Install syslinux MBR record
	einfo "Copying syslinux MBR record"
	local gptdev
	gptdev="$(resolve_device_by_id "${DISK_ID_PART_TO_GPT_ID[$DISK_ID_BIOS]}")" \
		|| die "Could not resolve device with id=${DISK_ID_PART_TO_GPT_ID[$DISK_ID_BIOS]}"
	try dd bs=440 conv=notrunc count=1 if=/usr/share/syslinux/gptmbr.bin of="$gptdev"
}

function install_kernel_bios_root_bootable() {
	try emerge --verbose sys-boot/syslinux

	# Link kernel to known name in /boot (no separate /boot/bios partition)
	local kernel_file
	kernel_file="$(find "/boot" \( -name "vmlinuz-*" -or -name 'kernel-*' \) -printf '%f\n' | sort -V | tail -n 1)" \
		|| die "Could not list newest kernel file"

	try cp "/boot/$kernel_file" "/boot/vmlinuz-current"

	# Generate initramfs in /boot
	generate_initramfs "/boot/initramfs.img"

	# Install syslinux to root partition
	einfo "Installing syslinux to root partition"
	local rootdev
	rootdev="$(resolve_device_by_id "$DISK_ID_ROOT")" \
		|| die "Could not resolve device with id=$DISK_ID_ROOT"
	
	# Create syslinux directory in /boot
	mkdir_or_die 0700 "/boot/syslinux"
	
	# Install syslinux to the root partition
	try syslinux --directory boot/syslinux --install "$rootdev"

	# Create syslinux.cfg for root partition boot
	generate_syslinux_cfg_root_bootable > /boot/syslinux/syslinux.cfg \
		|| die "Could save generated syslinux.cfg"

	# Install syslinux MBR record
	einfo "Copying syslinux MBR record"
	local gptdev
	gptdev="$(resolve_device_by_id "${DISK_ID_PART_TO_GPT_ID[$DISK_ID_ROOT]}")" \
		|| die "Could not resolve device with id=${DISK_ID_PART_TO_GPT_ID[$DISK_ID_ROOT]}"
	try dd bs=440 conv=notrunc count=1 if=/usr/share/syslinux/gptmbr.bin of="$gptdev"
}

function generate_syslinux_cfg_root_bootable() {
	cat <<EOF
DEFAULT libero
PROMPT 0
TIMEOUT 0

LABEL libero
	LINUX vmlinuz-current
	APPEND initrd=initramfs.img $(get_cmdline)
EOF
}

function install_kernel() {
	# Install vanilla kernel
	einfo "Installing vanilla kernel and related tools"

	if [[ $IS_EFI == "true" ]]; then
		install_kernel_efi
	elif [[ -v "DISK_ID_BIOS" ]]; then
		install_kernel_bios
	else
		# No separate BIOS partition, install directly to root
		install_kernel_bios_root_bootable
	fi

	einfo "Installing linux-firmware"
	echo "sys-kernel/linux-firmware linux-fw-redistributable no-source-code" >> /etc/portage/package.license \
		|| die "Could not write to /etc/portage/package.license"
	try emerge --verbose linux-firmware
}

function add_fstab_entry() {
	printf '%-46s  %-24s  %-6s  %-96s %s\n' "$1" "$2" "$3" "$4" "$5" >> /etc/fstab \
		|| die "Could not append entry to fstab"
}

function generate_fstab() {
	einfo "Generating fstab"
	install -m0644 -o root -g root "/tmp/libero-install/contrib/fstab" /etc/fstab \
		|| die "Could not overwrite /etc/fstab"
	if [[ $USED_ZFS != "true" && -n $DISK_ID_ROOT_TYPE ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")" "/" "$DISK_ID_ROOT_TYPE" "$DISK_ID_ROOT_MOUNT_OPTS" "0 1"
	fi
	if [[ $IS_EFI == "true" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_EFI")" "/boot/efi" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	elif [[ -v "DISK_ID_BIOS" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_BIOS")" "/boot/bios" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	fi
	# No fstab entry needed for root-bootable BIOS layout
	if [[ -v "DISK_ID_SWAP" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_SWAP")" "none" "swap" "defaults,discard" "0 0"
	fi
}

function main_install_libero_in_chroot() {
	[[ $# == 0 ]] || die "Too many arguments"

	maybe_exec 'before_install'

	# Remove the root password, making the account accessible for automated
	# tasks during the period of installation.
	einfo "Clearing root password"
	passwd -d root \
		|| die "Could not change root password"

	# Sync portage
	einfo "Syncing portage tree"
	try emerge-webrsync

	# Install mdadm if we used RAID (needed for UUID resolving)
	if [[ $USED_RAID == "true" ]]; then
		einfo "Installing mdadm"
		try emerge --verbose sys-fs/mdadm
	fi

	if [[ $IS_EFI == "true" ]]; then
		# Mount efi partition
		mount_efivars
		einfo "Mounting efi partition"
		mount_by_id "$DISK_ID_EFI" "/boot/efi"
	elif [[ -v "DISK_ID_BIOS" ]]; then
		# Mount bios partition
		einfo "Mounting bios partition"
		mount_by_id "$DISK_ID_BIOS" "/boot/bios"
	else
		# No separate BIOS partition - kernel will be installed directly to root /boot
		einfo "Using root partition for boot (no separate BIOS partition)"
	fi

	# Configure basic system things like timezone, locale, ...
	maybe_exec 'before_configure_base_system'
	configure_base_system
	maybe_exec 'after_configure_base_system'

	# Configure os-release
	einfo "Configuring os-release"
	echo 'NAME="Libero GNU/Linux"' > /usr/lib/os-release \
		|| die "Could not write to /usr/lib/os-release"
	echo 'ID=libero' >> /usr/lib/os-release \
		|| die "Could not append to /usr/lib/os-release"
	echo 'PRETTY_NAME="Libero GNU/Linux"' >> /usr/lib/os-release \
		|| die "Could not append to /usr/lib/os-release"
	echo 'ANSI_COLOR="1;34"' >> /usr/lib/os-release \
		|| die "Could not append to /usr/lib/os-release"
	echo 'HOME_URL="https://libero.eu.org/"' >> /usr/lib/os-release \
		|| die "Could not append to /usr/lib/os-release"
	echo 'VERSION_ID="1.1"' >> /usr/lib/os-release \
		|| die "Could not append to /usr/lib/os-release"

	# Prepare portage environment
	maybe_exec 'before_configure_portage'
	configure_portage

	# Install git (for git portage overlays)
	einfo "Installing git"
	try emerge --verbose dev-vcs/git

	if [[ "$PORTAGE_SYNC_TYPE" == "git" ]]; then
		mkdir_or_die 0755 "/etc/portage/repos.conf"
		cat > /etc/portage/repos.conf/gentoo.conf <<EOF
[DEFAULT]
main-repo = gentoo

[libero]
location = /var/db/repos/libero
sync-type = git
sync-uri = $PORTAGE_GIT_MIRROR
auto-sync = yes
sync-depth = $([[ $PORTAGE_GIT_FULL_HISTORY == true ]] && echo -n 0 || echo -n 1)
sync-git-verify-commit-signature = yes
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
EOF
		chmod 644 /etc/portage/repos.conf/gentoo.conf \
			|| die "Could not change permissions of '/etc/portage/repos.conf/gentoo.conf'"
		rm -rf /var/db/repos/gentoo \
			|| die "Could not delete obsolete rsync gentoo repository"
		try emerge --sync
	fi
	maybe_exec 'after_configure_portage'

	einfo "Generating ssh host keys"
	try ssh-keygen -A

	# Install authorized_keys before dracut, which might need them for remote unlocking.
	install_authorized_keys

	einfo "Enabling dracut USE flag on sys-kernel/installkernel"
	echo "sys-kernel/installkernel dracut" > /etc/portage/package.use/installkernel \
		|| die "Could not write /etc/portage/package.use/installkernel"

	# Install required programs and kernel now, in order to
	# prevent emerging module before an imminent kernel upgrade
	try emerge --verbose sys-kernel/dracut sys-kernel/libero-kernel-bin app-arch/zstd

	# Install cryptsetup if we used LUKS
	if [[ $USED_LUKS == "true" ]]; then
		einfo "Installing cryptsetup"
		try emerge --verbose sys-fs/cryptsetup
	fi

	if [[ $SYSTEMD == "true" && $USED_LUKS == "true" ]] ; then
		einfo "Enabling cryptsetup USE flag on sys-apps/systemd"
		echo "sys-apps/systemd cryptsetup" > /etc/portage/package.use/systemd \
			|| die "Could not write /etc/portage/package.use/systemd"
		einfo "Rebuilding systemd with changed USE flag"
		try emerge --verbose --changed-use --oneshot sys-apps/systemd
	fi

	# Install btrfs-progs if we used Btrfs
	if [[ $USED_BTRFS == "true" ]]; then
		einfo "Installing btrfs-progs"
		try emerge --verbose sys-fs/btrfs-progs
	fi

	try emerge --verbose dev-vcs/git

	# Install ZFS kernel module and tools if we used ZFS
	if [[ $USED_ZFS == "true" ]]; then
		einfo "Installing zfs"
		try emerge --verbose sys-fs/zfs sys-fs/zfs-kmod

		einfo "Enabling zfs services"
		if [[ $SYSTEMD == "true" ]]; then
			try systemctl enable zfs.target
			try systemctl enable zfs-import-cache
			try systemctl enable zfs-mount
			try systemctl enable zfs-import.target
		else
			try rc-update add zfs-import boot
			try rc-update add zfs-mount boot
		fi
	fi

	# Install kernel and initramfs
	maybe_exec 'before_install_kernel'
	install_kernel
	maybe_exec 'after_install_kernel'

	# Generate a valid fstab file
	generate_fstab

	# Install gentoolkit
	einfo "Installing gentoolkit"
	try emerge --verbose app-portage/gentoolkit

	if [[ $SYSTEMD == "true" ]]; then
		if [[ $SYSTEMD_NETWORKD == "true" ]]; then
			# Enable systemd networking and dhcp
			enable_service systemd-networkd
			enable_service systemd-resolved
			if [[ $SYSTEMD_NETWORKD_DHCP == "true" ]]; then
				echo -en "[Match]\nName=${SYSTEMD_NETWORKD_INTERFACE_NAME}\n\n[Network]\nDHCP=yes" > /etc/systemd/network/20-wired.network \
					|| die "Could not write dhcp network config to '/etc/systemd/network/20-wired.network'"
			else
				addresses=""
				for addr in "${SYSTEMD_NETWORKD_ADDRESSES[@]}"; do
					addresses="${addresses}Address=$addr\n"
				done
				echo -en "[Match]\nName=${SYSTEMD_NETWORKD_INTERFACE_NAME}\n\n[Network]\n${addresses}Gateway=$SYSTEMD_NETWORKD_GATEWAY" > /etc/systemd/network/20-wired.network \
					|| die "Could not write dhcp network config to '/etc/systemd/network/20-wired.network'"
			fi
			chown root:systemd-network /etc/systemd/network/20-wired.network \
				|| die "Could not change owner of '/etc/systemd/network/20-wired.network'"
			chmod 640 /etc/systemd/network/20-wired.network \
				|| die "Could not change permissions of '/etc/systemd/network/20-wired.network'"
		fi
	else
		# Install and enable dhcpcd
		einfo "Installing dhcpcd"
		try emerge --verbose net-misc/dhcpcd

		enable_service dhcpcd
	fi

	if [[ $ENABLE_SSHD == "true" ]]; then
		enable_sshd
	fi

	# Install additional packages, if any.
	if [[ ${#ADDITIONAL_PACKAGES[@]} -gt 0 ]]; then
		einfo "Installing additional packages"
		# shellcheck disable=SC2086
		try emerge --verbose --autounmask-continue=y -- "${ADDITIONAL_PACKAGES[@]}"
	fi

	if ask "Do you want to assign a root password now?"; then
		try passwd root
		einfo "Root password assigned"
	else
		try passwd -d root
		ewarn "Root password cleared, set one as soon as possible!"
	fi

	# If configured, change to libero testing at the last moment.
	# This is to ensure a smooth installation process. You can deal
	# with the blockers after installation ;)
	if [[ $USE_PORTAGE_TESTING == "true" ]]; then
		einfo "Adding ~$LIBERO_ARCH to ACCEPT_KEYWORDS"
		echo "ACCEPT_KEYWORDS=\"~$LIBERO_ARCH\"" >> /etc/portage/make.conf \
			|| die "Could not modify /etc/portage/make.conf"
	fi

	maybe_exec 'after_install'

	einfo "Libero installation complete."
	[[ $USED_LUKS == "true" ]] \
		&& einfo "A backup of your luks headers can be found at '$LUKS_HEADER_BACKUP_DIR', in case you want to have a backup."
	
	# Clean up temporary files to free up disk space
	cleanup_temp_files
	
	einfo "You may now reboot your system or execute ./install --chroot $ROOT_MOUNTPOINT to enter your system in a chroot."
	einfo "Chrooting in this way is always possible in case you need to fix something after rebooting."
}

function main_install() {
	[[ $# == 0 ]] || die "Too many arguments"

	libero_umount
	install_stage3

	[[ $IS_EFI == "true" ]] \
		&& mount_efivars
	libero_chroot "$ROOT_MOUNTPOINT" "/tmp/libero-install/install" __install_libero_in_chroot
}

function main_chroot() {
	# Skip if already mounted
	mountpoint -q -- "$1" \
		|| die "'$1' is not a mountpoint"

	libero_chroot "$@"
}

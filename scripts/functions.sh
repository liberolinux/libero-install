# shellcheck source=./scripts/protection.sh
source "$LIBERO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Functions

function sync_time() {
	einfo "Syncing time"
	if command -v ntpd &> /dev/null; then
		try ntpd -g -q
	elif command -v chrony &> /dev/null; then
		try chronyd -q
	else
		# why am I doing this?
		try date -s "$(curl -sI http://example.com | grep -i ^date: | cut -d' ' -f3-)"
	fi

	einfo "Current date: $(LANG=C date)"
	einfo "Writing time to hardware clock"
	hwclock --systohc --utc \
		|| die "Could not save time to hardware clock"
}

function check_config() {
	[[ $KEYMAP =~ ^[0-9A-Za-z-]*$ ]] \
		|| die "KEYMAP contains invalid characters"

	if [[ "$SYSTEMD" == "true" ]]; then
		[[ "$STAGE3_BASENAME" == *systemd* ]] \
			|| die "Using systemd requires a systemd stage3 archive!"
	else
		[[ "$STAGE3_BASENAME" != *systemd* ]] \
			|| die "Using OpenRC requires a non-systemd stage3 archive!"
	fi

	# Check hostname per RFC1123
	local hostname_regex='^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$'
	[[ $HOSTNAME =~ $hostname_regex ]] \
		|| die "'$HOSTNAME' is not a valid hostname"

	[[ -v "DISK_ID_ROOT" && -n $DISK_ID_ROOT ]] \
		|| die "You must assign DISK_ID_ROOT"
	   # Allow root-bootable BIOS installs without a BIOS partition
	   if [[ ! ( -v "DISK_ID_EFI" && -n $DISK_ID_EFI ) && ! ( -v "DISK_ID_BIOS" && -n $DISK_ID_BIOS ) ]]; then
			   if [[ -v "DISK_ID_ROOT" && -n $DISK_ID_ROOT ]]; then
					   elog "No EFI or BIOS partition set, assuming root-bootable BIOS mode."
			   else
					   die "You must assign DISK_ID_EFI or DISK_ID_BIOS or have a valid DISK_ID_ROOT for root-bootable BIOS."
			   fi
	   fi

	   if [[ -v "DISK_ID_BIOS" && -n "$DISK_ID_BIOS" ]]; then
			   [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_BIOS]" ]] \
					   && die "Missing uuid for DISK_ID_BIOS, have you made sure it is used?"
	   fi
	if [[ "$LIBERO_ARCH" != "x86" ]]; then
		[[ -v "DISK_ID_EFI" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_EFI]" ]] \
			&& die "Missing uuid for DISK_ID_EFI, have you made sure it is used?"
	fi
	[[ -v "DISK_ID_SWAP" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_SWAP]" ]] \
		&& die "Missing uuid for DISK_ID_SWAP, have you made sure it is used?"
	[[ -v "DISK_ID_ROOT" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_ROOT]" ]] \
		&& die "Missing uuid for DISK_ID_ROOT, have you made sure it is used?"

	if [[ -v "DISK_ID_EFI" ]]; then
		IS_EFI=true
	else
		IS_EFI=false
	fi
}

function preprocess_config() {
	disk_configuration

	# Check encryption key if used
	[[ $USED_ENCRYPTION == "true" ]] \
		&& check_encryption_key

	check_config
}

function check_installation_environment() {
	# Check if running as root (required for low-memory installations)
	if [[ $EUID -ne 0 ]]; then
		ewarn "Not running as root. Some disk operations may fail."
		ewarn "For best results with memory-constrained systems, run as root."
	fi
	
	# Check available memory
	local total_mem_kb
	total_mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")"
	local total_mem_mb=$((total_mem_kb / 1024))
	
	if [[ $total_mem_mb -lt 2048 ]]; then
		einfo "Detected low memory system: ${total_mem_mb}MB available"
		einfo "Enabling disk-based temporary storage for installation"
		export LIBERO_LOW_MEMORY_MODE=true
	else
		einfo "Available memory: ${total_mem_mb}MB"
	fi
	
	# Check for block device access
	if [[ ! -r /proc/partitions ]]; then
		ewarn "Cannot read /proc/partitions - block device detection may be limited"
	fi
	
	# Ensure udev is running for device management
	if ! pgrep -f "udevd\|systemd-udevd" >/dev/null 2>&1; then
		ewarn "udev daemon not detected - device symlinks may not be available"
	fi
}

function prepare_installation_environment() {
	maybe_exec 'before_prepare_environment'

	einfo "Preparing installation environment"
	
	# Check system environment first
	check_installation_environment

	local wanted_programs=(
		blkid
		gpg
		hwclock
		lsblk
		ntpd
		partprobe
		python3
		realpath
		"?rhash"
		sha512sum
		sgdisk
		timeout
		uuidgen
		wget
	)

	[[ $USED_BTRFS == "true" ]] \
		&& wanted_programs+=(btrfs)
	[[ $USED_ZFS == "true" ]] \
		&& wanted_programs+=(zfs)
	[[ $USED_RAID == "true" ]] \
		&& wanted_programs+=(mdadm)
	[[ $USED_LUKS == "true" ]] \
		&& wanted_programs+=(cryptsetup)

	# Check for existence of required programs
	check_wanted_programs "${wanted_programs[@]}"

	# Sync time now to prevent issues later
	sync_time

	maybe_exec 'after_prepare_environment'
}

function check_encryption_key() {
	if [[ -z "${LIBERO_INSTALL_ENCRYPTION_KEY+set}" ]]; then
		elog "You have enabled encryption, but haven't specified a key in the environment variable LIBERO_INSTALL_ENCRYPTION_KEY."
		if ask "Do you want to enter an encryption key now?"; then
			local encryption_key_1
			local encryption_key_2

			while true; do
				flush_stdin
				IFS="" read -s -r -p "Enter encryption key: " encryption_key_1 \
					|| die "Error in read"
				echo

				[[ ${#encryption_key_1} -ge 8 ]] \
					|| { ewarn "Your encryption key must be at least 8 characters long."; continue; }

				flush_stdin
				IFS="" read -s -r -p "Repeat encryption key: " encryption_key_2 \
					|| die "Error in read"
				echo

				[[ "$encryption_key_1" == "$encryption_key_2" ]] \
					|| { ewarn "Encryption keys mismatch."; continue; }
				break
			done

			export LIBERO_INSTALL_ENCRYPTION_KEY="$encryption_key_1"
		else
			die "Please export LIBERO_INSTALL_ENCRYPTION_KEY with the desired key."
		fi
	fi

	[[ ${#LIBERO_INSTALL_ENCRYPTION_KEY} -ge 8 ]] \
		|| die "Your encryption key must be at least 8 characters long."
}

function add_summary_entry() {
	local parent="$1"
	local id="$2"
	local name="$3"
	local hint="$4"
	local desc="$5"

	local ptr
	case "$id" in
		"${DISK_ID_BIOS-__unused__}")  ptr="[1;32m← bios[m" ;;
		"${DISK_ID_EFI-__unused__}")   ptr="[1;32m← efi[m"  ;;
		"${DISK_ID_SWAP-__unused__}")  ptr="[1;34m← swap[m" ;;
		"${DISK_ID_ROOT-__unused__}")  ptr="[1;33m← root[m" ;;
		*bios_grub*)             ptr="[1;35m← bios_grub[m" ;;
		# \x1f characters compensate for printf byte count and unicode character count mismatch due to '←'
		*)                             ptr="[1;32m[m$(echo -e "\x1f\x1f")" ;;
	esac

	summary_tree[$parent]+=";$id"
	summary_name[$id]="$name"
	summary_hint[$id]="$hint"
	summary_ptr[$id]="$ptr"
	summary_desc[$id]="$desc"
}

function summary_color_args() {
	for arg in "$@"; do
		if [[ -v "arguments[$arg]" ]]; then
			printf '%-28s ' "[1;34m$arg[2m=[m${arguments[$arg]}"
		fi
	done
}

function disk_existing() {
	local new_id="${arguments[new_id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry __root__ "$new_id" "${arguments[device]}" "(no-format, existing)" ""
	fi
	# no-op;
}

function disk_create_gpt() {
	local new_id="${arguments[new_id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -v arguments[id] ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "gpt" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(gpt)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -v arguments[id] ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")"
		device_desc="$device ($id)"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	local ptuuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "Creating new gpt partition table ($new_id) on $device_desc"
	wipefs --quiet --all --force "$device" \
		|| die "Could not erase previous file system signatures from '$device'"
	sgdisk -Z -U "$ptuuid" "$device" >/dev/null \
		|| die "Could not create new gpt partition table ($new_id) on '$device'"
	partprobe "$device"
}

function disk_create_mbr() {
	local new_id="${arguments[new_id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -v arguments[id] ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "mbr" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(mbr)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -v arguments[id] ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")"
		device_desc="$device ($id)"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	einfo "Creating new mbr partition table ($new_id) on $device_desc"
	wipefs --quiet --all --force "$device" \
		|| die "Could not erase previous file system signatures from '$device'"
	parted -s "$device" mklabel msdos >/dev/null \
		|| die "Could not create new mbr partition table ($new_id) on '$device'"
	partprobe "$device"
}

function disk_create_partition() {
	local new_id="${arguments[new_id]}"
	local id="${arguments[id]}"
	local size="${arguments[size]}"
	local type="${arguments[type]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry "$id" "$new_id" "part" "($type)" "$(summary_color_args size)"
		return 0
	fi

	if [[ $size == "remaining" ]]; then
		arg_size=0
	else
		arg_size="+$size"
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"
	local partuuid="${DISK_ID_TO_UUID[$new_id]}"
	local extra_args=""
	case "$type" in
		'bios_grub') type='ef02';;
		'bios')  type='ef02' extra_args='--attributes=0:set:2';;
		'efi')   type='ef00' ;;
		'swap')  type='8200' ;;
		'raid')  type='fd00' ;;
		'luks')  type='8309' ;;
		'linux') type='8300' ;;
		*) ;;
	esac

	local table_type="${DISK_ID_TABLE_TYPE[$id]}"
	if [[ "$table_type" == "mbr" ]]; then
		# For MBR we use parted; map types to partition type codes via sfdisk afterwards if needed
		# Determine start/end (always append). parted mkpart primary START END, using percentages or sizes.
		# We'll just let parted choose the first available space.
		local part_label="primary"
		# parted requires start/end; obtain free space via 'parted -m' is complex; simpler approach: use 'sfdisk --append' with size
		# Implement using sfdisk script style.
		local hex_type="83"
		case "$type" in
			'swap') hex_type='82';;
			*) hex_type='83';;
		esac
		# Compute size in sectors if not remaining; if remaining leave size blank so sfdisk allocates rest.
		local sfdisk_size_field=""
		if [[ $size != "remaining" ]]; then
			# Accept size like 512M/1G etc -> we can pass as +size to sfdisk
			sfdisk_size_field="size=$size"
		fi
		# Append new partition definition
		einfo "Creating MBR partition ($new_id) type=$hex_type size=$size on $device"
		local sfdisk_line="$sfdisk_size_field,type=$hex_type"
		# Use a subshell to avoid sfdisk reading existing layout modification complexity
		echo "$sfdisk_line" | sfdisk --append "$device" >/dev/null \
			|| die "Could not create new mbr partition ($new_id) on '$device' ($id)"
		partprobe "$device"
	else
		einfo "Creating partition ($new_id) with type=$type, size=$size on $device"
		# shellcheck disable=SC2086
		sgdisk -n "0:0:$arg_size" -t "0:$type" -u "0:$partuuid" $extra_args "$device" >/dev/null \
			|| die "Could not create new gpt partition ($new_id) on '$device' ($id)"
		partprobe "$device"
	fi

	# On some system, we need to wait a bit for the partition to show up.
	local new_device
	new_device="$(resolve_device_by_id "$new_id")" \
		|| die "Could not resolve new device with id=$new_id"
	for i in {1..10}; do
		[[ -e "$new_device" ]] && break
		[[ "$i" -eq 1 ]] && printf "Waiting for partition (%s) to appear..." "$new_device"
		printf " %s" "$((10 - i + 1))"
		sleep 1
		[[ "$i" -eq 10 ]] && echo
	done
}

function disk_create_raid() {
	local new_id="${arguments[new_id]}"
	local level="${arguments[level]}"
	local name="${arguments[name]}"
	local ids="${arguments[ids]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "_$new_id" "raid$level" "" "$(summary_color_args name)"
		done

		add_summary_entry __root__ "$new_id" "raid$level" "" "$(summary_color_args name)"
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	local mddevice="/dev/md/$name"
	local uuid="${DISK_ID_TO_UUID[$new_id]}"

	extra_args=()
	if [[ "$level" == 1 && "$name" == "efi" ]]; then
		extra_args+=("--metadata=1.0")
	else
		extra_args+=("--metadata=1.2")
	fi

# See https://serverfault.com/questions/1163715/mdadm-value-arch12021-cannot-be-set-as-devname-reason-not-posix-compatible
	einfo "Creating raid$level ($new_id) on $devices_desc"
	mdadm \
			--create "$mddevice" \
			--verbose \
			--level="$level" \
			--raid-devices="${#devices[@]}" \
			--uuid="$uuid" \
			--homehost="$HOSTNAME" \
			"${extra_args[@]}" \
			"${devices[@]}" \
		|| die "Could not create raid$level array '$mddevice' ($new_id) on $devices_desc"
}

function disk_create_luks() {
	local new_id="${arguments[new_id]}"
	local name="${arguments[name]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -v arguments[id] ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "luks" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(luks)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -v arguments[id] ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")"
		device_desc="$device ($id)"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	local uuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "Creating luks ($new_id) on $device_desc"
	cryptsetup luksFormat \
			--type luks2 \
			--uuid "$uuid" \
			--key-file <(echo -n "$LIBERO_INSTALL_ENCRYPTION_KEY") \
			--cipher aes-xts-plain64 \
			--hash sha512 \
			--pbkdf argon2id \
			--iter-time 4000 \
			--key-size 512 \
			--batch-mode \
			"$device" \
		|| die "Could not create luks on $device_desc"
	mkdir -p "$LUKS_HEADER_BACKUP_DIR" \
		|| die "Could not create luks header backup dir '$LUKS_HEADER_BACKUP_DIR'"
	local header_file="$LUKS_HEADER_BACKUP_DIR/luks-header-$id-${uuid,,}.img"
	[[ ! -e $header_file ]] \
		|| rm "$header_file" \
		|| die "Could not remove old luks header backup file '$header_file'"
	cryptsetup luksHeaderBackup "$device" \
			--header-backup-file "$header_file" \
		|| die "Could not backup luks header on $device_desc"
	cryptsetup open --type luks2 \
			--key-file <(echo -n "$LIBERO_INSTALL_ENCRYPTION_KEY") \
			"$device" "$name" \
		|| die "Could not open luks encrypted device $device_desc"
}

function disk_create_dummy() {
	local new_id="${arguments[new_id]}"
	local device="${arguments[device]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry __root__ "$new_id" "$device" "" ""
		return 0
	fi
}

function init_btrfs() {
	local device="$1"
	local desc="$2"
	mkdir -p /btrfs \
		|| die "Could not create /btrfs directory"
	mount "$device" /btrfs \
		|| die "Could not mount $desc to /btrfs"
	btrfs subvolume create /btrfs/root \
		|| die "Could not create btrfs subvolume /root on $desc"
	btrfs subvolume set-default /btrfs/root \
		|| die "Could not set default btrfs subvolume to /root on $desc"
	umount /btrfs \
		|| die "Could not unmount btrfs on $desc"
}

function disk_format() {
	local id="${arguments[id]}"
	local type="${arguments[type]}"
	local label="${arguments[label]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ "$type" == "bios_grub" ]]; then
			add_summary_entry "${arguments[id]}" "__fs__${arguments[id]}" "bios_grub" "(special)" ""
		else
			add_summary_entry "${arguments[id]}" "__fs__${arguments[id]}" "${arguments[type]}" "(fs)" "$(summary_color_args label)"
		fi
		return 0
	fi

	if [[ "$type" == "bios_grub" ]]; then
		die "bios_grub partition '$id' must not be formatted"
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"

	einfo "Formatting $device ($id) with $type"
	wipefs --quiet --all --force "$device" \
		|| die "Could not erase previous file system signatures from '$device' ($id)"

	case "$type" in
		'bios'|'efi')
			if [[ -v "arguments[label]" ]]; then
				mkfs.fat -F 32 -n "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.fat -F 32 "$device" \
					|| die "Could not format device '$device' ($id)"
			fi
			;;
		'swap')
			if [[ -v "arguments[label]" ]]; then
				mkswap -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkswap "$device" \
					|| die "Could not format device '$device' ($id)"
			fi

			# Try to swapoff in case the system enabled swap automatically
			swapoff "$device" &>/dev/null
			;;
		'ext4')
			if [[ -v "arguments[label]" ]]; then
				mkfs.ext4 -q -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.ext4 -q "$device" \
					|| die "Could not format device '$device' ($id)"
			fi
			;;
		'btrfs')
			if [[ -v "arguments[label]" ]]; then
				mkfs.btrfs -q -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.btrfs -q "$device" \
					|| die "Could not format device '$device' ($id)"
			fi

			init_btrfs "$device" "'$device' ($id)"
			;;
		*) die "Unknown filesystem type" ;;
	esac
}

# This function will be called when a custom zfs pool type has been chosen.
# $1: either 'true' or 'false' determining if the datasets should be encrypted
# $2: either 'false' or a value determining the dataset compression algorithm
# $3: a string describing all device paths (for error messages)
# $@: device paths
function format_zfs_standard() {
	local encrypt="$1"
	local compress="$2"
	local device_desc="$3"
	shift 3
	local devices=("$@")
	local extra_args=()

	einfo "Creating zfs pool on $devices_desc"

	local zfs_stdin=""
	if [[ "$encrypt" == true ]]; then
		extra_args+=(
			"-O" "encryption=aes-256-gcm"
			"-O" "keyformat=passphrase"
			"-O" "keylocation=prompt"
			)

		zfs_stdin="$LIBERO_INSTALL_ENCRYPTION_KEY"
	fi

	# dnodesize=legacy might be needed for GRUB2, but auto is preferred for xattr=sa.
	zpool create \
		-R "$ROOT_MOUNTPOINT" \
		-o ashift=12          \
		-O acltype=posix      \
		-O atime=off          \
		-O xattr=sa           \
		-O dnodesize=auto     \
		-O mountpoint=none    \
		-O canmount=noauto    \
		-O devices=off        \
		"${extra_args[@]}"    \
		rpool                 \
		"${devices[@]}"       \
			<<< "$zfs_stdin"  \
		|| die "Could not create zfs pool on $devices_desc"

	if [[ "$compress" != false ]]; then
		zfs set "compression=$compress" rpool \
			|| die "Could enable compression on dataset 'rpool'"
	fi
	zfs create rpool/ROOT \
		|| die "Could not create zfs dataset 'rpool/ROOT'"
	zfs create -o mountpoint=/ rpool/ROOT/default \
		|| die "Could not create zfs dataset 'rpool/ROOT/default'"
	zpool set bootfs=rpool/ROOT/default rpool \
		|| die "Could not set zfs property bootfs on rpool"
}

function disk_format_zfs() {
	local ids="${arguments[ids]}"
	local pool_type="${arguments[pool_type]}"
	local encrypt="${arguments[encrypt]-false}"
	local compress="${arguments[compress]-false}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "__fs__$id" "zfs" "(fs)" "$(summary_color_args label)"
		done
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	wipefs --quiet --all --force "${devices[@]}" \
		|| die "Could not erase previous file system signatures from $devices_desc"

	if [[ "$pool_type" == "custom" ]]; then
		format_zfs_custom "$devices_desc" "${devices[@]}"
	else
		format_zfs_standard "$encrypt" "$compress" "$devices_desc" "${devices[@]}"
	fi
}

function disk_format_btrfs() {
	local ids="${arguments[ids]}"
	local label="${arguments[label]}"
	local raid_type="${arguments[raid_type]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "__fs__$id" "btrfs" "(fs)" "$(summary_color_args label)"
		done
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	wipefs --quiet --all --force "${devices[@]}" \
		|| die "Could not erase previous file system signatures from $devices_desc"

	# Collect extra arguments
	extra_args=()
	if [[ "${#devices}" -gt 1 ]] && [[ -v "arguments[raid_type]" ]]; then
		extra_args+=("-d" "$raid_type")
	fi

	if [[ -v "arguments[label]" ]]; then
		extra_args+=("-L" "$label")
	fi

	einfo "Creating btrfs on $devices_desc"
	mkfs.btrfs -q "${extra_args[@]}" "${devices[@]}" \
		|| die "Could not create btrfs on $devices_desc"

	init_btrfs "${devices[0]}" "btrfs array ($devices_desc)"
}

function disk_mark_bootable() {
	local id="${arguments[id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry "${arguments[id]}" "__bootable__${arguments[id]}" "bootable" "(flag)" ""
		return 0
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"

	einfo "Marking $device ($id) as bootable"
	
	# Set the legacy BIOS bootable flag on the partition
	# This requires getting the partition number and parent device
	local partnum=""
	local parent_device=""
	
	# Extract partition number from device path
	if [[ "$device" =~ ^/dev/([a-z]+)([0-9]+)$ ]]; then
		parent_device="/dev/${BASH_REMATCH[1]}"
		partnum="${BASH_REMATCH[2]}"
	elif [[ "$device" =~ ^/dev/nvme[0-9]+n[0-9]+p([0-9]+)$ ]]; then
		parent_device="${device%p*}"
		partnum="${BASH_REMATCH[1]}"
	else
		die "Could not determine partition number for device '$device'"
	fi
	
	# Decide on GPT vs MBR
	local parent_table_type="${DISK_ID_TABLE_TYPE[${arguments[id]}]}"
	if [[ -z "$parent_table_type" ]]; then
		# Attempt to infer by checking if parent has a protective MBR via sgdisk -p
		if sgdisk -p "$parent_device" >/dev/null 2>&1; then
			parent_table_type="gpt"
		else
			parent_table_type="mbr"
		fi
	fi

	if [[ "$parent_table_type" == "gpt" ]]; then
		# Use sgdisk attribute (2) for legacy BIOS bootable
		sgdisk --attributes="$partnum:set:2" "$parent_device" >/dev/null \
			|| die "Could not set GPT bootable attribute on partition $partnum of '$parent_device'"
	else
		# Use parted to set boot flag for MBR
		parted -s "$parent_device" set "$partnum" boot on >/dev/null \
			|| die "Could not set MBR boot flag on partition $partnum of '$parent_device'"
	fi
	partprobe "$parent_device"
}

function apply_disk_action() {
	unset known_arguments
	unset arguments; declare -A arguments; parse_arguments "$@"
	case "${arguments[action]}" in
		'existing')          disk_existing         ;;
		'create_gpt')        disk_create_gpt       ;;
		'create_mbr')        disk_create_mbr       ;;
		'create_partition')  disk_create_partition ;;
		'create_raid')       disk_create_raid      ;;
		'create_luks')       disk_create_luks      ;;
		'create_dummy')      disk_create_dummy     ;;
		'format')            disk_format           ;;
		'format_zfs')        disk_format_zfs       ;;
		'format_btrfs')      disk_format_btrfs     ;;
		'mark_bootable')     disk_mark_bootable    ;;
		*) echo "Ignoring invalid action: ${arguments[action]}" ;;
	esac
}

function print_summary_tree_entry() {
	local indent_chars=""
	local indent="0"
	local d="1"
	local maxd="$((depth - 1))"
	while [[ $d -lt $maxd ]]; do
		if [[ ${summary_depth_continues[$d]} == "true" ]]; then
			indent_chars+='│ '
		else
			indent_chars+='  '
		fi
		indent=$((indent + 2))
		d="$((d + 1))"
	done
	if [[ $maxd -gt 0 ]]; then
		if [[ ${summary_depth_continues[$maxd]} == "true" ]]; then
			indent_chars+='├─'
		else
			indent_chars+='└─'
		fi
		indent=$((indent + 2))
	fi

	local name="${summary_name[$root]}"
	local hint="${summary_hint[$root]}"
	local desc="${summary_desc[$root]}"
	local ptr="${summary_ptr[$root]}"
	local id_name="[2m[m"
	if [[ $root != __* ]]; then
		if [[ $root == _* ]]; then
			id_name="[2m${root:1}[m"
		else
			id_name="[2m${root}[m"
		fi
	fi

	local align=0
	if [[ $indent -lt 33 ]]; then
		align="$((33 - indent))"
	fi

	elog "$indent_chars$(printf "%-${align}s %-47s %s" \
		"$name [2m$hint[m" \
		"$id_name $ptr" \
		"$desc")"
}

function print_summary_tree() {
	local root="$1"
	local depth="$((depth + 1))"
	local has_children=false

	if [[ -v "summary_tree[$root]" ]]; then
		local children="${summary_tree[$root]}"
		has_children=true
		summary_depth_continues[$depth]=true
	else
		summary_depth_continues[$depth]=false
	fi

	if [[ $root != __root__ ]]; then
		print_summary_tree_entry "$root"
	fi

	if [[ $has_children == "true" ]]; then
		local count
		count="$(tr ';' '\n' <<< "$children" | grep -c '\S')" \
			|| count=0
		local idx=0
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${children//';'/ }; do
			idx="$((idx + 1))"
			[[ $idx == "$count" ]] \
				&& summary_depth_continues[$depth]=false
			print_summary_tree "$id"
			# separate blocks by newline
			[[ ${summary_depth_continues[0]} == "true" ]] && [[ $depth == 1 ]] && [[ $idx == "$count" ]] \
				&& elog
		done
	fi
}

function apply_disk_actions() {
	local param
	local current_params=()
	for param in "${DISK_ACTIONS[@]}"; do
		if [[ $param == ';' ]]; then
			apply_disk_action "${current_params[@]}"
			current_params=()
		else
			current_params+=("$param")
		fi
	done
}

function summarize_disk_actions() {
	elog "[1mCurrent lsblk output:[m"
	for_line_in <(lsblk \
		|| die "Error in lsblk") elog

	local disk_action_summarize_only=true
	declare -A summary_tree
	declare -A summary_name
	declare -A summary_hint
	declare -A summary_ptr
	declare -A summary_desc
	declare -A summary_depth_continues
	apply_disk_actions

	local depth=-1
	elog
	elog "[1mConfigured disk layout:[m"
	elog ────────────────────────────────────────────────────────────────────────────────
	elog "$(printf '%-26s %-28s %s' NODE ID OPTIONS)"
	elog ────────────────────────────────────────────────────────────────────────────────
	print_summary_tree __root__
	elog ────────────────────────────────────────────────────────────────────────────────
}

function check_disk_usage() {
	local devices=()
	
	# Collect all devices that will be formatted
	local param
	local current_params=()
	for param in "${DISK_ACTIONS[@]}"; do
		if [[ $param == ';' ]]; then
			# Process collected params
			if [[ "${current_params[0]}" == "action=format" ]] || [[ "${current_params[0]}" == "action=create_gpt" ]]; then
				local device_id=""
				local device_path=""
				for p in "${current_params[@]}"; do
					if [[ $p == device=* ]]; then
						device_path="${p#device=}"
						devices+=("$device_path")
					elif [[ $p == id=* ]]; then
						device_id="${p#id=}"
						# Try to resolve device by id
						if device_path="$(resolve_device_by_id "$device_id" 2>/dev/null)"; then
							devices+=("$device_path")
						fi
					fi
				done
			fi
			current_params=()
		else
			current_params+=("$param")
		fi
	done
	
	# Check if any devices contain data
	local has_data=false
	for device in "${devices[@]}"; do
		if [[ -b "$device" ]] && blkid "$device" >/dev/null 2>&1; then
			has_data=true
			ewarn "Device $device appears to contain a filesystem or data"
			# Show filesystem info if available
			if fs_info=$(blkid -o full "$device" 2>/dev/null); then
				ewarn "  $fs_info"
			fi
		fi
	done
	
	if [[ $has_data == true ]]; then
		ewarn "One or more devices contain existing data that will be destroyed."
		einfo "Automatically proceeding with data destruction for installation"
	fi
}

function apply_disk_configuration() {
	summarize_disk_actions

	if [[ $NO_PARTITIONING_OR_FORMATTING == true ]]; then
		elog "You have chosen an existing disk configuration. No devices will"
		elog "actually be re-partitioned or formatted. Please make sure that all"
		elog "devices are already formatted."
	else
		ewarn "Please ensure that all selected devices are fully unmounted and are"
		ewarn "not otherwise in use by the system. This includes stopping mdadm arrays"
		ewarn "and closing opened luks volumes if applicable for all relevant devices."
		ewarn "Otherwise, automatic partitioning may fail."
		
		# Check for existing data on devices
		check_disk_usage
	fi
	ask "Do you really want to apply this disk configuration?" \
		|| die "Aborted"
	countdown "Applying in " 5

	# Enforcement: If system will boot via BIOS (no EFI) and any GPT table present, require bios_grub partition.
	if [[ ${IS_EFI-false} != true ]]; then
		# Scan DISK_ACTIONS for any create_gpt entries and record their id
		local current_params=()
		local param
		local gpt_ids=()
		for param in "${DISK_ACTIONS[@]}"; do
			if [[ $param == ';' ]]; then
				if [[ ${current_params[0]} == "action=create_gpt" ]]; then
					local gpt_new_id=""
					local p
					for p in "${current_params[@]}"; do
						[[ $p == new_id=* ]] && gpt_new_id="${p#new_id=}"
					done
					[[ -n $gpt_new_id ]] && gpt_ids+=("$gpt_new_id")
				fi
				current_params=()
			else
				current_params+=("$param")
			fi
		done
		if [[ ${#gpt_ids[@]} -gt 0 ]]; then
			local missing=false
			for gid in "${gpt_ids[@]}"; do
				if [[ ! -v "DISK_GPT_HAS_BIOS_GRUB[$gid]" ]]; then
					missing=true
					ewarn "GPT table '$gid' has no bios_grub partition; required for legacy BIOS boot"
				fi
			done
			[[ $missing == true ]] && die "Refusing to continue without required bios_grub partition(s)"
		fi
	fi

	maybe_exec 'before_disk_configuration'

	einfo "Applying disk configuration"
	apply_disk_actions

	einfo "Disk configuration was applied successfully"
	elog "[1mNew lsblk output:[m"
	for_line_in <(lsblk \
		|| die "Error in lsblk") elog

	maybe_exec 'after_disk_configuration'
}

function mount_efivars() {
	   # Bypass EFI code for x86
	   if [[ "$LIBERO_ARCH" == "x86" ]]; then
			   einfo "Skipping efivars mount for x86 architecture."
			   return
	   fi

	   # Skip if already mounted
	   mountpoint -q -- "/sys/firmware/efi/efivars" \
			   && return

	   # Mount efivars
	   einfo "Mounting efivars"
	   mount -t efivarfs efivarfs "/sys/firmware/efi/efivars" \
			   || die "Could not mount efivarfs"
}

function mount_by_id() {
	local dev
	local id="$1"
	local mountpoint="$2"
	local retry_count=0
	local max_retries=3

	# Validate input parameters
	[[ -n "$id" ]] || die "mount_by_id: id parameter is required"
	[[ -n "$mountpoint" ]] || die "mount_by_id: mountpoint parameter is required"

	   # Prevent mounting if id is empty or unset
	   if [[ -z "$id" ]]; then
			   einfo "Skipping mount: id parameter is not set."
			   return 0
	   fi

	   # Mount BIOS partition if it's FAT-formatted (for systems that need it accessible)
	   if [[ "$id" == "$DISK_ID_BIOS" ]]; then
			   # Check if the BIOS partition has a FAT filesystem
			   local fstype
			   if fstype="$(get_blkid_field_by_device 'TYPE' "$(resolve_device_by_id "$id")" 2>/dev/null)" && [[ "$fstype" == "vfat" ]]; then
					   einfo "Mounting BIOS FAT partition (id=$id) at /boot/bios"
					   # Create /boot/bios directory if it doesn't exist
					   mkdir -p "/boot/bios" || die "Could not create /boot/bios directory"
					   # Mount with appropriate FAT options
					   mount -t vfat -o defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid "$(resolve_device_by_id "$id")" "/boot/bios" \
							   || die "Could not mount BIOS FAT partition to /boot/bios"
					   return 0
			   else
					   einfo "Skipping mount of BIOS partition (id=$id) - contains boot code, not a filesystem"
					   return 0
			   fi
	   fi

	# Skip if already mounted
	if mountpoint -q -- "$mountpoint" 2>/dev/null; then
		einfo "Device with id=$id already mounted at '$mountpoint'"
		return 0
	fi

	# Create mountpoint directory with proper error handling
	einfo "Mounting device with id=$id to '$mountpoint'"
	if ! mkdir -p "$mountpoint" 2>/dev/null; then
		die "Could not create mountpoint directory '$mountpoint'"
	fi

	while [[ $retry_count -lt $max_retries ]]; do
		# Resolve device with better error handling
		if dev="$(resolve_device_by_id "$id")"; then
			# Verify the device exists and is a block device
			if [[ -b "$dev" ]]; then
				# Try mounting with timeout and better error handling
				einfo "Attempting to mount '$dev' to '$mountpoint' (attempt $((retry_count + 1))/$max_retries)"
				
				# Check if the device is already mounted elsewhere
				if mount | grep -q "^$dev "; then
					local existing_mount
					existing_mount="$(mount | grep "^$dev " | awk '{print $3}' | head -1)"
					ewarn "Device '$dev' is already mounted at '$existing_mount'"
					if [[ "$existing_mount" == "$mountpoint" ]]; then
						return 0
					fi
				fi
				
				# Detect filesystem type and use appropriate mount options
				local fstype
				if fstype="$(get_blkid_field_by_device 'TYPE' "$dev" 2>/dev/null)"; then
					einfo "Detected filesystem type: $fstype"
					case "$fstype" in
						vfat|fat32|fat16|fat12)
							# Use specific options for FAT filesystems to ensure proper mounting
							if timeout 30 mount -t vfat -o defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid "$dev" "$mountpoint" 2>/dev/null; then
								einfo "Successfully mounted FAT filesystem '$dev' to '$mountpoint'"
								return 0
							else
								ewarn "Failed to mount FAT filesystem '$dev' to '$mountpoint'"
							fi
							;;
						ext4|ext3|ext2)
							# Use specific options for ext filesystems
							if timeout 30 mount -t "$fstype" "$dev" "$mountpoint" 2>/dev/null; then
								einfo "Successfully mounted ext filesystem '$dev' to '$mountpoint'"
								return 0
							else
								ewarn "Failed to mount ext filesystem '$dev' to '$mountpoint'"
							fi
							;;
						*)
							# For other filesystems, use standard mount
							if timeout 30 mount "$dev" "$mountpoint" 2>/dev/null; then
								einfo "Successfully mounted '$dev' to '$mountpoint'"
								return 0
							else
								ewarn "Failed to mount '$dev' to '$mountpoint'"
							fi
							;;
					esac
				else
					# Fallback: try standard mount without filesystem detection
					if timeout 30 mount "$dev" "$mountpoint" 2>/dev/null; then
						einfo "Successfully mounted '$dev' to '$mountpoint'"
						return 0
					else
						ewarn "Mount attempt failed for '$dev' to '$mountpoint'"
					fi
				fi
			else
				ewarn "Resolved device '$dev' is not a valid block device"
			fi
		else
			ewarn "Could not resolve device with id=$id"
		fi
		
		retry_count=$((retry_count + 1))
		if [[ $retry_count -lt $max_retries ]]; then
			einfo "Retrying mount operation (attempt $((retry_count + 1))/$max_retries)"
			sleep 3
			# Force udev to settle and refresh device information
			if type udevadm &>/dev/null; then
				udevadm settle &>/dev/null || true
			fi
			# Force partition table re-read
			if type partprobe &>/dev/null; then
				partprobe &>/dev/null || true
			fi
		fi
	done

	die "Could not mount device with id=$id to '$mountpoint' after $max_retries attempts"
}

function mount_root() {
	if [[ $USED_ZFS == "true" ]] && ! mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		die "Error: Expected zfs to be mounted under '$ROOT_MOUNTPOINT', but it isn't."
	else
		mount_by_id "$DISK_ID_ROOT" "$ROOT_MOUNTPOINT"
	fi
}

function copy_scripts_to_chroot() {
	local chroot_dir="$1"
	local scripts_dest="$chroot_dir/tmp/libero-install/scripts"
	
	# Create destination directory in chroot
	einfo "Copying scripts to chroot environment"
	mkdir -p "$scripts_dest" \
		|| die "Could not create scripts directory '$scripts_dest'"
	
	# Copy all scripts from the original repository to chroot
	cp -r "$LIBERO_INSTALL_REPO_DIR_ORIGINAL/scripts/"* "$scripts_dest/" \
		|| die "Could not copy scripts to '$scripts_dest'"
	
	# Copy the main install script as well
	cp "$LIBERO_INSTALL_REPO_DIR_ORIGINAL/install" "$chroot_dir/tmp/libero-install/" \
		|| die "Could not copy install script to chroot"
	chmod +x "$chroot_dir/tmp/libero-install/install" \
		|| die "Could not make install script executable"
	
	# Make all scripts executable
	find "$scripts_dest" -type f -name "*.sh" -exec chmod +x {} \; \
		|| die "Could not make scripts executable"
	
	# Copy other necessary files (contrib, etc.) if they exist
	if [[ -d "$LIBERO_INSTALL_REPO_DIR_ORIGINAL/contrib" ]]; then
		local contrib_dest="$chroot_dir/tmp/libero-install/contrib"
		mkdir -p "$contrib_dest" \
			|| die "Could not create contrib directory '$contrib_dest'"
		cp -r "$LIBERO_INSTALL_REPO_DIR_ORIGINAL/contrib/"* "$contrib_dest/" \
			|| die "Could not copy contrib files to '$contrib_dest'"
	fi
	
	# Copy libero.conf if it exists
	if [[ -f "$LIBERO_INSTALL_REPO_DIR_ORIGINAL/libero.conf" ]]; then
		cp "$LIBERO_INSTALL_REPO_DIR_ORIGINAL/libero.conf" "$chroot_dir/tmp/libero-install/" \
			|| die "Could not copy libero.conf to chroot"
	fi
	
	# Set the repo directory path for use inside chroot
	export LIBERO_INSTALL_REPO_DIR="/tmp/libero-install"
}

function download_stage3() {
	# Always mount root first and use target disk for downloads to conserve RAM
	einfo "Mounting root filesystem early for disk-based temporary storage"
	mount_root
	
	# Use target disk for temporary storage instead of RAM-based /tmp
	local DISK_TMP_DIR="$ROOT_MOUNTPOINT/tmp/libero-install"
	mkdir -p "$DISK_TMP_DIR" \
		|| die "Could not create disk-based temp directory '$DISK_TMP_DIR'"
	cd "$DISK_TMP_DIR" \
		|| die "Could not cd into '$DISK_TMP_DIR'"
	
	# Update TMP_DIR for subsequent operations
	export TMP_DIR="$DISK_TMP_DIR"
	einfo "Using disk-based temporary directory: $TMP_DIR"

	local STAGE3_BASENAME_FINAL
	if [[ ("$LIBERO_ARCH" == "amd64" && "$STAGE3_VARIANT" == *x32*) || ("$LIBERO_ARCH" == "x86" && -n "$LIBERO_SUBARCH") ]]; then
		STAGE3_BASENAME_FINAL="$STAGE3_BASENAME_CUSTOM"
	else
		STAGE3_BASENAME_FINAL="$STAGE3_BASENAME"
	fi

	local STAGE3_RELEASES="$LIBERO_MIRROR/releases/$LIBERO_ARCH/autobuilds/current-$STAGE3_BASENAME_FINAL/"

	# Download upstream list of files
	CURRENT_STAGE3="$(download_stdout "$STAGE3_RELEASES")" \
		|| die "Could not retrieve list of tarballs"
	# Decode urlencoded strings
	CURRENT_STAGE3=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))' <<< "$CURRENT_STAGE3")
	# Parse output for correct filename
	CURRENT_STAGE3="$(grep -o "\"${STAGE3_BASENAME_FINAL}-[0-9A-Z]*.tar.xz\"" <<< "$CURRENT_STAGE3" \
		| sort -u | head -1)" \
		|| die "Could not parse list of tarballs"
	# Strip quotes
	CURRENT_STAGE3="${CURRENT_STAGE3:1:-1}"
	# File to indicate successful verification
	CURRENT_STAGE3_VERIFIED="${CURRENT_STAGE3}.verified"

	maybe_exec 'before_download_stage3' "$STAGE3_BASENAME_FINAL"

	# Download file if not already downloaded
	if [[ -e $CURRENT_STAGE3_VERIFIED ]]; then
		einfo "$STAGE3_BASENAME_FINAL tarball already downloaded and verified"
	else
		einfo "Downloading $STAGE3_BASENAME_FINAL tarball"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}" "${CURRENT_STAGE3}"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}.DIGESTS" "${CURRENT_STAGE3}.DIGESTS"

		# Import libero keys
		einfo "Importing gentoo gpg key"
		local LIBERO_GPG_KEY="$TMP_DIR/gentoo-keys.gpg"
		download "https://gentoo.org/.well-known/openpgpkey/hu/wtktzo4gyuhzu8a4z5fdj3fgmr1u6tob?l=releng" "$LIBERO_GPG_KEY" \
			|| die "Could not retrieve gentoo gpg key"
		gpg --quiet --import < "$LIBERO_GPG_KEY" \
			|| die "Could not import gentoo gpg key"

		# Verify DIGESTS signature
		einfo "Verifying tarball signature"
		gpg --quiet --verify "${CURRENT_STAGE3}.DIGESTS" \
			|| die "Signature of '${CURRENT_STAGE3}.DIGESTS' invalid!"

		# Check hashes
		einfo "Verifying tarball integrity"
		# Replace any absolute paths in the digest file with just the stage3 basename, so it will be found by rhash
		digest_line=$(grep 'tar.xz$' "${CURRENT_STAGE3}.DIGESTS" | sed -e 's/  .*stage3-/  stage3-/')
		if type rhash &>/dev/null; then
			rhash -P --check <(echo "# SHA512"; echo "$digest_line") \
				|| die "Checksum mismatch!"
		else
			sha512sum --check <<< "$digest_line" \
				|| die "Checksum mismatch!"
		fi

		# Create verification file in case the script is restarted
		touch_or_die 0644 "$CURRENT_STAGE3_VERIFIED"
	fi

	maybe_exec 'after_download_stage3' "${CURRENT_STAGE3}"
}

function extract_stage3() {
	[[ -n $CURRENT_STAGE3 ]] \
		|| die "CURRENT_STAGE3 is not set"
	[[ -e "$TMP_DIR/$CURRENT_STAGE3" ]] \
		|| die "stage3 file does not exist"

	# Mount root if not already mounted (for low RAM mode it's already mounted)
	if ! mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		mount_root
	fi

	maybe_exec 'before_extract_stage3' "$TMP_DIR/$CURRENT_STAGE3" "$ROOT_MOUNTPOINT"
	if find "$ROOT_MOUNTPOINT" -mindepth 1 -maxdepth 1 -not -name 'lost+found' -not -name 'tmp' | grep -q .; then
		einfo "Root directory '$ROOT_MOUNTPOINT' is not empty"
		
		# Show what's in the directory
		einfo "Contents of root directory:"
		ls -la "$ROOT_MOUNTPOINT/" | while read -r line; do
			einfo "  $line"
		done
		
		# Automatically clean root directory for installation
		einfo "Automatically cleaning root directory for installation"
		# Clean everything except lost+found and tmp (which contains our temporary files)
		if ! find "$ROOT_MOUNTPOINT" -mindepth 1 -maxdepth 1 -not -name 'lost+found' -not -name 'tmp' -exec rm -rf {} +; then
			ewarn "Some files could not be removed. Attempting to continue anyway..."
			# Try to remove what we can, file by file
			find "$ROOT_MOUNTPOINT" -mindepth 1 -maxdepth 1 -not -name 'lost+found' -not -name 'tmp' | while read -r item; do
				if ! rm -rf "$item" 2>/dev/null; then
					ewarn "Could not remove: $item"
				fi
			done
		fi
		einfo "Root directory cleaned successfully"
	fi

	# Extract tarball directly to root mountpoint to save space
	einfo "Extracting stage3 tarball directly to root mountpoint"
	
	# Check and prepare the extraction directory
	if [[ ! -d "$ROOT_MOUNTPOINT" ]]; then
		mkdir -p "$ROOT_MOUNTPOINT" || die "Could not create root mountpoint directory"
	fi
	
	# Ensure the directory has proper permissions
	chmod 755 "$ROOT_MOUNTPOINT" || die "Could not set permissions on root mountpoint"
	
	# Check available space before extraction
	local available_space=$(df --output=avail "$ROOT_MOUNTPOINT" | tail -n1)
	local archive_size=$(stat -c%s "$TMP_DIR/$CURRENT_STAGE3")
	einfo "Available space: ${available_space}KB, archive size: $((archive_size / 1024))KB"
	
	# Extract with more robust options and better error handling
	if ! tar xpf "$TMP_DIR/$CURRENT_STAGE3" \
		--xattrs-include='*.*' \
		--numeric-owner \
		--no-same-owner \
		--delay-directory-restore \
		--keep-directory-symlink \
		--overwrite \
		-C "$ROOT_MOUNTPOINT" 2>&1; then
		
		eerror "Failed to extract stage3 tarball"
		eerror "This could be due to:"
		eerror "1. Insufficient disk space"
		eerror "2. Permission issues"
		eerror "3. Corrupted tarball"
		eerror "4. Filesystem limitations"
		
		# Try to get more information about the failure
		einfo "Checking filesystem status:"
		df -h "$ROOT_MOUNTPOINT" || true
		df -i "$ROOT_MOUNTPOINT" || true
		
		die "Error while extracting tarball"
	fi
	
	# Verify extraction was successful
	if [[ ! -f "$ROOT_MOUNTPOINT/etc/portage/make.conf" ]] && [[ ! -f "$ROOT_MOUNTPOINT/etc/make.conf" ]]; then
		ewarn "Extraction appears incomplete - no make.conf found"
		einfo "Contents of ROOT_MOUNTPOINT:"
		ls -la "$ROOT_MOUNTPOINT/" || true
	else
		einfo "Stage3 extraction completed successfully"
	fi

	maybe_exec 'after_extract_stage3' "$TMP_DIR/$CURRENT_STAGE3" "$ROOT_MOUNTPOINT"
}

function cleanup_temp_files() {
	# Clean up temporary files from target disk if they exist
	if [[ -d "$ROOT_MOUNTPOINT/tmp/libero-install" ]]; then
		einfo "Cleaning up temporary files from target disk"
		rm -rf "$ROOT_MOUNTPOINT/tmp/libero-install" \
			|| ewarn "Could not clean up temporary files at '$ROOT_MOUNTPOINT/tmp/libero-install'"
	fi
}

function libero_umount() {
	if mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		einfo "Unmounting root filesystem"
		umount -R -l "$ROOT_MOUNTPOINT" \
			|| die "Could not unmount filesystems"
	fi
}

function init_bash() {
	source /etc/profile
	umask 0077
	export PS1='(chroot) \[[0;31m\]\u\[[1;31m\]@\h \[[1;34m\]\w \[[m\]\$ \[[m\]'
}; export -f init_bash

function env_update() {
	env-update \
		|| die "Error in env-update"
	source /etc/profile \
		|| die "Could not source /etc/profile"
	umask 0077
}

function mkdir_or_die() {
	# shellcheck disable=SC2174
	mkdir -m "$1" -p "$2" \
		|| die "Could not create directory '$2'"
}

function touch_or_die() {
	touch "$2" \
		|| die "Could not touch '$2'"
	chmod "$1" "$2"
}

# $1: root directory
# $@: command...
function libero_chroot() {
	if [[ $# -eq 1 ]]; then
		einfo "To later unmount all virtual filesystems, simply use umount -l ${1@Q}"
		libero_chroot "$1" /bin/bash --init-file <(echo 'init_bash')
	fi

	[[ ${EXECUTED_IN_CHROOT-false} == "false" ]] \
		|| die "Already in chroot"

	local chroot_dir="$1"
	shift

	# Copy scripts to chroot environment instead of bind mounting
	copy_scripts_to_chroot "$chroot_dir"

	# Copy resolv.conf
	einfo "Preparing chroot environment"
	install --mode=0644 /etc/resolv.conf "$chroot_dir/etc/resolv.conf" \
		|| die "Could not copy resolv.conf"

	# Mount virtual filesystems
	einfo "Mounting virtual filesystems"
	(
		mountpoint -q -- "$chroot_dir/proc" || mount -t proc /proc "$chroot_dir/proc" || exit 1
		mountpoint -q -- "$chroot_dir/run"  || {
			mount --rbind /run  "$chroot_dir/run" &&
			mount --make-rslave "$chroot_dir/run"; } || exit 1
		
		# Always use disk-based /tmp (part of target filesystem) instead of bind mounting RAM-based host /tmp
		# This conserves RAM and works better on low-memory systems and Live CDs
		mkdir -p "$chroot_dir/tmp" || exit 1
		chmod 1777 "$chroot_dir/tmp" || exit 1
		
		mountpoint -q -- "$chroot_dir/sys"  || {
			mount --rbind /sys  "$chroot_dir/sys" &&
			mount --make-rslave "$chroot_dir/sys"; } || exit 1
		mountpoint -q -- "$chroot_dir/dev"  || {
			mount --rbind /dev  "$chroot_dir/dev" &&
			mount --make-rslave "$chroot_dir/dev"; } || exit 1
	) || die "Could not mount virtual filesystems"

	# Cache lsblk output, because it doesn't work correctly in chroot (returns almost no info for devices, e.g. empty uuids)
	cache_lsblk_output

	# Execute command
	einfo "Chrooting..."
	EXECUTED_IN_CHROOT=true \
		TMP_DIR="$TMP_DIR" \
		CACHED_LSBLK_OUTPUT="$CACHED_LSBLK_OUTPUT" \
		exec chroot -- "$chroot_dir" "/tmp/libero-install/scripts/dispatch_chroot.sh" "$@" \
			|| die "Failed to chroot into '$chroot_dir'."
}

function enable_service() {
	if [[ $SYSTEMD == "true" ]]; then
		try systemctl enable "$1"
	else
		try rc-update add "$1" default
	fi
}

function diagnose_locale_issues() {
	local locale_to_check="${1:-$LOCALE}"
	
	eerror "Diagnosing locale configuration issues for: $locale_to_check"
	
	# Check if locale-gen was run and succeeded
	einfo "Checking if locales were generated..."
	if [[ -f /etc/locale.gen ]]; then
		einfo "Contents of /etc/locale.gen:"
		cat /etc/locale.gen | sed 's/^/  /'
	else
		ewarn "/etc/locale.gen does not exist"
	fi
	
	# Check available locales
	einfo "Available locales on system:"
	if locale -a 2>/dev/null; then
		: # Success, output already shown
	else
		ewarn "locale -a command failed"
	fi
	
	# Check current locale environment
	einfo "Current locale environment:"
	locale 2>/dev/null | sed 's/^/  /' || ewarn "locale command failed"
	
	# Check locale configuration files
	einfo "Checking locale configuration files..."
	for file in /etc/locale.conf /etc/env.d/02locale; do
		if [[ -f "$file" ]]; then
			einfo "Contents of $file:"
			cat "$file" | sed 's/^/  /'
		else
			einfo "$file does not exist"
		fi
	done
	
	# Check if eselect locale is available and working
	einfo "Checking eselect locale..."
	if command -v eselect >/dev/null 2>&1; then
		if eselect locale list 2>/dev/null; then
			: # Success, output already shown
		else
			ewarn "eselect locale list failed"
		fi
	else
		ewarn "eselect command not available"
	fi
	
	# Suggest fixes
	einfo "Suggested fixes:"
	einfo "1. Ensure LOCALES contains entries like 'en_US.UTF-8 UTF-8'"
	einfo "2. Ensure LOCALE matches a generated locale (use 'locale -a' to check)"
	einfo "3. For minimal systems, consider using 'C.UTF-8' as the locale"
	einfo "4. After fixing LOCALES, re-run 'locale-gen' manually"
}

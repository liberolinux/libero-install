# shellcheck source=./scripts/protection.sh
source "$LIBERO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1

function elog() {
	echo "[[1m+[m] $*"
}

function einfo() {
	echo "[[1m+[m] [1;33m$*[m"
}

function ewarn() {
	echo "[[1;31m![m] [1;33m$*[m" >&2
}

function eerror() {
	echo "[1;31merror:[m $*" >&2
}

function die() {
	eerror "$*"
	[[ -v LIBERO_INSTALL_REPO_SCRIPT_PID && $$ -ne $LIBERO_INSTALL_REPO_SCRIPT_PID ]] \
		&& kill "$LIBERO_INSTALL_REPO_SCRIPT_PID"
	exit 1
}

# Prints an error with file:line info of the nth "stack frame".
# 0 is this function, 1 the calling function, 2 its parent, and so on.
function die_trace() {
	local idx="${1:-0}"
	shift
	echo "[1m${BASH_SOURCE[$((idx + 1))]}:${BASH_LINENO[$idx]}: [1;31merror:[m ${FUNCNAME[$idx]}: $*" >&2
	exit 1
}

function for_line_in() {
	while IFS="" read -r line || [[ -n $line ]]; do
		"$2" "$line"
	done <"$1"
}

function flush_stdin() {
	local empty_stdin
	# Unused variable is intentional.
	# shellcheck disable=SC2034
	while read -r -t 0.01 empty_stdin; do true; done
}

function ask() {
	local response
	while true; do
		flush_stdin
		read -r -p "$* (Y/n) " response \
			|| die "Error in read"
		case "${response,,}" in
			'') return 0 ;;
			y|yes) return 0 ;;
			n|no) return 1 ;;
			*) continue ;;
		esac
	done
}

function try() {
	local response
	local cmd_status
	local prompt_parens="([1mS[mhell/[1mr[metry/[1ma[mbort/[1mc[montinue/[1mp[mrint)"

	# Outer loop, allows us to retry the command
	while true; do
		# Try command
		"$@"
		cmd_status="$?"

		if [[ $cmd_status != 0 ]]; then
			echo "[1;31m * Command failed: [1;33m\$[m $*"
			echo "Last command failed with exit code $cmd_status"

			# Prompt until input is valid
			while true; do
				echo -n "Specify next action $prompt_parens "
				flush_stdin
				read -r response \
					|| die "Error in read"
				case "${response,,}" in
					''|s|shell)
						echo "You will be prompted for action again after exiting this shell."
						/bin/bash --init-file <(echo "init_bash")
						;;
					r|retry) continue 2 ;;
					a|abort) die "Installation aborted" ;;
					c|continue) return 0 ;;
					p|print) echo "[1;33m\$[m $*" ;;
					*) ;;
				esac
			done
		fi

		return
	done
}

function countdown() {
	echo -n "$1" >&2

	local i="$2"
	while [[ $i -gt 0 ]]; do
		echo -n "[1;31m$i[m " >&2
		i=$((i - 1))
		sleep 1
	done
	echo >&2
}

function download_stdout() {
	wget --quiet --https-only --secure-protocol=PFS -O - -- "$1"
}

function download() {
	wget --quiet --https-only --secure-protocol=PFS --show-progress -O "$2" -- "$1"
}

function get_blkid_field_by_device() {
	local blkid_field="$1"
	local device="$2"
	local val=""
	local retry_count=0
	local max_retries=3
	
	# Validate input parameters
	[[ -n "$blkid_field" ]] || die "blkid_field parameter is required"
	[[ -n "$device" ]] || die "device parameter is required"
	[[ -b "$device" ]] || die "Device '$device' is not a valid block device"
	
	while [[ $retry_count -lt $max_retries ]]; do
		# Force kernel to re-read partition table
		if type partprobe &>/dev/null; then
			partprobe "$device" &>/dev/null || true
		fi
		
		# Try multiple blkid approaches with timeouts
		if timeout 30 blkid -g -c /dev/null &>/dev/null; then
			# Method 1: Direct blkid export
			if val="$(timeout 30 blkid -c /dev/null -o export "$device" 2>/dev/null)"; then
				if [[ -n "$val" ]] && val="$(grep -- "^$blkid_field=" <<< "$val" 2>/dev/null)"; then
					val="${val#"$blkid_field="}"
					if [[ -n "$val" ]]; then
						echo -n "$val"
						return 0
					fi
				fi
			fi
			
			# Method 2: Direct field query
			if val="$(timeout 30 blkid -c /dev/null -s "$blkid_field" -o value "$device" 2>/dev/null)"; then
				if [[ -n "$val" ]]; then
					echo -n "$val"
					return 0
				fi
			fi
		fi
		
		# Method 3: Use /dev/disk/by-* symlinks as fallback
		case "$blkid_field" in
			'UUID'|'PARTUUID'|'LABEL'|'PARTLABEL')
				local by_field="${blkid_field,,}"
				[[ "$by_field" == "partlabel" ]] && by_field="partlabel"
				[[ "$by_field" == "partuuid" ]] && by_field="partuuid"
				[[ "$by_field" == "label" ]] && by_field="label"
				[[ "$by_field" == "uuid" ]] && by_field="uuid"
				
				for link in "/dev/disk/by-$by_field"/*; do
					if [[ -L "$link" ]] && [[ "$(readlink -f "$link" 2>/dev/null)" == "$device" ]]; then
						val="$(basename "$link")"
						if [[ -n "$val" ]]; then
							echo -n "$val"
							return 0
						fi
					fi
				done
				;;
		esac
		
		retry_count=$((retry_count + 1))
		if [[ $retry_count -lt $max_retries ]]; then
			einfo "Retrying blkid for $device (attempt $((retry_count + 1))/$max_retries)"
			sleep 2
		fi
	done
	
	die "Could not get $blkid_field from device '$device' after $max_retries attempts"
}

function get_blkid_uuid_for_id() {
	local dev
	dev="$(resolve_device_by_id "$1")" \
		|| die "Could not resolve device with id=$dev"
	local uuid
	uuid="$(get_blkid_field_by_device 'UUID' "$dev")" \
		|| die "Could not get UUID from blkid for device=$dev"
	echo -n "$uuid"
}

function get_device_by_blkid_field() {
	local blkid_field="$1"
	local field_value="$2"
	local dev=""
	local retry_count=0
	local max_retries=3
	
	# Validate input parameters
	[[ -n "$blkid_field" ]] || die "blkid_field parameter is required"
	[[ -n "$field_value" ]] || die "field_value parameter is required"
	
	while [[ $retry_count -lt $max_retries ]]; do
		# Force kernel to re-read partition tables
		if type partprobe &>/dev/null; then
			partprobe &>/dev/null || true
		fi
		
		# Method 1: Try direct blkid lookup with timeout
		if timeout 30 blkid -g -c /dev/null &>/dev/null; then
			if dev="$(timeout 30 blkid -c /dev/null -o export -t "$blkid_field=$field_value" 2>/dev/null)"; then
				if [[ -n "$dev" ]] && dev="$(grep DEVNAME <<< "$dev" 2>/dev/null)"; then
					dev="${dev#"DEVNAME="}"
					if [[ -n "$dev" ]] && [[ -b "$dev" ]]; then
						echo -n "$dev"
						return 0
					fi
				fi
			fi
		fi
		
		# Method 2: Use /dev/disk/by-* symlinks as primary fallback
		case "$blkid_field" in
			'UUID')
				local symlink_path="/dev/disk/by-uuid/$field_value"
				if [[ -L "$symlink_path" ]]; then
					dev="$(readlink -f "$symlink_path" 2>/dev/null)"
					if [[ -n "$dev" ]] && [[ -b "$dev" ]]; then
						echo -n "$dev"
						return 0
					fi
				fi
				;;
			'PARTUUID')
				local symlink_path="/dev/disk/by-partuuid/$field_value"
				if [[ -L "$symlink_path" ]]; then
					dev="$(readlink -f "$symlink_path" 2>/dev/null)"
					if [[ -n "$dev" ]] && [[ -b "$dev" ]]; then
						echo -n "$dev"
						return 0
					fi
				fi
				;;
			'LABEL')
				local symlink_path="/dev/disk/by-label/$field_value"
				if [[ -L "$symlink_path" ]]; then
					dev="$(readlink -f "$symlink_path" 2>/dev/null)"
					if [[ -n "$dev" ]] && [[ -b "$dev" ]]; then
						echo -n "$dev"
						return 0
					fi
				fi
				;;
			'PARTLABEL')
				local symlink_path="/dev/disk/by-partlabel/$field_value"
				if [[ -L "$symlink_path" ]]; then
					dev="$(readlink -f "$symlink_path" 2>/dev/null)"
					if [[ -n "$dev" ]] && [[ -b "$dev" ]]; then
						echo -n "$dev"
						return 0
					fi
				fi
				;;
		esac
		
		# Method 3: Manual search through block devices as last resort
		for device in /dev/sd* /dev/nvme* /dev/vd* /dev/xvd* /dev/hd*; do
			[[ -b "$device" ]] || continue
			
			# Quick check using blkid for this specific device
			if timeout 10 blkid -s "$blkid_field" -o value "$device" 2>/dev/null | grep -q "^$field_value$"; then
				echo -n "$device"
				return 0
			fi
		done
		
		retry_count=$((retry_count + 1))
		if [[ $retry_count -lt $max_retries ]]; then
			einfo "Retrying device lookup for $blkid_field=$field_value (attempt $((retry_count + 1))/$max_retries)"
			sleep 2
		fi
	done
	
	die "Could not find device with $blkid_field=$field_value after $max_retries attempts"
}

function get_device_by_partuuid() {
	local partuuid="$1"
	local symlink_path="/dev/disk/by-partuuid/$partuuid"
	
	# Validate input
	[[ -n "$partuuid" ]] || die "partuuid parameter is required"
	
	# Method 1: Direct symlink check
	if [[ -e "$symlink_path" ]]; then
		echo -n "$symlink_path"
		return 0
	fi
	
	# Method 2: Wait for udev to create the symlink
	local wait_timeout=15
	local count=0
	while [[ $count -lt $wait_timeout ]]; do
		sleep 1
		count=$((count + 1))
		# Trigger udev refresh
		if type udevadm &>/dev/null; then
			udevadm settle &>/dev/null || true
		fi
		if [[ -e "$symlink_path" ]]; then
			echo -n "$symlink_path"
			return 0
		fi
	done
	
	# Method 3: Use improved blkid fallback
	get_device_by_blkid_field 'PARTUUID' "$partuuid"
}

function get_device_by_uuid() {
	local uuid="$1"
	local symlink_path="/dev/disk/by-uuid/$uuid"
	
	# Validate input
	[[ -n "$uuid" ]] || die "uuid parameter is required"
	
	# Method 1: Direct symlink check
	if [[ -e "$symlink_path" ]]; then
		echo -n "$symlink_path"
		return 0
	fi
	
	# Method 2: Wait for udev to create the symlink
	local wait_timeout=15
	local count=0
	while [[ $count -lt $wait_timeout ]]; do
		sleep 1
		count=$((count + 1))
		# Trigger udev refresh
		if type udevadm &>/dev/null; then
			udevadm settle &>/dev/null || true
		fi
		if [[ -e "$symlink_path" ]]; then
			echo -n "$symlink_path"
			return 0
		fi
	done
	
	# Method 3: Use improved blkid fallback
	get_device_by_blkid_field 'UUID' "$uuid"
}

function cache_lsblk_output() {
	CACHED_LSBLK_OUTPUT="$(lsblk --all --path --pairs --output NAME,PTUUID,PARTUUID)" \
		|| die "Error while executing lsblk to cache output"
}

function get_device_by_ptuuid() {
	local ptuuid="${1,,}"
	local dev
	if [[ -v CACHED_LSBLK_OUTPUT && -n "$CACHED_LSBLK_OUTPUT" ]]; then
		dev="$CACHED_LSBLK_OUTPUT"
	else
		dev="$(lsblk --all --path --pairs --output NAME,PTUUID,PARTUUID)" \
			|| die "Error while executing lsblk to find PTUUID=$ptuuid"
	fi
	dev="$(grep "ptuuid=\"$ptuuid\" partuuid=\"\"" <<< "${dev,,}")" \
		|| die "Could not find PTUUID=... in lsblk output"
	dev="${dev%'" ptuuid='*}"
	dev="${dev#'name="'}"
	echo -n "$dev"
}

function uuid_to_mduuid() {
	local mduuid="${1,,}"
	mduuid="${mduuid//-/}"
	mduuid="${mduuid:0:8}:${mduuid:8:8}:${mduuid:16:8}:${mduuid:24:8}"
	echo -n "$mduuid"
}

function get_device_by_mdadm_uuid() {
	local mduuid
	mduuid="$(uuid_to_mduuid "$1")" \
		|| die "Could not resolve mduuid from uuid=$1"
	local dev
	dev="$(mdadm --examine --scan)" \
		|| die "Error while executing mdadm to find array with UUID=$mduuid"
	dev="$(grep "uuid=$mduuid" <<< "${dev,,}")" \
		|| die "Could not find UUID=... in mdadm output"
	dev="${dev%'metadata='*}"
	dev="${dev#'array'}"
	dev="${dev#"${dev%%[![:space:]]*}"}"
	dev="${dev%"${dev##*[![:space:]]}"}"
	echo -n "$dev"
}

function get_device_by_luks_name() {
	echo -n "/dev/mapper/$1"
}

function create_resolve_entry() {
	local id="$1"
	local type="$2"
	local arg="${3,,}"

	DISK_ID_TO_RESOLVABLE[$id]="$type:$arg"
}

function create_resolve_entry_device() {
	local id="$1"
	local dev="$2"

	DISK_ID_TO_RESOLVABLE[$id]="device:$dev"
}

# Returns the basename of the device, if its path starts with /dev/disk/by-id/
function shorten_device() {
	echo -n "${1#/dev/disk/by-id/}"
}

# Return matching device from /dev/disk/by-id/ if possible,
# otherwise return the parameter unchanged.
function canonicalize_device() {
	local given_dev="$1"
	local resolved_dev=""
	
	# Validate input
	if [[ -z "$given_dev" || "$given_dev" == "." ]]; then
		echo -n "$given_dev"
		return 0
	fi
	
	# Check if device exists as a block device
	if [[ ! -b "$given_dev" ]] && [[ ! -L "$given_dev" ]]; then
		echo -n "$given_dev"
		return 0
	fi
	
	# Try to resolve the device path with error handling
	resolved_dev="$(realpath "$given_dev" 2>/dev/null)" || {
		# If realpath fails, try readlink for symlinks
		if [[ -L "$given_dev" ]]; then
			resolved_dev="$(readlink -f "$given_dev" 2>/dev/null)" || {
				echo -n "$given_dev"
				return 0
			}
		else
			echo -n "$given_dev"
			return 0
		fi
	}
	
	# Look for matching /dev/disk/by-id/ entry
	if [[ -d "/dev/disk/by-id" ]]; then
		for dev in /dev/disk/by-id/*; do
			[[ -e "$dev" ]] || continue
			local dev_resolved
			dev_resolved="$(realpath "$dev" 2>/dev/null)" || continue
			if [[ "$dev_resolved" == "$resolved_dev" ]]; then
				echo -n "$dev"
				return 0
			fi
		done
	fi

	# Return the resolved path or original if no by-id match found
	echo -n "${resolved_dev:-$given_dev}"
}

function resolve_device_by_id() {
	local id="$1"
	[[ -v DISK_ID_TO_RESOLVABLE[$id] ]] \
		|| die "Cannot resolve id='$id' to a block device (no table entry)"

	local type="${DISK_ID_TO_RESOLVABLE[$id]%%:*}"
	local arg="${DISK_ID_TO_RESOLVABLE[$id]#*:}"

	local dev
	case "$type" in
		'partuuid') dev=$(get_device_by_partuuid   "$arg") ;;
		'ptuuid')   dev=$(get_device_by_ptuuid     "$arg") ;;
		'uuid')     dev=$(get_device_by_uuid       "$arg") ;;
		'mdadm')    dev=$(get_device_by_mdadm_uuid "$arg") ;;
		'luks')     dev=$(get_device_by_luks_name  "$arg") ;;
		'device')   dev="$arg" ;;
		*) die "Cannot resolve '$type:$arg' to device (unknown type)"
	esac

	canonicalize_device "$dev"
}

function load_or_generate_uuid() {
	local uuid
	local uuid_file="$UUID_STORAGE_DIR/$1"

	if [[ -e $uuid_file ]]; then
		uuid="$(cat "$uuid_file")"
	else
		uuid="$(uuidgen -r)"
		mkdir -p "$UUID_STORAGE_DIR"
		echo -n "$uuid" > "$uuid_file"
	fi

	echo -n "$uuid"
}

# Parses named arguments and stores them in the associative array `arguments`.
# If given, the associative array `known_arguments` must contain a list of arguments
# prefixed with + (mandatory) or ? (optional). "at least one of" can be expressed by +a|b|c.
function parse_arguments() {
	local key
	local value
	local a
	for a in "$@"; do
		key="${a%%=*}"
		value="${a#*=}"

		if [[ $key == "$a" ]]; then
			extra_arguments+=("$a")
			continue
		fi

		arguments[$key]="$value"
	done

	declare -A allowed_keys
	if [[ -v known_arguments ]]; then
		local m
		for m in "${known_arguments[@]}"; do
			case "${m:0:1}" in
				'+')
					m="${m:1}"
					local has_opt=false
					local m_opt
					# Splitting is intentional here
					# shellcheck disable=SC2086
					for m_opt in ${m//|/ }; do
						allowed_keys[$m_opt]=true
						if [[ -v arguments[$m_opt] ]]; then
							has_opt=true
						fi
					done

					[[ $has_opt == "true" ]] \
						|| die_trace 2 "Missing mandatory argument $m=..."
					;;

				'?')
					allowed_keys[${m:1}]=true
					;;

				*) die_trace 2 "Invalid start character in known_arguments, in argument '$m'" ;;
			esac
		done

		for a in "${!arguments[@]}"; do
			[[ -v allowed_keys[$a] ]] \
				|| die_trace 2 "Unknown argument '$a'"
		done
	fi
}

# $1: program
# $2: checkfile
function has_program() {
	local program="$1"
	local checkfile="$2"
	if [[ -z "$checkfile" ]]; then
		type "$program" &>/dev/null \
			|| return 1
	elif [[ "${checkfile:0:1}" == "/" ]]; then
		[[ -e "$checkfile" ]] \
			|| return 1
	else
		type "$checkfile" &>/dev/null \
			|| return 1
	fi
	return 0
}

function check_wanted_programs() {
	local missing_required=()
	local missing_wanted=()
	local tuple
	local program
	local checkfile
	for tuple in "$@"; do
		program="${tuple%%=*}"
		checkfile=""
		[[ "$tuple" == *=* ]] \
			&& checkfile="${tuple##*=}"
		if ! has_program "${program#"?"}" "$checkfile"; then
			if [[ "$program" == "?"* ]]; then
				missing_wanted+=("${program#"?"}")
			else
				missing_required+=("$program")
			fi
		fi
	done

	[[ "${#missing_required[@]}" -eq 0 && "${#missing_wanted[@]}" -eq 0 ]] \
		&& return

	if [[ "${#missing_required[@]}" -gt 0 ]]; then
		elog "The following programs are required for the installer to work, but are currently missing on your system:" >&2
		elog "  ${missing_required[*]}" >&2
	fi
	if [[ "${#missing_wanted[@]}" -gt 0 ]]; then
		elog "Missing optional programs:" >&2
		elog "  ${missing_wanted[*]}" >&2
	fi

	if type pacman &>/dev/null; then
		declare -A pacman_packages
		pacman_packages=(
			[ntpd]=ntp
			[zfs]=""
		)
		elog "Detected pacman package manager."
		if ask "Do you want to install all missing programs automatically?"; then
			local packages
			local need_zfs=false

			for program in "${missing_required[@]}" "${missing_wanted[@]}"; do
				[[ "$program" == "zfs" ]] \
					&& need_zfs=true

				if [[ -v "pacman_packages[$program]" ]]; then
					# Assignments to the empty string are explicitly ignored,
					# as for example, zfs needs to be handled separately.
					[[ -n "${pacman_packages[$program]}" ]] \
						&& packages+=("${pacman_packages[$program]}")
				else
					packages+=("$program")
				fi
			done
			pacman -Sy "${packages[@]}"

			if [[ "$need_zfs" == true ]]; then
				elog "On an Arch live-stick you need the archzfs repository and some tools and modifications to use zfs."
				elog "There is an automated installer available at https://raw.githubusercontent.com/eoli3n/archiso-zfs/master/init."
				if ask "Do you want to automatically download and execute this zfs installation script?"; then
					curl -s "https://raw.githubusercontent.com/eoli3n/archiso-zfs/master/init" | bash
				fi
			fi

			return
		fi
	elif type emerge &>/dev/null; then
		elog "Detected Portage (emerge) package manager."
		if ask "Do you want to install all missing programs automatically?"; then
			elog "Updating Portage repository cache..."
			emerge --sync || die "Failed to synchronize Portage repositories."

			for program in "${missing_required[@]}" "${missing_wanted[@]}"; do
				if [[ "$program" == "ntpd" ]]; then
					elog "Installing ntpd using emerge..."
					emerge --ask ntp || die "Failed to install ntpd."
				else
					elog "You need to manually install $program."
				fi
			done
		fi
	elif type curl &>/dev/null; then
		:
	else
		if [[ "${#missing_required[@]}" -gt 0 ]]; then
			die "Aborted installer because of missing required programs."
		else
			ask "Continue without recommended programs?"
		fi
	fi
}

# exec function if defined
# $@ function name and arguments
function maybe_exec() {
	type "$1" &>/dev/null && "$@"
}

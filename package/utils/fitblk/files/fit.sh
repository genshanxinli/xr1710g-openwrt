fitblk_read_u32() {
	hexdump -v -n 4 -e '1/1 "%02x"' "$1" 2>/dev/null
}

export_fitblk_bootdev() {
	[ -e /sys/firmware/devicetree/base/chosen/rootdisk ] || return

	local rootdisk handle bootdev volid
	rootdisk="$(fitblk_read_u32 /sys/firmware/devicetree/base/chosen/rootdisk)"
	[ "${#rootdisk}" -eq 8 ] || return
	case "$rootdisk" in
		*[!0-9a-f]*) return 1 ;;
	esac

	for handle in /sys/class/mtd/mtd*/of_node/volumes/*/phandle; do
		[ ! -e "$handle" ] && continue
		if [ "$rootdisk" = "$(fitblk_read_u32 "$handle")" ]; then
			if [ -e "${handle%/phandle}/volname" ]; then
				CI_KERNPART="$(cat "${handle%/phandle}/volname")"
				export CI_KERNPART
			elif [ -e "${handle%/phandle}/volid" ]; then
				volid="$(fitblk_read_u32 "${handle%/phandle}/volid")"
				[ "${#volid}" -eq 8 ] || return
				case "$volid" in
					*[!0-9a-f]*) return 1 ;;
				esac
				CI_KERNVOLID="$((0x$volid))"
				export CI_KERNVOLID
			else
				return
			fi
			CI_UBIPART="$(cat "${handle%%/of_node*}/name")"
			export CI_UBIPART
			export CI_METHOD="ubi"
			return
		fi
	done

	for handle in /sys/class/mtd/mtd*/of_node/phandle; do
		[ ! -e "$handle" ] && continue
		if [ "$rootdisk" = "$(fitblk_read_u32 "$handle")" ]; then
			bootdev="${handle%/of_node/phandle}"
			bootdev="${bootdev#/sys/class/mtd/}"
			export PART_NAME="/dev/$bootdev"
			export CI_METHOD="default"
			return
		fi
	done

	for handle in /sys/class/block/*/of_node/phandle; do
		[ ! -e "$handle" ] && continue
		if [ "$rootdisk" = "$(fitblk_read_u32 "$handle")" ]; then
			bootdev="${handle%/of_node/phandle}"
			bootdev="${bootdev#/sys/class/block/}"
			export EMMC_KERN_DEV="/dev/$bootdev"
			export CI_METHOD="emmc"
			return
		fi
	done
}

fit_do_upgrade() {
	export_fitblk_bootdev
	[ -n "$CI_METHOD" ] || return 1
	[ -e /dev/fit0 ] && { fitblk /dev/fit0 || return 1; }
	[ -e /dev/fitrw ] && { fitblk /dev/fitrw || return 1; }

	case "$CI_METHOD" in
	emmc)
		emmc_do_upgrade "$1"
		;;
	default)
		default_do_upgrade "$1"
		;;
	ubi)
		nand_do_upgrade "$1"
		;;
	*)
		return 1
		;;
	esac
}

fit_check_image() {
	local magic
	magic="$(get_magic_long "$1")"
	[ "$magic" != "d00dfeed" ] && {
		echo "Invalid image type."
		return 74
	}

	fit_check_sign -f "$1" >/dev/null || return 74
}

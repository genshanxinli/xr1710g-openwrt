RAMFS_COPY_BIN='dumpimage fitblk fit_check_sign'

REQUIRE_IMAGE_METADATA=1

nokia_initial_setup()
{
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	fw_setenv bootcmd "flash read 0xc0000 0x800000 0x85000000; bootm 0x85000000"
}

platform_check_image() {
	local board=$(board_name)

	[ "$#" -gt 1 ] && return 1

	case "$board" in
	nokia,xg-040g-md)
		nand_do_platform_check "$board" "$1"
		return $?
		;;
	nokia,xg-040g-md-ubi|\
	quantum,q1000k-ubi)
		fit_check_image "$1"
		return $?
		;;
	gemtek,xr1710g-ubi|\
	gemtek,w1700k-ubi)
		# The bootloader boots whatever FDT the FIT carries, so an image for
		# the other Gemtek board flashes fine and then comes up with a device
		# tree whose MAC cells, PHY wiring and LED map do not exist there.
		# fwtool_check_image() already matches the image metadata against
		# board_name on the normal path, but it is skipped with -F, so also
		# look at the FDT description inside the FIT.
		local devname desc

		fit_check_image "$1" || return $?

		# mkits.sh names the FDT node "<ARCH> OpenWrt <DEVICE_NAME> device
		# tree blob", where DEVICE_NAME is the underscore form of
		# board_name. Only reject on a positive mismatch: if the FIT cannot
		# be listed, keep the previous behaviour instead of blocking valid
		# upgrades.
		devname="$(echo "$board" | tr ',' '_')"
		desc="$(dumpimage -l "$1" 2>/dev/null | \
			sed -n 's/^ *Description: .* OpenWrt \(.*\) device tree blob$/\1/p' | \
			head -n 1)"
		if [ -n "$desc" ] && [ "$desc" != "$devname" ]; then
			echo "Invalid image: built for '$desc', this device is '$devname'."
			return 74
		fi

		return 0
		;;
	esac

	return 0
}

platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
		gemtek,w1700k-ubi|\
		gemtek,xr1710g-ubi|\
		nokia,xg-040g-md-ubi|\
		quantum,q1000k-ubi)
			fit_do_upgrade "$1"
			;;
		*)
			nand_do_upgrade "$1"
			;;
	esac
}

platform_pre_upgrade() {
	local board=$(board_name)

	case "$board" in
	nokia,xg-040g-md)
		nokia_initial_setup
		;;
	*)
		;;
	esac
}

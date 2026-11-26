#!/bin/sh

# Airoha fan control RPC backend for LuCI

find_nct7802() {
	local hwmon
	for hwmon in /sys/class/hwmon/hwmon*; do
		if [ -f "$hwmon/name" ] && [ "$(cat "$hwmon/name" 2>/dev/null)" = "nct7802" ]; then
			echo "$hwmon"
			return
		fi
	done
}

find_mt7996_hwmon() {
	local band="$1" hwmon name
	for hwmon in /sys/class/hwmon/hwmon*; do
		if [ -f "$hwmon/name" ]; then
			name=$(cat "$hwmon/name" 2>/dev/null)
			case "$name" in
				mt7996_phy0."$band"|mt7996_phy0_"$band")
					echo "$hwmon"
					return
					;;
			esac
		fi
	done
	echo ""
}

find_phy_hwmon() {
	local suffix="$1" hwmon name
	for hwmon in /sys/class/hwmon/hwmon*; do
		if [ -f "$hwmon/name" ]; then
			name=$(cat "$hwmon/name" 2>/dev/null)
			case "$name" in
				*"$suffix")
					echo "$hwmon"
					return
					;;
			esac
		fi
	done
	echo ""
}

is_uint() {
	case "$1" in
		''|0[0-9]*|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

is_int() {
	local v="$1"
	case "$v" in
		-*) v="${v#-}" ;;
	esac
	is_uint "$v"
}

safe_uint() {
	if is_uint "$1"; then
		echo "$1"
	else
		echo "$2"
	fi
}

HWMON=$(find_nct7802)

read_temp() {
	local file="$1" raw
	if [ -n "$file" ] && [ -f "$file" ]; then
		raw=$(cat "$file" 2>/dev/null)
		if is_int "$raw"; then
			echo $((raw / 1000))
			return
		fi
	fi
	echo 0
}

read_value() {
	local file="$1" raw
	if [ -n "$file" ] && [ -f "$file" ]; then
		raw=$(cat "$file" 2>/dev/null)
		if is_uint "$raw"; then
			echo "$raw"
			return
		fi
	fi
	echo 0
}

get_status() {
	local temp_cpu temp_board=0 temp_phy1=0 temp_phy2=0
	local fan_rpm=0 fan_pwm=0 fan_mode=0 fan_percentage=0
	local phy1_hwmon phy2_hwmon wifi_24g=0 wifi_5g=0 wifi_6g=0
	local wifi_24g_hwmon wifi_5g_hwmon wifi_6g_hwmon
	local uci_mode uci_preset uci_manual_pwm mode_desc

	temp_cpu=$(read_temp "/sys/class/thermal/thermal_zone0/temp")
	[ -n "$HWMON" ] && temp_board=$(read_temp "${HWMON}/temp1_input")

	phy1_hwmon=$(find_phy_hwmon ":05")
	phy2_hwmon=$(find_phy_hwmon ":08")
	[ -n "$phy1_hwmon" ] && temp_phy1=$(read_temp "$phy1_hwmon/temp1_input")
	[ -n "$phy2_hwmon" ] && temp_phy2=$(read_temp "$phy2_hwmon/temp1_input")

	if [ -n "$HWMON" ]; then
		fan_rpm=$(read_value "${HWMON}/fan1_input")
		fan_pwm=$(read_value "${HWMON}/pwm1")
		fan_mode=$(read_value "${HWMON}/pwm1_enable")
	fi

	fan_percentage=$((fan_pwm * 100 / 255))

	wifi_24g_hwmon=$(find_mt7996_hwmon 0)
	wifi_5g_hwmon=$(find_mt7996_hwmon 1)
	wifi_6g_hwmon=$(find_mt7996_hwmon 2)
	[ -n "$wifi_24g_hwmon" ] && wifi_24g=$(read_temp "$wifi_24g_hwmon/temp1_input")
	[ -n "$wifi_5g_hwmon" ] && wifi_5g=$(read_temp "$wifi_5g_hwmon/temp1_input")
	[ -n "$wifi_6g_hwmon" ] && wifi_6g=$(read_temp "$wifi_6g_hwmon/temp1_input")

	uci_mode=$(uci -q get "fan.settings.mode")
	case "$uci_mode" in
		auto|manual) ;;
		*) uci_mode="auto" ;;
	esac
	uci_preset=$(uci -q get "fan.settings.curve_preset")
	case "$uci_preset" in
		quiet|balanced|performance|custom) ;;
		*) uci_preset="balanced" ;;
	esac
	uci_manual_pwm=$(safe_uint "$(uci -q get "fan.settings.manual_pwm")" 127)

	mode_desc="Unknown"
	case "$fan_mode" in
		0) mode_desc="Full Speed" ;;
		1) mode_desc="Manual" ;;
		2) mode_desc="Automatic" ;;
		3) mode_desc="Auto (Closed Loop)" ;;
	esac

	printf '{"temp_cpu":%d,"temp_board":%d,"temp_phy1":%d,"temp_phy2":%d,"wifi_24g":%d,"wifi_5g":%d,"wifi_6g":%d,"fan_rpm":%d,"fan_pwm":%d,"fan_percentage":%d,"fan_mode":%d,"fan_mode_desc":"%s","uci_mode":"%s","uci_preset":"%s","uci_manual_pwm":%d}\n' \
		"$temp_cpu" "$temp_board" "$temp_phy1" "$temp_phy2" \
		"$wifi_24g" "$wifi_5g" "$wifi_6g" \
		"$fan_rpm" "$fan_pwm" "$fan_percentage" \
		"$fan_mode" "$mode_desc" \
		"$uci_mode" "$uci_preset" "$uci_manual_pwm"
}

in_range() {
	is_uint "$1" && [ "$1" -le "$2" ] 2>/dev/null
}

reload_fan() {
	/etc/init.d/fan reload >/dev/null 2>&1
}

restore_uci_key() {
	local key="$1" prev="$2"
	if [ -n "$prev" ]; then
		uci -q set "${key}=${prev}" >/dev/null 2>&1 || true
	else
		uci -q delete "$key" >/dev/null 2>&1 || true
	fi
}

commit_and_reload() {
	local key="$1" val="$2" label="$3" prev
	prev=$(uci -q get "$key")

	if ! uci set "${key}=${val}" || ! uci commit fan; then
		uci -q revert fan >/dev/null 2>&1 || true
		printf '{"success":false,"error":"Failed to save %s"}\n' "$label"
		return
	fi

	if ! reload_fan; then
		restore_uci_key "$key" "$prev"
		uci -q commit fan >/dev/null 2>&1 || true
		printf '{"success":false,"error":"Failed to apply %s"}\n' "$label"
		return
	fi

	echo '{"success":true}'
}

get_curve() {
	local preset="$1" points="[" first=1 i temp pwm
	[ -z "$preset" ] && preset="balanced"

	case "$preset" in
		quiet|balanced|performance|custom) ;;
		*)
			echo '{"error":"Invalid preset"}'
			return
			;;
	esac

	for i in 1 2 3 4 5; do
		temp=$(safe_uint "$(uci -q get "fan.${preset}.point${i}_temp")" 0)
		if [ "$i" -eq 5 ]; then
			pwm=255
		else
			pwm=$(safe_uint "$(uci -q get "fan.${preset}.point${i}_pwm")" 0)
		fi

		[ "$first" -eq 0 ] && points="${points},"
		first=0
		points="${points}{\"temp\":${temp},\"pwm\":${pwm}}"
	done
	points="${points}]"

	printf '{"preset":"%s","points":%s}\n' "$preset" "$points"
}

get_all_curves() {
	local curves="{" first=1 preset points pfirst i temp pwm

	for preset in quiet balanced performance custom; do
		[ "$first" -eq 0 ] && curves="${curves},"
		first=0

		points="["
		pfirst=1
		for i in 1 2 3 4 5; do
			temp=$(safe_uint "$(uci -q get "fan.${preset}.point${i}_temp")" 0)
			if [ "$i" -eq 5 ]; then
				pwm=255
			else
				pwm=$(safe_uint "$(uci -q get "fan.${preset}.point${i}_pwm")" 0)
			fi

			[ "$pfirst" -eq 0 ] && points="${points},"
			pfirst=0
			points="${points}{\"temp\":${temp},\"pwm\":${pwm}}"
		done
		points="${points}]"

		curves="${curves}\"${preset}\":${points}"
	done
	curves="${curves}}"

	printf '%s\n' "$curves"
}

set_mode() {
	case "$1" in
		manual|auto) commit_and_reload "fan.settings.mode" "$1" "fan mode" ;;
		*) echo '{"success":false,"error":"Invalid mode"}' ;;
	esac
}

set_manual_pwm() {
	if in_range "$1" 255; then
		commit_and_reload "fan.settings.manual_pwm" "$1" "manual PWM"
	else
		echo '{"success":false,"error":"Invalid PWM value (0-255)"}'
	fi
}

set_preset() {
	case "$1" in
		quiet|balanced|performance|custom)
			commit_and_reload "fan.settings.curve_preset" "$1" "curve preset"
			;;
		*)
			echo '{"success":false,"error":"Invalid preset"}'
			;;
	esac
}

set_custom_curve() {
	local json i idx temp pwm old_t old_p prev_temp="" valid=0 prev_preset
	local nt1="" nt2="" nt3="" nt4="" nt5="" np1="" np2="" np3="" np4=""
	local ot1="" ot2="" ot3="" ot4="" ot5="" op1="" op2="" op3="" op4="" op5=""
	read -r json

	if ! command -v jsonfilter >/dev/null 2>&1; then
		echo '{"success":false,"error":"jsonfilter not available"}'
		return
	fi

	for i in 1 2 3 4 5; do
		idx=$((i - 1))
		old_t=$(uci -q get "fan.custom.point${i}_temp")
		old_p=$(uci -q get "fan.custom.point${i}_pwm")
		temp=$(printf '%s\n' "$json" | jsonfilter -e "@.points[${idx}].temp" 2>/dev/null)
		pwm=$(printf '%s\n' "$json" | jsonfilter -e "@.points[${idx}].pwm" 2>/dev/null)

		if [ -z "$temp" ] && [ -z "$pwm" ]; then
			temp="$old_t"
			pwm="$old_p"
			if ! in_range "$temp" 100 || { [ "$i" -lt 5 ] && ! in_range "$pwm" 255; }; then
				echo '{"success":false,"error":"Incomplete or invalid curve points"}'
				return
			fi
		else
			if ! in_range "$temp" 100; then
				echo '{"success":false,"error":"Invalid curve point values"}'
				return
			fi
			if [ "$i" -eq 5 ]; then
				# point5_pwm is hardware-fixed at 255 on NCT7802.
				if [ -n "$pwm" ] && [ "$pwm" != "255" ]; then
					echo '{"success":false,"error":"Point 5 PWM is hardware-fixed at 255"}'
					return
				fi
			elif ! in_range "$pwm" 255; then
				echo '{"success":false,"error":"Invalid curve point values"}'
				return
			fi
			valid=$((valid + 1))
		fi

		if [ -n "$prev_temp" ] && [ "$temp" -lt "$prev_temp" ]; then
			echo '{"success":false,"error":"Curve temperatures must be non-decreasing"}'
			return
		fi
		prev_temp="$temp"

		case "$i" in
			1) nt1="$temp"; np1="$pwm"; ot1="$old_t"; op1="$old_p" ;;
			2) nt2="$temp"; np2="$pwm"; ot2="$old_t"; op2="$old_p" ;;
			3) nt3="$temp"; np3="$pwm"; ot3="$old_t"; op3="$old_p" ;;
			4) nt4="$temp"; np4="$pwm"; ot4="$old_t"; op4="$old_p" ;;
			5) nt5="$temp"; ot5="$old_t"; op5="$old_p" ;;
		esac
	done

	if [ "$valid" -eq 0 ]; then
		echo '{"success":false,"error":"No valid curve points"}'
		return
	fi

	prev_preset=$(uci -q get "fan.settings.curve_preset")

	if ! uci set "fan.custom.point1_temp=$nt1" || ! uci set "fan.custom.point1_pwm=$np1" ||
	   ! uci set "fan.custom.point2_temp=$nt2" || ! uci set "fan.custom.point2_pwm=$np2" ||
	   ! uci set "fan.custom.point3_temp=$nt3" || ! uci set "fan.custom.point3_pwm=$np3" ||
	   ! uci set "fan.custom.point4_temp=$nt4" || ! uci set "fan.custom.point4_pwm=$np4" ||
	   ! uci set "fan.custom.point5_temp=$nt5" || ! uci set "fan.custom.point5_pwm=255" ||
	   ! uci set "fan.settings.curve_preset=custom" || ! uci commit fan; then
		uci -q revert fan >/dev/null 2>&1 || true
		echo '{"success":false,"error":"Failed to save custom curve"}'
		return
	fi

	if ! reload_fan; then
		restore_uci_key "fan.custom.point1_temp" "$ot1"
		restore_uci_key "fan.custom.point1_pwm" "$op1"
		restore_uci_key "fan.custom.point2_temp" "$ot2"
		restore_uci_key "fan.custom.point2_pwm" "$op2"
		restore_uci_key "fan.custom.point3_temp" "$ot3"
		restore_uci_key "fan.custom.point3_pwm" "$op3"
		restore_uci_key "fan.custom.point4_temp" "$ot4"
		restore_uci_key "fan.custom.point4_pwm" "$op4"
		restore_uci_key "fan.custom.point5_temp" "$ot5"
		restore_uci_key "fan.custom.point5_pwm" "$op5"
		restore_uci_key "fan.settings.curve_preset" "$prev_preset"
		uci -q commit fan >/dev/null 2>&1 || true
		echo '{"success":false,"error":"Failed to apply custom curve"}'
		return
	fi

	echo '{"success":true}'
}

case "$1" in
	list)
		echo '{"getStatus":{},"getCurve":{"preset":"str"},"getAllCurves":{},"setMode":{"mode":"str"},"setManualPwm":{"pwm":0},"setPreset":{"preset":"str"},"setCustomCurve":{"points":[]}}'
		;;
	call)
		case "$2" in
			getStatus)
				get_status
				;;
			getCurve)
				read -r input
				preset=$(printf '%s\n' "$input" | jsonfilter -e '@.preset' 2>/dev/null || echo "balanced")
				get_curve "$preset"
				;;
			getAllCurves)
				get_all_curves
				;;
			setMode)
				read -r input
				mode=$(printf '%s\n' "$input" | jsonfilter -e '@.mode' 2>/dev/null)
				set_mode "$mode"
				;;
			setManualPwm)
				read -r input
				pwm=$(printf '%s\n' "$input" | jsonfilter -e '@.pwm' 2>/dev/null)
				set_manual_pwm "$pwm"
				;;
			setPreset)
				read -r input
				preset=$(printf '%s\n' "$input" | jsonfilter -e '@.preset' 2>/dev/null)
				set_preset "$preset"
				;;
			setCustomCurve)
				set_custom_curve
				;;
			*)
				echo '{"error":"Invalid method"}'
				;;
		esac
		;;
esac

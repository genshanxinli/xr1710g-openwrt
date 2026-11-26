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
		pwm=$(safe_uint "$(uci -q get "fan.${preset}.point${i}_pwm")" 0)

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
			pwm=$(safe_uint "$(uci -q get "fan.${preset}.point${i}_pwm")" 0)

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
	local mode="$1"

	case "$mode" in
		manual|auto)
			uci set "fan.settings.mode=$mode"
			uci commit fan
			/etc/init.d/fan reload
			echo '{"success":true}'
			;;
		*)
			echo '{"success":false,"error":"Invalid mode"}'
			;;
	esac
}

set_manual_pwm() {
	local pwm="$1"

	if is_uint "$pwm" && [ "$pwm" -ge 0 ] 2>/dev/null && [ "$pwm" -le 255 ] 2>/dev/null; then
		uci set "fan.settings.manual_pwm=$pwm"
		uci commit fan
		/etc/init.d/fan reload
		echo '{"success":true}'
	else
		echo '{"success":false,"error":"Invalid PWM value (0-255)"}'
	fi
}

set_preset() {
	local preset="$1"

	case "$preset" in
		quiet|balanced|performance|custom)
			uci set "fan.settings.curve_preset=$preset"
			uci commit fan
			/etc/init.d/fan reload
			echo '{"success":true}'
			;;
		*)
			echo '{"success":false,"error":"Invalid preset"}'
			;;
	esac
}

set_custom_curve() {
	local json i idx temp pwm prev_temp="" valid=0
	read -r json

	if command -v jsonfilter >/dev/null 2>&1; then
		for i in 1 2 3 4 5; do
			idx=$((i - 1))
			temp=$(printf '%s\n' "$json" | jsonfilter -e "@.points[${idx}].temp" 2>/dev/null)
			pwm=$(printf '%s\n' "$json" | jsonfilter -e "@.points[${idx}].pwm" 2>/dev/null)

			if [ -z "$temp" ] && [ -z "$pwm" ]; then
				temp=$(uci -q get "fan.custom.point${i}_temp")
				is_uint "$temp" || continue
			else
				if ! is_uint "$temp" || ! [ "$temp" -ge 0 ] 2>/dev/null || ! [ "$temp" -le 100 ] 2>/dev/null ||
				   ! is_uint "$pwm" || ! [ "$pwm" -ge 0 ] 2>/dev/null || ! [ "$pwm" -le 255 ] 2>/dev/null; then
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
		done

		if [ "$valid" -eq 0 ]; then
			echo '{"success":false,"error":"No valid curve points"}'
			return
		fi

		for i in 1 2 3 4 5; do
			idx=$((i - 1))
			temp=$(printf '%s\n' "$json" | jsonfilter -e "@.points[${idx}].temp" 2>/dev/null)
			pwm=$(printf '%s\n' "$json" | jsonfilter -e "@.points[${idx}].pwm" 2>/dev/null)

			if [ -n "$temp" ] && [ -n "$pwm" ]; then
				uci set "fan.custom.point${i}_temp=$temp"
				uci set "fan.custom.point${i}_pwm=$pwm"
			fi
		done
		uci set "fan.settings.curve_preset=custom"
		uci commit fan
		/etc/init.d/fan reload
		echo '{"success":true}'
	else
		echo '{"success":false,"error":"jsonfilter not available"}'
	fi
}

case "$1" in
	list)
		echo '{"getStatus":{},"getCurve":{"preset":"str"},"getAllCurves":{},"setMode":{"mode":"str"},"setManualPwm":{"pwm":"int"},"setPreset":{"preset":"str"},"setCustomCurve":{"points":"array"}}'
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

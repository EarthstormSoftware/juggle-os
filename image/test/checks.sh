#!/bin/bash
# The checks of a running Juggle OS, run on it as its admin user over SSH, by test-qemu.ps1 (qemu-virt.sh) and
# test-pi.ps1. Prints what it looked at, then a line per check ("ok      <check>" or "FAILED  <check>: <why>"), and
# exits 1 if any failed.
#   checks.sh [qemu]   qemu: QEMU's machine, which has no hardware watchdog, and whose second boot starts the updated
#                      slot without tryboot (QEMU can't do it)
mode=${1:-pi}

echo "== Details"
(
	set -x
	cat /etc/juggle-release; hostname; uptime
	findmnt -n / ; findmnt -n /media/root-ro ; findmnt -n /data ; findmnt -n /boot/firmware
	sudo -n /usr/lib/juggle/os-update status
	ls /boot/firmware /boot/firmware/slot? | grep -vE "\.dtb$"; grep "^os_prefix" /boot/firmware/config.txt
	lsblk -o NAME,SIZE,FSTYPE,LABEL
	sudo -n ls -l /data /data/settings /data/ssh
	ls -l /run/juggle /run/juggle/authorized_keys
	readlink /etc/localtime; date
	ls -l /etc/resolv.conf; resolvectl status --no-pager | head -5
	systemctl --failed --no-legend
	systemctl list-timers --all --no-legend
	sudo -n ss -tulpn
	free -m
	systemd-analyze
	systemd-analyze blame | head -12
	systemctl show -p RuntimeWatchdogUSec; cat /sys/class/watchdog/watchdog0/state 2>&1
	sudo -n journalctl -b -u juggle-data -u juggle-settings -u juggle-os-check --no-pager
	# SSH's connections this boot, with any it dropped (OpenSSH's penalties for connections that don't finish)
	sudo -n journalctl -b -u ssh --no-pager | tail -40
	systemctl status --no-pager --lines=5 juggle-app; sudo -n ls -l /data/app /data/app-state
	bash /etc/update-motd.d/00-juggle | sed "s/\x1b\[[0-9;]*m//g" | tail -9
	grep -A2 "OS slot" /etc/issue
) 2>&1

# Each check prints why it failed, and returns non-zero
failed_units() {
	local state units
	state=$(systemctl is-system-running)
	units=$(systemctl --failed --no-legend --plain | awk '{ print $1 }' | xargs)
	[ "$state" = running ] && [ -z "$units" ] || { echo "the system is $state${units:+; failed: $units}"; return 1; }
}

# Only SSH (port 22), mDNS (Avahi), the DNS stub on the loopback (resolved), DHCP (networkd's clients: 68 for IPv4,
# 546 for IPv6) and the app's web page (port 80)
listening() {
	sudo -n ss -tulpnH | awk '
		{ match($0, /users:\(\("[^"]+"/); name = substr($0, RSTART + 9, RLENGTH - 10); local = $5 }
		name == "sshd" && local ~ /:22$/ { next }
		name == "avahi-daemon" { next }
		name == "systemd-resolve" && local ~ /^127\.0\.0\.5[34](%lo)?:53$/ { next }
		name == "systemd-network" && local ~ /:(68|546)$/ { next }
		name == "python3" && local ~ /:80$/ { next }
		{ print name " on " local; bad = 1 }
		END { exit bad }'
}

read_only_root() {
	[ "$(findmnt -n -o FSTYPE /)" = overlay ] || { echo "/ isn't overlayroot's overlay"; return 1; }
	findmnt -n -o OPTIONS /media/root-ro | tr ',' '\n' | grep -qx ro || { echo "the root isn't mounted read-only"; return 1; }
}

no_root_login() {
	local answer
	answer=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost true 2>&1)
	[ $? -ne 0 ] && grep -q "Permission denied" <<< "$answer" || { echo "root: $answer"; return 1; }
}

no_partition_ids() {
	! grep -H PARTUUID /media/root-ro/etc/fstab /etc/fstab
}

mounts() {
	systemctl is-active --quiet boot-firmware.mount || { echo "the boot partition isn't mounted by juggle-boot"; return 1; }
	findmnt -n /data > /dev/null || { echo "/data isn't mounted"; return 1; }
}

settings_applied() {
	! ls /boot/firmware | grep -iE "juggle(\.json|-error\.txt)" || { echo "(left on the boot partition)"; return 1; }
	[ -s /run/juggle/authorized_keys ] || { echo "no SSH keys in /run/juggle"; return 1; }
}

slot() {
	local status running permanent tryboot waiting
	status=$(sudo -n /usr/lib/juggle/os-update status) || { echo "os-update status failed"; return 1; }
	running=$(sed -n 's/^running=//p' <<< "$status"); permanent=$(sed -n 's/^permanent=//p' <<< "$status")
	tryboot=$(sed -n 's/^tryboot=//p' <<< "$status"); waiting=$(sed -n 's/^waiting=//p' <<< "$status")
	[ "$running" = "$permanent" ] && return 0
	# QEMU's second boot runs the updated slot as tryboot would, but without the firmware's flag
	[ "$mode" = qemu ] && [ "$tryboot" = 0 ] && [ "$waiting" = "$running" ] && return 0
	echo "running slot $running, but the permanent slot is $permanent (tryboot=$tryboot)"
	return 1
}

watchdog() {
	[ "$(systemctl show -p RuntimeWatchdogUSec --value)" = 15s ] || { echo "systemd isn't driving it"; return 1; }
	[ "$(cat /sys/class/watchdog/watchdog0/state 2>/dev/null)" = active ] || { echo "the hardware watchdog isn't active"; return 1; }
}

# The guard of a trial boot (os-update guard): enabled, and finished without a fault, at once on a boot that isn't a
# trial and once the check has decided on one (a trial boot that isn't kept is restarted, so never gets here)
trial_guard() {
	[ "$(systemctl is-enabled juggle-os-guard.service)" = enabled ] || { echo "juggle-os-guard isn't enabled"; return 1; }
	local state result
	for _ in 1 2 3 4 5; do
		state=$(systemctl show -p SubState --value juggle-os-guard); result=$(systemctl show -p Result --value juggle-os-guard)
		[ "$state" = dead ] && break
		sleep 2
	done
	[ "$state" = dead ] && [ "$result" = success ] || { echo "juggle-os-guard is $state ($result)"; return 1; }
}

# Only the services a Juggle OS Pi needs are running (and the update check and its guard, on a trial boot, the Wi-Fi check
# in the first minutes, and the SSH user's session)
services() {
	systemctl list-units --type=service --state=running --no-legend --plain | awk '{ print $1 }' | grep -vxE \
		'juggle-(app|console-logo|os-check|os-guard|wifi-check)\.service|avahi-daemon\.service|dbus\.service|(serial-)?getty@tty(1|AMA0)\.service|ssh\.service|systemd-(journald|logind|networkd|resolved|timesyncd|udevd|hostnamed)\.service|user@[0-9]+\.service|wpa_supplicant@wlan0\.service' \
		&& return 1 || return 0
}

# Nothing that changes the system on a timer: only systemd's own clean-up of temporary files
timers() {
	systemctl list-timers --all --no-legend --plain | awk '{ print $NF }' | grep -vx -e systemd-tmpfiles-clean.service \
		-e '' && return 1 || return 0
}

login_screens() {
	grep -q "OS slot" /etc/issue || { echo "the console's text has no slot"; return 1; }
	bash /etc/update-motd.d/00-juggle | grep -q "OS slot" || { echo "the SSH login screen has no slot"; return 1; }
	grep -q "App  " /etc/issue || { echo "the console's text has no app"; return 1; }
	bash /etc/update-motd.d/00-juggle | grep -q "App  " || { echo "the SSH login screen has no app"; return 1; }
	! grep -q '@[A-Z_]*@' /etc/issue || { echo "the console's text has a placeholder left"; return 1; }
	! grep -q '()' /etc/issue || { echo "the console's text has an empty model"; return 1; }
	systemctl -q is-enabled juggle-console-logo.service || { echo "the console's icons aren't enabled"; return 1; }
}

# If there's an app: running, not restarting, and its web page answering (any HTTP answer will do)
app() {
	[ -e /data/app/main.py ] || return 0
	local state restarts
	state=$(systemctl show -p SubState --value juggle-app); restarts=$(systemctl show -p NRestarts --value juggle-app)
	[ "$state" = running ] && [ "$restarts" = 0 ] || { echo "the app is $state, restarted $restarts times"; return 1; }
	python3 -c 'import urllib.request, urllib.error, sys
try:
    urllib.request.urlopen("http://localhost/", timeout=10)
except urllib.error.HTTPError:
    pass
except OSError as error:
    sys.exit(f"its web page: {error}")' || return 1
	# The app is told this OS's Juggle OS version (JUGGLE, the app contract's)
	local pid
	pid=$(systemctl show -p MainPID --value juggle-app)
	sudo -n cat "/proc/$pid/environ" | tr '\0' '\n' | grep -qxE 'JUGGLE=[0-9]+\.[0-9]+' ||
		{ echo "the app isn't given JUGGLE"; return 1; }
}

# The compiled libraries for apps import, and the onboard audio is loaded unless the app uses the PWM hardware
libraries() {
	python3 -c 'import rpi_ws281x' || return 1
	python3 -c 'from PIL import Image, ImageDraw, ImageFont; ImageFont.load_default(24)' || return 1
	# QEMU's machine has no Pi audio hardware, so the driver can't load there
	[ "$mode" = qemu ] && return 0
	local pwm loaded
	pwm=$(python3 -c 'import json; print(json.load(open("/data/app/app.json")).get("pwm", False))' 2> /dev/null)
	loaded=$(lsmod | grep -c '^snd_bcm2835 ')
	if [ "$pwm" = True ]; then
		[ "$loaded" = 0 ] || { echo "the app uses PWM, but the audio driver is loaded"; return 1; }
	else
		[ "$loaded" = 1 ] || { echo "the audio driver isn't loaded"; return 1; }
	fi
}

sudo_works() {
	sudo -n true
}

# Installing an app from an app.json, which must be refused with a reason containing the text given. A refused app is
# checked before the installed one is touched.
refused() {
	local dir out
	dir=$(mktemp -d)
	trap 'rm -rf "$dir" "$dir.tar"; trap - RETURN' RETURN
	echo 'print("never run")' > "$dir/main.py"
	echo "$1" > "$dir/app.json"
	tar -cf "$dir.tar" -C "$dir" main.py app.json || return 1
	if out=$(sudo -n /usr/lib/juggle/app install "$dir.tar" 2>&1); then
		echo "installed $1"
		return 1
	fi
	grep -qF "$2" <<< "$out" || { echo "refused $1 with: $out"; return 1; }
}

# Every file of the installed app, with its checksum
app_files() {
	sudo -n find /data/app -type f -exec sha256sum {} + 2> /dev/null | sort
}

# An app must say which Juggle OS it needs (the app contract, from v1.0), and one that needs a later one is refused;
# the installed app (if there is one) stays as it was
juggle_needed() {
	local before
	before=$(app_files)
	refused '{"name": "versionless", "version": "1"}' "doesn't say which Juggle OS it needs" || return 1
	refused '{"juggle": "9.0", "name": "later", "version": "1"}' "needs Juggle 9.0 or later" || return 1
	[ "$(app_files)" = "$before" ] || { echo "the installed app changed"; return 1; }
}

# In QEMU only, as it replaces the app: an app from before v1.0 (no "juggle", which this OS won't start) installed
# again with it is the same app, and keeps its state
juggle_added() {
	local dir out
	dir=$(mktemp -d)
	trap 'rm -rf "$dir" "$dir.tar"; trap - RETURN' RETURN
	sudo -n mkdir -p /data/app /data/app-state || return 1
	echo '{"name": "keeper", "version": "0.9"}' | sudo -n tee /data/app/app.json > /dev/null
	echo 'print("from before v1.0")' | sudo -n tee /data/app/main.py > /dev/null
	echo kept | sudo -n tee /data/app-state/marker > /dev/null
	printf 'import time\nwhile True:\n    time.sleep(60)\n' > "$dir/main.py"
	echo '{"juggle": "1.0", "name": "keeper", "version": "1.0"}' > "$dir/app.json"
	tar -cf "$dir.tar" -C "$dir" main.py app.json || return 1
	out=$(sudo -n /usr/lib/juggle/app install "$dir.tar" 2>&1) || { echo "not installed: $out"; return 1; }
	[ "$(sudo -n cat /data/app-state/marker 2> /dev/null)" = kept ] || { echo "its state is gone: $out"; return 1; }
	sudo -n /usr/lib/juggle/app remove > /dev/null 2>&1 || { echo "it couldn't be removed again"; return 1; }
}

# In QEMU only, as it replaces the app: an app that draws on the screen (display, from Juggle 1.1) has it to itself
# while it runs, and the console has it back once the app is removed
display_app() {
	local dir out
	dir=$(mktemp -d)
	trap 'rm -rf "$dir" "$dir.tar"; trap - RETURN' RETURN
	printf 'import time
while True:
    time.sleep(60)
' > "$dir/main.py"
	echo '{"juggle": "1.1", "name": "drawer", "version": "1.0", "display": true}' > "$dir/app.json"
	tar -cf "$dir.tar" -C "$dir" main.py app.json || return 1
	out=$(sudo -n /usr/lib/juggle/app install "$dir.tar" 2>&1) || { echo "not installed: $out"; return 1; }
	[ -e /run/juggle/display ] || { echo "the screen isn't the app's"; return 1; }
	systemctl -q is-active getty@tty1 juggle-console-logo && { echo "the console still runs"; return 1; }
	sudo -n /usr/lib/juggle/app remove > /dev/null 2>&1 || { echo "it couldn't be removed again"; return 1; }
	[ ! -e /run/juggle/display ] || { echo "the screen is still the app's"; return 1; }
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do systemctl -q is-active getty@tty1 && return 0; sleep 1; done
	echo "the login screen didn't come back"; return 1
}

# The display's backlight (if there is one) is the app user's to dim and switch off
backlight() {
	local light
	for light in /sys/class/backlight/*; do
		[ -e "$light/brightness" ] || continue
		sudo -n -u app test -w "$light/brightness" -a -w "$light/bl_power" || { echo "the app can't change $light"; return 1; }
	done
}

# The app user may run app-request as root, and nothing else; it answers, and refuses what it shouldn't do
app_requests() {
	local rights
	rights=$(sudo -n -l -U app | sed -n '/may run the following/,$p' | tail -n +2 | sed 's/^ *//')
	[ "$rights" = "(root) NOPASSWD: /usr/lib/juggle/app-request" ] || { echo "the app user may run: $rights"; return 1; }
	sudo -n -u app sudo -n /usr/lib/juggle/app-request settings | grep -q '"time_zone"' || return 1
	if sudo -n -u app sudo -n /usr/lib/juggle/app-request time-zone ../../etc/shadow 2> /dev/null; then
		echo "app-request took a path for a time zone"; return 1
	fi
	[ "$(systemctl show -p NotifyAccess --value juggle-app)" = main ] || { echo "the app can't ask for a watchdog"; return 1; }
}

# The app may turn the display (app-request display-rotation, from Juggle 1.1): into the permanent slot's boot files,
# then back as it was; a rotation that isn't one is refused
display_rotation() {
	local request=(sudo -n -u app sudo -n /usr/lib/juggle/app-request) before slot
	before=$("${request[@]}" settings | python3 -c 'import json, sys; print(json.load(sys.stdin)["display"]["rotation"])') ||
		return 1
	if "${request[@]}" display-rotation 45 2> /dev/null; then echo "it took 45 degrees"; return 1; fi
	slot=$(sed -n 's|^os_prefix=\(slot[AB]\)/$|\1|p' /boot/firmware/config.txt)
	"${request[@]}" display-rotation 270 > /dev/null || return 1
	grep -qw 'fbcon=rotate:3' "/boot/firmware/$slot/cmdline.txt" || { echo "the console isn't turned"; return 1; }
	grep -qw 'plymouth.splash=juggle-270' "/boot/firmware/$slot/cmdline.txt" || { echo "the splash isn't turned"; return 1; }
	grep -qx 'dtoverlay=vc4-kms-dsi-7inch,invy,swapxy' /boot/firmware/config.txt || { echo "the touch screen isn't turned"; return 1; }
	"${request[@]}" display-rotation "$before" > /dev/null || return 1
	[ "$("${request[@]}" settings | python3 -c 'import json, sys; print(json.load(sys.stdin)["display"]["rotation"])')" = "$before" ] ||
		{ echo "it isn't back to $before"; return 1; }
	if [ "$before" = 0 ] && grep -q 'fbcon=rotate\|dsi-7inch' "/boot/firmware/$slot/cmdline.txt" /boot/firmware/config.txt; then
		echo "the rotation stayed in the boot files"; return 1
	fi
}

echo
echo "== Checks"
result=0
check() {
	local why
	if why=$("$1" 2>&1); then
		echo "ok      $2"
	else
		echo "FAILED  $2: $(tr '\n' ' ' <<< "$why" | sed 's/ *$//')"
		result=1
	fi
}
check failed_units "no failed units"
check listening "only SSH, mDNS, the DNS stub, DHCP and the app listening"
check read_only_root "read-only root"
check no_root_login "root can't log in"
check no_partition_ids "no partition IDs in fstab"
check mounts "boot and data partitions mounted"
check settings_applied "settings applied, juggle.json gone"
check slot "running the permanent slot"
[ "$mode" = qemu ] || check watchdog "hardware watchdog running"
check services "only the expected services running"
check trial_guard "the trial boot's guard is enabled, and done"
check timers "no timers that change the system"
check login_screens "login screens show the slot and the app"
check app "the app runs, answers and is given JUGGLE (if there is one)"
check libraries "the libraries for apps import, audio as the app needs"
check sudo_works "sudo works for the admin user"
check juggle_needed "an app that doesn't say which Juggle OS it needs, or needs a later one, isn't installed"
[ "$mode" = qemu ] && check juggle_added "an app from before v1.0 installed again with juggle keeps its state"
[ "$mode" = qemu ] && check display_app "an app that draws on the screen has it to itself, and gives it back"
check app_requests "the app may ask app-request, and only that"
check display_rotation "the app may turn the display, into the boot files and back"
check backlight "the app may dim and switch off the display (if there is one)"
exit $result

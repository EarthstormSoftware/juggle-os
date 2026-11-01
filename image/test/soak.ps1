<#
.SYNOPSIS
The soak test: a Pi runs its app for several days, and what it uses at the start and the end is compared.

.DESCRIPTION
Run it with -Start to take the starting snapshot, then without it (as often as you like, days later) to take another
and compare it with the start: memory (the root filesystem is an overlay in RAM, so writes there use memory too),
the app's memory and restarts, disk space, the logs' size, and the clock against this PC's. A reboot, an app that
restarted, a clock that isn't synchronized or drifted, and errors in the log are flagged. Nothing on the Pi changes.
The snapshots go to deploy\soak\.

.PARAMETER Name
The Pi's name. Defaults to the last Pi set up (%APPDATA%\Juggle\devices.json).

.PARAMETER Start
Take the starting snapshot (replacing any earlier one for this Pi).
#>
[CmdletBinding()]
param([string]$Name, [switch]$Start)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$results = Join-Path $repo 'deploy\soak'

if (-not $Name) {
    $devices = Join-Path $env:APPDATA 'Juggle\devices.json'
    if (Test-Path $devices) { $Name = (Get-Content $devices -Raw | ConvertFrom-Json).LastDevice }
    if (-not $Name) { throw 'Name the Pi: no Pi has been set up on this PC yet.' }
}
$target = "juggle@$Name.local"
$startFile = Join-Path $results "$Name-start.json"
if (-not $Start -and -not (Test-Path $startFile)) { throw "No starting snapshot for ${Name}: run with -Start first." }

# One key=value per line; sizes in KiB
$snapshot = @'
kv() { echo "$1=$2"; }
kib() { sudo du -sk "$1" 2>/dev/null | cut -f1; }
used() { df -k --output=used "$1" 2>/dev/null | tail -1 | tr -d ' '; }
mem() { awk -v k="$1:" '$1 == k { print $2 }' /proc/meminfo; }
kv clock "$(date +%s.%N)"
kv boot_id "$(cat /proc/sys/kernel/random/boot_id)"
kv uptime_s "$(cut -d' ' -f1 /proc/uptime)"
kv version "$(. /etc/juggle-release; echo "$VERSION")"
kv mem_available "$(mem MemAvailable)"
kv mem_shmem "$(mem Shmem)"
kv mem_slab_unreclaimable "$(mem SUnreclaim)"
pid=$(systemctl show juggle-app -p MainPID --value)
kv app_state "$(systemctl is-active juggle-app)"
kv app_since "$(systemctl show juggle-app -p ActiveEnterTimestamp --value)"
kv app_restarts "$(systemctl show juggle-app -p NRestarts --value)"
kv app_rss "$([ "$pid" != 0 ] && awk '$1 == "VmRSS:" { print $2 }' /proc/$pid/status)"
kv app_threads "$([ "$pid" != 0 ] && awk '$1 == "Threads:" { print $2 }' /proc/$pid/status)"
kv app_fds "$([ "$pid" != 0 ] && sudo ls /proc/$pid/fd | wc -l)"
kv overlay_used "$(kib /media/root-rw/overlay)"
kv data_used "$(used /data)"
kv boot_used "$(used /boot/firmware)"
kv run_used "$(used /run)"
kv tmp_used "$(used /tmp)"
kv journal "$(kib /run/log/journal)"
kv var_log "$(kib /var/log)"
kv clock_synced "$(timedatectl show -p NTPSynchronized --value)"
kv ntp_offset_ms "$(timedatectl timesync-status 2>/dev/null | awk '$1 == "Offset:" { v = $2; u = v; gsub(/[-+0-9.]/, "", u); sub(/[a-zµ]+$/, "", v); print (u == "us" || u == "µs") ? v / 1000 : (u == "s" ? v * 1000 : v) }')"
kv load "$(cut -d' ' -f1-3 /proc/loadavg)"
kv temp_c "$(awk '{ printf "%.1f", $1 / 1000 }' /sys/class/thermal/thermal_zone0/temp)"
kv failed_units "$(systemctl list-units --failed --no-legend | wc -l)"
kv errors_this_boot "$(journalctl -b -p err -q --no-pager | wc -l)"
'@ -replace "`r", ''

# Native programs' stderr isn't an error here: their exit codes say how they went
$ErrorActionPreference = 'Continue'
$lines = $snapshot | ssh -o ConnectTimeout=15 $target 'bash -s'
$pcAfter = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000
if ($LASTEXITCODE -ne 0) { throw "Couldn't reach $Name over SSH." }
$ErrorActionPreference = 'Stop'

$now = [ordered]@{ name = $Name; taken = (Get-Date).ToString('o') }
foreach ($line in $lines) {
    $key, $value = $line -split '=', 2
    if ($key) { $now[$key] = $value }
}
# The Pi's clock against this PC's, roughly: SSH takes about a second, mostly connecting before the command runs
$now.clock_offset_s = [math]::Round([double]$now.clock - $pcAfter, 2)

New-Item -ItemType Directory -Force $results | Out-Null
if ($Start) {
    $now | ConvertTo-Json | Set-Content -Encoding utf8 $startFile
    Write-Host "Soak test started on $Name ($($now.version), Juggle app $($now.app_state), clock off by $($now.clock_offset_s) s)."
    Write-Host "Run this again without -Start in a few days to compare. The snapshot: $startFile"
    exit 0
}
$nowFile = Join-Path $results "$Name-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
$now | ConvertTo-Json | Set-Content -Encoding utf8 $nowFile
$was = Get-Content $startFile -Raw | ConvertFrom-Json

$days = [math]::Round(((Get-Date $now.taken) - (Get-Date $was.taken)).TotalDays, 2)
Write-Host "$Name after $days days (snapshots: $startFile, $nowFile)"
$rows = @(
    @('Memory available (KiB)', 'mem_available'), @('Shared memory, tmpfs (KiB)', 'mem_shmem'),
    @('Kernel memory, unreclaimable (KiB)', 'mem_slab_unreclaimable'), @('App memory, RSS (KiB)', 'app_rss'),
    @('App threads', 'app_threads'), @('App open files', 'app_fds'), @('App restarts', 'app_restarts'),
    @('Root overlay, in RAM (KiB)', 'overlay_used'), @('/data used (KiB)', 'data_used'),
    @('/boot/firmware used (KiB)', 'boot_used'), @('/run used (KiB)', 'run_used'), @('/tmp used (KiB)', 'tmp_used'),
    @('Journal (KiB)', 'journal'), @('/var/log (KiB)', 'var_log'),
    @('Clock against this PC (s, rough)', 'clock_offset_s'), @('NTP offset (ms)', 'ntp_offset_ms'),
    @('Errors logged this boot', 'errors_this_boot'), @('Failed units', 'failed_units'), @('Temperature (C)', 'temp_c')
)
$rows | ForEach-Object {
    $first, $last = $was.($_[1]), $now[$_[1]]
    $change = if ($first -as [double] -ne $null -and $last -as [double] -ne $null) { [double]$last - [double]$first }
    [pscustomobject]@{ What = $_[0]; Start = $first; Now = $last; Change = $change }
} | Format-Table -AutoSize | Out-String | Write-Host

$problems = @()
if ($now.boot_id -ne $was.boot_id) { $problems += "It rebooted (up $([math]::Round([double]$now.uptime_s / 3600, 1)) hours)." }
if ($now.app_state -ne 'active') { $problems += "The app is $($now.app_state)." }
elseif ($now.boot_id -eq $was.boot_id -and [int]$now.app_restarts -gt [int]$was.app_restarts) {
    $problems += "The app restarted $([int]$now.app_restarts - [int]$was.app_restarts) times."
}
if ($now.clock_synced -ne 'yes') { $problems += 'The clock is not synchronized.' }
if ($now.ntp_offset_ms -as [double] -ne $null -and [math]::Abs([double]$now.ntp_offset_ms) -gt 500) {
    $problems += "The clock is $($now.ntp_offset_ms) ms off its time server."
}
if ([math]::Abs($now.clock_offset_s) -gt 10) { $problems += "The clock is $($now.clock_offset_s) s off this PC's." }
if ([int]$now.failed_units -gt 0) { $problems += "$($now.failed_units) failed units." }
if ([int]$now.errors_this_boot -gt [int]$was.errors_this_boot) {
    $problems += "$([int]$now.errors_this_boot - [int]$was.errors_this_boot) more errors logged: journalctl -b -p err"
}
if ($problems) { $problems | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } }
else { Write-Host 'No reboot, app restart, clock problem or new errors.' -ForegroundColor Green }

# SecondLook - check a used Windows PC before you pay. https://github.com/honow48-tech/SecondLook
#   irm https://raw.githubusercontent.com/honow48-tech/SecondLook/main/check.ps1 | iex
# ponytail: one file, inline CSS/JS, no deps. Source kept ASCII so PS 5.1 reads it right without a BOM.

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -and -not $env:CHECKUP_ELEVATED) {  # flag set by the relaunch below, so it never loops
    # Relaunch elevated: from the file if run locally, else re-download (irm | iex case).
    $url = 'https://raw.githubusercontent.com/honow48-tech/SecondLook/main/check.ps1'
    $cmd = if ($PSCommandPath) { "& '$PSCommandPath'" } else { "irm $url | iex" }
    Write-Host "`n  Not Administrator - asking Windows for Admin (click Yes)..." -ForegroundColor Yellow
    try { Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -Command `$env:CHECKUP_ELEVATED=1; $cmd"; return }
    catch { Write-Host '  Admin refused - continuing with limited data.' -ForegroundColor Yellow }
}
Write-Host "`n  SecondLook" -ForegroundColor White
Write-Host "  Checking this PC... (Administrator: $admin)" -ForegroundColor Cyan

# Reads the drive's own health log, same source as Settings > Disks > Drive health. Needs Admin.
if (-not ('DiskHealth' -as [type])) { Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class DiskHealth {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] i, int il, byte[] o, int ol, out int r, IntPtr ov);
  static byte[] Io(int disk, uint code, byte[] inBuf, int outLen) {
    using (var h = CreateFile(@"\\.\PhysicalDrive" + disk, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
      if (h.IsInvalid) return null;
      var o = new byte[outLen]; int r;
      return DeviceIoControl(h, code, inBuf, inBuf.Length, o, o.Length, out r, IntPtr.Zero) ? o : null;
    }
  }
  // NVMe SMART / Health log page (02h) via IOCTL_STORAGE_QUERY_PROPERTY.
  public static byte[] Nvme(int disk) {
    var q = new byte[8 + 40 + 512];
    BitConverter.GetBytes(50).CopyTo(q, 0);   // StorageDeviceProtocolSpecificProperty
    BitConverter.GetBytes(3).CopyTo(q, 8);    // ProtocolTypeNvme
    BitConverter.GetBytes(2).CopyTo(q, 12);   // NVMeDataTypeLogPage
    BitConverter.GetBytes(2).CopyTo(q, 16);   // health log
    BitConverter.GetBytes(40).CopyTo(q, 24);  // data offset
    BitConverter.GetBytes(512).CopyTo(q, 28); // data length
    var o = Io(disk, 0x2D1400, q, q.Length);
    if (o == null) return null;
    var log = new byte[512]; Array.Copy(o, 8 + BitConverter.ToInt32(o, 24), log, 0, 512); return log;
  }
  // ATA SMART READ DATA via SMART_RCV_DRIVE_DATA.
  public static byte[] Ata(int disk) {
    var q = new byte[33];
    BitConverter.GetBytes(512).CopyTo(q, 0);
    q[4]=0xD0; q[5]=1; q[6]=1; q[7]=0x4F; q[8]=0xC2; q[9]=0xA0; q[10]=0xB0;
    var o = Io(disk, 0x7C088, q, 16 + 512);
    if (o == null) return null;
    var d = new byte[512]; Array.Copy(o, 16, d, 0, 512); return d;
  }
}
'@ }

function E($s) { [Net.WebUtility]::HtmlEncode([string]$s) }
function Check($s, $t, $v) { [pscustomobject]@{ S = $s; T = $t; V = $v } }
function Sev($v, $warn, $bad) { if ($v -lt $bad) { 'fix' } elseif ($v -lt $warn) { 'review' } else { 'ok' } }  # higher = healthier
function KV([object[]]$a) {
    $r = for ($i = 0; $i -lt $a.Count; $i += 2) { if ("$($a[$i+1])") { "<tr><th>$(E $a[$i])</th><td>$(E $a[$i+1])</td></tr>" } }
    "<table class=kv>$($r -join '')</table>"
}
$dot = [char]0xB7; $deg = [char]0xB0; $dash = [char]0x2014

# ---------------- collect ----------------
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$bios = Get-CimInstance Win32_BIOS
$board = Get-CimInstance Win32_BaseBoard
$cpu = @(Get-CimInstance Win32_Processor)[0]
$cpuName = ($cpu.Name -replace '\((R|TM)\)|CPU ', '' -replace '\s+', ' ').Trim()
$gpus = @(Get-CimInstance Win32_VideoController)
$ram = @(Get-CimInstance Win32_PhysicalMemory)
$ramGB = [math]::Round(($ram | Measure-Object Capacity -Sum).Sum / 1GB)
$slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
# Custom-built desktops leave maker / model / serial as placeholders; fall back to the motherboard.
$generic = '^\s*$|System Product Name|System manufacturer|To Be Filled|Default string|O\.E\.M|Not Applicable|^System$'
$maker = if ($cs.Manufacturer -match $generic) { $board.Manufacturer } else { $cs.Manufacturer }
$model = if ($cs.Model -match $generic) { "$($board.Product) (custom build)" } else { $cs.Model }
$serial = if ($bios.SerialNumber -match $generic) { $board.SerialNumber } else { $bios.SerialNumber }
$chassis = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)
$chassisName = @{ 3 = 'Desktop'; 4 = 'Desktop'; 5 = 'Desktop'; 6 = 'Mini tower'; 7 = 'Tower'; 8 = 'Portable'; 9 = 'Laptop'; 10 = 'Notebook'; 13 = 'All-in-one'
    14 = 'Notebook'; 15 = 'Small form factor'; 16 = 'Small form factor'; 30 = 'Tablet'; 31 = 'Convertible'; 32 = 'Detachable'; 35 = 'Mini PC'; 36 = 'Stick PC' }
$pcType = @($chassis | % { $chassisName[[int]$_] } | ? { $_ }) | Select-Object -First 1
# Real VRAM: Win32_VideoController.AdapterRAM caps at 4 GB, the driver's registry entry doesn't.
$vram = @{}
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' -ErrorAction SilentlyContinue | % {
    $m = $_.'HardwareInformation.qwMemorySize'; if (-not $m) { $m = $_.'HardwareInformation.MemorySize' }
    if ($m -is [byte[]]) { $m = [BitConverter]::ToUInt32($m, 0) }
    if ($m -and $_.DriverDesc) { $vram[$_.DriverDesc] = [double]$m } }
function Size($b) { if ($b -ge 1GB) { '{0:N0} GB' -f ($b / 1GB) } elseif ($b) { '{0:N0} MB' -f ($b / 1MB) } }

Write-Host '  - drives'
$disks = foreach ($p in Get-PhysicalDisk | Sort-Object { [int]$_.DeviceId }) {
    $r = $p | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    $o = [ordered]@{ Name = $p.FriendlyName; Bus = "$($p.BusType)"; Media = "$($p.MediaType)"; GB = [math]::Round($p.Size / 1GB); Health = "$($p.HealthStatus)"
        Life = $null; Spare = $null; Temp = $r.Temperature; Hours = $r.PowerOnHours; TBW = $null; Unsafe = $null; Errors = $null; Realloc = $null; Warn = 0 }
    if ($r.Wear) { $o.Life = 100 - $r.Wear }  # ponytail: Windows returns Wear=0 when the drive doesn't say, so 0 = unknown
    if ($p.BusType -eq 'NVMe' -and ($g = [DiskHealth]::Nvme([int]$p.DeviceId))) {
        $o.Warn = $g[0]; $o.Temp = [BitConverter]::ToUInt16($g, 1) - 273; $o.Spare = $g[3]; $o.Life = [math]::Max(0, 100 - $g[5])
        $o.TBW = [BitConverter]::ToUInt64($g, 48) * 512000 / 1e12
        $o.Hours = [BitConverter]::ToUInt64($g, 128); $o.Unsafe = [BitConverter]::ToUInt64($g, 144); $o.Errors = [BitConverter]::ToUInt64($g, 160)
    }
    elseif ($p.BusType -eq 'SATA' -and ($g = [DiskHealth]::Ata([int]$p.DeviceId))) {
        $a = @{}; for ($k = 2; $k -lt 362; $k += 12) { if ($g[$k]) { $a[[int]$g[$k]] = @{ Cur = [int]$g[$k + 3]; Raw = [BitConverter]::ToUInt32($g, $k + 5) } } }
        # ponytail: SMART IDs are vendor-specific; first known "life left" attribute wins. Add IDs if a drive shows none.
        foreach ($k in 231, 202, 233, 177, 169, 173) { if ($a[$k] -and $a[$k].Cur -gt 0 -and $a[$k].Cur -le 100) { $o.Life = $a[$k].Cur; break } }
        if ($a[5]) { $o.Realloc = $a[5].Raw }
        if ($a[9] -and -not $o.Hours) { $o.Hours = $a[9].Raw }
        if ($a[194] -and -not $o.Temp) { $o.Temp = $a[194].Raw -band 0xFF }
        if ($a[192]) { $o.Unsafe = $a[192].Raw } elseif ($a[174]) { $o.Unsafe = $a[174].Raw }
    }
    [pscustomobject]$o
}

Write-Host '  - battery, licences, security'
$bx = "$env:TEMP\checkup-battery.xml"
$batt = $null
try {
    powercfg /batteryreport /xml /output $bx | Out-Null
    $batt = @(([xml](Get-Content $bx -Raw)).BatteryReport.Batteries.Battery | ? { [double]$_.DesignCapacity -gt 0 })[0]
} catch {}
Remove-Item $bx -ErrorAction SilentlyContinue
$battPct = if ($batt) { [math]::Round(100 * [double]$batt.FullChargeCapacity / [double]$batt.DesignCapacity) }
# ponytail: laptop = portable chassis or a battery. A desktop on a USB UPS may read as laptop; add a chassis override if that shows up.
$isLaptop = [bool]$batt -or [bool]($chassis | ? { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 })

$crashEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue |
    ? { $_.Id -eq 41 -or $_.ProviderName -match 'BugCheck|WER-SystemErrorReporting' })
$crashes = @($crashEv | ? Id -eq 41).Count

$sv = Get-CimInstance SoftwareLicensingService
$lics = @(Get-CimInstance SoftwareLicensingProduct -Filter 'PartialProductKey IS NOT NULL')
$licStatus = 'Not activated', 'Activated', 'Grace period', 'Grace period', 'Non-genuine', 'Not active (expired)', 'Extended grace'
function Channel($c) {
    switch -Wildcard ($c) {
        'OEM*' { 'OEM, tied to this PC'; break }
        'Retail:TB*' { 'Subscription'; break }
        'Retail*' { 'Retail, transferable'; break }
        'Volume:GVLK' { 'KMS volume'; break }
        'Volume*' { 'MAK volume'; break }
        default { $c }
    }
}
$win = $lics | ? Name -like 'Windows*' | Select-Object -First 1
$oa3 = "$($sv.OA3xOriginalProductKey)"
$licRows = $lics | % { [pscustomobject]@{
    Product = ($_.Name -replace '\(R\)|,| edition', '').Trim(); Status = $licStatus[[int]$_.LicenseStatus]
    Channel = Channel $_.ProductKeyChannel; Key = "*****-$($_.PartialProductKey)" } }

$tpm = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue
$tpmVer = if ($tpm) { ($tpm.SpecVersion -split ',')[0].Trim() }
$tpmText = if ($tpm) { "$tpmVer$(if ($tpm.IsEnabled_InitialValue) { ', enabled' } else { ', disabled' })" } elseif ($admin) { 'Not found' } else { 'Needs Admin' }
$secureBoot = try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'On' } else { 'Off' } } catch { if ($admin) { 'Not supported (legacy BIOS)' } else { 'Needs Admin' } }
$bl = try { @(Get-BitLockerVolume -ErrorAction Stop) } catch { @() }
$blOn = @($bl | ? { "$($_.ProtectionStatus)" -eq 'On' -or "$($_.VolumeStatus)" -notin 'FullyDecrypted', '' })
$av = (@(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue).displayName | Select-Object -Unique) -join ', '
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
$hf = Get-HotFix -ErrorAction SilentlyContinue | ? InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1

$vols = Get-Volume | ? { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size } | Sort-Object DriveLetter | % {
    $l = "$($_.DriveLetter):"; $b = $bl | ? MountPoint -eq $l
    [pscustomobject]@{ Drive = $l; Label = $_.FileSystemLabel; Size = '{0:N0} GB' -f ($_.Size / 1GB)
        Free = '{0:N0} GB ({1:N0}%)' -f ($_.SizeRemaining / 1GB), (100 * $_.SizeRemaining / $_.Size)
        BitLocker = $(if ($b) { "$($b.ProtectionStatus) $dot $($b.VolumeStatus)" } elseif ($admin) { 'Off' } else { 'Needs Admin' }) }
}

Write-Host '  - software'
$apps = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    ? { $_.DisplayName -and -not $_.SystemComponent } | Sort-Object DisplayName -Unique | % {
        [pscustomobject]@{ Name = $_.DisplayName; Version = $_.DisplayVersion; Publisher = $_.Publisher
            Installed = $(if ("$($_.InstallDate)" -match '^(\d{4})(\d\d)(\d\d)$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" }) } }

Write-Host '  - ownership, hardware errors, devices'
# Company management: a domain / Azure AD / MDM (Intune) PC can be locked or wiped remotely by its owner.
$dsr = "$(dsregcmd /status 2>$null)"
$aad = if ($dsr -match 'AzureAdJoined\s*:\s*YES') { if ($dsr -match 'TenantName\s*:\s*(.+?)\s{2,}') { "Azure AD: $($Matches[1])" } else { 'Azure AD' } }
$mdm = @(Get-ChildItem HKLM:\SOFTWARE\Microsoft\Enrollments -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue | ? { $_.ProviderID -and $_.UPN } | % { "MDM: $($_.UPN)" })
$managed = @($(if ($cs.PartOfDomain) { "Domain: $($cs.Domain)" }); $aad; $mdm) | ? { $_ }

$since = (Get-Date).AddDays(-30)
$whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction SilentlyContinue)
$wheaErr = @($whea | ? Level -le 2).Count
$diskErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk', 'stornvme', 'storahci'; Level = 1, 2, 3; StartTime = $since } -ErrorAction SilentlyContinue)
# Code 45 = device not plugged in right now; everything else (incl. 22 disabled) is worth a look.
$badDev = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' | ? ConfigManagerErrorCode -ne 45 | % { "$(if ($_.Name) { $_.Name } else { $_.DeviceID }) (code $($_.ConfigManagerErrorCode))" })

$remoteRx = 'AnyDesk|TeamViewer|Remote Desktop Host|RustDesk|UltraViewer|Splashtop|LogMeIn|RealVNC|TightVNC|UltraVNC|Radmin|ScreenConnect|Parsec|AeroAdmin|Supremo|DWService|Ammyy|NoMachine|Zoho Assist'
$remote = @(@($apps | ? Name -match $remoteRx | % Name) + @(Get-Service | ? DisplayName -match $remoteRx | % DisplayName) | Sort-Object -Unique)
$users = @(Get-LocalUser -ErrorAction SilentlyContinue | ? Enabled | % Name)
$admins = @(try { Get-LocalGroupMember -SID S-1-5-32-544 -ErrorAction Stop | % { ($_.Name -split '\\')[-1] } } catch {})

$nets = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
$wifi = $nets | ? { $_.PhysicalMediaType -match '802\.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless' } | Select-Object -First 1
$eth = $nets | ? { $_.PhysicalMediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless' } | Select-Object -First 1
$bt = Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue | ? { $_.InstanceId -match '^(USB|PCI)\\' } | Select-Object -First 1
$monIds = @(Get-CimInstance -Namespace root\wmi WmiMonitorID -ErrorAction SilentlyContinue)
$screens = @(Get-CimInstance -Namespace root\wmi WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue | % {
    $m = $_; $id = $monIds | ? InstanceName -eq $m.InstanceName
    $name = -join (@($id.UserFriendlyName) | ? { $_ } | % { [char]$_ }); if (-not $name) { $name = if ($isLaptop) { 'Built-in' } else { 'Monitor' } }
    '{0} {1} {2:N1} in' -f $name, $dot, ([math]::Sqrt([math]::Pow($m.MaxHorizontalImageSize, 2) + [math]::Pow($m.MaxVerticalImageSize, 2)) / 2.54)
})
$res = @($gpus | ? CurrentHorizontalResolution | % { "$($_.CurrentHorizontalResolution) x $($_.CurrentVerticalResolution) @ $($_.CurrentRefreshRate) Hz" }) | Select-Object -First 1
$daysInstalled = ((Get-Date) - $os.InstallDate).Days

# ---------------- checks ----------------
# Each check: severity, short title, short value. One line each in the report.
$checks = @(
    if (-not $win) { Check fix 'No Windows licence' 'no product key installed' }
    elseif ($win.LicenseStatus -ne 1) { Check fix 'Windows not activated' $licStatus[[int]$win.LicenseStatus] }
    elseif ($win.ProductKeyChannel -eq 'Volume:GVLK' -and $os.Caption -notmatch 'Enterprise|Education') { Check review 'Windows uses KMS activation' 'company PC or unofficial activator' }
    else { Check ok 'Windows activated' "$(Channel $win.ProductKeyChannel) $dot key ends $($win.PartialProductKey)$(if ($oa3 -and $oa3.EndsWith($win.PartialProductKey)) { ', matches BIOS' })" }
    foreach ($l in $lics | ? { $_.Name -notlike 'Windows*' -and $_.LicenseStatus -ne 1 }) { Check note "$(($l.Name -split ',')[0]) not active" $(if ($l.LicenseStatus -eq 5) { 'licence expired' } else { $licStatus[[int]$l.LicenseStatus].ToLower() }) }
    foreach ($x in $disks) {
        if ($x.Health -ne 'Healthy') { Check fix "$($x.Name) $($x.Health)" 'back up and replace' }
        if ($x.Warn) { Check fix "$($x.Name) critical warning" "code $($x.Warn)" }
        if ($null -ne $x.Life) { Check (Sev $x.Life 50 20) "$($x.Name) $($x.Life)% life left" $(if ($x.TBW) { '{0:N1} TB written' -f $x.TBW }) }
        else { Check note "$($x.Name) life unknown" $(if ($admin) { 'check with CrystalDiskInfo' } else { 'needs Admin' }) }
        if ($x.Errors) { Check review "$($x.Name) media errors" "$($x.Errors)" }
        if ($x.Realloc) { Check review "$($x.Name) reallocated sectors" "$($x.Realloc)" }
    }
    $slow = @($ram | ? { $_.ConfiguredClockSpeed -and $_.Speed -and $_.ConfiguredClockSpeed -lt $_.Speed })
    if ($slow) { Check note "RAM at $($slow[0].ConfiguredClockSpeed) of $($slow[0].Speed) MHz" 'XMP / EXPO off in BIOS, or CPU limit' }
    if ($ram.Count -eq 1 -and $slots -ge 2) { Check note 'One RAM stick' 'single channel, slower; add a matching stick' }
    if (@($ram | % { "$($_.PartNumber)".Trim() } | Sort-Object -Unique).Count -gt 1) { Check note 'Mixed RAM sticks' 'different models, can be unstable' }
    if ($batt) { Check (Sev $battPct 80 60) "Battery $battPct% of original capacity" ('{0:N0} / {1:N0} mWh' -f [double]$batt.FullChargeCapacity, [double]$batt.DesignCapacity) }
    if ($crashes) { Check $(if ($crashes -ge 5) { 'fix' } else { 'review' }) "$crashes unexpected restart$(if ($crashes -gt 1) { 's' }), 30 days" (($crashEv | ? Id -eq 41 | Select-Object -First 3 | % { $_.TimeCreated.ToString('dd MMM') }) -join ', ') }
    else { Check ok 'No crashes, 30 days' '' }
    if ($blOn) { Check review "BitLocker on $(($blOn.MountPoint) -join ', ')" 'get the recovery key before paying' }
    if ($admin -and -not $tpm) { Check review 'No TPM' 'Windows 11 needs TPM 2.0' }
    elseif ($tpm -and $tpmVer -notlike '2*') { Check review "TPM $tpmVer" 'Windows 11 needs TPM 2.0' }
    if ($secureBoot -eq 'Off') { Check note 'Secure Boot off' 'can be enabled in BIOS' }
    if ($mp -and -not $mp.RealTimeProtectionEnabled -and ($av -replace 'Windows Defender|Microsoft Defender') -notmatch '\w') { Check review 'Antivirus off' 'no real-time protection' }
    if ($managed) { Check fix 'Managed by an organisation' "$($managed -join ', ') $dot owner can lock or wipe it" }
    else { Check ok 'Not managed by a company' 'no domain, Azure AD or MDM' }
    if ($wheaErr) { Check fix "$wheaErr hardware error$(if ($wheaErr -gt 1) { 's' }) (WHEA), 30 days" 'CPU, RAM or motherboard fault' }
    elseif ($whea) { Check review "$($whea.Count) corrected hardware error$(if ($whea.Count -gt 1) { 's' }), 30 days" 'often PCIe; watch if it grows' }
    if ($diskErr) { Check review "$($diskErr.Count) disk / controller error$(if ($diskErr.Count -gt 1) { 's' }), 30 days" (($diskErr | Group-Object ProviderName | % { "$($_.Name) x$($_.Count)" }) -join ', ') }
    if ($badDev) { Check review "$($badDev.Count) device$(if ($badDev.Count -gt 1) { 's' }) with driver problems" (($badDev | Select-Object -First 2) -join ', ') }
    if ($remote) { Check review 'Remote access app installed' (($remote | Select-Object -First 3) -join ', ') }
    if ($users.Count -gt 1) { Check note "$($users.Count) user accounts" ($users -join ', ') }
    if ($batt -and -not $wifi) { Check review 'No Wi-Fi adapter found' 'broken or disabled' }
    if ($daysInstalled -lt 14) { Check note "Windows installed $daysInstalled day$(if ($daysInstalled -ne 1) { 's' }) ago" 'error history is short' }
    if (-not $admin) { Check review 'Not run as Administrator' 'drive health, TPM and BitLocker missing' }
)
$order = @{ fix = 0; review = 1; note = 2; ok = 3 }
$checks = @($checks | Sort-Object { $order[$_.S] })
$verdict = if ($checks.S -contains 'fix') { 'fix', 'Needs a closer look' } elseif ($checks.S -contains 'review') { 'review', 'Worth a second look' } else { 'ok', 'Looks healthy' }

# ---------------- html ----------------
function N($v, $fmt = '{0}') { if ($null -ne $v -and "$v" -ne '') { $fmt -f $v } else { $dash } }
$osName = $os.Caption -replace '^Microsoft ', ''

$checkHtml = ($checks | % { "<li class=$($_.S)><span class=dot></span><span>$(E $_.T)</span><span class=v>$(E $_.V)</span></li>" }) -join ''

$driveRows = ($disks | % {
    $s = if ($_.Health -ne 'Healthy' -or $_.Warn) { 'fix' } elseif ($null -eq $_.Life) { 'note' } else { Sev $_.Life 50 20 }
    $life = if ($null -ne $_.Life) { "$($_.Life)%<span class=bar><i style='--w:$($_.Life)%'></i></span>" } else { $dash }
    "<tr class=$s><td>$(E $_.Name)<small>$(E "$($_.Bus) $dot $($_.GB) GB")</small></td><td>$life</td><td>$(N $_.Spare '{0}%')</td>" +
    "<td>$(N $(if ($_.Temp) { $_.Temp }) "{0}$deg`C")</td><td>$(N $(if ($_.Hours) { $_.Hours }) '{0:N0} h')</td><td>$(N $_.TBW '{0:N1} TB')</td><td>$(N $_.Unsafe '{0:N0}')</td><td>$(E $_.Health)</td></tr>"
}) -join ''
$drives = "<div class=x><table class=data><thead><tr><th>Drive</th><th>Life</th><th>Spare</th><th>Temp</th><th>On</th><th>Written</th><th>Unsafe off</th><th>Health</th></tr></thead><tbody>$driveRows</tbody></table></div>" +
    '<div class=x><table class=data><thead><tr><th>Volume</th><th>Size</th><th>Free</th><th>BitLocker</th></tr></thead><tbody>' +
    (($vols | % { "<tr><td>$(E "$($_.Drive) $($_.Label)")</td><td>$(E $_.Size)</td><td>$(E $_.Free)</td><td>$(E $_.BitLocker)</td></tr>" }) -join '') + '</tbody></table></div>'

$hw = KV @(
    'Model', "$maker $model"; 'Type', $pcType; 'Serial', $serial
    'Motherboard', "$($board.Manufacturer) $($board.Product)"; 'BIOS', "$($bios.SMBIOSBIOSVersion) $dot $($bios.ReleaseDate.ToString('dd MMM yyyy'))"
    'CPU', "$cpuName $dot $($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T"
    ($gpus | % { 'GPU', ("$($_.Name) $dot $(Size $(if ($vram[$_.Name]) { $vram[$_.Name] } else { $_.AdapterRAM })) $dot driver $($_.DriverVersion)" -replace " $dot\s+$dot", " $dot") })
    'RAM', "$ramGB GB $dot $($ram.Count) of $slots slots"
    ($ram | % { "  $($_.DeviceLocator)", ("$($_.Capacity / 1GB) GB $dot $($_.ConfiguredClockSpeed) MHz $dot $($_.Manufacturer) $($_.PartNumber)".Trim()) })
    'Display', "$($screens -join ', ')$(if ($res) { "  $dot  $res" })"
    'Wi-Fi', $(if ($wifi) { "$($wifi.InterfaceDescription) $dot $($wifi.Status)" } else { 'none' })
    'Ethernet', $(if ($eth) { "$($eth.InterfaceDescription) $dot $($eth.Status)" } else { 'none' })
    'Bluetooth', $(if ($bt) { "$($bt.FriendlyName) $dot $($bt.Status)" } else { 'none' })
    'Problem devices', ($badDev -join ', ')
    'Battery', $(if ($batt) { "$battPct% $dot {0:N0} / {1:N0} mWh $dot {2} cycles" -f [double]$batt.FullChargeCapacity, [double]$batt.DesignCapacity, $batt.CycleCount })
    'Windows', "$osName $dot build $($os.BuildNumber) $dot installed $($os.InstallDate.ToString('dd MMM yyyy'))"
)
$lic = '<div class=x><table class=data><thead><tr><th>Product</th><th>Status</th><th>Channel</th><th>Key</th></tr></thead><tbody>' +
    (($licRows | % { "<tr><td>$(E $_.Product)</td><td>$(E $_.Status)</td><td>$(E $_.Channel)</td><td class=m>$(E $_.Key)</td></tr>" }) -join '') +
    "<tr><td>Key stored in BIOS</td><td colspan=3>$(E $(if ($oa3) { "ends $($oa3.Substring($oa3.Length - 5)) $dot $($sv.OA3xOriginalProductKeyDescription)" } else { 'none' }))</td></tr></tbody></table></div>"
$sec = KV @(
    'Managed by', $(if ($managed) { $managed -join ', ' } else { 'nobody (personal PC)' })
    'User accounts', ($users -join ', '); 'Administrators', ($admins -join ', ')
    'Remote access', $(if ($remote) { $remote -join ', ' } else { 'none found' })
    'TPM', $tpmText; 'Secure Boot', $secureBoot
    'Antivirus', "$av$(if ($mp) { " $dot real-time $(if ($mp.RealTimeProtectionEnabled) { 'on' } else { 'off' }) $dot definitions $($mp.AntivirusSignatureLastUpdated.ToString('dd MMM'))" })"
    'Last update', $(if ($hf) { "$($hf.HotFixID) $dot $($hf.InstalledOn.ToString('dd MMM yyyy'))" })
)
$sw = "<details><summary>Installed software <span>$(@($apps).Count)</span></summary><input id=q type=search placeholder='Filter' aria-label='Filter software'>" +
    '<div class=x><table class=data id=sw><tbody>' +
    (($apps | % { "<tr><td>$(E $_.Name)</td><td class=m>$(E $_.Version)</td><td class=m>$(E $_.Installed)</td></tr>" }) -join '') + '</tbody></table></div></details>'

# Interactive tests run in the browser (JS at the bottom of the template).
$tests = '<ul class=tests>' +
    '<li><span>Screen</span><span class=v>dead pixels, backlight bleed. Click to change colour, Esc to exit</span><button data-t=screen>Run</button></li>' +
    '<li><span>Keyboard</span><span class=v>press every key until all turn green</span><button data-t=kb>Run</button></li>' +
    '<li><span>Speakers</span><span class=v>tone plays left, then right</span><button data-t=sound>Run</button></li>' +
    '<li><span>Camera &amp; mic</span><span class=v>allow access, talk to see the level move</span><button data-t=cam>Run</button></li>' +
    '</ul><div id=kb hidden><p class=m id=kbn></p><div id=keys></div></div>' +
    '<div id=cam hidden><video id=vid autoplay muted playsinline></video><span class=bar id=mic><i></i></span><p class=m id=camn></p></div>' +
    '<div id=fs hidden><span>Click: next colour &middot; Esc: exit</span></div>'
$manual = '<ul class=manual>' + ((@(
    'CPU, GPU, RAM and drives above match what the seller advertised'
    if ($isLaptop) {
        "Serial on the sticker / under the battery matches S/N $serial"
        'Body: no cracks, hinges firm, no missing screws, screen does not wobble'
        'Battery not swollen: case flat, touchpad not raised'
        'Every USB port, HDMI, audio jack and SD slot works; charge port does not wiggle'
        'Original charger with the right wattage; laptop charges and runs unplugged'
        'Touchpad clicks, keyboard backlight, fingerprint / face login'
        'Wi-Fi connects and Bluetooth pairs'
        'Stress test 10 min (Cinebench R23) while watching HWiNFO: CPU under 95&deg;C, fans not grinding'
    } else {
        'Open the side panel: no thick dust, burnt smell, bulging capacitors or loose cables'
        'PSU: known brand, wattage on the label is enough for the GPU (avoid no-name units)'
        'GPU: VRAM above matches the advertised card; confirm in GPU-Z (fake re-flashed cards exist)'
        'Ask if the GPU was used for mining; look for worn fans, discoloured backplate, missing screws'
        'All fans spin (CPU, case, GPU) with no rattle or grinding'
        'Front and rear USB, audio jacks and every video output on the GPU work'
        'Stress test 10 min: Cinebench R23 (CPU), then FurMark or 3DMark (GPU), watching HWiNFO: CPU under 90&deg;C, GPU under 85&deg;C, no crash or black screen'
        'BIOS clock is correct (wrong time = dead CMOS battery)'
    }
    'BIOS opens with no password (F2 / Del at boot)'
    'Receipt or warranty; check the serial on the maker''s warranty site'
    'After buying: Reset this PC, sign in with your own account, no "managed by your organisation" screen'
) | % { "<li><label><input type=checkbox> <span>$($_ -replace '&(?!\w+;)', '&amp;')</span></label></li>" }) -join '') + '</ul>'

$i = 0
function Part($title, $html) { $script:i++; "<section style='--i:$script:i'><h2>$(E $title)</h2>$html</section>" }
$body = "<header style='--i:0'><div><h1>$(E $model)</h1><p>$(E "$maker $dot S/N $serial $dot $osName $dot $(Get-Date -f 'dd MMM yyyy, HH:mm')")</p></div>" +
    "<div class=right><span class='verdict $($verdict[0])'><span class=dot></span>$($verdict[1])</span><button onclick=print()>Print</button></div></header>" +
    (Part 'Checks' "<ul class=checks>$checkHtml</ul>") + (Part 'Drives' $drives) + (Part 'Hardware' $hw) +
    (Part 'License' $lic) + (Part 'Security' $sec) + (Part 'Software' $sw) +
    (Part 'Tests' $tests) + (Part 'Check by hand' $manual) +
    "<footer>SecondLook $dot <a href='https://github.com/honow48-tech/SecondLook'>github.com/honow48-tech/SecondLook</a></footer>"

$tpl = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{TITLE}}</title>
<style>
:root{--bg:#fbfbf9;--ink:#1a1a19;--mute:#6d6c66;--faint:#a3a29b;--line:#e8e7e1;--ok:#2f6b52;--warn:#9a5b10;--bad:#a83a2c;
  --sans:system-ui,-apple-system,"Segoe UI",sans-serif;--mono:ui-monospace,"Cascadia Mono",Consolas,monospace;--ease:cubic-bezier(.2,.7,.1,1)}
@media (prefers-color-scheme:dark){:root{--bg:#121211;--ink:#e9e8e3;--mute:#9a988f;--faint:#6a685f;--line:#262624;--ok:#7cc2a3;--warn:#e0a456;--bad:#ee8676}}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--ink);font:14px/1.5 var(--sans);-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums}
main{max-width:860px;margin:0 auto;padding:48px 20px 72px}
header{display:flex;justify-content:space-between;align-items:flex-end;gap:12px 24px;flex-wrap:wrap;padding-bottom:16px;border-bottom:1.5px solid var(--ink)}
h1{font-size:24px;font-weight:600;letter-spacing:-.02em;line-height:1.2}
header p{color:var(--mute);font-size:13px;margin-top:4px}
.right{display:flex;align-items:center;gap:16px}
.verdict{display:inline-flex;align-items:center;gap:8px;font-size:13px;font-weight:500}
button{font:12px var(--mono);color:var(--mute);background:none;border:0;border-bottom:1px solid var(--line);cursor:pointer;padding:0 0 1px;transition:color .2s,border-color .2s}
button:hover{color:var(--ink);border-color:var(--ink)}
.ok{--c:var(--ok)}.review{--c:var(--warn)}.fix{--c:var(--bad)}.note{--c:var(--faint)}
.dot{width:7px;height:7px;border-radius:50%;background:var(--c);flex:none}
section{margin-top:36px}
h2{font:600 11px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--mute);margin-bottom:6px}
.checks{list-style:none}
.checks li{display:flex;align-items:baseline;gap:12px;padding:8px 0;border-bottom:1px solid var(--line)}
.checks .dot{transform:translateY(-1px)}
.checks .v{margin-left:auto;text-align:right;font:12px var(--mono);color:var(--mute)}
.x{overflow-x:auto}.x+.x{margin-top:16px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 14px 8px 0;border-bottom:1px solid var(--line);vertical-align:baseline}
th:last-child,td:last-child{padding-right:0}
.data th{font:500 11px var(--mono);color:var(--faint);white-space:nowrap}
.data td{white-space:nowrap}
.data td small{display:block;font:11.5px var(--mono);color:var(--faint)}
.kv th{width:140px;font-weight:400;color:var(--mute)}
.m{font:12px var(--mono);color:var(--mute)}
tr.fix td:first-child,tr.review td:first-child{box-shadow:inset 2px 0 var(--c);padding-left:10px}
.bar{display:inline-block;width:44px;height:3px;margin-left:8px;background:var(--line);vertical-align:middle;overflow:hidden}
.bar i{display:block;height:100%;width:var(--w);background:var(--c);transform-origin:left;animation:fill 1.2s var(--ease) .4s both}
details summary{cursor:pointer;list-style:none;padding:8px 0;border-bottom:1px solid var(--line);color:var(--mute);transition:color .2s}
details summary::-webkit-details-marker{display:none}
details summary::before{content:"+";display:inline-block;width:18px;font-family:var(--mono)}
details[open] summary::before{content:"\2212"}
details summary:hover{color:var(--ink)}
details summary span{font:12px var(--mono);color:var(--faint);margin-left:6px}
#q{display:block;width:100%;max-width:280px;margin:12px 0 4px;font:13px var(--sans);padding:7px 10px;border:1px solid var(--line);border-radius:6px;background:transparent;color:var(--ink);outline:0;transition:border-color .2s}
#q:focus{border-color:var(--mute)}
#sw tr[hidden]{display:none}
footer{margin-top:48px;padding-top:14px;border-top:1px solid var(--line);font:12px var(--mono);color:var(--faint)}
footer a{color:inherit;text-underline-offset:3px}footer a:hover{color:var(--ink)}
.tests{list-style:none}
.tests li{display:flex;align-items:baseline;gap:12px;padding:8px 0;border-bottom:1px solid var(--line)}
.tests .v{margin-left:auto;font:12px var(--mono);color:var(--mute);text-align:right}
.tests button{min-width:40px}
#kb,#cam{padding:16px 0 4px}
#keys{display:grid;gap:4px;font:11px var(--mono)}
#keys div{display:flex;gap:4px}
#keys kbd{flex:1 1 0;min-width:0;padding:7px 2px;text-align:center;border:1px solid var(--line);border-radius:4px;color:var(--mute);overflow:hidden;white-space:nowrap;transition:background .25s,color .25s,border-color .25s}
#keys kbd.w{flex-grow:1.7}#keys kbd.sp{flex-grow:6}
#keys kbd.on{background:var(--ok);border-color:var(--ok);color:var(--bg)}
#vid{width:100%;max-width:360px;border-radius:6px;background:var(--line);display:block}
#mic{width:200px;height:4px;margin:10px 0 0}#mic i{animation:none;transition:transform .08s;transform:scaleX(0);--w:100%;--c:var(--ok)}
#fs{position:fixed;inset:0;z-index:9;cursor:none;background:#000}
#fs span{position:absolute;bottom:24px;left:50%;transform:translateX(-50%);font:12px var(--mono);color:#888;animation:out .6s 2s forwards}
@keyframes out{to{opacity:0}}
.manual{list-style:none}
.manual li{padding:7px 0;border-bottom:1px solid var(--line)}
.manual label{display:flex;gap:10px;align-items:baseline;cursor:pointer}
.manual input{accent-color:var(--ok);transform:translateY(1px)}
.manual input:checked+span{color:var(--faint);text-decoration:line-through;text-decoration-color:var(--faint)}
header,section{animation:in .5s var(--ease) both;animation-delay:calc(var(--i)*50ms)}
@keyframes in{from{opacity:0;transform:translateY(6px)}}
@keyframes fill{from{transform:scaleX(0)}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
@media print{button,#q{display:none}*{animation:none!important}details>*{display:revert}}
@media (max-width:560px){main{padding:28px 16px 48px}.kv th{width:100px}.checks li{flex-wrap:wrap}.checks .v{margin-left:19px;text-align:left;width:100%}}
</style></head>
<body><main>{{BODY}}</main>
<script>
const q=document.getElementById('q'),rows=[...document.querySelectorAll('#sw tr')];
q.addEventListener('input',()=>{const v=q.value.toLowerCase();rows.forEach(r=>r.hidden=!r.textContent.toLowerCase().includes(v))});
const $=id=>document.getElementById(id);

// Screen: full-screen colours for dead pixels / bleed.
const fs=$('fs'),cols=['#000','#fff','#f00','#0f0','#00f','#808080'];let ci=0;
const fsEnd=()=>{fs.hidden=true;document.fullscreenElement&&document.exitFullscreen()};
fs.onclick=()=>{ci=(ci+1)%cols.length;fs.style.background=cols[ci]};
document.addEventListener('fullscreenchange',()=>{if(!document.fullscreenElement)fs.hidden=true});

// Keyboard: standard layout by KeyboardEvent.code.
const rowsK=['Escape F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 Delete','Backquote 1 2 3 4 5 6 7 8 9 0 Minus Equal Backspace',
 'Tab Q W E R T Y U I O P BracketLeft BracketRight Backslash','CapsLock A S D F G H J K L Semicolon Quote Enter',
 'ShiftLeft Z X C V B N M Comma Period Slash ShiftRight','ControlLeft MetaLeft AltLeft Space AltRight ControlRight ArrowLeft ArrowUp ArrowDown ArrowRight'];
const nice={Escape:'Esc',Backquote:'`',Minus:'-',Equal:'=',Backspace:'Bksp',BracketLeft:'[',BracketRight:']',Backslash:'\\',CapsLock:'Caps',Semicolon:';',Quote:"'",
 Comma:',',Period:'.',Slash:'/',ShiftLeft:'Shift',ShiftRight:'Shift',ControlLeft:'Ctrl',ControlRight:'Ctrl',MetaLeft:'Win',AltLeft:'Alt',AltRight:'Alt',
 ArrowLeft:'\u2190',ArrowUp:'\u2191',ArrowDown:'\u2193',ArrowRight:'\u2192',Delete:'Del'};
const code=k=>/^[A-Z]$/.test(k)?'Key'+k:/^\d$/.test(k)?'Digit'+k:k;
$('keys').innerHTML=rowsK.map(r=>'<div>'+r.split(' ').map(k=>`<kbd data-c="${code(k)}" class="${k==='Space'?'sp':/Shift|Enter|Backspace|Caps|Tab/.test(k)?'w':''}">${nice[k]||k}</kbd>`).join('')+'</div>').join('');
const allK=[...document.querySelectorAll('#keys kbd')],kbn=$('kbn'),kbCount=()=>kbn.textContent=`${allK.filter(k=>k.classList.contains('on')).length} of ${allK.length} keys pressed`;
document.addEventListener('keydown',e=>{if($('kb').hidden)return;const k=document.querySelector(`#keys kbd[data-c="${e.code}"]`);if(k){e.preventDefault();k.classList.add('on');kbCount()}});

// Speakers: left then right.
function tone(){const a=new AudioContext();[-1,1].forEach((p,n)=>{const o=a.createOscillator(),g=a.createGain(),s=a.createStereoPanner();
 o.frequency.value=440;s.pan.value=p;g.gain.setValueAtTime(0,a.currentTime+n*1.2);g.gain.linearRampToValueAtTime(.3,a.currentTime+n*1.2+.05);
 g.gain.linearRampToValueAtTime(0,a.currentTime+n*1.2+1);o.connect(g).connect(s).connect(a.destination);o.start(a.currentTime+n*1.2);o.stop(a.currentTime+n*1.2+1.1)})}

// Camera + mic level.
let stream;async function cam(){const box=$('cam');if(stream){stream.getTracks().forEach(t=>t.stop());stream=null;box.hidden=true;return}
 box.hidden=false;try{stream=await navigator.mediaDevices.getUserMedia({video:true,audio:true});$('vid').srcObject=stream;$('camn').textContent='';
  const a=new AudioContext(),an=a.createAnalyser(),d=new Uint8Array(an.fftSize);a.createMediaStreamSource(stream).connect(an);
  (function loop(){if(!stream)return;an.getByteTimeDomainData(d);let m=0;for(const v of d)m=Math.max(m,Math.abs(v-128));
   document.querySelector('#mic i').style.transform=`scaleX(${Math.min(1,m/64)})`;requestAnimationFrame(loop)})()}
 catch(e){$('camn').textContent='Blocked or missing ('+e.name+'). Try the Windows Camera and Voice Recorder apps.'}}

document.querySelectorAll('[data-t]').forEach(b=>b.onclick=()=>{const t=b.dataset.t;
 if(t==='screen'){ci=0;fs.style.background=cols[0];fs.hidden=false;fs.requestFullscreen&&fs.requestFullscreen().catch(()=>{})}
 if(t==='kb'){$('kb').hidden=!$('kb').hidden;kbCount()}
 if(t==='sound')tone();
 if(t==='cam')cam()});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!fs.hidden)fsEnd()});
</script></body></html>
'@
$html = $tpl.Replace('{{TITLE}}', (E "SecondLook - $model")).Replace('{{BODY}}', $body)

# ---------------- save ----------------
$dl = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
if (-not $dl) { $dl = "$env:USERPROFILE\Downloads" }
Write-Host '  Done. Where to save the report?' -ForegroundColor Cyan
$dir = "$(Read-Host "  Folder (Enter = $dl)")".Trim().Trim('"')
if (-not $dir) { $dir = $dl }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir "secondlook-$(Get-Date -f yyyyMMdd-HHmm).html"
[IO.File]::WriteAllText($file, $html, (New-Object Text.UTF8Encoding $false))
Write-Host "  Saved: $file`n" -ForegroundColor Green
Start-Process $file

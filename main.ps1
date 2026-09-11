#Requires -Version 5.1
<#
.SYNOPSIS
    PLATINUM+ OPTIMIZER 9.1 - PowerShell Edition.
.DESCRIPTION
    Full PowerShell port of "Platinum+Optimizer.V9.1.FREE.cmd" by @STEFANO83223, @Aledect.
    Every function of the original batch optimizer is implemented here as a PowerShell
    function: boot config, telemetry, memory management, storage/NVMe, NTFS, graphics,
    GameDVR, MMCSS, mouse/keyboard, USB/PCI, service disabling, bloatware removal,
    event logs, browser telemetry, privacy, IFEO priorities, perf counters, VBS,
    Windows Update/Store blocking, hosts blocking, OneDrive removal, cleanup,
    power plan, scheduled tasks, autologgers, WER, UI/Explorer, pagefile, kernel tweaks
    and hardware-aware (Intel/AMD CPU + Intel/NVIDIA/AMD GPU) optimizations.
.PARAMETER Sections
    Optional list of section ids to run (default: all). Run with -ListSections to see ids.
.PARAMETER NoBackup
    Skip the restore point / HKLM .reg backup.
.PARAMETER SkipReboot
    Do not offer the final reboot.
.PARAMETER AutoYes
    Assume "Yes" for prompts (run without menu).
.PARAMETER ListSections
    Print the available section ids and exit.
.EXAMPLE
    .\main.ps1                          # interactive menu
    .\main.ps1 -AutoYes                 # run everything, answer yes to prompts
    .\main.ps1 -Sections services,cleanup -SkipReboot
.NOTES
    WARNING: applies aggressive tweaks (DEP optout, hypervisor off, UAC prompt off,
    mass service disabling, Windows Update/Store blocking, Edge removal, hosts edits).
    A restore point + HKLM .reg backup are created first (unless -NoBackup).
    A reboot is required for most tweaks to take effect.
#>
[CmdletBinding()]
param(
    [string[]]$Sections,
    [switch]$NoBackup,
    [switch]$SkipReboot,
    [switch]$AutoYes,
    [switch]$ListSections,
    [switch]$NoAuth
)

# =============================================================================
# BOOTSTRAP
# =============================================================================
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# TLS 1.2 for HTTPS (LicenseAuth API / GitHub raw downloads)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ANSI escape rendering (Windows Terminal / conhost with VT enabled)
$script:AnsiEnabled = $false
try { if ($Host.UI.SupportsVirtualTerminal) { $script:AnsiEnabled = $true } } catch { }

# Allow HKCR:\ drive usage (OneDrive CLSID tweaks)
if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script -ErrorAction SilentlyContinue | Out-Null
}

if ($Sections) {
    $Sections = @($Sections | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

# --- self elevation ----------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator privileges are required - relaunching elevated...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($key in @($PSBoundParameters.Keys)) {
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) { if ($value.IsPresent) { $argList += "-$key" } }
        elseif ($value -is [System.Array]) { $argList += "-$key"; $argList += (($value -join ',') -replace ' ', '') }
        else { $argList += "-$key"; $argList += ('"{0}"' -f $value) }
    }
    try   { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -ErrorAction Stop; exit 0 }
    catch { Write-Host 'Elevation was declined - exiting.' -ForegroundColor Red; exit 1 }
}

# =============================================================================
# GENERIC HELPERS (reg add / reg delete / sc config equivalents)
# =============================================================================

function ConvertTo-RegBinary {
    # "0011AAFF" -> byte[] (tolerates spaces)
    param([Parameter(Position = 0)][string]$Hex)
    $Hex = ($Hex -replace '[^0-9a-fA-F]', '')
    if ($Hex.Length % 2 -ne 0) { $Hex = '0' + $Hex }
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return ,$bytes
}

function Set-Reg {
    # reg add <path> /v <name> /t <type> /d <value> /f   (missing keys are created)
    param(
        [Parameter(Position = 0)][string]$Path,
        [Parameter(Position = 1)][string]$Name,
        [Parameter(Position = 2)][ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')][string]$Type = 'DWord',
        [Parameter(Position = 3)]$Value
    )
    try {
        # normalize raw hive names ("HKEY_LOCAL_MACHINE\...") to PS drive paths
        if ($Path -like 'HKEY_LOCAL_MACHINE\*') { $Path = $Path -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' }
        elseif ($Path -like 'HKEY_CURRENT_USER\*') { $Path = $Path -replace '^HKEY_CURRENT_USER', 'HKCU:' }
        elseif ($Path -like 'HKEY_CLASSES_ROOT\*') { $Path = $Path -replace '^HKEY_CLASSES_ROOT', 'HKCR:' }
        elseif ($Path -like 'HKEY_USERS\*') { $Path = $Path -replace '^HKEY_USERS', 'HKU:' }
        if ($Type -eq 'Binary' -and $Value -is [string]) { $Value = ConvertTo-RegBinary $Value }

        if ($Type -eq 'DWord' -and $Value -is [long] -and $Value -gt [int32]::MaxValue) { $Value = [uint32]$Value }
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force -ErrorAction Stop | Out-Null
    }
    catch { Write-Verbose ('Set-Reg failed [{0}\{1}]: {2}' -f $Path, $Name, $_.Exception.Message) }
}

function Remove-RegValue {
    # reg delete <path> /v <name> /f
    param([Parameter(Position = 0)][string]$Path, [Parameter(Position = 1)][string]$Name)
    try { Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop } catch { }
}

function Remove-RegKey {
    # reg delete <path> /f
    param([Parameter(Position = 0)][string]$Path)
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch { }
}

function Invoke-Exe {
    # external command with all output suppressed (>nul 2>&1 behaviour)
    param([Parameter(Position = 0)][string]$FilePath, [Parameter(Position = 1)][string[]]$Arguments = @())
    try { & $FilePath @Arguments *> $null } catch { }
}

function Set-ServiceStartType {
    # sc config <name> start= <type>
    param([Parameter(Position = 0)][string]$Name, [Parameter(Position = 1)][ValidateSet('disabled', 'demand', 'auto', 'delayed-auto')][string]$StartType)
    Invoke-Exe 'sc.exe' @('config', $Name, 'start=', $StartType)
}

function Set-ServiceStartValue {
    # registry Start= value (0 boot, 1 system, 2 auto, 3 demand, 4 disabled)
    param([Parameter(Position = 0)][string]$Name, [Parameter(Position = 1)][int]$Start)
    Set-Reg ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name) 'Start' DWord $Start
}

function Disable-WindowsService {
    param([Parameter(Position = 0)][string]$Name)
    Set-ServiceStartType $Name 'disabled'
    Set-ServiceStartValue $Name 4
}

function Stop-WindowsService {
    # net stop <name> /y
    param([Parameter(Position = 0)][string]$Name)
    Invoke-Exe 'net.exe' @('stop', $Name, '/y')
}

function Remove-ItemSilent {
    # del / rd /f /s /q equivalent for an explicit path
    param([Parameter(Position = 0)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
}

function Remove-ItemsByPattern {
    # del /f /s /q <wildcard pattern>
    param([Parameter(Position = 0)][string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return }
    Get-ChildItem -Path $Pattern -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Clear-DirectorySilent {
    # empties a directory without deleting the directory itself
    param([Parameter(Position = 0)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (Test-Path -LiteralPath $Path) { Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
}

function Write-Section {
    param([Parameter(Position = 0)][string]$Text)
    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkRed
    Write-Host ('  ' + $Text) -ForegroundColor Yellow
    Write-Host ('=' * 100) -ForegroundColor DarkRed
}

function Get-IfeoPerfPath {
    param([Parameter(Position = 0)][string]$Exe)
    return Join-Path $script:IFEO ($Exe + '\PerfOptions')
}

# =============================================================================
# REGISTRY PATH VARIABLES (same variables as the original .cmd)
# =============================================================================
$script:MM       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$script:PREFETCH = "$script:MM\PrefetchParameters"
$script:IOSYS    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\I/O System'
$script:FS       = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$script:DWM      = 'HKLM:\SOFTWARE\Microsoft\Windows\DWM'
$script:GD       = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$script:GDS      = "$script:GD\Scheduler"
$script:GDMM     = "$script:GD\MemoryManagement"
$script:GDPOWER  = "$script:GD\Power"
$script:POWER    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$script:SMPOWER  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$script:IFEO     = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$script:MMCSS    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$script:GFXCLASS = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$script:GFXKEY   = "$script:GFXCLASS\0000"

# =============================================================================
# SECTION TABLE (id -> function)
# =============================================================================
$script:OptimizerSections = @(
    [PSCustomObject]@{ Id = 'backup';          Title = '01. Initial backup (restore point + HKLM export)'; Function = 'Save-SystemBackup' }
    [PSCustomObject]@{ Id = 'boot';            Title = '03. BCDEdit - boot / hypervisor / timer / memory'; Function = 'Invoke-BootConfig' }
    [PSCustomObject]@{ Id = 'telemetry';       Title = '04. Base Windows telemetry';                       Function = 'Set-TelemetryPolicy' }
    [PSCustomObject]@{ Id = 'memory';          Title = '05. Memory management';                            Function = 'Set-MemoryManagement' }
    [PSCustomObject]@{ Id = 'prefetch';        Title = '06. Prefetch / SuperFetch / read-ahead';           Function = 'Disable-Prefetch' }
    [PSCustomObject]@{ Id = 'io-storage';      Title = '07. I/O system / storage / NVMe / disk';           Function = 'Optimize-IoStorage' }
    [PSCustomObject]@{ Id = 'ntfs';            Title = '08. NTFS / file system';                           Function = 'Optimize-Ntfs' }
    [PSCustomObject]@{ Id = 'graphics';        Title = '09. DWM / DXGI / graphics core / flip model';      Function = 'Optimize-Graphics' }
    [PSCustomObject]@{ Id = 'gamedvr';         Title = '10. Game DVR / Game Bar / Game Mode';              Function = 'Disable-GameDvr' }
    [PSCustomObject]@{ Id = 'mmcss';           Title = '11. MMCSS - multimedia class scheduler';           Function = 'Set-MmcssProfile' }
    [PSCustomObject]@{ Id = 'input';           Title = '12-13. Mouse / keyboard / accessibility';          Function = 'Set-MouseKeyboard' }
    [PSCustomObject]@{ Id = 'usb-pci';         Title = '14. USB / interrupt / PCI / class devices';        Function = 'Optimize-UsbPci' }
    [PSCustomObject]@{ Id = 'services';        Title = '15-16. Disable bloat services (sc config + reg)';  Function = 'Disable-BloatServices' }
    [PSCustomObject]@{ Id = 'bloatware';       Title = '17. AppX / bloatware removal';                     Function = 'Remove-Bloatware' }
    [PSCustomObject]@{ Id = 'logs';            Title = '18. Logman / ETL / event logs';                    Function = 'Clear-EventLogs' }
    [PSCustomObject]@{ Id = 'office-edge';     Title = '19. Office / Edge / WebView2 / Chrome telemetry';  Function = 'Set-BrowserTelemetry' }
    [PSCustomObject]@{ Id = 'privacy';         Title = '20. Privacy / telemetry / content delivery';       Function = 'Set-PrivacyPolicies' }
    [PSCustomObject]@{ Id = 'ifeo';            Title = '21. IFEO debugger block + process priorities';     Function = 'Set-IfeoPriorities' }
    [PSCustomObject]@{ Id = 'power-registry';  Title = '22. Power registry values';                        Function = 'Set-PowerRegistry' }
    [PSCustomObject]@{ Id = 'perfcounters';    Title = '30. Perf counters / ACPI / partmgr / WHEA';        Function = 'Set-PerfCounters' }
    [PSCustomObject]@{ Id = 'security-vbs';    Title = '31a. VBS / HVCI / fast startup / storage';         Function = 'Disable-VbsSecurity' }
    [PSCustomObject]@{ Id = 'update-block';    Title = '31b-31.3. Windows Update + Store block';           Function = 'Block-WindowsUpdate' }
    [PSCustomObject]@{ Id = 'update-files';    Title = '32. WU binary ACLs / renames';                     Function = 'Block-WindowsUpdateFiles' }
    [PSCustomObject]@{ Id = 'hosts';           Title = '33. HOSTS - block update domains';                 Function = 'Set-HostsBlock' }

    [PSCustomObject]@{ Id = 'onedrive';        Title = '34. OneDrive removal and cleanup';                 Function = 'Remove-OneDrive' }
    [PSCustomObject]@{ Id = 'cleanup';         Title = '35. Temp / cache / log / prefetch cleanup';        Function = 'Clear-TempFiles' }
    [PSCustomObject]@{ Id = 'powerplan';       Title = '36. Power plan / monitor / sleep';                 Function = 'Set-PowerPlanConfig' }
    [PSCustomObject]@{ Id = 'tasks';           Title = '37. Scheduled tasks disable/delete';               Function = 'Remove-ScheduledTasks' }
    [PSCustomObject]@{ Id = 'location';        Title = '38. Location / sensors / microphone privacy';      Function = 'Set-LocationPrivacy' }
    [PSCustomObject]@{ Id = 'autologger';      Title = '39. AutoLogger / DiagTrack / Defender logger';     Function = 'Disable-Autologgers' }
    [PSCustomObject]@{ Id = 'error-reporting'; Title = '40. WER / reliability / crash control';            Function = 'Set-ErrorReporting' }
    [PSCustomObject]@{ Id = 'ui-explorer';     Title = '41. UI / Explorer / UAC / personalization';        Function = 'Set-UiExplorer' }
    [PSCustomObject]@{ Id = 'storagesense';    Title = '42. StorageSense / serialize';                     Function = 'Set-StorageSense' }
    [PSCustomObject]@{ Id = 'pagefile';        Title = '43. Pagefile / FTH / WDF';                         Function = 'Set-PagefileConfig' }
    [PSCustomObject]@{ Id = 'boot-pnp';        Title = '44. Boot / Windows / PnP / wait-kill';             Function = 'Set-BootPnp' }
    [PSCustomObject]@{ Id = 'bluetooth';       Title = '45. Bluetooth / peripherals / legacy services';    Function = 'Set-BluetoothServices' }
    [PSCustomObject]@{ Id = 'processor';       Title = '46. Processor generic / power throttling';         Function = 'Set-ProcessorPower' }
    [PSCustomObject]@{ Id = 'kernel';          Title = '47. Kernel / executive / I/O deep tweaks';         Function = 'Set-KernelTweaks' }
    [PSCustomObject]@{ Id = 'memory-extra';    Title = '48. Memory management extras';                     Function = 'Set-MemoryExtra' }
    [PSCustomObject]@{ Id = 'disk-cache';      Title = '49. Disk / NVMe cache / partmgr / SCSI';           Function = 'Optimize-DiskCache' }
    [PSCustomObject]@{ Id = 'remove-edge';     Title = '50. Microsoft Edge removal';                       Function = 'Remove-MicrosoftEdge' }
    [PSCustomObject]@{ Id = 'remove-cortana';  Title = '51. Cortana removal (winget)';                     Function = 'Remove-Cortana' }
    [PSCustomObject]@{ Id = 'final-services';  Title = '52-53. Sensors / AppX deployment / ClipSVC';       Function = 'Set-FinalServices' }
    [PSCustomObject]@{ Id = 'diskperf';        Title = '54. Disk performance / verifier reset';            Function = 'Reset-DiskVerifier' }
    [PSCustomObject]@{ Id = 'ifeo-apps';       Title = '55. IFEO - maximum priority for apps/games';       Function = 'Set-IfeoAppPriority' }
    [PSCustomObject]@{ Id = 'cpu';             Title = '56. Hardware phase - CPU (Intel/AMD aware)';       Function = 'Invoke-CpuPhase' }
    [PSCustomObject]@{ Id = 'gpu';             Title = '57. Hardware phase - GPU (Intel/NVIDIA/AMD)';      Function = 'Invoke-GpuPhase' }
    [PSCustomObject]@{ Id = 'visual-effects';  Title = '58. Final visual effects + shell restart';         Function = 'Invoke-VisualEffectsFinal' }
)

# =============================================================================
# AUTHENTICATION - REGIX STUDIO (LicenseAuth / licenseauth.help client)
# Reference: referance/licenseauth.py (python) - re-implemented natively here.
# Credentials come from this file, or from REGIX_AUTH_* env vars injected by the
# REGIX Studio Cloudflare worker (worker.js) secure launcher.
# =============================================================================
$script:AuthConfig = @{
    ApiUrl            = 'https://licenseauth.help/api/1.3/'
    Name              = 'regix paid sensi' # LicenseAuth application name (from dashboard)
    OwnerId           = 'RTgStl6UQK'      # owner id (10 characters)
    Secret            = 'bea0ec057fb51de71558e9b98af18a77c34aa4e43124670a0a79594d4c50a072' # secret (64 characters)
    Version           = '1.0'
    TokenPath         = ''               # optional token-validation file, empty = disabled
    AllowUnconfigured = $false # $false = enforce auth now that credentials are configured
}
# overrides injected by the REGIX Studio worker launcher
if ($env:REGIX_AUTH_NAME)    { $script:AuthConfig.Name    = $env:REGIX_AUTH_NAME }
if ($env:REGIX_AUTH_OWNER)   { $script:AuthConfig.OwnerId = $env:REGIX_AUTH_OWNER }
if ($env:REGIX_AUTH_SECRET)  { $script:AuthConfig.Secret  = $env:REGIX_AUTH_SECRET }
if ($env:REGIX_AUTH_VERSION) { $script:AuthConfig.Version = $env:REGIX_AUTH_VERSION }
if ($env:REGIX_TOKEN_PATH)   { $script:AuthConfig.TokenPath = $env:REGIX_TOKEN_PATH }

$script:AuthSession  = @{ SessionId = ''; EncKey = ''; Initialized = $false }
$script:AuthUserData = $null

function Get-AuthHwid {
    # Windows user SID as hardware id (same approach as the reference client)
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return 'UNKNOWN-HWID' }
}

function Get-AuthChecksum {
    # MD5 checksum of this script file (sent with init, like the reference)
    try {
        if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
            return (Get-FileHash -LiteralPath $PSCommandPath -Algorithm MD5 -ErrorAction Stop).Hash.ToLowerInvariant()
        }
    } catch { }
    return ''
}

function Get-AuthHmac {
    param([Parameter(Position = 0)][string]$Key, [Parameter(Position = 1)][string]$Text)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Key))
    try {
        return (($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally { $hmac.Dispose() }
}

function Write-Ansi {
    # Raw ANSI output (real escape sequences) with Write-Host fallback.
    param([Parameter(Position = 0)][string]$Text = '')
    if ($script:AnsiEnabled) { [Console]::WriteLine($Text) }
    else { Write-Host ($Text -replace "`e\[[0-9;]*m", '') }
}

function Show-RegixBanner {
    <# ANSI branded banner: 'REGIX Studio' + '</> DEV | JAHID' #>
    $e = [char]27
    $cols = @(196, 202, 208, 214, 220, 190, 154, 118, 82, 46, 51, 45, 39, 33, 27, 99, 163, 201)
    $rows = @(
        '  @@@@    @@@@@@    @@@@@   @  @   @   @',
        '  @   @   @        @        @  @    @ @ ',
        '  @@@@    @@@@     @ @@@    @   @    @  ',
        '  @  @    @        @   @    @  @    @ @ ',
        '  @   @   @@@@@@    @@@@    @@@    @   @'
    )
    Write-Ansi ''
    for ($r = 0; $r -lt $rows.Count; $r++) {
        $paint = ''; $ci = ($r * 3) % $cols.Count
        foreach ($ch in $rows[$r].ToCharArray()) {
            if ($ch -eq ' ') { $paint += ' ' }
            else { $paint += ('{0}[38;5;{1}m{2}' -f $e, $cols[$ci % $cols.Count], $ch); $ci++ }
        }
        Write-Ansi ($paint + ('{0}[0m' -f $e))
    }
    Write-Ansi ('{0}[1;38;5;51m  S T U D I O{0}[0m' -f $e)
    Write-Ansi ('{0}[38;5;240m  ------------------------------------------{0}[0m' -f $e)
    $dev = '{0}[1;38;5;46m  </>{0}[0m{0}[1;37m DEV {0}[38;5;240m|{0}[0m {0}[1;38;5;220mJAHID{0}[0m' -f $e, $e, $e, $e, $e
    Write-Ansi $dev
    Write-Ansi ('{0}[38;5;240m  ------------------------------------------{0}[0m' -f $e)
    Write-Ansi ''
}

function Write-AuthDebugLog {
    # mirrors the reference debug log: C:\ProgramData\LicenseAuth\Debug\<script>\log.txt
    param([Parameter(Position = 0)][string]$Type, [Parameter(Position = 1)][string]$Body, [Parameter(Position = 2)][bool]$Tampered)
    try {
        $exeName = 'main.ps1'
        try { $exeName = [IO.Path]::GetFileName($PSCommandPath) } catch { }
        if (-not $exeName) { $exeName = 'main.ps1' }
        $dir = Join-Path 'C:\ProgramData\LicenseAuth\Debug' $exeName
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        if ($Body.Length -le 200) {
            $stamp = Get-Date -Format 'hh:mm tt | MM/dd/yyyy'
            Add-Content -LiteralPath (Join-Path $dir 'log.txt') -Value ("`n{0} | {1} `nResponse: {2}`n Was response tampered with? {3}`n" -f $stamp, $Type, $Body, $Tampered) -ErrorAction Stop
        }
    } catch { }
}

function Invoke-LicenseAuthRequest {
    # POSTs one LicenseAuth call and verifies the HMAC-SHA256 'signature' header
    # (native port of api.__do_request in referance/licenseauth.py).
    param([Parameter(Mandatory = $true)][hashtable]$PostData)
    $type = [string]$PostData['type']
    try {
        $resp = Invoke-WebRequest -Uri $script:AuthConfig.ApiUrl -Method Post -Body $PostData -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $raw = [string]$resp.Content
        $sig = [string]$resp.Headers['signature']
        if ($type -eq 'log') { return $raw }
        $key = if ($type -eq 'init') { $script:AuthConfig.Secret } else { $script:AuthSession.EncKey }
        try { $computed = Get-AuthHmac $key $raw } catch { $computed = '' }
        $tampered = $true
        try {
            if ($sig -and $computed) {
                $a = [Text.Encoding]::UTF8.GetBytes($computed); $b = [Text.Encoding]::UTF8.GetBytes($sig)
                $tampered = -not ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, $b))
            }
        } catch { $tampered = ($computed -ne $sig) }
        Write-AuthDebugLog $type $raw $tampered
        if ($tampered) {
            Write-Host '  Signature checksum failed. Request was tampered with or session ended most likely.' -ForegroundColor Red
            Write-Host ('  Response: ' + $raw) -ForegroundColor Red
            Start-Sleep -Seconds 3
            return $null
        }
        return $raw
    }
    catch {
        Write-Host '  Request timed out. Server is probably down/slow at the moment' -ForegroundColor Red
        return $null
    }
}

function Initialize-LicenseAuth {
    # type=init handshake (port of api.init). Returns $true on success.
    if ($script:AuthSession.Initialized -and $script:AuthSession.SessionId) {
        Write-Host "  You've already initialized!" -ForegroundColor Yellow
        return $false
    }
    $sentKey = [Guid]::NewGuid().ToString('N').Substring(0, 16)
    $script:AuthSession.EncKey = $sentKey + '-' + $script:AuthConfig.Secret
    $raw = Invoke-LicenseAuthRequest @{
        type    = 'init'
        ver     = $script:AuthConfig.Version
        hash    = (Get-AuthChecksum)
        enckey  = $sentKey
        name    = $script:AuthConfig.Name
        ownerid = $script:AuthConfig.OwnerId
    }
    if (-not $raw) { return $false }
    if ($raw -eq 'LicenseAuth_Invalid') {
        Write-Host "  The application doesn't exist" -ForegroundColor Red
        Start-Sleep -Seconds 3
        return $false
    }
    try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { Write-Host '  Invalid server response.' -ForegroundColor Red; return $false }
    if ([string]$json.message -eq 'invalidver') {
        if ([string]$json.download) {
            Write-Host '  New Version Available' -ForegroundColor Yellow
            try { Start-Process ([string]$json.download) } catch { }
        }
        else { Write-Host '  Invalid Version, Contact owner to add download link to latest app version' -ForegroundColor Red }
        Start-Sleep -Seconds 3
        return $false
    }
    if (-not $json.success) { Write-Host ('  ' + [string]$json.message) -ForegroundColor Red; Start-Sleep -Seconds 3; return $false }
    $script:AuthSession.SessionId   = [string]$json.sessionid
    $script:AuthSession.Initialized = $true
    if ($json.newSession) { Start-Sleep -Milliseconds 100 }
    return $true
}

function Set-AuthUserData {
    # stores the user block from login / license calls (port of __load_user_data)
    param([Parameter(Position = 0)]$Info)
    $subs = @()
    try { foreach ($s in $Info.subscriptions) { $subs += $s } } catch { }
    $script:AuthUserData = [PSCustomObject]@{
        Username      = [string]$Info.username
        Ip            = [string]$Info.ip
        Hwid          = if ($Info.hwid) { [string]$Info.hwid } else { 'N/A' }
        Expires       = if ($subs.Count -gt 0) { [string]$subs[0].expiry } else { '' }
        CreatedAt     = [string]$Info.createdate
        LastLogin     = [string]$Info.lastlogin
        SubName       = if ($subs.Count -gt 0) { [string]$subs[0].subscription } else { '' }
        Subscriptions = $subs
    }
}

function ConvertFrom-AuthUnixTime {
    param([Parameter(Position = 0)][string]$Seconds)
    try { return ([DateTimeOffset]::FromUnixTimeSeconds([long]$Seconds)).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') }
    catch { return [string]$Seconds }
}

function Show-AuthUserData {
    # mirrors the "User data:" summary printed at the end of referance/main.py
    if (-not $script:AuthUserData) { return }
    $u = $script:AuthUserData
    Write-Host ''
    Write-Host '  User data:' -ForegroundColor Cyan
    Write-Host ('  Username: ' + $u.Username) -ForegroundColor Gray
    Write-Host ('  IP address: ' + $u.Ip) -ForegroundColor Gray
    Write-Host ('  Hardware-Id: ' + $u.Hwid) -ForegroundColor Gray
    $subs = @($u.Subscriptions)
    for ($i = 0; $i -lt $subs.Count; $i++) {
        $expiry = ConvertFrom-AuthUnixTime ([string]$subs[$i].expiry)
        Write-Host ('  [{0} / {1}] | Subscription: {2} - Expiry: {3} - Timeleft: {4}' -f ($i + 1), $subs.Count, [string]$subs[$i].subscription, $expiry, [string]$subs[$i].timeleft) -ForegroundColor Gray
    }
    Write-Host ('  Created at: ' + (ConvertFrom-AuthUnixTime $u.CreatedAt)) -ForegroundColor Gray
    Write-Host ('  Last login at: ' + (ConvertFrom-AuthUnixTime $u.LastLogin)) -ForegroundColor Gray
    Write-Host ('  Expires at: ' + (ConvertFrom-AuthUnixTime $u.Expires)) -ForegroundColor Gray
}

function Read-AuthPassword {
    # masked password prompt (no plaintext echo)
    param([Parameter(Position = 0)][string]$Prompt = 'Provide password: ')
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return '' }
}

function Invoke-LicenseAuthLogin {
    # type=login with username + password (+ HWID). Returns $true on success.
    param([string]$User, [string]$Password)
    $raw = Invoke-LicenseAuthRequest @{
        type      = 'login'
        username  = $User
        pass      = $Password
        hwid      = (Get-AuthHwid)
        sessionid = $script:AuthSession.SessionId
        name      = $script:AuthConfig.Name
        ownerid   = $script:AuthConfig.OwnerId
    }
    if (-not $raw) { return $false }
    try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { Write-Host '  Invalid server response.' -ForegroundColor Red; return $false }
    if ($json.success) { Set-AuthUserData $json.info; Write-Host ('  ' + [string]$json.message) -ForegroundColor Green; return $true }
    Write-Host ('  ' + [string]$json.message) -ForegroundColor Red
    Start-Sleep -Seconds 3
    return $false
}

function Invoke-LicenseAuthKey {
    # type=license with licence key only (+ HWID). Returns $true on success.
    param([string]$Key)
    $raw = Invoke-LicenseAuthRequest @{
        type      = 'license'
        key       = $Key
        hwid      = (Get-AuthHwid)
        sessionid = $script:AuthSession.SessionId
        name      = $script:AuthConfig.Name
        ownerid   = $script:AuthConfig.OwnerId
    }
    if (-not $raw) { return $false }
    try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { Write-Host '  Invalid server response.' -ForegroundColor Red; return $false }
    if ($json.success) { Set-AuthUserData $json.info; Write-Host ('  ' + [string]$json.message) -ForegroundColor Green; return $true }
    Write-Host ('  ' + [string]$json.message) -ForegroundColor Red
    Start-Sleep -Seconds 3
    return $false
}

function Invoke-Authentication {
    <#
    .SYNOPSIS
        REGIX Studio auth gate. User picks: 1 = username + password, 2 = licence key.
    .PARAMETER AuthMethod
        '1' (username/password) or '2' (licence key). Prompts when empty.
    .PARAMETER AuthUser / AuthPass / LicenseKey
        Non-interactive credential overrides (used by worker.js launcher).
    #>
    param([string]$AuthMethod = '', [string]$AuthUser = '', [string]$AuthPass = '', [string]$LicenseKey = '')
    if ($env:REGIX_AUTH_METHOD -and -not $AuthMethod) { $AuthMethod = $env:REGIX_AUTH_METHOD }
    if ($env:REGIX_AUTH_USER -and -not $AuthUser)     { $AuthUser = $env:REGIX_AUTH_USER }
    if ($env:REGIX_AUTH_PASS -and -not $AuthPass)     { $AuthPass = $env:REGIX_AUTH_PASS }
    if ($env:REGIX_LICENSE_KEY -and -not $LicenseKey) { $LicenseKey = $env:REGIX_LICENSE_KEY }
    if (-not $script:AuthConfig.Name -or -not $script:AuthConfig.OwnerId -or -not $script:AuthConfig.Secret) {
        if ($script:AuthConfig.AllowUnconfigured) {
            Write-Host '  [AUTH] LicenseAuth credentials are not configured - continuing in dev mode.' -ForegroundColor Yellow
            Write-Host '  [AUTH] Fill $script:AuthConfig (or REGIX_AUTH_* env vars via worker.js) to enforce auth.' -ForegroundColor DarkYellow
            return $true
        }
        Write-Host '  LicenseAuth credentials are missing - auth cannot run.' -ForegroundColor Red
        return $false
    }
    if ($script:AuthConfig.OwnerId.Length -ne 10 -or $script:AuthConfig.Secret.Length -ne 64) {
        Write-Host '  Go to Manage Applications on dashboard, copy the values, and set them in $script:AuthConfig (Name / OwnerId / Secret).' -ForegroundColor Red
        return $false
    }
    Write-Host '  Initializing' -ForegroundColor Cyan
    if (-not (Initialize-LicenseAuth)) { return $false }
    while ($true) {
        Show-RegixBanner
        Write-Host '    [1] Login with username and password' -ForegroundColor Yellow
        Write-Host '    [2] Login with licence key' -ForegroundColor Yellow
        Write-Host '    [0] Exit' -ForegroundColor Yellow
        if (-not $AuthMethod) { $AuthMethod = (Read-Host 'Select Option').Trim() }
        switch ($AuthMethod) {
            '1' {
                if (-not $AuthUser) { $AuthUser = (Read-Host 'Provide username: ') }
                if (-not $AuthPass) { $AuthPass = Read-AuthPassword }
                if (Invoke-LicenseAuthLogin -User $AuthUser -Password $AuthPass) { Show-AuthUserData; return $true }
                return $false
            }
            '2' {
                if (-not $LicenseKey) { $LicenseKey = (Read-Host 'Enter your license: ') }
                if (Invoke-LicenseAuthKey -Key $LicenseKey) { Show-AuthUserData; return $true }
                return $false
            }
            '0' { return $false }
            default {
                Write-Host ''
                Write-Host '  Invalid option' -ForegroundColor Red
                Start-Sleep -Seconds 1
                $AuthMethod = ''
            }
        }
    }
}

# =============================================================================
# SECTION FUNCTIONS
# =============================================================================

function Save-SystemBackup {
    # 01. BACKUP - restore point + full HKLM export
    Write-Host '  Creating system restore point (this may take a moment)...' -ForegroundColor Gray
    Invoke-Exe 'sc.exe' @('config', 'VSS', 'start=', 'demand')
    Invoke-Exe 'sc.exe' @('start', 'VSS')
    Invoke-Exe 'sc.exe' @('config', 'swprv', 'start=', 'demand')
    Invoke-Exe 'sc.exe' @('start', 'swprv')
    try { Checkpoint-Computer -Description 'Platinum+ Optimizer' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop }
    catch { Write-Host ('  Restore point skipped/unavailable: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
    Write-Host '  Exporting HKLM backup to Desktop\platinum_backup.reg ...' -ForegroundColor Gray
    Invoke-Exe 'reg.exe' @('export', 'HKLM', (Join-Path $env:USERPROFILE 'Desktop\platinum_backup.reg'), '/y')
}

function Invoke-BootConfig {
    # 03. BCDEDIT - BOOT, HYPERVISOR, TIMER, MEMORY, SECURITY BOOT
    Invoke-Exe 'bcdedit.exe' @('/deletevalue', 'useplatformclock')   # remove platform clock/tick leftovers
    Invoke-Exe 'bcdedit.exe' @('/deletevalue', 'useplatformtick')
    Invoke-Exe 'bcdedit.exe' @('/set', 'isolatedcontext', 'no')      # disable isolated context
    Invoke-Exe 'bcdedit.exe' @('/set', 'useplatformtick', 'yes')     # force platform tick
    Invoke-Exe 'bcdedit.exe' @('/set', 'disabledynamictick', 'yes')  # disable dynamic tick
    Invoke-Exe 'bcdedit.exe' @('/set', 'x2apicpolicy', 'enable')     # enable X2APIC when available
    Invoke-Exe 'bcdedit.exe' @('/set', 'groupsize', '64')            # interrupt group size
    Invoke-Exe 'bcdedit.exe' @('/set', 'groupaware', 'yes')
    Invoke-Exe 'bcdedit.exe' @('/set', 'hypervisorlaunchtype', 'off')# hypervisor off
    Invoke-Exe 'bcdedit.exe' @('/set', 'avoidlowmemory', '0')        # low memory boot options
    Invoke-Exe 'bcdedit.exe' @('/set', 'nolowmem', 'yes')
    Invoke-Exe 'bcdedit.exe' @('/set', 'badmemoryaccess', 'no')
    Invoke-Exe 'bcdedit.exe' @('/set', 'nx', 'optout')               # DEP: optout
    Invoke-Exe 'bcdedit.exe' @('/set', 'pae', 'forceenable')         # force PAE
    Invoke-Exe 'bcdedit.exe' @('/set', 'legacyaslr', 'no')           # legacy ASLR off
    Invoke-Exe 'bcdedit.exe' @('/set', 'tpmbootentropy', 'forcedisable')
    Invoke-Exe 'bcdedit.exe' @('/set', 'msi', 'force')               # force MSI
    Invoke-Exe 'bcdedit.exe' @('/set', 'configaccesspolicy', 'default')
    Invoke-Exe 'bcdedit.exe' @('/set', 'bootuxdisabled', 'on')       # boot UI / menu
    Invoke-Exe 'bcdedit.exe' @('/set', 'bootmenupolicy', 'standard')
    Invoke-Exe 'bcdedit.exe' @('/set', 'timeout', '0')
    Invoke-Exe 'bcdedit.exe' @('/set', '{bootmgr}', 'timeout', '0')
    Invoke-Exe 'bcdedit.exe' @('/set', 'ems', 'off')                 # Emergency Management Services off
    Invoke-Exe 'bcdedit.exe' @('/set', 'forcefailuremup', 'no')
    Invoke-Exe 'bcdedit.exe' @('/set', 'hibernation', 'off')         # hibernation off via boot
    Invoke-Exe 'bcdedit.exe' @('/set', 'tscsyncpolicy', 'enhanced')  # TSC sync policy
    Invoke-Exe 'powercfg.exe' @('-h', 'off')                         # Windows hibernation off
}

function Set-TelemetryPolicy {
    # 04. TELEMETRIA BASE WINDOWS
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' DWord 0
}

function Set-MemoryManagement {
    # 05. MEMORY MANAGEMENT - CACHE, PAGING, POOL, PRIORITIES
    Set-Reg $script:MM 'LargeSystemCache' DWord 1                    # large system cache
    Set-Reg $script:MM 'DisablePagingExecutive' DWord 1              # paging executive on
    Set-Reg $script:MM 'ZeroPageThreadPriority' DWord 31
    Set-Reg $script:MM 'MemoryManagementPriority' DWord 1
    Set-Reg $script:MM 'DisableMemoryThrottling' DWord 1
    Set-Reg $script:MM 'DisablePageSplitting' DWord 1
    Set-Reg $script:MM 'DisableMemoryScrubbing' DWord 1
    Set-Reg $script:MM 'SecondLevelDataCache' DWord 0
    Set-Reg $script:MM 'PoolUsageMaximum' DWord 60
    Set-Reg $script:MM 'MoveImages' DWord 0
    Set-Reg $script:MM 'FeatureSettings' DWord 1
    Set-Reg $script:MM 'ClearPageFileAtShutdown' DWord 0             # do not clear pagefile at shutdown
    Set-Reg $script:MM 'SessionViewSize' DWord 192
    Set-Reg $script:MM 'SessionPoolSize' DWord 128
    Set-Reg $script:MM 'SystemViewSize' DWord 24576
    Set-Reg $script:MM 'EnforceWriteProtection' DWord 1
    Set-Reg $script:MM 'TrimWorkingSet' DWord 0
    Set-Reg $script:MM 'WriteWatch' DWord 0
    Set-Reg $script:MM 'MapTransferCount' DWord 0
    Set-Reg $script:MM 'DisablePagingOfKernelStacks' DWord 1
    Set-Reg $script:MM 'DisablePoolTagging' DWord 1
    Set-Reg $script:MM 'SystemCacheReserve' DWord 1
    Set-Reg $script:MM 'LargePageAlways' DWord 1
    Set-Reg $script:MM 'DisableBackgroundScavenging' DWord 1
    Set-Reg $script:MM 'DisableVadCleanup' DWord 1
    Set-Reg $script:MM 'FeatureSettingsOverride' DWord 3             # mitigation override (1st setting)
    Set-Reg $script:MM 'FeatureSettingsOverrideMask' DWord 3
    Set-Reg $script:MM 'PoolAllocationPriority' DWord 1
    Set-Reg $script:MM 'MemoryPriority' DWord 1
    Set-Reg $script:MM 'NonPagedPoolMaximum' DWord 0
    Set-Reg $script:MM 'DisableMemoryCompression' DWord 1
    Set-Reg $script:MM 'EnablePageCombining' DWord 0
    Set-Reg $script:MM 'DisablePageCombining' DWord 1
    Set-Reg $script:MM 'NumaNodeSelectionPolicy' DWord 1
    Set-Reg $script:MM 'DramPowerManagement' DWord 0
    Set-Reg $script:MM 'DisableDriverPaging' DWord 1
    Set-Reg $script:MM 'PrioritizeForegroundApplications' DWord 1
    Set-Reg $script:MM 'DisableWorkingSetAging' DWord 1
    Set-Reg $script:MM 'DisableKernelStackPaging' DWord 1
    Set-Reg $script:MM 'LargePageMinimum' DWord 0
    Set-Reg $script:MM 'NonPagedPoolSize' DWord 0
    Set-Reg $script:MM 'PagedPoolSize' DWord 4294967295
    Set-Reg $script:MM 'IoPageLockLimit' DWord 0
    Set-Reg $script:MM 'MmMinimumFreePages' DWord 256000
    Set-Reg $script:MM 'SystemCacheDirtyPageThreshold' DWord 81920
    Set-Reg $script:MM 'AllocationPreference' DWord 1048576
    Set-Reg $script:MM 'AvoidLargePageCollisions' DWord 1
    Set-Reg $script:MM 'PhysicalAddressExtension' DWord 1            # PAE
    Set-Reg $script:MM 'NonPagedPoolQuota' DWord 0
    Set-Reg $script:MM 'PagedPoolQuota' DWord 0
    Set-Reg $script:MM 'SystemStartOptions' String 'MAXLATENCY'
    Set-Reg $script:MM 'VirtualizarionFlags' DWord 0
    Set-Reg $script:MM 'FirstLevelDataCache' DWord 65536
    Set-Reg $script:MM 'ThirdLevelDataCache' DWord 131072
    Set-Reg $script:MM 'PhysicalMemoryAllocationPolicy' DWord 0
    Set-Reg $script:MM 'EnableCfg' DWord 0                           # CFG / hot patch off
    Set-Reg $script:MM 'HotPatch' DWord 0
    Set-Reg $script:MM 'McGlobalShortBankQueueDepth' DWord 16
    Set-Reg $script:MM 'McBankQueueDepth' DWord 8
    Set-Reg $script:MM 'McMaxChannelCount' DWord 4
    Set-Reg $script:MM 'DisableMemoryPatrolScrub' DWord 1
    Set-Reg $script:MM 'NumaCrossNodeAccess' DWord 2
    Set-Reg $script:MM 'SharedUserData' DWord 1
    Set-Reg $script:MM 'MappedCommitLimit' DWord 4294967295          # commit limits
    Set-Reg $script:MM 'CommitLimit' DWord 4294967295
    Set-Reg $script:MM 'IoModification' DWord 0
    Set-Reg $script:MM 'GameModeCacheSize' DWord 1073741824
    Set-Reg $script:MM 'GameModeEnabled' DWord 1
    Set-Reg $script:MM 'GameModeCachePriority' DWord 15
}



function Disable-Prefetch {
    # 06. PREFETCH / SUPERFETCH / READ-AHEAD
    Set-Reg $script:PREFETCH 'EnablePrefetcher' DWord 0
    Set-Reg $script:PREFETCH 'EnableSuperfetch' DWord 0
    Set-Reg $script:PREFETCH 'SfTracingState' DWord 0
    Set-Reg $script:PREFETCH 'EnableBootTrace' DWord 0
    Set-Reg $script:PREFETCH 'EnableReadAhead' DWord 0
    Set-Reg $script:PREFETCH 'EnableSeekAhead' DWord 0
    Set-Reg $script:PREFETCH 'MaxReadAheadSize' DWord 0
    Set-Reg $script:PREFETCH 'PrefetchAttempts' DWord 0
    try { Disable-MMAgent -MemoryCompression -PageCombining -ErrorAction Stop } catch { }
}

function Optimize-IoStorage {
    # 07. I/O SYSTEM / STORAGE / NVME / DISK
    Set-Reg $script:IOSYS 'EnableIoRing' DWord 1                     # IoRing
    Set-Reg $script:IOSYS 'IoRingMaxSubmitQueueSize' DWord 65536
    Set-Reg $script:IOSYS 'CountOperations' DWord 0
    Set-Reg $script:IOSYS 'InterruptSteeringDisabled' DWord 0
    Set-Reg $script:IOSYS 'BypassIosEnable' DWord 1
    Set-Reg $script:IOSYS 'DisableLookAside' DWord 1
    Set-Reg $script:IOSYS 'IoPriorityHint' DWord 3
    Set-Reg $script:IOSYS 'IoNoWorkQueue' DWord 1
    Set-Reg $script:IOSYS 'DisableIoBuffering' DWord 1
    Set-Reg $script:IOSYS 'DisableThreadLibraryCalls' DWord 1
    Set-Reg $script:IOSYS 'OptimizationFlags' DWord 4194304          # 0x400000
    Set-Reg $script:IOSYS 'IoReadOperationLimit' DWord 65536
    Set-Reg $script:IOSYS 'IoWriteOperationLimit' DWord 65536
    Set-Reg $script:IOSYS 'IoOtherOperationLimit' DWord 65536
    Set-Reg $script:IOSYS 'IOMaximumLength' DWord 1048576
    Set-Reg $script:IOSYS 'IoPageLockLimit' DWord 16777216
    Set-Reg $script:IOSYS 'IOMatchDeadline' DWord 0

    # Storport: transfer length, requests, priorities
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\storport\Parameters' 'MaximumTransferLength' DWord 4294967295
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\storport\Parameters' 'NumberOfRequests' DWord 512
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\storport\Parameters' 'ThreadPriority' DWord 31
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\storport\Parameters' 'InterruptPriority' DWord 3
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\storport\Parameters' 'DpcIsolation' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\storport\Parameters' 'DisableIdleTimeout' DWord 1

    # Stornvme: flush cache, priority, DPC, bypass IO, power idle off
    $nvmeDev = 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Device'
    Set-Reg $nvmeDev 'DisableWriteCacheBufferFlush' DWord 1
    Set-Reg $nvmeDev 'InterruptPriority' DWord 3
    Set-Reg $nvmeDev 'DpcIsolation' DWord 1
    Set-Reg $nvmeDev 'BypassIoEnable' DWord 1
    Set-Reg $nvmeDev 'IdlePowerMode' DWord 0
    Set-Reg $nvmeDev 'DisableIdlePowerManagement' DWord 1
    Set-Reg $nvmeDev 'HostMemoryBufferBytes' DWord 0
    Set-Reg $nvmeDev 'MessageNumberLimit' DWord 2048
    Set-Reg $nvmeDev 'NvmeCommandTimeout' DWord 300
    Set-Reg $nvmeDev 'NvmeMaxIoConcurrency' DWord 128

    # MSI / interrupt NVME
    $nvmeMsi = 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Interrupt Management'
    Set-Reg "$nvmeMsi\MessageSignaledInterruptProperties" 'MSIXSupported' DWord 1
    Set-Reg "$nvmeMsi\Affinity Policy" 'DeviceExecutionMode' DWord 1
    Set-Reg "$nvmeMsi\Affinity Policy" 'DevicePriority' DWord 31

    # Disk timeout / cache
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\disk\Parameters' 'TimeOutValue' DWord 180
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Disk' 'EnableCache' DWord 1

    # Storage control
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage' 'DisableDeleteNotification' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage' 'ZeroPoweredNTDisks' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage' 'ShortStreakQueuing' DWord 1

    # FairShare disk/netfs off
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\TSFairShare\Disk' 'EnableFairShare' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\TSFairShare\NetFS' 'EnableFairShare' DWord 0

    # FSUTIL: last access, 8.3, MFT zone, encryption/compression
    Invoke-Exe 'fsutil.exe' @('behavior', 'set', 'disablelastaccess', '1')
    Invoke-Exe 'fsutil.exe' @('behavior', 'set', 'disable8dot3', '1')
    Invoke-Exe 'fsutil.exe' @('behavior', 'set', 'mftzone', '4')
    Invoke-Exe 'fsutil.exe' @('behavior', 'set', 'encryptpagingfile', '0')
    Invoke-Exe 'fsutil.exe' @('behavior', 'set', 'disablecompression', '1')
    Invoke-Exe 'fsutil.exe' @('behavior', 'set', 'disableencryption', '1')
    Invoke-Exe 'fsutil.exe' @('behavior', 'set', 'memoryusage', '2')
}

function Optimize-Ntfs {
    # 08. NTFS / FILE SYSTEM
    Set-Reg $script:FS 'NtfsDisableLastAccessUpdate' DWord 1
    Set-Reg $script:FS 'NtfsMftZoneReservation' DWord 4
    Set-Reg $script:FS 'NtfsDisable8dot3NameCreation' DWord 1
    Set-Reg $script:FS 'NtfsMemoryUsage' DWord 2
    Set-Reg $script:FS 'ContigFileAllocSize' DWord 64
    Set-Reg $script:FS 'NtfsDisableEncryption' DWord 1
    Set-Reg $script:FS 'MaximumTunnelEntries' DWord 0
    Set-Reg $script:FS 'MaximumTunnelEntryAgeInSeconds' DWord 0
    Set-Reg $script:FS 'NameCache' DWord 512
    Set-Reg $script:FS 'PathCache' DWord 128
    Set-Reg $script:FS 'LongPathsEnabled' DWord 1
    Set-Reg $script:FS 'RefsDisableLastAccessUpdate' DWord 1
    Set-Reg $script:FS 'NtfsDisableCompression' DWord 1
    Set-Reg $script:FS 'NtfsAllowExtendedCharacter8dot3Rename' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Ntfs' 'DisableReadAhead' DWord 1
}



function Optimize-Graphics {
    # 09. DWM / DXGI / GRAPHICS CORE / FLIP MODEL
    Set-Reg $script:DWM 'UseHWDrawList' DWord 1                      # use HW draw list
    Set-Reg $script:DWM 'ForceSoftwareD3D' DWord 0
    Set-Reg $script:DWM 'OverlayTestMode' DWord 5
    Set-Reg $script:DWM 'EnableIndependentFlip' DWord 1
    Set-Reg $script:DWM 'EnableMachineCheck' DWord 0
    Set-Reg $script:DWM 'AlwaysHibernateThumbnails' DWord 0
    Set-Reg $script:DWM 'DisableProcessWindowsGhosting' DWord 1
    Set-Reg $script:DWM 'MaxQueuedBuffers' DWord 1
    Set-Reg $script:DWM 'OverlaySupported' DWord 0
    Set-Reg $script:DWM 'ForceDirectFlip' DWord 1
    Set-Reg $script:DWM 'DisableOverlays' DWord 0

    Set-Reg $script:GD 'HwSchMode' DWord 2                           # hardware GPU scheduling
    Set-Reg $script:GD 'HwSch_QueueDepth' DWord 1
    Set-Reg $script:GD 'HwSch_MaxPendingCommand' DWord 1
    Set-Reg $script:GD 'HwSch_ThreadPriority' DWord 31
    Set-Reg $script:GD 'TdrDdiDelay' DWord 20                        # TDR delay
    Set-Reg $script:GD 'TdrDelay' DWord 60
    Set-Reg $script:GD 'DmaRemappingCompatible' DWord 0
    Set-Reg $script:GD 'DisableVsyncLatencyUpdate' DWord 1
    Set-Reg $script:GD 'EnableDirtyRectangles' DWord 0
    Set-Reg $script:GD 'FrameQueueMode' DWord 0
    Set-Reg $script:GD 'FSE_Enable' DWord 1
    Set-Reg $script:GD 'DisableWddm2Checks' DWord 1
    Set-Reg $script:GD 'PowerSettingEnable' DWord 0
    Set-Reg $script:GD 'EnableAsyncPresentation' DWord 1
    Set-Reg $script:GD 'PlatformSupportMiracast' DWord 0
    Set-Reg $script:GD 'IommuUsage' DWord 0
    Set-Reg $script:GD 'D3D12DisableSharedDynamicValueManagement' DWord 1
    Set-Reg $script:GD 'DisableMemoryEncryption' DWord 1
    Set-Reg $script:GD 'VerifyDriverLevel' DWord 0
    Set-Reg $script:GD 'MaxFrameLatency' DWord 1
    Set-Reg $script:GD 'TdrLevel' DWord 8
    Set-Reg $script:GD 'EnableMultiPlaneOverlay3DDIs' DWord 0
    Set-Reg $script:GD 'ForceDirectFlip' DWord 0
    Set-Reg $script:GD 'DisableOverlays' DWord 0
    Set-Reg $script:GD 'HighPriorityCompletionMode' DWord 1
    Set-Reg $script:GD 'GpuPriorityChangeMode' DWord 1
    Set-Reg $script:GD 'DCIControl' DWord 1

    Set-Reg $script:GDMM 'DirectStorageForceFlush' DWord 0           # DirectStorage force flush off

    # Scheduler GPU: preemption, priority, vsync, async compute
    Set-Reg $script:GDS 'EnableComputePreemption' DWord 0
    Set-Reg $script:GDS 'VsyncIdleTimeout' DWord 0
    Set-Reg $script:GDS 'EnableVsyncClockGroup' DWord 0
    Set-Reg $script:GDS 'GpuPriority' DWord 31
    Set-Reg $script:GDS 'PreemptionLevel' DWord 0
    Set-Reg $script:GDS 'MicrocodeQueuePriority' DWord 31
    Set-Reg $script:GDS 'EnableAsyncCompute' DWord 1
    Set-Reg $script:GDS 'EnableMidGfxPreemption' DWord 0
    Set-Reg $script:GDS 'EnableSCGMidBufferPreemption' DWord 0
    Set-Reg $script:GDS 'SchedulePolicy' DWord 4
    Set-Reg $script:GDS 'GpuResourceAccessPriority' DWord 31
    Set-Reg $script:GDS 'EnableYield' DWord 0
    Set-Reg $script:GDS 'EnablePreemptiveScheduling' DWord 1
    Set-Reg $script:GDS 'EnableCudaContextPreemption' DWord 0
    Set-Reg $script:GDS 'PollStatusIterations' DWord 1

    # Power GPU: dynamic pstate, DPC per core, registry caching off
    Set-Reg $script:GDPOWER 'InvalidateDynamicPstate' DWord 1
    Set-Reg $script:GDPOWER 'RmGpsPsEnablePerCpuCoreDpc' DWord 1
    Set-Reg $script:GDPOWER 'RmDisableRegistryCaching' DWord 1
    Set-Reg $script:GDPOWER 'EnablePowerBudget' DWord 0
    Set-Reg $script:GDPOWER 'IgnoreBatteryVoltageSag' DWord 1

    # DXGKrnl thread priority
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\DXGKrnl\Parameters' 'ThreadPriority' DWord 15

    # Direct3D contexts / loader / driver / d3d12 / d3d11 / directdraw / vulkan
    $d3d = 'HKLM:\SOFTWARE\Microsoft\Direct3D'
    Set-Reg $d3d 'MaxContexts' DWord 4096
    Set-Reg $d3d 'MaxLoaderThreads' DWord 16
    Set-Reg $d3d 'ContextReordering' DWord 0
    Set-Reg "$d3d\Drivers" 'SoftwareOnly' DWord 0
    Set-Reg "$d3d\12.0" 'DisableClearOnAllocate' DWord 1
    Set-Reg "$d3d\12.0" 'EnableAsyncCompute' DWord 1
    Set-Reg "$d3d\12.0" 'DisablePsoEviction' DWord 1
    Set-Reg "$d3d\11.0" 'DisableClearOnAllocate' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\DirectDraw' 'EmulationOnly' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Khronos\Vulkan\ImplicitLayers' 'DisableValidation' DWord 1

    # DirectX user GPU preferences
    Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' String 'SwapEffectUpgradeEnable=1'
}


function Disable-GameDvr {
    # 10. GAME DVR / GAME BAR / GAME MODE
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' DWord 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DSEBehavior' DWord 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' DWord 0
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' DWord 1
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' DWord 1
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags' DWord 0
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' DWord 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Priority' DWord 1
    # app / audio / cursor capture off
    $gameDvr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    Set-Reg $gameDvr 'AppCaptureEnabled' DWord 0
    Set-Reg $gameDvr 'AudioCaptureEnabled' DWord 0
    Set-Reg $gameDvr 'CursorCaptureEnabled' DWord 0
    # GameDVR policy off
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR' 'value' DWord 0
    # GameMode DVR
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'GameModeEnabled' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'GameModeUseNullRenderer' DWord 1
}

function Set-MmcssProfile {
    # 11. MMCSS - MULTIMEDIA CLASS SCHEDULER
    Set-Reg $script:MMCSS 'NetworkThrottlingIndex' DWord 4294967295   # network throttling index max
    Set-Reg $script:MMCSS 'SystemResponsiveness' DWord 0
    Set-Reg $script:MMCSS 'NoLazyMode' DWord 1
    Set-Reg $script:MMCSS 'AlwaysOn' DWord 1
    Set-Reg $script:MMCSS 'Priority' DWord 6
    Set-Reg $script:MMCSS 'CacheQualityOfService' DWord 0
    # Games task profile
    $games = "$script:MMCSS\Tasks\Games"
    Set-Reg $games 'Affinity' DWord 0
    Set-Reg $games 'Background Only' String 'False'
    Set-Reg $games 'Scheduling Category' String 'High'
    Set-Reg $games 'GPU Priority' DWord 8
    Set-Reg $games 'Priority' DWord 6
    Set-Reg $games 'SFIO Priority' String 'High'
    Set-Reg $games 'Latency Sensitive' String 'True'
    Set-Reg $games 'BackgroundPriority' DWord 0
    Set-Reg $games 'Clock Rate' DWord 10000
    # Audio task profile
    Set-Reg "$script:MMCSS\Tasks\Audio" 'Priority' DWord 6
    # Low Latency task profile
    $lowLatency = "$script:MMCSS\Tasks\Low Latency"
    Set-Reg $lowLatency 'Scheduling Category' String 'High'
    Set-Reg $lowLatency 'Priority' DWord 8
}

function Set-MouseKeyboard {
    # 12-13. MOUSE / KEYBOARD / ACCESSIBILITY / DESKTOP
    $mouse = 'HKCU:\Control Panel\Mouse'
    Set-Reg $mouse 'MouseSpeed' String '0'                            # mouse speed & thresholds
    Set-Reg $mouse 'MouseThreshold1' String '0'
    Set-Reg $mouse 'MouseThreshold2' String '0'
    Set-Reg $mouse 'MouseHoverTime' String '0'
    Set-Reg $mouse 'SmoothMouseXCurve' Binary '0000000000000000C0CC0C0000000000809919000000000040662600000000000033330000000000'
    Set-Reg $mouse 'SmoothMouseYCurve' Binary '0000000000000000000038000000000000007000000000000000A800000000000000E00000000000'
    $keyboard = 'HKCU:\Control Panel\Keyboard'
    Set-Reg $keyboard 'KeyboardDelay' String '0'                      # keyboard delay / speed
    Set-Reg $keyboard 'KeyboardSpeed' String '31'
    $kbResp = 'HKCU:\Control Panel\Accessibility\Keyboard Response'
    Set-Reg $kbResp 'AutoRepeatDelay' String '200'                    # keyboard accessibility
    Set-Reg $kbResp 'AutoRepeatRate' String '6'
    Set-Reg $kbResp 'DelayBeforeAcceptance' String '0'
    Set-Reg $kbResp 'Flags' String '122'
    Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' String '506'
    Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' String '58'
    $desktop = 'HKCU:\Control Panel\Desktop'
    Set-Reg $desktop 'MenuShowDelay' String '0'                       # menu delay, auto end tasks, app timeout
    Set-Reg $desktop 'AutoEndTasks' String '1'
    Set-Reg $desktop 'HungAppTimeout' String '1000'
    Set-Reg $desktop 'WaitToKillAppTimeout' String '7000'
    Set-Reg $desktop 'LowLevelHooksTimeout' String '9000'
    Set-Reg $desktop 'ForegroundLockTimeout' DWord 0
    Set-Reg $desktop 'BlockSendInputResets' String '0'
    Set-Reg $desktop 'ActiveWndTrkTimeout' DWord 0
    Set-Reg $desktop 'CaretWidth' DWord 1
    Set-Reg $desktop 'FontSmoothing' String '1'
    # Mouclass / Kbdclass queue size and priority
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Mouclass\Parameters' 'MouseDataQueueSize' DWord 100
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Mouclass\Parameters' 'ThreadPriority' DWord 31
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Kbdclass\Parameters' 'KeyboardDataQueueSize' DWord 100
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Kbdclass\Parameters' 'ThreadPriority' DWord 31
}

function Optimize-UsbPci {
    # 14. USB / INTERRUPT / PCI / CLASS DEVICE
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\USB' 'DisableSelectiveSuspend' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\USBXHCI\Parameters' 'ThreadPriority' DWord 31
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\USBXHCI\Parameters' 'InterruptModeration' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\USBHUB3\Parameters' 'ThreadPriority' DWord 31
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\HidUsb' 'IdleEnabled' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{36fc9e60-c465-11cf-8056-444553540000}' 'IdleEnable' DWord 0
    # mouse class: force high priority
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E96F-E325-11CE-BFC1-08002BE10318}\0000' 'ForceProcessHighPriority' DWord 1
    # display class: MSI / ASPM / latency
    $displayKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'
    Set-Reg $displayKey 'MessageSignaledInterrupts' DWord 1
    Set-Reg $displayKey 'MSISupported' DWord 1
    Set-Reg $displayKey 'EnableAspm' DWord 0
    Set-Reg $displayKey 'PciLatencyTimerControl' DWord 32
    Set-Reg "$displayKey\Interrupt Management\Affinity Policy" 'Strategy' DWord 2
    Set-Reg "$displayKey\Interrupt Management\Affinity Policy" 'DevicePriority' DWord 4
    # PCI: MSI / latency / ASPM
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\PCI' 'EnableMsi' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\PCI' 'MessageSignaledInterrupt' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\PCI' 'BusSolverMaxDepth' DWord 32
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\PCI' 'BusCheck' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\PCI' 'PerfOptimize' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\pci' 'PciLatencyTimerControl' DWord 32
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\pci' 'LinkDisableAspm' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\pci\Parameters' 'PciBufferSize' DWord 64
}


function Disable-BloatServices {
    # 15-16. SERVICES - DISABLED VIA SC CONFIG + REGISTRY START=4
    $script:DisabledServices = @(
        'DiagTrack','dmwappushservice','WerSvc','DPS','WdiServiceHost','WdiSystemHost','PcaSvc',
        'diagnosticshub.standardcollector.service','diagsvc','SysMain','RemoteRegistry','RemoteAccess',
        'WinRM','iphlpsvc','lfsvc','BDESVC','EFS','SCardSvr','ScDeviceEnum','Fax','MapsBroker',
        'PhoneSvc','TrkWks','TapiSrv','AJRouter','WpcMonSvc','ALG','EntAppSvc','wisvc','RetailDemo',
        'WMPNetworkSvc','FontCache3.0.0.0','StiSvc','SensorService','SensrSvc','SensorDataService',
        'XboxGipSvc','XblAuthManager','XboxNetApiSvc','XblGameSave','SEMgrSvc','uhssvc','upfc',
        'PushToInstall','dosvc','UsoSvc','WaaSMedicSvc','microsoftedgeupdater','microsoftedgeupdatem',
        'EsifTelemetryService','ipfsvc','RtkAudioUniversalService','AeLookupSvc','WSAIFabricSvc',
        'edgeupdate','edgeupdatem','DsSvc','CDPSvc','CDPUserSvc','WarpSvc','NvTelemetryContainer',
        'OneSyncSvc','Wecsvc','bthserv','DoSvc','NetTcpPortSharing','perceptionsimulation','spectrum',
        'MixedRealityOpenXRSvc','BcastDVRUserService','BTAGService','BthAvctpSvc','icssvc',
        'DmEnrollmentSvc','DusmSvc','embeddedmode','GraphicsPerfSvc','HvHost','IpxlatCfgSvc',
        'jhi_service','KtmRm','LxpSvc','McpManagementService','MicrosoftEdgeElevationService',
        'NetSetupSvc','NcdAutoSetup','p2pimsvc','p2psvc','PerfHost','pla','PolicyAgent','PNRPAutoReg',
        'PNRPsvc','QWAVE','RasAuto','RasMan','RpcLocator','shpamsvc','smphost','SmsRouter','SNMPTRAP',
        'svsvc','swprv','TroubleshootingSvc','tzautoupdate','WebClient','WEPHOSTSVC','wercplsupport',
        'WFDSConMgrSvc','WiaRpc','WManSvc','wmiApSrv','WPDBusEnum','BITS','InstallService',
        'LicenseManager','SDRSVC','fhsvc','defragsvc','vds','TieringEngineService','StorSvc',
        'UdkUserSvc','FontCache','W32Time','Spooler','SharedAccess','WwanSvc'
    )
    foreach ($svc in $script:DisabledServices) { Disable-WindowsService $svc }

    # services with spaces in the name (sc config only, like the original)
    foreach ($svc in @('AMD Crash Defender Service', 'AUEPLauncher', 'cplcon', 'SECOMNService',
                       'SECOMN Service', 'Sound Research SECOMN Service', 'NvTelemetryContainer')) {
        Set-ServiceStartType $svc 'disabled'
    }

    # delete Edge update services
    Invoke-Exe 'sc.exe' @('delete', 'edgeupdate')
    Invoke-Exe 'sc.exe' @('delete', 'edgeupdatem')

    # auto / demand services
    Set-ServiceStartType 'TabletInputService' 'auto'
    Set-ServiceStartType 'IntelAudioService' 'demand'
    Set-ServiceStartType 'bits' 'demand'
    Set-ServiceStartType 'camsvc' 'auto'

    # services with different start values
    Set-ServiceStartValue 'DispBrokerDesktopSvc' 2
    Set-ServiceStartValue 'KeyIso' 2
    Set-ServiceStartValue 'AppXSvc' 3
    Set-ServiceStartValue 'camsvc' 2
    Set-ServiceStartValue 'TabletInputService' 2

    # offline / temp system keys present in the original file
    Set-Reg 'HKLM:\TEMP_SYSTEM\ControlSet001\Services\wlidsvc' 'Start' DWord 3
    Set-Reg 'HKLM:\TEMP_SYSTEM\ControlSet001\Services\WbioSrvc' 'Start' DWord 4
    Set-Reg 'HKLM:\OFFLINE_SYS\ControlSet001\Services\DispBrokerDesktopSvc' 'Start' DWord 2
    Set-Reg 'HKLM:\OFFLINE_SYS\ControlSet001\Services\BcastDVRUserService' 'Start' DWord 2
}


function Remove-Bloatware {
    # 17. APPX / BLOATWARE REMOVAL
    try { Clear-RecycleBin -Confirm:$false -ErrorAction SilentlyContinue } catch { }   # empty recycle bin

    $userAppx = @(
        'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted',
        'Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftOfficeHub','Microsoft.People',
        'Microsoft.PowerAutomateDesktop','Microsoft.Todos','Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsMaps','Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
        'Microsoft.SkypeApp','Clipchamp.Clipchamp','Microsoft.Bing','Microsoft.OutlookForWindows',
        'Microsoft.DevHome','Microsoft.Windows.DevHome','Microsoft.WebExperiencePack',
        'Microsoft.Windows.Ai.Copilot.Provider','Microsoft.Copilot','MSTeams','Microsoft.MicrosoftEdge.Stable'
    )
    foreach ($app in $userAppx) {
        Get-AppxPackage -Name "*$app*" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
    }

    # removal for all users
    foreach ($app in @('*MixedReality.Portal*', '*windowscommunicationsapps*', '*OutlookForWindows*',
                       '*MSPaint*', '*ScreenSketch*', '*MicrosoftStickyNotes*', '*WindowsSoundRecorder*')) {
        Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    }

    # optional Windows features off
    try { Disable-WindowsOptionalFeature -Online -FeatureName 'WorkFolders-Client', 'SMB1Protocol' -NoRestart -ErrorAction SilentlyContinue } catch { }

    # Defender sample consent
    try { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue } catch { }
}


function Clear-EventLogs {
    # 18. LOGMAN / ETL / EVENT LOG
    foreach ($trace in @(
        'Microsoft-Windows-Storage-Storport-Operational','Microsoft-Windows-Rdp-Graphics-RdpIdd-Trace',
        'Microsoft-Windows-Kernel-Processor-Power','Microsoft-Windows-UserModePowerService',
        'Microsoft-Windows-Ntfs-Operational','Microsoft-Windows-DeviceSetupManager-Admin',
        'Circular Kernel Context Logger','UBPM','AutoLogger-Diagtrack-Listener','NetCore',
        'ContextLogger','CloudExperienceHost')) {
        Invoke-Exe 'logman.exe' @('stop', $trace, '-ets')
    }
    foreach ($log in @('System', 'Application', 'Security', 'Setup')) {
        Invoke-Exe 'wevtutil.exe' @('cl', $log)
    }
    foreach ($log in @('Microsoft-Windows-SleepStudy/Diagnostic',
                       'Microsoft-Windows-Kernel-Processor-Power/Diagnostic',
                       'Microsoft-Windows-UserModePowerService/Diagnostic')) {
        Invoke-Exe 'wevtutil.exe' @('set-log', $log, '/e:false')
    }
}

function Set-BrowserTelemetry {
    # 19. OFFICE / EDGE / WEBVIEW2 / CHROME TELEMETRY
    $officePrivacy = 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Privacy'
    Set-Reg $officePrivacy 'DisconnectedState' DWord 2
    Set-Reg $officePrivacy 'ContentSlotState' DWord 2
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Office\16.0\OSM' 'Enablelogging' DWord 0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Office\16.0\OSM' 'EnableUpload' DWord 0

    # Edge telemetry
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $edge 'MetricsReportingEnabled' DWord 0
    Set-Reg $edge 'PersonalizationReportingEnabled' DWord 0
    Set-Reg $edge 'UserFeedbackAllowed' DWord 0
    Set-Reg $edge 'BackgroundModeEnabled' DWord 0
    Set-Reg "$edge\WebView2" 'TelemetryEnabled' DWord 0

    # Chrome background mode
    Set-Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' DWord 0

    # Edge update block
    Set-Reg 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'DisableAutoUpdateChecksCheckboxValue' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\Main' 'AllowPrelaunch' DWord 0
}


function Set-PrivacyPolicies {
    # 20. PRIVACY / TELEMETRIA / CONTENT DELIVERY / COPILOT / RECALL
    # deep telemetry
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\DataCollection' 'MaxTelemetryAllowed' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'LimitEnhancedDiagnosticData' DWord 0
    # advertising info off
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' DWord 0
    # tailored experiences off
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' DWord 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesAllowed' DWord 0
    # feedback frequency off
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' DWord 0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' DWord 0
    # Content Delivery Manager off
    $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-Reg $cdm 'ContentDeliveryAllowed' DWord 0
    Set-Reg $cdm 'RotatingLockScreenEnabled' DWord 0
    Set-Reg $cdm 'RotatingLockScreenOverlayEnabled' DWord 0
    foreach ($sub in @('310093', '338380', '338381', '338382', '338387', '338388',
                       '338389', '338393', '353694', '353696', '353698')) {
        Set-Reg $cdm "SubscribedContent-$sub`Enabled" DWord 0
    }
    Set-Reg $cdm 'RemediationRequired' DWord 0
    Set-Reg $cdm 'OemPreInstalledAppsEnabled' DWord 0
    Set-Reg $cdm 'PreInstalledAppsEnabled' DWord 0
    Set-Reg $cdm 'PreInstalledAppsEverEnabled' DWord 0
    Set-Reg $cdm 'SilentInstalledAppsEnabled' DWord 0
    Set-Reg $cdm 'SystemPaneSuggestionsEnabled' DWord 0
    Set-Reg $cdm 'SoftLandingEnabled' DWord 0
    # Windows AI / Recall / Copilot off
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' DWord 1
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' DWord 0
    # Bing search off
    Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' DWord 1
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' DWord 0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' DWord 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' DWord 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'SearchboxTaskbarMode' DWord 0
    # Windows Spotlight off
    $cloud = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    Set-Reg $cloud 'DisableSoftLanding' DWord 1
    Set-Reg $cloud 'DisableWindowsSpotlightFeatures' DWord 1
    Set-Reg $cloud 'DisableWindowsSpotlightOnActionCenter' DWord 1
    Set-Reg $cloud 'DisableWindowsSpotlightWindowsWelcomeExperience' DWord 1
    Set-Reg $cloud 'DisableWindowsConsumerFeatures' DWord 1
    # Cortana off
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' DWord 0
    # Activity feed off
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' DWord 0
}


function Set-IfeoPriorities {
    # 21. IFEO - DEBUGGER BLOCK / PRIORITIES / LARGE PAGES
    foreach ($exe in @('CompatTelRunner.exe', 'DeviceCensus.exe', 'AggregatorHost.exe')) {
        Set-Reg (Join-Path $script:IFEO $exe) 'Debugger' String 'nul'
    }
    # system / shell processes -> high priority
    foreach ($exe in @('ShellExperienceHost.exe', 'dwm.exe', 'explorer.exe', 'SearchHost.exe')) {
        $perf = Get-IfeoPerfPath $exe
        Set-Reg $perf 'CpuPriorityClass' DWord 3
        Set-Reg $perf 'IoPriority' DWord 3
        Set-Reg $perf 'PagePriority' DWord 5
    }
    # low priority for update / WMI / spooler
    Set-Reg (Get-IfeoPerfPath 'wuauclt.exe') 'CpuPriorityClass' DWord 4
    Set-Reg (Get-IfeoPerfPath 'wuauclt.exe') 'IoPriority' DWord 4
    Set-Reg (Get-IfeoPerfPath 'WMIADAP.exe') 'CpuPriorityClass' DWord 4
    Set-Reg (Get-IfeoPerfPath 'WMIADAP.exe') 'IoPriority' DWord 3
    Set-Reg (Get-IfeoPerfPath 'WmiPrvSE.exe') 'CpuPriorityClass' DWord 4
    Set-Reg (Get-IfeoPerfPath 'spoolsv.exe') 'CpuPriorityClass' DWord 4
}

function Set-PowerRegistry {
    # 22. POWER REGISTRY VALUES (sensor watchdog, clock gating, C-States, VR, memory perf)
    Set-Reg $script:POWER 'DisableSensorWatchdog' DWord 1
    Set-Reg $script:POWER 'FabricClockGating' DWord 0
    Set-Reg $script:POWER 'LclkClockGating' DWord 0
    Set-Reg $script:POWER 'ProcessorPerformanceMinimum' DWord 100
    Set-Reg $script:POWER 'ProcessorPerformanceMaximum' DWord 100
    Set-Reg $script:POWER 'ProcessorPerformanceMaximumPolicy' DWord 0
    Set-Reg $script:POWER 'CpuUtilizationPercentage' DWord 100
    Set-Reg $script:POWER 'EnergyEstimationDisabled' DWord 1
    Set-Reg $script:POWER 'ResponsiveModeEnabled' DWord 1
    Set-Reg $script:POWER 'AcceleratedHibernateEnabled' DWord 0
    Set-Reg $script:POWER 'EnergyEfficientTurbo' DWord 0
    Set-Reg $script:POWER 'TurboBoostEnabled' DWord 1
    Set-Reg $script:POWER 'CoreCStatesEnabled' DWord 0
    Set-Reg $script:POWER 'CoreC6Enable' DWord 0
    Set-Reg $script:POWER 'PlatformCStateSupport' DWord 0
    Set-Reg $script:POWER 'CStatesForIdle' DWord 0
    Set-Reg $script:POWER 'VRReadyEnabled' DWord 1
    Set-Reg $script:POWER 'VRMode' DWord 1
    Set-Reg $script:POWER 'LowLatencyMode' DWord 1
    Set-Reg $script:POWER 'LowLatencyState' DWord 2
    Set-Reg $script:POWER 'MemoryPerformanceMode' DWord 1
    Set-Reg $script:POWER 'MemoryTimingOverride' DWord 1
    Set-Reg $script:POWER 'SOCPStateSupport' DWord 0
    Set-Reg $script:POWER 'SOCPciePStateSupport' DWord 0
    Set-Reg $script:POWER 'SOCD3ColdSupport' DWord 0
    Set-Reg $script:POWER 'USB3PowerEnable' DWord 0
    Set-Reg $script:POWER 'S0AutoPowerDownTimer' DWord 0
    Set-Reg $script:POWER 'CpuComputeEfficiencyEnabled' DWord 1
    Set-Reg $script:POWER 'CpuBusyBudgeting' DWord 0
    Set-Reg $script:POWER 'UnifiedStackPolicy' DWord 0
    Set-Reg $script:POWER 'FastS4' DWord 0
    Set-Reg $script:POWER 'HiberFileEnabled' DWord 0
    Set-Reg "$script:POWER\PowerThresholds" 'AcThermalScalingRatio' DWord 0
    Set-Reg "$script:POWER\PowerThresholds" 'DcThermalScalingRatio' DWord 0
    Set-Reg "$script:POWER\PowerThresholds" 'AcLineStatus' DWord 1
    Set-Reg "$script:POWER\PowerThresholds" 'BatteryFlag' DWord 0
    Set-Reg "$script:POWER\PowerSettings" 'DefaultPowerSchemeValues' Binary '000000'
}


function Set-PerfCounters {
    # 30. PERFORMANCE COUNTERS / PERFLIB / ACPI / PARTMGR / WHEA (+ intermediate re-applies)
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\PerfData' 'Disable Performance Counters' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\PerfData' 'ForceSingleDPC' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\PerfData' 'BufferSize' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib' 'Disable Performance Counters' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib' 'ExtensibleCounters' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009' 'Collect Timeout' DWord 0
    # ACPI MSI / interrupt syntax
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\ACPI\Parameters' 'EnableMsi' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\ACPI\Parameters' 'InterruptSyntax' DWord 0
    # Partmgr staggered spin watches
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\partmgr' 'StaggeredSpinWatches' DWord 0
    # WHEA polling / offline off
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\WHEA\Policy' 'DisableMCAPolling' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\WHEA\Policy' 'DisableOffline' DWord 1
    # MMCSS (re-apply)
    Set-Reg $script:MMCSS 'SystemResponsiveness' DWord 0
    Set-Reg $script:MMCSS 'NoLazyMode' DWord 1
    Set-Reg $script:MMCSS 'LazyModeTimeout' DWord 10000
    Set-Reg "$script:MMCSS\Tasks\Games" 'Network Throttling Index' DWord 4294967295
    # GraphicsDrivers / Direct3D (re-apply)
    Set-Reg $script:GD 'HwSchMode' DWord 2
    Set-Reg $script:GD 'DpiMapIommuContiguous' DWord 1
    Set-Reg $script:GD 'MaximumFrameLatency' DWord 1
    Set-Reg $script:GD 'CS_Disable' DWord 1
    Set-Reg $script:GD 'D3D9AsyncQueue' DWord 1
    Set-Reg $script:GD 'TdrDelay' DWord 10
    Set-Reg $script:GD 'TdrDdiDelay' DWord 10
    Set-Reg $script:GD 'FSE_Enable' DWord 0
    Set-Reg $script:GDS 'VsyncCpuThreadPriority' DWord 15
    Set-Reg $script:GDS 'ThreadPriority' DWord 31
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Direct3D' 'FeatureTestControl' DWord 113
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Direct3D' 'DisableDriverManagement' DWord 1
    # Memory Management (re-apply)
    Set-Reg $script:MM 'LargeSystemCache' DWord 1
    Set-Reg $script:MM 'SecondLevelDataCache' DWord 0
    Set-Reg $script:MM 'PoolUsageMaximum' DWord 60
    Set-Reg $script:MM 'IoPageLockLimit' DWord 67108864
    Set-Reg $script:MM 'DisablePagingExecutive' DWord 1
    Set-Reg $script:MM 'DisableDriverPaging' DWord 1
    Set-Reg $script:MM 'DisableKernelStackPaging' DWord 1
    Set-Reg $script:MM 'DisablePagingOfKernelStacks' DWord 1
    Remove-RegValue $script:MM 'ThirdLevelDataCache'
    # Explorer / ControlPanel
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' 'StartupDelay' DWord 0
    # PowerCfg GPU
    Invoke-Exe 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_GRAPHICS', 'GPUPREFERENCE', '1')
    Invoke-Exe 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_GRAPHICS', 'GPUPOWER', '100')
    Invoke-Exe 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_GRAPHICS', 'GPUPREFERENCE', '1')
    Invoke-Exe 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_GRAPHICS', 'GPUPOWER', '100')
    Invoke-Exe 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT')
}


function Disable-VbsSecurity {
    # 31a. VBS / HVCI / CREDENTIAL GUARD / SYSTEM GUARD + FAST STARTUP / TRIM / COMPACTOS / AHCI
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard' 'Enabled' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\KernelShadowStacks' 'Enabled' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\SystemGuard' 'Enabled' DWord 0
    # fast startup / hibernation / timer coalescing
    Set-Reg $script:SMPOWER 'HiberbootEnabled' DWord 0
    Set-Reg $script:POWER 'HibernateEnabled' DWord 0
    Set-Reg $script:SMPOWER 'CoalescingTimerInterval' DWord 0
    # storage / TRIM / Compact OS / AHCI
    Invoke-Exe 'fsutil.exe' @('behavior', 'set', 'DisableDeleteNotify', '0')
    Invoke-Exe 'compact.exe' @('/compactos:never')
    $ahci = 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device'
    Set-Reg $ahci 'EnableHIPM' DWord 0
    Set-Reg $ahci 'EnableDIPM' DWord 0
    Set-Reg $ahci 'IdlePowerMode' DWord 0
    Set-Reg $ahci 'DisableIdlePowerManagement' DWord 1
    # GameDVR / fullscreen optimizations (re-apply)
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' DWord 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' DWord 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags' DWord 0
    # Game Mode off
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'GameModeEnabled' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'GameModeEnabled' DWord 0
    # driver searching off
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' 'InstallEveryDevice' DWord 0
    # quick machine recovery off
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Recovery' 'QuickMachineRecoveryEnabled' DWord 0
}


function Block-WindowsUpdate {
    # 31b/31.2/31.3. WINDOWS UPDATE + STORE BLOCK
    # --- 31.2 intermediate restore/override ---
    Set-ServiceStartValue 'wuauserv' 3
    Set-ServiceStartValue 'UsoSvc' 2
    Set-ServiceStartValue 'BITS' 2
    Set-ServiceStartValue 'WaaSMedicSvc' 3
    $wuPolicies = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    Remove-RegValue $wuPolicies 'DisableWindowsUpdateAccess'
    Remove-RegValue $wuPolicies 'DeferUpdatePeriod'
    Remove-RegValue $wuPolicies 'DeferUpgrade'
    Set-Reg "$wuPolicies\AU" 'NoAutoUpdate' DWord 0
    Set-Reg "$wuPolicies\AU" 'AUOptions' DWord 2
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    Remove-RegValue $ux 'PauseFeatureUpdatesEndTime'
    Remove-RegValue $ux 'PauseFeatureUpdatesStartTime'
    Remove-RegValue $ux 'PauseQualityUpdatesEndTime'
    Remove-RegValue $ux 'PauseQualityUpdatesStartTime'
    Remove-RegValue $ux 'PauseUpdatesExpiryTime'
    Remove-RegValue $ux 'PauseUpdatesStartTime'
    Remove-RegValue $ux 'FlightSettingsMaxPauseDays'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings' 'PausedFeatureStatus' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings' 'PausedQualityStatus' DWord 0
    Set-Reg $wuPolicies 'DeferFeatureUpdates' DWord 0
    Set-Reg $wuPolicies 'DeferFeatureUpdatesPeriodInDays' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Realtime\Policies\QualityUpdate' 'DeferDays' DWord 30
    # --- 31.3 final block ---
    foreach ($svc in @('wuauserv', 'bits', 'cryptsvc', 'dosvc', 'usosvc', 'WaaSMedicSvc', 'stisvc',
                       'InstallService', 'DiagTrack', 'dmwappushservice', 'WerSvc')) {
        Stop-WindowsService $svc
    }
    Remove-ItemSilent (Join-Path $env:SystemRoot 'SoftwareDistribution')
    Remove-ItemsByPattern (Join-Path $env:SystemRoot 'system32\catroot2\*.*')
    foreach ($svc in @('wuauserv', 'usosvc', 'WaaSMedicSvc', 'bits')) { Invoke-Exe 'sc.exe' @('triggerinfo', $svc, 'delete') }
    Invoke-Exe 'sc.exe' @('triggerinfo', 'stisvc', 'start/disabled')
    foreach ($svc in @('wuauserv', 'usosvc', 'bits', 'WaaSMedicSvc', 'DoSvc', 'InstallService', 'stisvc')) {
        Set-ServiceStartType $svc 'disabled'
    }
    foreach ($svc in @('DiagTrack', 'dmwappushservice', 'WerSvc')) { Invoke-Exe 'sc.exe' @('delete', $svc) }
    if (-not (Test-Path -LiteralPath $wuPolicies)) { New-Item -Path $wuPolicies -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-Reg $wuPolicies 'DisableWindowsUpdateAccess' DWord 1
    Set-Reg "$wuPolicies\AU" 'NoAutoUpdate' DWord 1
    Set-Reg "$wuPolicies\AU" 'AUOptions' DWord 2
    Set-Reg "$wuPolicies\AU" 'SetDisableUXWUAccess' DWord 0
    Set-Reg "$wuPolicies\AU" 'NoAutoRebootWithLoggedOnUsers' DWord 1
    foreach ($svc in @('wuauserv', 'usosvc', 'bits', 'WaaSMedicSvc', 'DoSvc', 'stisvc')) {
        Set-ServiceStartValue $svc 4
    }
    # pause updates until 2099
    Set-Reg $ux 'PauseUpdatesExpiryTime' String '2099-12-31T23:59:59Z'
    Set-Reg $ux 'PauseUpdatesStartTime' String '2026-01-01T00:00:00Z'
    Set-Reg $ux 'PauseFeatureUpdatesStartTime' String '2026-01-01T00:00:00Z'
    Set-Reg $ux 'PauseQualityUpdatesStartTime' String '2026-01-01T00:00:00Z'
    Set-Reg $ux 'PauseFeatureUpdatesEndTime' String '2099-12-31T23:59:59Z'
    Set-Reg $ux 'PauseQualityUpdatesEndTime' String '2099-12-31T23:59:59Z'
    Set-Reg $ux 'PauseUpdatesRequested' DWord 1
    Set-Reg $ux 'IsExpanded' DWord 1
    # Windows Store block
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'RemoveWindowsStore' DWord 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun' '1' String 'StoreDesktopExtension.exe'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'DisallowRun' DWord 1
    Invoke-Exe 'taskkill.exe' @('/f', '/im', 'StoreDesktopExtension.exe')
    # service key permissions (Everyone full control + Start=4)
    foreach ($svc in @('wuauserv', 'stisvc', 'WaaSMedicSvc')) {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $svc
        if (Test-Path -LiteralPath $path) {
            $acl = Get-Acl -Path $path
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule('Everyone', 'FullControl', 'Allow')
            $acl.SetAccessRule($rule)
            Set-Acl -Path $path -AclObject $acl
            Set-ItemProperty -Path $path -Name 'Start' -Value 4
        }
    }
}


function Block-WindowsUpdateFiles {
    # 32. WU BINARY ACLs / RENAMES (takeown / icacls / ren)
    foreach ($file in @('waasmedicagent.exe', 'USOClient.exe')) {
        $p = Join-Path $env:SystemRoot ('System32\' + $file)
        if (Test-Path -LiteralPath $p) {
            Invoke-Exe 'takeown.exe' @('/f', $p, '/a')
            Invoke-Exe 'icacls.exe' @($p, '/reset')
            Invoke-Exe 'icacls.exe' @($p, '/deny', 'everyone:(X)')
        }
    }
    foreach ($file in @('wuaueng.dll', 'wuaserv.dll', 'waasmedicsvc.dll', 'wiaservc.dll', 'wlidcli.dll')) {
        $p = Join-Path $env:SystemRoot ('System32\' + $file)
        if (Test-Path -LiteralPath $p) {
            Invoke-Exe 'takeown.exe' @('/f', $p, '/a')
            Invoke-Exe 'icacls.exe' @($p, '/grant', 'Administrators:F')
            Rename-Item -LiteralPath $p -NewName ($file + '.bak') -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-HostsBlock {
    # 33. HOSTS - WINDOWS UPDATE / MICROSOFT DOMAIN BLOCK
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hostsPath)) { return }
    Invoke-Exe 'attrib.exe' @('-r', $hostsPath)
    $content = ''
    try { $content = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction Stop } catch { }
    if ($content -notmatch 'windowsupdate\.com') {
        Add-Content -LiteralPath $hostsPath -Encoding ASCII -ErrorAction SilentlyContinue -Value @(
            '127.0.0.1 microsoft.com'
            '127.0.0.1 *.microsoft.com'
            '127.0.0.1 windowsupdate.com'
            '127.0.0.1 *.windowsupdate.com'
            '127.0.0.1 windows.com'
            '127.0.0.1 ://microsoft.com'
        )
    }
    Invoke-Exe 'attrib.exe' @('+r', $hostsPath)
}


function Remove-OneDrive {
    # 34. ONEDRIVE - REMOVAL AND CLEANUP
    $setup = Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'
    if (-not (Test-Path -LiteralPath $setup)) { $setup = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe' }
    if (Test-Path -LiteralPath $setup) { Invoke-Exe $setup @('/uninstall') }
    Remove-ItemSilent (Join-Path $env:USERPROFILE 'OneDrive')
    Remove-ItemSilent (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive')
    Remove-ItemSilent (Join-Path $env:PROGRAMDATA 'Microsoft OneDrive')
    Remove-RegKey 'HKCU:\Software\Microsoft\OneDrive'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' DWord 1
    Set-Reg 'HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' 'System.IsPinnedToNameSpaceTree' DWord 0
    Set-Reg 'HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' 'System.IsPinnedToNameSpaceTree' DWord 0
    Remove-RegKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    Remove-RegKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{04271989-C4D2-9950-BDF1-DD622415241E}'
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\DelegateFolders\{F02C1A0D-BE21-4350-88B0-7367FC96EFF3}' -Force -ErrorAction SilentlyContinue | Out-Null
}


function Clear-TempFiles {
    # 35. TEMP FILE / CACHE / LOG / PREFETCH / THUMBS CLEANUP
    Remove-ItemSilent 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization'
    Invoke-Exe 'DISM.exe' @('/Online', '/Set-ReservedStorageState', '/State:Disabled')
    Remove-ItemSilent (Join-Path $env:SystemRoot 'Logs')
    Remove-ItemSilent (Join-Path $env:SystemRoot 'Installer\$PatchCache$')
    Remove-ItemSilent (Join-Path $env:SystemDrive 'OneDriveTemp')
    Remove-ItemSilent (Join-Path $env:LOCALAPPDATA 'Temp')
    Remove-ItemSilent (Join-Path $env:SystemRoot 'System32\SleepStudy')
    Remove-ItemsByPattern 'C:\Windows\Temp\*.*'
    Remove-ItemsByPattern 'C:\Windows\Prefetch\*.*'
    Remove-ItemSilent 'C:\Windows\SoftwareDistribution\Download'
    New-Item -Path 'C:\Windows\SoftwareDistribution\Download' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-ItemsByPattern (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer\thumbcache_*.db')
    Remove-ItemSilent (Join-Path $env:LOCALAPPDATA 'IconCache.db')
    Remove-ItemsByPattern (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache\*.*')
    Remove-ItemsByPattern (Join-Path $env:LOCALAPPDATA 'AMD\DXCache\*.*')
    # deep cleaning
    Remove-ItemSilent (Join-Path $env:LOCALAPPDATA 'Temp\mozilla-temp-files')
    Remove-ItemSilent (Join-Path $env:SystemRoot ('Users\' + $env:USERNAME + '\AppData\Local\Microsoft\GameDVR'))
    Remove-ItemSilent (Join-Path $env:SystemRoot ('Users\' + $env:USERNAME + '\AppData\Local\Microsoft\Edge'))
    Remove-ItemSilent (Join-Path $env:SystemRoot 'Windows\bcastdvr')
    Remove-ItemSilent (Join-Path $env:SystemRoot 'Windows\GameBarPresenceWriter')
    Remove-ItemSilent (Join-Path $env:SystemRoot 'System32\GameBarPresenceWriter')
    Remove-ItemsByPattern 'C:\Windows\Logs\*.log'
    Remove-ItemsByPattern 'C:\Windows\inf\*.log'
    Remove-ItemsByPattern 'C:\ProgramData\Microsoft\Windows\WER\*.*'
    Remove-ItemSilent 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive'
    Remove-ItemSilent 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue'
    Remove-ItemsByPattern (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache\*')
    Remove-ItemsByPattern (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles\*.default\cache2\*')
    Remove-ItemsByPattern (Join-Path $env:APPDATA 'Microsoft\Windows\Recent\*')
    Remove-ItemSilent (Join-Path $env:APPDATA 'Discord\Cache')
    Remove-ItemSilent (Join-Path $env:APPDATA 'Discord\Code Cache')
    Remove-ItemSilent (Join-Path $env:SystemDrive '$GetCurrent')
    Remove-ItemSilent (Join-Path $env:SystemDrive '$Windows.~BT')
    Remove-ItemSilent (Join-Path $env:SystemDrive '$Windows.~WS')
    Remove-ItemsByPattern 'C:\Windows\System32\DriverStore\FileRepository\*.tmp'
    Remove-ItemsByPattern 'C:\Windows\System32\DriverStore\FileRepository\*.log'
    Remove-ItemsByPattern 'C:\Windows\panther\*.*'
    Remove-ItemSilent 'C:\Windows\panther'
    Remove-ItemSilent (Join-Path $env:SystemRoot 'inf\setupapi.dev.log')
    Remove-ItemSilent (Join-Path $env:SystemRoot 'inf\setupapi.setup.log')
    Remove-ItemsByPattern (Join-Path $env:SystemRoot 'System32\DriverStore\Temp\*.*')
}


function Set-PowerPlanConfig {
    # 36. POWER PLAN / MONITOR / SLEEP
    Invoke-Exe 'powercfg.exe' @('/change', 'monitor-timeout-ac', '0')
    Invoke-Exe 'powercfg.exe' @('/change', 'monitor-timeout-dc', '0')
    Invoke-Exe 'powercfg.exe' @('/change', 'standby-timeout-ac', '0')
    Invoke-Exe 'powercfg.exe' @('/change', 'standby-timeout-dc', '0')
    Invoke-Exe 'powercfg.exe' @('-setactive', 'SCHEME_CURRENT')
}

function Remove-ScheduledTasks {
    # 37. SCHEDULED TASKS - DELETE
    foreach ($task in @(
        'MicrosoftEdgeUpdateTaskMachineUA',
        'MicrosoftEdgeUpdateTaskMachineCore',
        'MicrosoftEdgeUpdateBrowserReplacementServer',
        'Microsoft\Windows\Maps\MapsUpdateTask',
        'Microsoft\Windows\Maps\MapsToastTask',
        'Microsoft\Windows\Shell\FamilySafetyMonitor',
        'Microsoft\Windows\Shell\FamilySafetyRefreshTask',
        'Microsoft\Windows\Application Experience\PcaPatchDbTask')) {
        Invoke-Exe 'schtasks.exe' @('/delete', '/tn', $task, '/f')
    }
}


function Set-LocationPrivacy {
    # 38. LOCATION / SENSORS / MICROPHONE / APP PRIVACY
    Set-ServiceStartValue 'lfsvc' 4
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' DWord 1
    Remove-RegKey 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\TriggerInfo'
    $consent = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
    Set-Reg $consent 'location' 'Value' String 'Deny'
    Set-Reg "$consent\microphone" 'Value' String 'Allow'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone' 'Value' String 'Allow'
    Set-Reg "$consent\radios" 'Value' String 'Allow'
    Set-Reg "$consent\bluetoothSync" 'Value' String 'Allow'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessMicrophone' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' DWord 1
}

function Disable-Autologgers {
    # 39. AUTOLOGGER / DIAGTRACK / DEFENDER LOGGER
    $autologger = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
    foreach ($logger in @(
        'AutoLogger-Diagtrack-Listener', 'AppModel', 'DefenderApiLogger', 'DefenderAuditLogger',
        'NtfsLog', 'UBPM', 'EventLog-Application', 'EventLog-Security', 'EventLog-System',
        'Circular Kernel Context Logger', 'ReadyBoot', 'SQMLogger', 'DiagLog', 'WdiContextLog',
        'TCPIPTrafficLogger', 'EventLog-Direct3D', 'GraphicsPerf', 'FaultTolerantHeap')) {
        Set-Reg (Join-Path $autologger $logger) 'Start' DWord 0
    }
    # DiagTrack ETL file lock
    $etlFile = 'C:\ProgramData\Microsoft\Diagnosis\ETLLogs\AutoLogger\AutoLogger-Diagtrack-Listener.etl'
    Remove-ItemsByPattern $etlFile
    New-Item -Path $etlFile -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
    Invoke-Exe 'icacls.exe' @($etlFile, '/deny', 'SYSTEM:(F)')
    Invoke-Exe 'icacls.exe' @($etlFile, '/deny', 'EVERYONE:(F)')
}


function Set-ErrorReporting {
    # 40. WINDOWS ERROR REPORTING / WER / RELIABILITY / CRASH CONTROL
    Set-ServiceStartValue 'WerSvc' 4
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'NMICrashDump' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'LogEvent' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'SendAlert' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Reliability' 'TimeStampInterval' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Reliability' 'LastAliveStamp' DWord 0
}

function Set-UiExplorer {
    # 41. UI / EXPLORER / UAC / PERSONALIZATION
    # UAC off
    $policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-Reg $policies 'ConsentPromptBehaviorAdmin' DWord 0
    Set-Reg $policies 'PromptOnSecureDesktop' DWord 0
    Set-Reg $policies 'FilterAdministratorToken' DWord 0
    Set-Reg $policies 'DelayedDesktopSwitchTimeout' DWord 0
    # Explorer tweaks
    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $advanced 'SeparateProcess' DWord 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'DesktopProcess' DWord 1
    Set-Reg $advanced 'DisablePreviewPane' DWord 1
    Set-Reg $advanced 'ListviewAlphaSelect' DWord 0
    Set-Reg $advanced 'Start_TrackDocs' DWord 0
    Set-Reg $advanced 'HideFileExt' DWord 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' DWord 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' DWord 0
    # dark theme
    $theme = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    Set-Reg $theme 'AppsUseLightTheme' DWord 0
    Set-Reg $theme 'SystemUsesLightTheme' DWord 0
    # slideshow skip
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Personalization\DesktopSlideshow' 'Skip' DWord 1
    # hide "Meet Now" / copilot
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' DWord 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'HideSCAMeetNow' DWord 1
    # no low disk space checks
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoLowDiskSpaceChecks' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'LinkResolveIgnoreLinkInfo' DWord 1
    # PCA / AppCompat off
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisablePCA' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableEngine' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags' 'AITEnable' DWord 0
    # GameBar presence writer off
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter' 'ActivationType' DWord 0
    # font smoothing / console
    Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' String '1'
    Set-Reg 'HKCU:\Console' 'VirtualTerminalLevel' DWord 0
    # remote assistance off
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' DWord 0
    # device metadata network off
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' 'PreventDeviceMetadataFromNetwork' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' DWord 1
    # maps auto update off
    Set-Reg 'HKLM:\SYSTEM\Maps' 'AutoUpdateEnabled' DWord 0
    # sensor permission state off
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' DWord 0
    # background apps / photos off
    $photoBg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\Microsoft.Windows.Photos_8wekyb3d8bbwe'
    Set-Reg $photoBg 'Disabled' DWord 1
    Set-Reg $photoBg 'DisabledByUser' DWord 1
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'Disabled' DWord 1
    # lockscreen / toast / account notifications off
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK' DWord 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' DWord 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications' 'EnableAccountNotifications' DWord 0
    # StorageSense policy
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' 'AllowStorageSenseGlobal' DWord 1
    # visual effects (first pass)
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' DWord 1
    Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' Binary '9e3e078012000000'
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' String '1'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' DWord 1
    Set-Reg 'HKCU:\Control Panel\Accessibility' 'DynamicScrollbars' DWord 1
    Set-Reg 'HKCU:\Control Panel\Desktop' 'SmoothScroll' DWord 1
}


function Set-StorageSense {
    # 42. STORAGESENSE / SERIALIZE / PAINT DESKTOP VERSION
    $policy = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    Set-Reg $policy '01' DWord 1
    Set-Reg $policy '1024' DWord 1
    Set-Reg $policy '2048' DWord 30
    Set-Reg $policy '04' DWord 1
    Set-Reg $policy '32' DWord 0
    Set-Reg $policy '02' DWord 0
    Set-Reg $policy '128' DWord 0
    Set-Reg $policy '08' DWord 0
    Set-Reg $policy '256' DWord 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'WaitForIdleState' DWord 0
    Set-Reg 'HKCU:\Control Panel\Desktop' 'PaintDesktopVersion' DWord 0
}

function Set-PagefileConfig {
    # 43. PAGEFILE / FTH / WDF
    try {
        Set-CimInstance -Query 'SELECT * FROM Win32_ComputerSystem' -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
    } catch { }
    try {
        Set-CimInstance -Query 'SELECT * FROM Win32_PageFileSetting WHERE Name="C:\\pagefile.sys"' -Property @{ InitialSize = [uint32]8192; MaximumSize = [uint32]16384 } -ErrorAction Stop
    } catch {
        try { Set-CimInstance -Query 'SELECT * FROM Win32_PageFileSetting' -Property @{ InitialSize = [uint32]8192; MaximumSize = [uint32]16384 } -ErrorAction Stop } catch { }
    }
    # Fault Tolerant Heap off
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\FTH' 'CheckPointPeriod' DWord 4294967295
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\FTH' 'CrashVelocity' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' 'DisableFTH' String '1'
    # WDF diagnostics off
    $wdf = 'HKLM:\SYSTEM\CurrentControlSet\Control\Wdf\Wdf01000'
    Set-Reg $wdf 'DbgBreakOnError' DWord 0
    Set-Reg $wdf 'LogPages' DWord 0
    Set-Reg $wdf 'VerboseOn' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Wdf\Kmdf\Diagnostics' 'RetrieveVerboseLogs' DWord 0
}


function Set-BootPnp {
    # 44. BOOT / WINDOWS / PNP / WAIT KILL SERVICE
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\BootControl' 'BootProgressAnimation' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Windows' 'NoPopupsOnBoot' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Windows' 'ErrorMode' DWord 2
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PnP' 'DisableTargetDeviceLogging' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PnP' 'DeviceActionRequests' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' String '8000'
}

function Set-BluetoothServices {
    # 45. BLUETOOTH / PERIPHERALS / LEGACY START VALUES
    $serviceStarts = @{
        'BthA2dp' = 3; 'Microsoft_Bluetooth_AvrcpTransport' = 3; 'BthMini' = 3; 'BTHPORT' = 3; 'BTHUSB' = 3
        'BthLEEnum' = 3; 'BTHMODEM' = 3; 'WSService' = 4; 'PimIndexMaintenanceSvc' = 4; 'xbgm' = 4
        'Csc' = 4; 'ossrs' = 4; 'CDPSvc' = 4; 'CDPUserSvc' = 4; 'DusmSvc' = 4; 'FDResPub' = 4
        'GpuEnergyDrv' = 4; 'AppReadiness' = 3; 'i8042prt' = 3; 'EventSystem' = 2; 'gpsvc' = 2
        'mpssvc' = 2; 'Appinfo' = 2; 'msiserver' = 3; 'DevicesFlowUserSvc' = 3; 'DsmSvc' = 3
        'DeviceAssociationService' = 3; 'PolicyAgent' = 3; 'Themes' = 4; 'SENS' = 2; 'HPOSvc' = 4
        'MidiSrv' = 4; 'IKEEXT' = 4; 'UdkUserSvc' = 4; 'whesvc' = 4; 'Netprofm' = 3
    }
    foreach ($name in $serviceStarts.Keys) { Set-ServiceStartValue $name $serviceStarts[$name] }
}


function Set-ProcessorPower {
    # 46. PROCESSOR GENERIC / POWER THROTTLING / IDLE
    $processor = 'HKLM:\SYSTEM\CurrentControlSet\Processor'
    Set-Reg $processor 'EnablePerformanceStates' DWord 1
    Set-Reg $processor 'FrequencyToPerfStateThreshold' DWord 1
    Set-Reg $processor 'IdleResidencyDuration' DWord 0
    Set-Reg $processor 'PerfBoostState' DWord 1
    Set-Reg $processor 'ResponsivenessReductionThreshold' DWord 0
    Set-Reg $processor 'CpuIdle' DWord 1
    Set-Reg $processor 'CpuIdleThread' DWord 1
    Set-Reg $processor 'ThreadThrottleAdditiveLowOffset' DWord 0
    Set-Reg $processor 'ThreadThrottleAdditiveHighOffset' DWord 0
    Set-Reg $processor 'FastThrottle' DWord 1
    Set-Reg $processor 'LatencyThrottleOffset' DWord 0
    Set-Reg $processor 'PerfAutoSmoothing' DWord 0
    Set-Reg $processor 'PerfAutoSmoothingEnabled' DWord 0
    Set-Reg $script:POWER 'PlatformAoAcOverride' DWord 0
    Set-Reg $script:POWER 'PlatformRoleOverride' DWord 0
    Set-Reg $script:POWER 'EventProcessorEnabled' DWord 0
    Set-Reg $script:POWER 'HibernateEnabledDefault' DWord 0
}


function Set-KernelTweaks {
    # 47. KERNEL / EXECUTIVE / I/O DEEP TWEAKS
    $kernel = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
    Set-Reg $kernel 'MaximumDpcStackDepth' DWord 512
    Set-Reg $kernel 'MinimumDpcRate' DWord 100
    Set-Reg $kernel 'InterruptTimerRate' DWord 0
    Set-Reg $kernel 'DpcWatchdogProfileOffset' DWord 0
    $executive = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Executive'
    Set-Reg $executive 'FastDeadlockReliance' DWord 1
    Set-Reg $executive 'ParallelProcessorMinimum' DWord 100
    Set-Reg $executive 'ForegroundQuantum' DWord 0
    Set-Reg $executive 'BackgroundQuantum' DWord 0
    Set-Reg $executive 'ThreadQuantum' DWord 0
    Set-Reg $executive 'LFH_Aggressive_Enable' DWord 1
    Set-Reg $executive 'WorkerFactoryThreadIdleTimeout' DWord 0
    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    Set-Reg $sessionManager 'HeapSegmentCommit' DWord 1048576
    Set-Reg $sessionManager 'HeapSegmentReserve' DWord 16777216
    Set-Reg $sessionManager 'Heap_ForceLFH' DWord 1
    # priority control IRQ / interrupt separation
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'IRQ12Priority' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'InterruptPrioritySeparation' DWord 4

    # GraphicsDrivers frame queue
    Set-Reg $script:GD 'MinQueueDepth' DWord 0
    Set-Reg $script:GD 'FrameQueueSize' DWord 1
    Set-Reg $script:GD 'FrameQueueDepth' DWord 1
    Set-Reg $script:GD 'FrameQueueMode' DWord 0
    Set-Reg $script:GD 'FrameQueuePolicy' DWord 0
    Set-Reg $script:GD 'FrameQueueTimeout' DWord 0
    Set-Reg $script:GD 'FrameQueueThreshold' DWord 0
    # GraphicsDrivers\Scheduler preemption off
    foreach ($value in @('EnablePreemption', 'PreemptionTimeout', 'PreemptionThreshold', 'PreemptionMode',
                         'PreemptionPolicy', 'PreemptionLevel', 'PreemptionPriority', 'PreemptionAffinity',
                         'PreemptionQuantum', 'PreemptionInterval')) {
        Set-Reg $script:GDS $value DWord 0
    }
    # Direct3D feature no-op list (all 0 - kept 1:1 from the original file)
    $d3dNoops = @(
        'DisableDXGI','DisableD3D','DisableD3D12','DisableD3D11','DisableD3D10','DisableD3D9',
        'DisableD3D8','DisableD3D7','DisableD3D6','DisableD3D5','DisableD3D4','DisableD3D3',
        'DisableD3D2','DisableD3D1','DisableDirectDraw','DisableDirectSound','DisableDirectInput',
        'DisableDirectPlay','DisableDirectShow','DisableDirectMusic','DisableDirectAnimation',
        'DisableDirect3DRM','DisableDirect3DImmediateMode','DisableDirect3DRetainedMode',
        'DisableDirect3DHardwareAbstractionLayer','DisableDirect3DReferenceRasterizer',
        'DisableDirect3DNullRasterizer','DisableDirect3DRGBRasterizer','DisableDirect3DMMXRasterizer',
        'DisableDirect3DSSE','DisableDirect3DSSE2','DisableDirect3DSSE3','DisableDirect3DSSSE3',
        'DisableDirect3DSSE41','DisableDirect3DSSE42','DisableDirect3DAVX','DisableDirect3DAVX2',
        'DisableDirect3DAVX512','DisableDirect3DFMA','DisableDirect3DFMA3','DisableDirect3DFMA4',
        'DisableDirect3DBMI1','DisableDirect3DBMI2','DisableDirect3DTBM','DisableDirect3DLZCNT',
        'DisableDirect3DPOPCNT','DisableDirect3DRDRAND','DisableDirect3DRDSEED','DisableDirect3DADX',
        'DisableDirect3DMPX','DisableDirect3DSGX','DisableDirect3DCET','DisableDirect3DIBT',
        'DisableDirect3DSS','DisableDirect3DSSB','DisableDirect3DSSBD','DisableDirect3DIBRS',
        'DisableDirect3DIBPB','DisableDirect3DIBRSAll','DisableDirect3DIBRSFixed',
        'DisableDirect3DIBRSAlwaysOn','DisableDirect3DIBRSPerf','DisableDirect3DIBRSCost',
        'DisableDirect3DIBRSBenefit','DisableDirect3DIBRSMode','DisableDirect3DIBRSPolicy',
        'DisableDirect3DIBRSThreshold','DisableDirect3DIBRSTimeout','DisableDirect3DIBRSTherm',
        'DisableDirect3DIBRSQuad','DisableDirect3DIBRSCCF','DisableDirect3DIBRSMMBTU',
        'DisableDirect3DIBRSMWh','DisableDirect3DIBRSkWh','DisableDirect3DIBRSWh',
        'DisableDirect3DIBRSmWh','DisableDirect3DIBRSuWh','DisableDirect3DIBRSnWh',
        'DisableDirect3DIBRSpWh','DisableDirect3DIBRSfWh','DisableDirect3DIBRSaWh',
        'DisableDirect3DIBRSzWh','DisableDirect3DIBRSyWh'
    )
    foreach ($value in $d3dNoops) { Set-Reg 'HKLM:\SOFTWARE\Microsoft\Direct3D' $value DWord 0 }
}



function Set-MemoryExtra {
    # 48. MEMORY MANAGEMENT EXTRAS / CACHE / HEAP / LFH
    Set-Reg $script:MM 'SystemCacheLimit' DWord 4294967295
    Set-Reg $script:MM 'VirtualizationFlags' DWord 0
}

function Optimize-DiskCache {
    # 49. DISK / NVME CACHE / PARTMGR / SCSI
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\disk' 'TimeoutValue' DWord 10
    $nvmeDisk = 'HKLM:\SYSTEM\CurrentControlSet\Enum\SCSI\Disk&Ven_NVMe\Device Parameters\Disk'
    Set-Reg $nvmeDisk 'CacheIsPowerProtected' DWord 1
    Set-Reg $nvmeDisk 'UserWriteCacheSetting' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Partmgr\Parameters' 'IoLatencyCap' DWord 1
}


function Remove-MicrosoftEdge {
    # 50. EDGE REMOVAL / TASKS / DIRECTORY
    $edgeSetup = Get-Item 'C:\Program Files (x86)\Microsoft\Edge\Application\*\Installer\setup.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($edgeSetup) {
        Start-Process -FilePath $edgeSetup.FullName -ArgumentList '--uninstall', '--system-level', '--verbose-logging', '--force-uninstall' -Wait -ErrorAction SilentlyContinue
    }
    Remove-ItemSilent 'C:\Program Files (x86)\Microsoft\EdgeUpdate'
}

function Remove-Cortana {
    # 51. CORTANA REMOVAL / WINGET
    Invoke-Exe 'winget.exe' @('uninstall', 'cortana', '--accept-source-agreements', '--accept-package-agreements')
}

function Set-FinalServices {
    # 52-53. SENSORS / APPX DEPLOYMENT / CLIPSVC / TOAST FINAL
    Set-ServiceStartValue 'SensorService' 3
    Invoke-Exe 'taskkill.exe' @('/f', '/im', 'SearchHost.exe')
    Invoke-Exe 'taskkill.exe' @('/f', '/im', 'svchost.exe', '/fi', 'SERVICES eq AppXSvc')
    Invoke-Exe 'taskkill.exe' @('/f', '/im', 'svchost.exe', '/fi', 'SERVICES eq clipsvc')
    Set-ServiceStartValue 'AppXSvc' 4
    Set-ServiceStartValue 'ClipSVC' 4
}

function Reset-DiskVerifier {
    # 54. DISK PERFORMANCE / VERIFIER RESET
    Invoke-Exe 'diskperf.exe' @('-N')
    Invoke-Exe 'verifier.exe' @('/reset')
}

function Set-IfeoAppPriority {
    # 55. IFEO - MAXIMUM PRIORITY FOR APPS / GAMES
    foreach ($exe in @('WinRAR.exe', '7zFM.exe', '7zG.exe', 'qemu-system-x86_64.exe', 'obs64.exe')) {
        Set-Reg (Get-IfeoPerfPath $exe) 'CpuPriorityClass' DWord 3
    }
    Set-Reg (Get-IfeoPerfPath 'BetGame.exe') 'WorkingSetLimitInKB' DWord 0
    Set-Reg $script:IFEO 'UseLargePages' DWord 1
}


function Optimize-CpuIntel {
    # 56a. INTEL CPU (intelppm / intelpep / HWP / turbo)
    Write-Host '  [CPU] Applying Intel CPU optimizations...' -ForegroundColor Cyan
    $ipp = 'HKLM:\SYSTEM\CurrentControlSet\Services\intelppm\Parameters'
    $iep = 'HKLM:\SYSTEM\CurrentControlSet\Services\intelpep\Parameters'
    Set-Reg $ipp 'L3_Cache_Foreground_Priority' DWord 31
    Set-Reg $ipp 'Cache_QoS_Enable' DWord 1
    Set-Reg $ipp 'LLC_ForegroundMonopoly' DWord 1
    Set-Reg $ipp 'IMC_Scrubber_Disable' DWord 1
    Set-Reg $ipp 'Cache_Locality_Strict' DWord 1
    Set-Reg $ipp 'CStateLimit' DWord 1
    Set-Reg $ipp 'HWP_Enable' DWord 1
    # timer-related bcdedit re-apply
    Invoke-Exe 'bcdedit.exe' @('/set', 'useplatformtick', 'yes')
    Invoke-Exe 'bcdedit.exe' @('/set', 'disabledynamictick', 'yes')
    Invoke-Exe 'bcdedit.exe' @('/set', 'tscsyncpolicy', 'enhanced')
    Set-Reg $ipp 'Boost_Policy' DWord 1
    Set-Reg $ipp 'SamplingInterval' DWord 0
    Set-Reg $ipp 'IMC_Power_Down_Enable' DWord 0
    Set-Reg $ipp 'IMC_Opportunistic_Refresh_Disable' DWord 1
    Set-Reg $ipp 'Ring_Bus_Priority_Mode' DWord 1
    Set-Reg $ipp 'ThermalThrottlingSoftwareDisable' DWord 1
    Set-Reg $ipp 'MinPerformance' DWord 100
    Set-Reg $ipp 'AutonomousCurrentLimitDisable' DWord 1
    Set-Reg $ipp 'LatencyToleranceValue' DWord 0
    Set-Reg $ipp 'RingBusPriority' DWord 1
    Set-Reg $ipp 'InterruptToleranceValue' DWord 0
    # extra HWP / Speed Shift
    Set-Reg $ipp 'HWP_Interrupt_Mode' DWord 1
    Set-Reg $ipp 'HWP_Time_Window' DWord 0
    Set-Reg $ipp 'HWP_PerformanceSetting' DWord 1
    # extra turbo
    Set-Reg $ipp 'EnableTurboBoost' DWord 1
    Set-Reg $ipp 'TurboMode' DWord 1
    # extra Intel PEP / PCIe power saving
    Set-Reg $iep 'DisableD3Hot' DWord 1
    Set-Reg $iep 'DisableRuntimePowerManagement' DWord 1
    Set-Reg $iep 'DisableL1Substates' DWord 1
    Set-Reg $iep 'DisableAspm' DWord 1
    foreach ($profile in @('Brighten Movie', 'Darken Movie', 'Enhance Movie', 'Preserve Details')) {
        Set-Reg ('HKLM:\SOFTWARE\Intel\Display\igfxcui\profiles\Media\' + $profile) 'DPST' DWord 0
    }
    # HWP request tuning
    Set-Reg $ipp 'HWP_Request_Desired_Performance' DWord 255
    Set-Reg $ipp 'HWP_Request_Minimum_Performance' DWord 8
    Set-Reg $ipp 'HWP_Request_Maximum_Performance' DWord 255
    Set-Reg $ipp 'HWP_Request_Energy_Performance_Preference' DWord 0
    Set-Reg $ipp 'HWP_Request_Autonomous_Activity_Window' DWord 0
    Set-Reg $ipp 'HWP_Request_Autonomous_EPP' DWord 0
    Set-Reg $ipp 'HWP_Lowest_Frequency' DWord 800
    Set-Reg $ipp 'HWP_Highest_Frequency' DWord 4200
    Set-Reg $ipp 'HWP_Time_Window' DWord 0
    Set-Reg $ipp 'HWP_Request_Response' DWord 0

    # Processor\Power
    $procPower = 'HKLM:\SYSTEM\CurrentControlSet\Control\Processor\Power'
    Set-Reg $procPower 'MaxThrottleCapacity' DWord 100
    Set-Reg $procPower 'PerfState' DWord 0
    Set-Reg $procPower 'ThermalThrottle' DWord 0
    # intelpep S0 sensor disables
    foreach ($value in @(
        'DisableS0LidOpen','DisableS0ACPower','DisableS0DCPower','DisableS0Battery','DisableS0Thermal',
        'DisableS0Fan','DisableS0Cooling','DisableS0Heating','DisableS0Humidity','DisableS0Pressure',
        'DisableS0Altitude','DisableS0Light','DisableS0Proximity','DisableS0Orientation','DisableS0Location',
        'DisableS0Gyroscope','DisableS0Accelerometer','DisableS0Magnetometer','DisableS0Compass',
        'DisableS0Barometer','DisableS0AmbientLight','DisableS0RGBLight','DisableS0IRLight',
        'DisableS0UVLight','DisableS0XRay','DisableS0GammaRay')) {
        Set-Reg $iep $value DWord 1
    }
    Set-Reg $iep 'DisableLtr' DWord 1
    Set-Reg $iep 'PkgCStateLimit' DWord 0
    Set-Reg $iep 'TimerCoalescingEnable' DWord 0
    Set-Reg $iep 'S0LowPowerIdle' DWord 0
    Set-Reg $iep 'AutonomousCStateEnable' DWord 0
    Set-Reg $iep 'TransitDelay' DWord 0
    Set-Reg $iep 'PciePowerGatingEnable' DWord 0
    Set-Reg $iep 'AutonomousPowerStatesDisable' DWord 1
    Set-Reg $iep 'PerformanceBias' DWord 0
    # mitigation override (re-apply)
    Set-Reg $script:MM 'FeatureSettingsOverride' DWord 3
    Set-Reg $script:MM 'FeatureSettingsOverrideMask' DWord 3
    # final HWP / EPP pass
    Set-Reg $ipp 'HWP_EPP' DWord 0
    Set-Reg $ipp 'PerfBoostMode' DWord 2
    Set-Reg $ipp 'AllowThrottling' DWord 0
    Set-Reg $ipp 'BackgroundPriority' DWord 0
    Set-Reg $ipp 'HWP_Activity_Window' DWord 0
    Set-Reg $iep 'RootComplex_VC1_Enable' DWord 1
    Set-Reg $iep 'EnableD3Cold' DWord 0
    Set-Reg $iep 'DisableLtr' DWord 1
}

function Invoke-CpuPhase {
    # 56. HARDWARE PHASE - CPU DETECTION (Intel / AMD)
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $cpuVendor = 'Unknown'
    if ($cpu -and $cpu.Manufacturer -match 'GenuineIntel') { $cpuVendor = 'Intel' }
    elseif ($cpu -and $cpu.Manufacturer -match 'AuthenticAMD') { $cpuVendor = 'AMD' }
    Write-Host ("  CPU detected: " + $cpuVendor) -ForegroundColor Cyan
    if ($cpuVendor -eq 'Intel') { Optimize-CpuIntel }
    elseif ($cpuVendor -eq 'AMD') { Write-Host '  [CPU] No AMD CPU tweaks in the original file - skipping.' -ForegroundColor Gray }
    else { Write-Host '  [CPU] Unknown CPU vendor - no vendor-specific tweaks applied.' -ForegroundColor Gray }
}



function Optimize-GpuIntel {
    # 57a. INTEL GPU (GFX_KEY / GMM / igfx + dynamic instance loop)
    Write-Host '  [GPU-INTEL] Applying Intel GPU optimizations...' -ForegroundColor Cyan
    $gmm = 'HKLM:\SOFTWARE\Intel\GMM'
    # display engine / power / compression values (GFX_KEY)
    $k = $script:GFXKEY
    Set-Reg $k 'PowerDpstAggressivenessLevel' DWord 0
    Set-Reg $k 'PowerThrottlingOff' DWord 1
    Set-Reg $k 'UnderRunCountPipeA' DWord 0
    Set-Reg $k 'Disable_OverlayDSQualityEnhancement' DWord 1
    Set-Reg $k 'PowerPolicy' DWord 0
    Set-Reg $k 'RuntimePowerManagementEnabled' DWord 0
    Set-Reg $k 'FbcEnable' DWord 0
    Set-Reg $k 'FlipQueueSize' DWord 1
    Set-Reg $k 'AdaptiveTessellation' DWord 0
    Set-Reg $k 'ShaderCacheSize' DWord 15
    Set-Reg $k 'AnisotropicFilteringMode' DWord 0
    Set-Reg $k 'UserPowerMode' DWord 3
    Set-Reg $k 'RenderStandby' DWord 0
    Set-Reg $k 'DisableRenderStandby' DWord 1
    Set-Reg $k 'DirectXHardwareAcceleration' DWord 1
    Set-Reg $k 'DisableVideoEnhancement' DWord 1
    Set-Reg $k 'TextureCacheOptimization' DWord 1
    Set-Reg $k 'ForceIntelTurbo' DWord 1
    Set-Reg $k 'RingBufferSize' DWord 1024
    Set-Reg $k 'DisableAsyncFlip' DWord 1
    Set-Reg $k 'DisableTripleBuffering' DWord 1
    Set-Reg $k 'VSyncControl' DWord 0
    Set-Reg $k 'DisablePFonDP' DWord 1
    Set-Reg $k 'DisablePSR' DWord 1
    Set-Reg $k 'PSREnable' DWord 0
    Set-Reg $k 'PSR_Enable' DWord 0
    Set-Reg $k 'DisableDisplayCaching' DWord 1
    Set-Reg $k 'DisableMemoryCompression' DWord 1
    Set-Reg $k 'DisableRC6' DWord 1
    Set-Reg $k 'RC6Disable' DWord 1
    Set-Reg $k 'DisableMediaPowerSaving' DWord 1
    Set-Reg $k 'MediaPowerSaving' DWord 0
    Set-Reg $k 'DisableDisplayPowerSaving' DWord 1
    Set-Reg $k 'DisableDynamicFrequencyScaling' DWord 1

    # clocks / compression / post processing
    Set-Reg $k 'MaxGPUClockFrequency' DWord 1350
    Set-Reg $k 'MinGPUClockFrequency' DWord 300
    Set-Reg $k 'GPUClockFrequency' DWord 1350
    Set-Reg $k 'EnableTurbo' DWord 1
    Set-Reg $k 'DisableFrameBufferCompression' DWord 1
    Set-Reg $k 'DisableLosslessCompression' DWord 1
    Set-Reg $k 'DisableCompression' DWord 1
    Set-Reg $k 'TextureFilteringQuality' DWord 0
    Set-Reg $k 'AntiAliasingMode' DWord 0
    Set-Reg $k 'DisablePostProcessing' DWord 1
    Set-Reg $k 'DisableVideoProcessing' DWord 1
    Set-Reg $k 'DisableImageProcessing' DWord 1
    Set-Reg $k 'DisableDisplayEnhancement' DWord 1
    Set-Reg $k 'DisableAdaptiveContrast' DWord 1
    Set-Reg $k 'AdaptiveContrastEnable' DWord 0
    Set-Reg $k 'DisableDynamicContrast' DWord 1
    Set-Reg $k 'DisableDynamicBrightness' DWord 1
    Set-Reg $k 'DisableAmbientLightSensor' DWord 1
    Set-Reg $k 'DisableALS' DWord 1
    Set-Reg $k 'DisableFBC' DWord 1
    Set-Reg $k 'DisableDynamicFBC' DWord 1
    Set-Reg $k 'ConservativeMorphologicalAntiAliasing' DWord 0
    Set-Reg $k 'EuThreadPriority' DWord 31
    Set-Reg $k 'RCPriority' DWord 31
    Set-Reg $k 'ContextPriority' DWord 31
    Set-Reg $k 'DisableDMACopy' DWord 1
    # power states
    Set-Reg $k 'DisablePowerState0' DWord 0
    foreach ($i in 1..15) { Set-Reg $k "DisablePowerState$i" DWord 1 }
    Set-Reg $k 'DisplayPowerSavingTechnology' DWord 0
    Set-Reg $k 'EnablePowerGating' DWord 0
    Set-Reg $k 'CmaaEnable' DWord 0
    Set-Reg $k 'ColorEnhancement' DWord 0
    Set-Reg $k 'EnableDynamicRefreshRate' DWord 0
    Set-Reg $k 'PowerDpstAggressivenessLevel' DWord 0
    Set-Reg $k 'DynamicVidMemoryControl' DWord 0
    Set-Reg $k 'GfxDynamicPstate' DWord 0
    Set-Reg $k 'DisableDynamicClock' DWord 1
    Set-Reg $k 'EnableOverclock' DWord 1
    Set-Reg $k 'DisableTextureCompression' DWord 1
    Set-Reg $k 'IncreaseFixedSegment' DWord 1
    Set-Reg $k 'RenderAheadLimit' DWord 1
    Set-Reg $k 'TextureMemorySize' DWord 2048
    Set-Reg $k 'RmDisableRegistryCaching' DWord 1
    # GFX_KEY interrupt management
    Set-Reg "$k\Interrupt Management\MessageSignaledInterruptProperties" 'MSISupported' DWord 1
    Set-Reg "$k\Interrupt Management\MessageSignaledInterruptProperties" 'MessageNumberLimit' DWord 2048
    Set-Reg "$k\Interrupt Management\Affinity Policy" 'DevicePriority' DWord 3
    Set-Reg "$k\Interrupt Management\Affinity Policy" 'ThreadPriority' DWord 31

    # Intel GMM (graphics memory manager)
    Set-Reg $gmm 'GmmPageTableSize' DWord 4194304
    Set-Reg $gmm 'GmmPageTablePoolSize' DWord 1048576
    Set-Reg $gmm 'GmmResourceCacheSize' DWord 268435456
    Set-Reg $gmm 'GmmCacheSize' DWord 536870912
    Set-Reg $gmm 'GmmCachePolicy' DWord 1
    Set-Reg $gmm 'GmmEvictionPolicy' DWord 0
    Set-Reg $gmm 'GmmDefragPolicy' DWord 1
    Set-Reg $gmm 'GmmDefragEnable' DWord 1
    Set-Reg $gmm 'GmmReclaimEnable' DWord 0
    Set-Reg $gmm 'GmmReclaimPolicy' DWord 0
    Set-Reg $gmm 'GmmPageTablePinned' DWord 1
    Set-Reg $gmm 'SchedulerPriority' DWord 1
    Set-Reg $gmm 'GmmContiguousMemoryRequired' DWord 1
    Set-Reg $gmm 'LowLatencyAllocations' DWord 1
    Set-Reg $gmm 'DisableGmmDelay' DWord 1
    Set-Reg $gmm 'AggressiveGarbageCollection' DWord 1
    Set-Reg $gmm 'SegmentAllocationPolicy' DWord 1
    Set-Reg $gmm 'DedicatedSegmentSize' DWord 2048
    Set-Reg $gmm 'UseLargePages' DWord 1
    Set-Reg $gmm 'EnableAggressiveMemoryReclaim' DWord 0
    Set-Reg $gmm 'MinFreeMemoryPool' DWord 256
    Set-Reg $gmm 'MaxFreeMemoryPool' DWord 512
    Set-Reg $gmm 'MemoryPoolPolicy' DWord 1
    # igfx service
    $igfx = 'HKLM:\SYSTEM\CurrentControlSet\Services\igfx'
    foreach ($value in @('DisablePowerManagement', 'DisableDynamicClock', 'DisableDeepSleep', 'DisableStandby',
                         'DisableHibernate', 'DisableSleep', 'DisablePowerButton', 'DisableLidClose',
                         'DisableLidOpen', 'DisableACPower', 'DisableStau', 'DisableSquark',
                         'DisableSlepton', 'DisableSfermion', 'DisableSboson')) {
        Set-Reg $igfx $value DWord 1
    }
    Set-Reg $igfx 'ThreadPriority' DWord 31
    Set-Reg "$igfx\Parameters" 'DisablePowerSaving' DWord 1
    Set-Reg "$igfx\Parameters" 'DisableDynamicClock' DWord 0
    # Intel display profiles
    foreach ($profile in @('Brighten Movie', 'Darken Movie', 'Enhance Movie', 'Preserve Details')) {
        Set-Reg ('HKLM:\SOFTWARE\Intel\Display\igfxcui\profiles\Media\' + $profile) 'DPST' DWord 0
    }
    Set-Reg 'HKLM:\SOFTWARE\Intel\Display\igfxcui\profiles\Device\Vulkan' 'DisableValidation' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Intel\Display\igfxcui\profiles\Device\Vulkan' 'PreferSystemMemoryContiguous' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Intel\Display\igfxcui\profiles\Device\OpenGL' 'DisablePFonDP' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Intel\Display\igfxcui\profiles\Device\OpenGL' 'FlipQueueSize' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\Intel\Display\igfxcui\profiles\Device\OpenGL' 'ThreadedOptimization' DWord 1
    # intelpep / intelppm extras
    $iep = 'HKLM:\SYSTEM\CurrentControlSet\Services\intelpep\Parameters'
    $ipp = 'HKLM:\SYSTEM\CurrentControlSet\Services\intelppm\Parameters'
    Set-Reg $iep 'DisablePchClockGating' DWord 1
    Set-Reg $iep 'DisablePchPmClockGating' DWord 1
    Set-Reg $iep 'DmiLinkPriority' DWord 3
    Set-Reg $iep 'PkgCStateLimit' DWord 0
    Set-Reg $iep 'TimerCoalescingEnable' DWord 0
    Set-Reg $iep 'S0LowPowerIdle' DWord 0
    Set-Reg $iep 'AutonomousCStateEnable' DWord 0
    Set-Reg $iep 'TransitDelay' DWord 0
    Set-Reg $iep 'PciePowerGatingEnable' DWord 0
    Set-Reg $ipp 'ApmEnable' DWord 0
    Set-Reg $ipp 'HWP_Ignore_Platform_Limits' DWord 1
    Set-Reg $ipp 'Boost_Policy' DWord 1
    Set-Reg $ipp 'SamplingInterval' DWord 0
    Set-Reg $ipp 'IMC_Power_Down_Enable' DWord 0
    Set-Reg $ipp 'IMC_Opportunistic_Refresh_Disable' DWord 1
    Set-Reg $ipp 'Ring_Bus_Priority_Mode' DWord 1
    Set-Reg $ipp 'ThermalThrottlingSoftwareDisable' DWord 1
    Set-Reg $ipp 'MinPerformance' DWord 100

    # global re-applies tied to the Intel GPU block
    foreach ($task in @('Scheduling Category', 'SFIO Priority')) { Set-Reg "$script:MMCSS\Tasks\Games" $task String 'High' }
    Set-Reg "$script:MMCSS\Tasks\Games" 'Background Only' String 'False'
    Set-Reg $script:GDS 'VsyncCpuThreadPriority' DWord 15
    Set-Reg $script:GDS 'ThreadPriority' DWord 31
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Direct3D' 'FeatureTestControl' DWord 113
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Direct3D' 'DisableDriverManagement' DWord 1
    Set-Reg $script:GD 'HwSchMode' DWord 2
    Set-Reg $script:GD 'MaximumFrameLatency' DWord 1
    Set-Reg $script:GD 'D3D9AsyncQueue' DWord 1
    Set-Reg $script:GD 'TdrDelay' DWord 10
    Set-Reg $script:GD 'TdrDdiDelay' DWord 10
    Set-Reg $script:GD 'CS_Disable' DWord 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\501a4d13-42af-4429-95c4-324a7d577775\ee12f2c1-9844-474d-987a-928659de2989' 'Attributes' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' 'StartupDelay' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' DWord 40
    Set-Reg $script:MM 'LargeSystemCache' DWord 1
    Set-Reg $script:MM 'SecondLevelDataCache' DWord 0
    Remove-RegValue $script:MM 'ThirdLevelDataCache'
    Set-Reg $script:MM 'PoolUsageMaximum' DWord 60
    Set-Reg $script:MM 'IoPageLockLimit' DWord 16777216
    Set-Reg $script:MM 'IoPageLockLimit' DWord 67108864
    # powercfg GPU
    Invoke-Exe 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_GRAPHICS', 'GPUPREFERENCE', '1')
    Invoke-Exe 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_GRAPHICS', 'GPUPOWER', '100')
    Invoke-Exe 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_GRAPHICS', 'GPUPREFERENCE', '1')
    Invoke-Exe 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_GRAPHICS', 'GPUPOWER', '100')
    Invoke-Exe 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT')
    # dynamic Intel instance enumeration
    Write-Host '  [GPU-INTEL] Searching Intel instances dynamically...' -ForegroundColor Gray
    $intelFound = $false
    $instances = Get-ChildItem -Path $script:GFXCLASS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }
    foreach ($instance in $instances) {
        $desc = (Get-ItemProperty -LiteralPath $instance.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
        if ($desc -match 'Intel') {
            $intelFound = $true
            Set-Reg $instance.PSPath 'AllowDeepSleep' DWord 0
            Set-Reg $instance.PSPath 'DisablePowerGating' DWord 1
            Set-Reg $instance.PSPath 'RenderStandby' DWord 0
            Set-Reg $instance.PSPath 'DPSTEnable' DWord 0
            Set-Reg $instance.PSPath 'DisableDynamicClock' DWord 1
            Set-Reg $instance.PSPath 'EnableOverclock' DWord 1
            Set-Reg $instance.PSPath 'DisableTextureCompression' DWord 1
            Set-Reg $instance.PSPath 'MaxClockFrequency' DWord 1350
            Set-Reg $instance.PSPath 'PreferSystemMemoryContiguous' DWord 1
            Set-Reg $instance.PSPath 'IncreaseFixedSegment' DWord 1
            $msiKey = Join-Path $instance.PSPath 'Interrupt Management\MessageSignaledInterruptProperties'
            Set-Reg $msiKey 'MSISupported' DWord 1
            Set-Reg $msiKey 'MessageNumberLimit' DWord 2048
        }
    }
    if (-not $intelFound) { Write-Host '  [WARNING] No Intel GPU instance found in the dynamic loop.' -ForegroundColor Yellow }
}





function Optimize-GpuNvidia {
    # 57b. NVIDIA GPU (NVTweak / nvlddmkm + dynamic instance loop)
    Write-Host '  [GPU-NVIDIA] Applying NVIDIA GPU optimizations...' -ForegroundColor Cyan
    # VRAM detection (same WMI approach as the original; AdapterRAM caps at 4 GB)
    $vramMb = 8192
    $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if ($gpu -and $gpu.AdapterRAM) { $vramMb = [math]::Round($gpu.AdapterRAM / 1MB) }
    if (-not $vramMb -or $vramMb -le 0) { $vramMb = 8192 }
    Write-Host ("  [GPU-NVIDIA] Detected VRAM: {0} MB" -f $vramMb) -ForegroundColor Cyan

    $nvtweakHkcu = 'HKCU:\SOFTWARE\NVIDIA Corporation\Global\NVTweak'
    $nvtweakHklm = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak'
    Set-Reg $nvtweakHkcu 'Gestalt' DWord 2
    Set-Reg $nvtweakHklm 'Gestalt' DWord 2
    Set-Reg $nvtweakHklm 'CoolBits' DWord 31
    Set-Reg $nvtweakHklm 'FlipQueueSize' DWord 1
    Set-Reg $nvtweakHklm 'ThreadedOptimization' DWord 1
    Set-Reg $nvtweakHklm 'ShaderCache' DWord 1
    Set-Reg $nvtweakHklm 'TripleBuffering' DWord 0
    Set-Reg $nvtweakHklm 'OpenGLShaders' DWord 1
    Set-Reg $nvtweakHklm 'DisableOptimusBatteryPolicy' DWord 1
    Set-Reg $nvtweakHklm 'OptimusDeleteRenderHint' DWord 1
    Set-Reg $nvtweakHklm 'DisableDynamicPstate' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\NVTweak' 'DisableOverlay' DWord 1
    Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client' 'OptInOrOutPreference' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID66610' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID64640' DWord 0
    Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID44231' DWord 0
    $nvGlobal = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak'
    Set-Reg $nvGlobal 'Gestalt' DWord 2
    Set-Reg $nvGlobal 'DisplayPowerSaving' DWord 0
    Set-Reg $nvGlobal 'RmProfilingAdminOnly' DWord 0
    Set-Reg $nvGlobal 'AllowDeepSleep' DWord 0
    Set-Reg $nvGlobal 'EnableGpuHealthCheck' DWord 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters' 'EnablePerformanceMode' DWord 1
    Set-Reg $script:GDPOWER 'RmGpsPsEnablePerCpuCoreDpc' DWord 1
    Set-Reg $script:GDPOWER 'InvalidateDynamicPstate' DWord 1
    Set-Reg $script:GDPOWER 'RmDisableRegistryCaching' DWord 1
    Set-Reg $script:GDPOWER 'EnablePowerBudget' DWord 0
    Set-Reg $script:GDPOWER 'IgnoreBatteryVoltageSag' DWord 1
    Set-Reg $script:GD 'TdrDelay' DWord 8
    Set-Reg $script:GD 'TdrDdiDelay' DWord 8
    Set-Reg (Get-IfeoPerfPath 'nvcontainer.exe') 'CpuPriorityClass' DWord 1
    Set-Reg (Get-IfeoPerfPath 'nvcontainer.exe') 'IoPriority' DWord 0

    # dynamic NVIDIA instance enumeration
    Write-Host '  [GPU-NVIDIA] Searching NVIDIA instances dynamically...' -ForegroundColor Gray
    $nvidiaFound = $false
    $instances = Get-ChildItem -Path $script:GFXCLASS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }
    foreach ($instance in $instances) {
        $desc = (Get-ItemProperty -LiteralPath $instance.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
        if ($desc -match 'NVIDIA') {
            $nvidiaFound = $true
            Set-Reg $instance.PSPath 'ReBarEnable' DWord 1
            Set-Reg $instance.PSPath 'ReBarSupported' DWord 1
            Set-Reg $instance.PSPath 'RmReBarEnable' DWord 1
            Set-Reg $instance.PSPath 'DisableWriteCombining' DWord 1
            Set-Reg $instance.PSPath 'RmGpsPsEnablePerCpuCoreDpc' DWord 1
            Set-Reg $instance.PSPath 'PreferSystemMemoryContiguous' DWord 1
            Set-Reg $instance.PSPath 'IncreaseFixedSegment' DWord 1
            Set-Reg $instance.PSPath 'DisableVRAMCompression' DWord 1
            Set-Reg $instance.PSPath 'DisableTextureCompression' DWord 1
            Set-Reg $instance.PSPath 'DedicatedSegmentSize' DWord $vramMb
            Set-Reg $instance.PSPath 'RmFbsrPagedDMA' DWord 0
            Set-Reg $instance.PSPath 'DisableDynamicClock' DWord 0
            Set-Reg $instance.PSPath 'EnableUlps' DWord 0
            Set-Reg $instance.PSPath 'DisablePowerGating' DWord 1
            Set-Reg $instance.PSPath 'EnableOverclock' DWord 1
            Set-Reg $instance.PSPath 'EnableCEPreemption' DWord 0
            Set-Reg $instance.PSPath 'RMForceMaxPerf' DWord 1
            Set-Reg $instance.PSPath 'RmDisableRegistryCaching' DWord 1
            Set-Reg $instance.PSPath 'PreferredPerformanceMode' DWord 1
            Set-Reg $instance.PSPath 'PerfLevelSrc' DWord 13107
            Set-Reg $instance.PSPath 'PowerMizerEnable' DWord 0
            Set-Reg $instance.PSPath 'InvalidateDynamicPstate' DWord 1
            Set-Reg $instance.PSPath 'RMPcieLinkSpeed' DWord 4
            Set-Reg $instance.PSPath 'DisableL1LowPower' DWord 1
            Set-Reg $instance.PSPath 'RMDisablePostL2Compression' DWord 1
            Set-Reg $instance.PSPath 'RMGC6Feature' DWord 0
            Set-Reg $instance.PSPath 'RMElpgStateOnInit' DWord 3
            Set-Reg $instance.PSPath 'RMHdcpKeyglobZero' DWord 1
            Set-Reg $instance.PSPath 'PeerMappingOverride' DWord 1
            Set-Reg $instance.PSPath 'RmGspcPerioduS' DWord 1
            Set-Reg $instance.PSPath 'RMCtxswLog' DWord 0
            Set-Reg $instance.PSPath 'RMLogMsg' DWord 0
            Set-Reg $instance.PSPath 'VRRAlwaysOn' DWord 0
            Set-Reg $instance.PSPath 'vrrSmartDetection' DWord 0
            Set-Reg $instance.PSPath 'GsyncCompatible' DWord 0
            Set-Reg $instance.PSPath 'WDDMv21Enable2MPageSupport' DWord 1
            Set-Reg $instance.PSPath 'WDDMv21Enable64KbSysmemSupport' DWord 1
            Set-Reg $instance.PSPath 'WDDMv21Force2MSizeAlignment' DWord 1
            Set-Reg $instance.PSPath 'NvencPreProcBlitDisable' DWord 1
            Set-Reg $instance.PSPath 'NVFBCEnable' DWord 1
            Set-Reg $instance.PSPath 'VideoControl3' DWord 1
            Set-Reg $instance.PSPath 'MessageSignaledInterrupts' DWord 1
            Set-Reg $instance.PSPath 'MSISupported' DWord 1
            Set-Reg $instance.PSPath 'EnableAspm' DWord 0
            Set-Reg $instance.PSPath 'PciLatencyTimerControl' DWord 32
            $affinity = Join-Path $instance.PSPath 'Interrupt Management\Affinity Policy'
            Set-Reg $affinity 'Strategy' DWord 2
            Set-Reg $affinity 'DevicePriority' DWord 4
            $msi = Join-Path $instance.PSPath 'Interrupt Management\MessageSignaledInterruptProperties'
            Set-Reg $msi 'MSISupported' DWord 1
            Set-Reg $msi 'MessageNumberLimit' DWord 2048
        }
    }
    if (-not $nvidiaFound) { Write-Host '  [WARNING] No NVIDIA GPU instance found in the dynamic loop.' -ForegroundColor Yellow }
}



function Optimize-GpuAmd {
    # 57c. AMD GPU (Radeon settings / UMD / AMD services)
    Write-Host '  [GPU-AMD] Applying AMD GPU optimizations...' -ForegroundColor Cyan
    Set-Reg $script:DWM 'OverlayTestMode' DWord 5
    $cn = 'HKCU:\Software\AMD\CN'
    Set-Reg $cn 'AutoUpdateTriggered' DWord 0
    Set-Reg $cn 'PowerSaverAutoEnable_CUR' DWord 0
    Set-Reg $cn 'BuildType' DWord 0
    Set-Reg $cn 'WizardProfile' String 'PROFILE_CUSTOM'
    Set-Reg $cn 'UserTypeWizardShown' DWord 1
    Set-Reg $cn 'AutoUpdate' DWord 0
    Set-Reg $cn 'RSXBrowserUnavailable' String 'true'
    Set-Reg $cn 'SystemTray' String 'false'
    Set-Reg $cn 'AllowWebContent' String 'false'
    Set-Reg $cn 'CN_Hide_Toast_Notification' String 'true'
    Set-Reg $cn 'AnimationEffect' String 'false'
    Set-Reg 'HKCU:\Software\AMD\CN\OverlayNotification' 'AlreadyNotified' DWord 1
    Set-Reg 'HKCU:\Software\AMD\CN\VirtualSuperResolution' 'AlreadyNotified' DWord 1
    $dvr = 'HKCU:\Software\AMD\DVR'
    Set-Reg $dvr 'PerformanceMonitorOpacityWA' DWord 0
    Set-Reg $dvr 'DvrEnabled' DWord 1
    Set-Reg $dvr 'ActiveSceneId' String '0'
    Set-Reg $dvr 'PrevInstantReplayEnable' DWord 0
    Set-Reg $dvr 'PrevInGameReplayEnabled' DWord 0
    Set-Reg $dvr 'PrevInstantGifEnabled' DWord 0
    Set-Reg $dvr 'RemoteServerStatus' DWord 0
    Set-Reg $dvr 'ShowRSOverlay' String 'false'
    Set-Reg 'HKCU:\Software\ATI\ACE\Settings\ADL\AppProfiles' 'AplReloadCounter' DWord 0
    Set-Reg 'HKLM:\Software\AMD\Install' 'AUEP' DWord 1
    Set-Reg 'HKLM:\Software\AUEP' 'RSX_AUEPStatus' DWord 2
    $amdKey = 'HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'
    Set-Reg $amdKey 'NotifySubscription' Binary '3000'
    Set-Reg $amdKey 'IsComponentControl' Binary '00000000'
    Set-Reg $amdKey 'KMD_USUEnable' DWord 0
    Set-Reg $amdKey 'KMD_RadeonBoostEnabled' DWord 0
    Set-Reg $amdKey 'IsAutoDefault' Binary '01000000'
    Set-Reg $amdKey 'KMD_ChillEnabled' DWord 0
    Set-Reg $amdKey 'KMD_DeLagEnabled' DWord 0
    Set-Reg $amdKey 'ACE' Binary '3000'
    Set-Reg $amdKey 'DisableBlockWrite' DWord 0
    Set-Reg $amdKey 'PP_ThermalAutoThrottlingEnable' DWord 0
    Set-Reg $amdKey 'DisableDrmdmaPowerGating' DWord 1
    $umd = "$amdKey\UMD"
    Set-Reg $umd 'AnisoDegree_SET' Binary '3020322034203820313600'
    Set-Reg $umd 'Main3D_SET' Binary '302031203220332034203500'
    Set-Reg $umd 'Tessellation_OPTION' Binary '3200'
    Set-Reg $umd 'Tessellation' Binary '3100'
    Set-Reg $umd 'AAF' Binary '30000000'
    Set-Reg $umd 'GI' Binary '31000000'
    Set-Reg $umd 'CatalystAI' Binary '31000000'
    Set-Reg $umd 'TemporalAAMultiplier_NA' Binary '3100'
    Set-Reg $umd 'ForceZBufferDepth' Binary '30000000'
    Set-Reg $umd 'EnableTripleBuffering' Binary '3000'
    Set-Reg $umd 'ExportCompressedTex' Binary '31000000'
    Set-Reg $umd 'PixelCenter' Binary '30000000'
    Set-Reg $umd 'ZFormats_NA' Binary '3100'
    Set-Reg $umd 'DitherAlpha_NA' Binary '3100'
    Set-Reg $umd 'SwapEffect_D3D_SET' Binary '3020312032203320342038203900'
    Set-Reg $umd 'TFQ' Binary '3200'
    Set-Reg $umd 'VSyncControl' Binary '3100'
    Invoke-Exe 'reg.exe' @('add', 'HKLM\System\CurrentControlSet\Services\amdwddmg', '/v', 'ChillEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
    Set-ServiceStartValue 'AMD Crash Defender Service' 4
    Set-ServiceStartValue 'AMD External Events Utility' 4
    Set-ServiceStartValue 'amdfendr' 4
    Set-ServiceStartValue 'amdfendrmgr' 4
    Set-ServiceStartValue 'amdlog' 4
}


function Invoke-GpuPhase {
    # 57. HARDWARE PHASE - GPU DETECTION (Intel / NVIDIA / AMD)
    $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    $hasIntel = $false; $hasNvidia = $false; $hasAmd = $false
    foreach ($gpu in $gpus) {
        if ($gpu.AdapterCompatibility -match 'Intel' -or $gpu.Name -match 'Intel') { $hasIntel = $true }
        elseif ($gpu.AdapterCompatibility -match 'NVIDIA' -or $gpu.Name -match 'NVIDIA') { $hasNvidia = $true }
        elseif ($gpu.AdapterCompatibility -match 'Advanced Micro Devices|AMD' -or $gpu.Name -match 'AMD|Radeon') { $hasAmd = $true }
    }
    Write-Host ("  GPU detection - Intel: {0} | NVIDIA: {1} | AMD: {2}" -f $hasIntel, $hasNvidia, $hasAmd) -ForegroundColor Cyan
    if ($hasIntel)  { Optimize-GpuIntel }
    if ($hasNvidia) { Optimize-GpuNvidia }
    if ($hasAmd)    { Optimize-GpuAmd }
}

function Invoke-VisualEffectsFinal {
    # 58. FINAL VISUAL EFFECTS + SHELL/ICON CACHE RESTART
    Set-Reg 'HKCU:\Control Panel\Desktop' 'VisualFXSetting' DWord 3
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' DWord 3
    Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' Binary '9012038010000000'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' String '1'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' String '2'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' DWord 2
    Invoke-Exe 'taskkill.exe' @('/f', '/im', 'explorer.exe')
    Invoke-Exe 'taskkill.exe' @('/f', '/im', 'dwm.exe')
    Remove-ItemSilent (Join-Path $env:LOCALAPPDATA 'IconCache.db')
    Remove-ItemsByPattern (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer\thumbcache_*.db')
    Invoke-Exe 'net.exe' @('stop', 'FontCache')
    Remove-ItemsByPattern (Join-Path $env:LOCALAPPDATA 'GDIPFONTCACHEV1.dat')
    Invoke-Exe 'net.exe' @('start', 'FontCache')
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}


function Show-Banner {
    # ANSI branded banner (REGIX Studio + </> DEV | JAHID); legacy block kept commented.
    Show-RegixBanner
    Write-Host '      OPTIMIZER - PowerShell Edition (port of V9.1)' -ForegroundColor Yellow
    Write-Host '      By @STEFANO83223, @Aledect - ported to PowerShell' -ForegroundColor DarkYellow
    Write-Host ''
}

function Invoke-OptimizerSections {
    <# runs the requested sections; validates each function exists (mirrors the CALL semantics of the .cmd) #>
    $selected = $script:OptimizerSections
    if ($Sections -and $Sections.Count -gt 0) {
        $selected = @()
        foreach ($id in $Sections) {
            $match = $script:OptimizerSections | Where-Object { $_.Id -eq $id }
            if ($match) { $selected += $match }
            else { Write-Host ("  Unknown section id: '{0}' (use -ListSections)" -f $id) -ForegroundColor Yellow }
        }
    }
    if (-not $selected -or $selected.Count -eq 0) { Write-Host 'No sections selected - nothing to do.' -ForegroundColor Red; return $false }
    foreach ($section in $selected) {
        Write-Section $section.Title
        $fn = Get-Command -Name $section.Function -ErrorAction SilentlyContinue
        if ($fn) {
            try { & $section.Function }
            catch { Write-Host ('  Section failed (continuing): ' + $_.Exception.Message) -ForegroundColor Yellow }
        }
        else { Write-Host ('  Function missing: ' + $section.Function) -ForegroundColor Red }
    }
    return $true
}


function Show-SectionList {
    Write-Section 'Available sections (-Sections <id1,id2,...>)'
    foreach ($section in $script:OptimizerSections) {
        Write-Host ('  {0,-16} {1}' -f $section.Id, $section.Title)
    }
}

function Show-Summary {
    Write-Section 'SUMMARY'
    Write-Host '  All selected sections have been applied.' -ForegroundColor Green
    Write-Host '  A REBOOT IS REQUIRED for most tweaks to take effect.' -ForegroundColor Yellow
    Write-Host '  Backup: Desktop\platinum_backup.reg (+ system restore point when available).' -ForegroundColor Gray
    Write-Host '  Powered by REGIX Studio  |  </> DEV | JAHID' -ForegroundColor DarkYellow
}

function Show-MainMenu {
    # interactive menu (like the original [1] Run / [0] Exit)
    while ($true) {
        Show-Banner
        Write-Host ('    {0}' -f ('=' * 60)) -ForegroundColor Red
        Write-Host ('    {0}' -f 'REGIX STUDIO - PLATINUM+ OPTIMIZER V9.1') -ForegroundColor White
        Write-Host ('    {0}' -f '</> DEV | JAHID') -ForegroundColor DarkYellow
        Write-Host ('    {0}' -f ('=' * 60)) -ForegroundColor Red
        Write-Host '    [1] Run Platinum+ Optimizer' -ForegroundColor Yellow
        Write-Host '    [2] List available sections' -ForegroundColor Yellow
        Write-Host '    [0] Exit' -ForegroundColor Yellow
        Write-Host ('    {0}' -f ('=' * 60)) -ForegroundColor Red
        $choice = Read-Host 'Select an option'
        switch ($choice) {
            '1' { return $true }
            '2' { Show-SectionList; Read-Host 'Press ENTER to continue' | Out-Null }
            '0' { return $false }
            default { }
        }
        Clear-Host
    }
}

# =============================================================================
# MAIN
# =============================================================================
if ($ListSections) { Show-SectionList; exit 0 }

# interactive menu ([1] Run / [2] List / [0] Exit) unless running non-interactively
if (-not $AutoYes) {
    if (-not (Show-MainMenu)) {
        Write-Host ''
        Write-Host 'Exiting Platinum+ Optimizer...' -ForegroundColor Gray
        exit 0
    }
}

Clear-Host
Show-Banner

# --- authentication gate (REGIX Studio) ---------------------------------------
if ($NoAuth) {
    Write-Host '  [AUTH] Authentication skipped (-NoAuth).' -ForegroundColor Yellow
}
elseif (-not (Invoke-Authentication)) {
    Write-Host ''
    Write-Host '  Authentication failed - exiting REGIX Optimizer.' -ForegroundColor Red
    exit 1
}

# countdown (mirrors the original 7-second automated start)
if (-not $AutoYes) {
    Write-Host 'Automated execution of the tweaks in:' -ForegroundColor Red
    foreach ($i in 7..1) {
        Write-Host ("  {0}..." -f $i) -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
    Write-Host ''
}

if (-not $NoBackup) {
    Write-Section '01. Initial backup'
    Save-SystemBackup
}

$ran = Invoke-OptimizerSections

if ($ran) {
    Show-Summary
    if (-not $SkipReboot) {
        $answer = 'y'
        if (-not $AutoYes) { $answer = (Read-Host 'Reboot now? [y/N]').Trim().ToLowerInvariant() }
        if ($answer -eq 'y' -or $answer -eq 'yes') {
            Write-Host '  Rebooting in 5 seconds... (press Ctrl+C to abort)' -ForegroundColor Red
            Start-Sleep -Seconds 5
            Invoke-Exe 'shutdown.exe' @('/r', '/f', '/t', '3')
        }
        else { Write-Host '  Reboot skipped - reboot manually to apply all tweaks.' -ForegroundColor Yellow }
    }
}
else { Write-Host 'Nothing was applied.' -ForegroundColor Red }

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host '  Powered by REGIX Studio  |  </> DEV | JAHID' -ForegroundColor DarkYellow







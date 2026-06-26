addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request))
})

async function handleRequest(request) {
  const userAgent = request.headers.get('user-agent') || '';
  
  // চেক করা হচ্ছে রিকোয়েস্টটি PowerShell থেকে এসেছে কি না
  if (userAgent.includes('PowerShell') || userAgent.includes('WindowsPowerShell')) {
    
    // একদম পারফেক্টলি ফরম্যাটেড পাওয়ারশেল কোড স্ট্রিং
    const powerShellScript = `# ==============================================================================
# REGIX EXTREME PERFORMANCE & LOW LATENCY OPTIMIZATION SCRIPT
# Environment Optimized for: Jahid Ekbal Mallick (REGIX / GURU ESPORTS)
# Powered by: REGIX Studio | Developed by: jahid
# Discord Support: https://discord.gg/zZwDv7ks5W
# ==============================================================================

# ১. এডমিনিস্ট্রেটর প্রিভিলেজ চেক (Administrator Privilege Check)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Please right-click and run PowerShell as Administrator to execute this script!"
    Exit
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "      REGIX OPTIMIZATION ENGINE ACTIVATING...       " -ForegroundColor Cyan
Write-Host "         Powered by: REGIX Studio                   " -ForegroundColor Green
Write-Host "         Developed by: jahid                        " -ForegroundColor Yellow
Write-Host "         Discord: https://discord.gg/zZwDv7ks5W     " -ForegroundColor Magenta
Write-Host "====================================================" -ForegroundColor Cyan

# ২. সিস্টেম রিস্টোর পয়েন্ট তৈরি (Create System Restore Point)
Write-Host "\`n[1/6] Creating a System Restore Point for safety..." -ForegroundColor Yellow
Enable-ComputerRestore -Drive "C:\\" -ErrorAction SilentlyContinue
Checkpoint-Computer -Description "REGIX_Optimization_Backup" -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue

# ৩. কার্নেল ক্লক ও টাইমার অপ্টিমাইজেশন (BCD Timer & Latency Tweaks)
Write-Host "[2/6] Applying BCD Kernel Clock & Latency tweaks..." -ForegroundColor Yellow
bcdedit /set disabledynamictick yes
bcdedit /deletevalue useplatformclock 2>$null
bcdedit /set useplatformtick yes

# ৪. মাস্টার রেজিস্ট্রি টিউনিং (Comprehensive Registry Optimizations)
Write-Host "[3/6] Configuring registry for Mouse, Network, and GPU priority..." -ForegroundColor Yellow

function Set-RegKey {
    param ($Path, $Name, $Value, $Type = "String")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force | Out-Null
}

# মাউস রেসপন্স ও লিনিয়ার মুভমেন্ট ফিক্স (Raw Mouse Input - No Acceleration)
$MousePath = "HKCU:\\Control Panel\\Mouse"
Set-RegKey $MousePath "MouseSpeed" "0"
Set-RegKey $MousePath "MouseThreshold1" "0"
Set-RegKey $MousePath "MouseThreshold2" "0"
Set-RegKey $MousePath "MouseSensitivity" "10"
Set-RegKey $MousePath "MouseHoverTime" "0"

# কাস্টম মাউস কার্ভ ডেটা রাইট (Pixel-Perfect Accuracy Curves)
[byte[]]$XCurve = 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x15,0x6e,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x40,0x01,0x00,0x00,0x00,0x00,0x00,0x29,0xdc,0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x28,0x00,0x00,0x00,0x00,0x00
[byte[]]$YCurve = 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xfd,0x11,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x24,0x04,0x00,0x00,0x00,0x00,0x00,0x00,0xfc,0x12,0x00,0x00,0x00,0x00,0x00,0x00,0xc0,0xbb,0x01,0x00,0x00,0x00,0x00
Set-ItemProperty -Path $MousePath -Name "SmoothMouseXCurve" -Value $XCurve -Type Binary
Set-ItemProperty -Path $MousePath -Name "SmoothMouseYCurve" -Value $YCurve -Type Binary

# নেটওয়ার্ক থ্রোটলিং নিষ্ক্রিয়করণ ও রেসপন্সিভনেস বুস্ট
$SysProfile = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile"
Set-RegKey $SysProfile "NetworkThrottlingIndex" 0xffffffff -Type DWord
Set-RegKey $SysProfile "SystemResponsiveness" 0 -Type DWord

# MMCSS গেমিং টাস্ক প্রায়োরিটি ইঞ্জিন (High Allocation)
$GameTask = "$SysProfile\\Tasks\\Games"
Set-RegKey $GameTask "GPU Priority" 8 -Type DWord
Set-RegKey $GameTask "Priority" 6 -Type DWord
Set-RegKey $GameTask "Scheduling Category" "High"
Set-RegKey $GameTask "SFIO Priority" "High"
Set-RegKey $GameTask "Background Only" "False"

# ফোরগ্রাউন্ড গেম অ্যাপ্লিকেশনকে সিপিইউ প্রায়োরিটি দেওয়া
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\PriorityControl" "Win32PrioritySeparation" 38 -Type DWord

# মনিটর ল্যাটেন্সি ও ডিসপ্লে আউটপুট ডিলে ফিক্স
$DXGPath = "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\DXGKrnl"
Set-RegKey $DXGPath "MonitorLatencyTolerance" 0 -Type DWord
Set-RegKey $DXGPath "MonitorRefreshLatencyTolerance" 0 -Type DWord

# ভিডিও র‍্যাম (VRAM) ক্লক স্টাটার মোড থ্রেশহোল্ড (1ms মনিটর টিউনিং)
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\0000" "PP_MCLKStutterModeThreshold" 1000 -Type DWord

# জিপিইউ ড্রাইভার লেভেল মাল্টি-কোর থ্রেডিং অপ্টিমাইজেশন (Nvidia DPC Split)
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers" "RmGpsPsEnablePerCpuCoreDpc" 1 -Type DWord
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers\\Power" "RmGpsPsEnablePerCpuCoreDpc" 1 -Type DWord
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\nvlddmkm" "RmGpsPsEnablePerCpuCoreDpc" 1 -Type DWord
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\nvlddmkm\\NVAPI" "RmGpsPsEnablePerCpuCoreDpc" 1 -Type DWord
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\nvlddmkm\\Global\\NVTweak" "RmGpsPsEnablePerCpuCoreDpc" 1 -Type DWord

# পাওয়ার থ্রোটলিং, ফাস্ট বুট ও হাইবারনেশন বন্ধ করা
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerThrottling" "PowerThrottlingOff" 1 -Type DWord
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power" "HiberbootEnabled" 0 -Type DWord
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power" "HibernateEnabledDefault" 0 -Type DWord
Set-RegKey "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching" "SearchOrderConfig" 0 -Type DWord

# কন্ট্রোল প্যানেলের লোকানো অ্যাডভান্সড প্রসেসর পাওয়ার সেটিংস আনলক করা
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\54533251-82be-4824-96c1-47b60b740d00\\943c8cb6-6f93-4227-ad87-e9a3feec08d1" "Attributes" 2 -Type DWord

# এক্সবক্স গেম বার, ওভারলে এবং ব্যাকগ্রাউন্ড ক্যাপচার নিষ্ক্রিয়করণ
Set-RegKey "HKCU:\\Software\\Microsoft\\GameBar" "ShowStartupPanel" 0 -Type DWord
Set-RegKey "HKCU:\\Software\\Microsoft\\GameBar" "AllowAutoGameMode" 0 -Type DWord
Set-RegKey "HKCU:\\Software\\Microsoft\\GameBar" "AutoGameModeEnabled" 0 -Type DWord
Set-RegKey "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\GameDVR" "AppCaptureEnabled" 0 -Type DWord
Set-RegKey "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\GameDVR" "AllowGameDVR" 0 -Type DWord

# গ্লোবাল ফুলস্ক্রিন এক্সক্লুসিভ মোড এনফোর্সমেন্ট (Enforce Fullscreen Exclusive Mode)
$GameStore = "HKCU:\\System\\GameConfigStore"
Set-RegKey $GameStore "GameDVR_Enabled" 0 -Type DWord
Set-RegKey $GameStore "GameDVR_FSEBehaviorMode" 2 -Type DWord
Set-RegKey $GameStore "GameDVR_HonorUserFSEBehaviorMode" 1 -Type DWord
Set-RegKey $GameStore "GameDVR_FSEBehavior" 2 -Type DWord
Set-RegKey $GameStore "GameDVR_DXGIHonorFSEWindowsCompatible" 1 -Type DWord

# উইন্ডোজ এক্সপ্লরার ইন্টারফেস এবং কিল-টাইমআউট অপ্টিমাইজেশন
$DesktopPath = "HKCU:\\Control Panel\\Desktop"
Set-RegKey $DesktopPath "MenuShowDelay" "0"
Set-RegKey $DesktopPath "WaitToKillAppTimeout" "2000"
Set-RegKey $DesktopPath "HungAppTimeout" "1000"
Set-RegKey $DesktopPath "AutoEndTasks" "1"
Set-RegKey "HKLM:\\SYSTEM\\CurrentControlSet\\Control" "WaitToKillServiceTimeout" "2000"

# মেমোরি ওভারহেড কমাতে সুপারফেচ চ্যানেলের ব্যাকগ্রাউন্ড ইভেন্ট লগিং বন্ধ করা
Set-RegKey "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WINEVT\\Channels\\Microsoft-Windows-Superfetch/Main" "Enabled" 0 -Type DWord
Set-RegKey "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WINEVT\\Channels\\Microsoft-Windows-Superfetch/PfApLog" "Enabled" 0 -Type DWord
Set-RegKey "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WINEVT\\Channels\\Microsoft-Windows-Superfetch/StoreLog" "Enabled" 0 -Type DWord

# ডেটা ট্র্যাকিং, টেলিমেট্রি এবং স্পনসর্ড ব্লটওয়্যার বন্ধ করা
Set-RegKey "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo" "Enabled" 0 -Type DWord
Set-RegKey "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System" "EnableActivityFeed" 0 -Type DWord
Set-RegKey "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent" "DisableWindowsConsumerFeatures" 1 -Type DWord

# ৫. অপ্রয়োজনীয় ও ক্ষতিকারক ব্যাকগ্রাউন্ড সার্ভিস নিষ্ক্রিয়করণ (Disable Unusable Background Services)
Write-Host "[4/6] Disabling unnecessary background services to free up RAM & CPU..." -ForegroundColor Yellow
$ServicesToDisable = @(
    "WSearch", "SSDPSRV", "lfsvc", "AXInstSV", "AJRouter", "AppReadiness", "SharedAccess",
    "lltdsvc", "diagnosticshub.standardcollector.service", "SmsRouter", "NcdAutoSetup",
    "PNRPsvc", "p2psvc", "p2pimsvc", "PNRPAutoReg", "WalletService", "WMPNetworkSvc",
    "icssvc", "XblAuthManager", "XblGameSave", "XboxNetApiSvc", "DmEnrollmentSvc",
    "RetailDemo", "SDRSVC", "WpcMonSvc", "fax", "wuauserv", "Spooler", "PrintNotify",
    "PrintWorkflowUserSvc"
)

foreach ($Service in $ServicesToDisable) {
    if (Get-Service -Name $Service -ErrorAction SilentlyContinue) {
        Set-Service -Name $Service -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue
    }
}

# ৬. সিস্টেম টেম্প ও এম্যুলেটর ক্যাশ ডিপ ক্লিন (Windows Junk & Emulator Logs Deletion)
Write-Host "[5/6] Cleaning junk files, prefetch cache, and emulator log trails..." -ForegroundColor Yellow

$TempPaths = @(
    "C:\\Windows\\Temp\\*",
    "$env:USERPROFILE\\AppData\\Local\\Temp\\*",
    "C:\\Windows\\Prefetch\\*",
    "C:\\ProgramData\\BlueStacks\\Logs\\*",
    "C:\\ProgramData\\BlueStacks\\Engine\\Android\\Logs\\*"
)

foreach ($Path in $TempPaths) {
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# মেমোরি ওভারহেড এবং ল্যাগ কমাতে উইন্ডোজের ভারী ইভেন্ট লগগুলো সাফ করা
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($_.LogName)
    } catch {}
}

Write-Host "\`n[6/6] REGIX EXTREME PERFORMANCE PACK APPLIED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "Please restart your PC now to run on the lowest latency." -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
`;

    return new Response(powerShellScript, {
      headers: { 
        'content-type': 'text/plain; charset=utf-8',
        'Access-Control-Allow-Origin': '*'
      },
    });

  } else {
    // যদি রিকোয়েস্ট ব্রাউজার থেকে আসে, তবে নির্দিষ্ট ইউটিউব লিংকে রিডাইরেক্ট হবে
    const youtubeVideoUrl = 'https://youtu.be/GVizJ_jpUnw?si=lbl9QKs9sX7jcrsp';
    return Response.redirect(youtubeVideoUrl, 302);
  }
}

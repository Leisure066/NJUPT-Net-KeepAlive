$ErrorActionPreference = 'Stop'

$root       = $PSScriptRoot
$configPath = Join-Path $root 'config.ps1'
$scriptPath = Join-Path $root 'portal.ps1'
$taskName   = 'NJUPT-net-KeepAlive'

Write-Host ''
Write-Host '=== NJUPT net KeepAlive setup ==='
Write-Host ''
Write-Host 'Select campus network:'
Write-Host '  1) NJUPT-CMCC       (CMCC / mobile)'
Write-Host '  2) NJUPT-CHINANET   (Telecom)'
Write-Host '  3) NJUPT            (General)'
$choice = Read-Host 'Enter 1 / 2 / 3'

switch ($choice.Trim()) {
    '1' { $ssid = 'NJUPT-CMCC';     $suffix = '@cmcc'    }
    '2' { $ssid = 'NJUPT-CHINANET'; $suffix = '@telecom' }
    '3' { $ssid = 'NJUPT';          $suffix = ''         }
    default { throw 'Invalid choice' }
}

$username = (Read-Host 'Student ID').Trim()
if ([string]::IsNullOrWhiteSpace($username)) { throw 'Student ID cannot be empty' }

$secure = Read-Host 'Password' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$wlanIface = 'WLAN'
$adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceDescription -match 'Wireless|Wi-Fi|WLAN|802\.11' } |
           Select-Object -First 1
if ($adapter) { $wlanIface = $adapter.Name }

$escapedPassword = $password.Replace("'", "''")

$lines = @(
    '$Config = @{',
    ("    Username      = '{0}'" -f $username),
    ("    Password      = '{0}'" -f $escapedPassword),
    ("    AccountSuffix = '{0}'" -f $suffix),
    ("    SSID          = '{0}'" -f $ssid),
    ("    WlanIface     = '{0}'" -f $wlanIface),
    "    PortalHost    = 'p.njupt.edu.cn'",
    "    PortalIP      = '10.10.244.11'",
    '    PortalPort    = 804',
    '}'
)
Set-Content -Path $configPath -Value $lines -Encoding UTF8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ConfigPath "{1}"' -f $scriptPath, $configPath) `
    -WorkingDirectory $root

$triggerBoot  = New-ScheduledTaskTrigger -AtStartup
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($triggerBoot, $triggerLogon) -Settings $settings `
    -Principal $principal -Force | Out-Null

Start-ScheduledTask -TaskName $taskName

Write-Host ''
Write-Host 'Done. Keepalive is running in background.'
Write-Host "Network : $ssid ($suffix)"
Write-Host "Config  : $configPath"
Write-Host "Log     : $(Join-Path $root 'keepalive.log')"
Write-Host ''
Write-Host 'To stop: run uninstall.bat as administrator.'
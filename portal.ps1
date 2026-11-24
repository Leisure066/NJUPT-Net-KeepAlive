#Requires -Version 5.1
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.ps1'),
    [switch]$Once,
    [switch]$DebugMode,
    [switch]$ProbeOnly,
    [switch]$ForceLogin
)

$ErrorActionPreference = 'Continue'
$script:KeepAliveVersion = '1.3.0'
$script:FailCount = 0
$script:AuthConfigFailCount = 0
$script:LastPortalMessage = ''
$script:LogFile = Join-Path $PSScriptRoot 'keepalive.log'

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    if ($DebugMode) { Write-Host $line }
}

function Test-Internet {
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 8
        return ($r.Content.Trim() -eq 'Microsoft Connect Test')
    } catch {
        return $false
    }
}

function Get-WifiState {
    $p = Get-NetConnectionProfile -InterfaceAlias $Config.WlanIface -ErrorAction SilentlyContinue
    if ($p) { return [pscustomobject]@{ SSID = $p.Name; State = 'connected' } }
    return [pscustomobject]@{ SSID = ''; State = 'disconnected' }
}

function Get-WiredAdapter {
    return Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceDescription -notmatch 'Wireless|Wi-Fi|WLAN|802\.11' -and $_.Status -eq 'Up' } |
           Select-Object -First 1
}

function Test-WiredUp {
    return [bool](Get-WiredAdapter)
}

function Ensure-Wifi {
    $wifi = Get-WifiState
    if ($wifi.State -eq 'connected' -and $wifi.SSID -eq $Config.SSID) { return $true }
    Write-Log ("connecting wifi {0} (current: state={1} ssid={2})" -f $Config.SSID, $wifi.State, $wifi.SSID)
    netsh wlan connect name="$($Config.SSID)" interface="$($Config.WlanIface)" 2>$null | Out-Null
    for ($i = 0; $i -lt 6; $i++) {
        Start-Sleep -Seconds 5
        $after = Get-WifiState
        if ($after.State -eq 'connected' -and $after.SSID -eq $Config.SSID) { break }
    }
    Write-Log ("wifi after connect: state={0} ssid={1}" -f $after.State, $after.SSID)
    return ($after.State -eq 'connected' -and $after.SSID -eq $Config.SSID)
}

function Get-LocalIP {
    $eth = Get-WiredAdapter
    if ($eth) {
        $ip = Get-NetIPAddress -InterfaceAlias $eth.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' } |
              Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    }
    $ip2 = Get-NetIPAddress -InterfaceAlias $Config.WlanIface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike '169.254.*' } |
           Select-Object -First 1
    if ($ip2) { return $ip2.IPAddress }
    return ''
}

function Get-Account([string]$Suffix, [bool]$UsePrefix) {
    $prefix = if ($UsePrefix) { ',0,' } else { '' }
    return ($prefix + $Config.Username + $Suffix)
}

function Get-PortalHost {
    if ($Config.PortalIP) { return $Config.PortalIP }
    return '10.10.244.11'
}

function Get-PortalPort {
    if ($Config.PortalPort) { return [int]$Config.PortalPort }
    return 802
}

function New-PortalPageResult {
    return [pscustomobject]@{
        HttpCode = ''
        CurlExit = -1
        ClientIP = ''
        JsVersion = '4.5.1'
        AccountSuffix = $null
        LoginMethod = 1
        AccountPrefixEnabled = $true
        NoFilterAccAndPwd = 0
        EnableR3 = 0
        EnableUuid = 0
        Rcn = ''
        SettingsLoaded = $false
    }
}

function Get-PortalPage {
    $result = New-PortalPageResult
    $tmp = Join-Path $env:TEMP ('portal-' + [guid]::NewGuid().ToString('N') + '.html')
    $err = Join-Path $env:TEMP ('portal-' + [guid]::NewGuid().ToString('N') + '.err')
    $jsTmp = Join-Path $env:TEMP ('portal-js-' + [guid]::NewGuid().ToString('N') + '.js')
    $settingsTmp = Join-Path $env:TEMP ('portal-settings-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $errPath = $err.Replace('\', '/')
        $pageUrl = "https://{0}/a79.htm" -f (Get-PortalHost)
        $result.HttpCode = (& curl.exe -k -sS -m 10 --stderr $errPath -o $tmp -w '%{http_code}' $pageUrl | Out-String).Trim()
        $result.CurlExit = $LASTEXITCODE
        if (Test-Path $tmp -PathType Leaf) {
            $html = Get-Content -Path $tmp -Raw -Encoding Default -ErrorAction SilentlyContinue
            if ($null -eq $html) { $html = '' }
            $m = [regex]::Match($html, "v46ip\s*=\s*'([0-9.]+)'")
            if ($m.Success) { $result.ClientIP = $m.Groups[1].Value }
            $fileVersion = ''
            $m = [regex]::Match($html, 'fileVersion\s*=\s*"([^"]+)"')
            if ($m.Success) { $fileVersion = $m.Groups[1].Value }
            $jsUrl = "https://{0}/a59.js" -f (Get-PortalHost)
            if ($fileVersion) { $jsUrl += '?v=_' + $fileVersion }
            & curl.exe -k -sS -m 10 --stderr NUL -o $jsTmp $jsUrl | Out-Null
            if (Test-Path $jsTmp -PathType Leaf) {
                $js = Get-Content -Path $jsTmp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($null -ne $js) {
                    $m = [regex]::Match($js, "var\s+jsVersion\s*=\s*'([^']+)'")
                    if ($m.Success) { $result.JsVersion = $m.Groups[1].Value }
                }
            }
            if ($result.ClientIP) {
                $encodedIp = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($result.ClientIP))
                $settingsUrl = "https://{0}:{1}/eportal/portal/page/loadConfig" -f (Get-PortalHost), (Get-PortalPort)
                & curl.exe -k -sS -G -m 10 --stderr NUL `
                    --data-urlencode 'callback=dr1003' `
                    --data-urlencode 'program_index=1' `
                    --data-urlencode 'wlan_vlan_id=0' `
                    --data-urlencode "wlan_user_ip=$encodedIp" `
                    --data-urlencode 'wlan_user_ipv6=' `
                    --data-urlencode "wlan_user_ssid=$($Config.SSID)" `
                    --data-urlencode 'wlan_user_areaid=' `
                    --data-urlencode 'wlan_ac_ip=' `
                    --data-urlencode 'wlan_ap_mac=' `
                    --data-urlencode 'gw_id=' `
                    --data-urlencode "jsVersion=$($result.JsVersion)" `
                    -o $settingsTmp $settingsUrl | Out-Null
                if (Test-Path $settingsTmp -PathType Leaf) {
                    $settingsText = Get-Content -Path $settingsTmp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    $settingsMatch = if ($null -ne $settingsText) { [regex]::Match($settingsText, '\{.*\}', [Text.RegularExpressions.RegexOptions]::Singleline) } else { $null }
                    if ($settingsMatch -and $settingsMatch.Success) {
                        try {
                            $settings = $settingsMatch.Value | ConvertFrom-Json
                            if ($settings.code -eq 1 -and $settings.data) {
                                $result.AccountSuffix = [string]$settings.data.account_suffix
                                $result.LoginMethod = [int]$settings.data.login_method
                                $result.AccountPrefixEnabled = ([int]$settings.data.account_prefix -eq 1)
                                $result.NoFilterAccAndPwd = [int]$settings.data.no_filter_accandpwd
                                $result.EnableR3 = [int]$settings.data.enable_r3
                                $result.EnableUuid = [int]$settings.data.enable_uuid
                                $result.Rcn = [string]$settings.data.rcn
                                $result.SettingsLoaded = $true
                            }
                        } catch { }
                    }
                }
            }
            return $result
        }
        return $result
    } catch {
        $result.CurlExit = -1
        return $result
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path $err) { Remove-Item $err -Force -ErrorAction SilentlyContinue }
        if (Test-Path $jsTmp) { Remove-Item $jsTmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path $settingsTmp) { Remove-Item $settingsTmp -Force -ErrorAction SilentlyContinue }
    }
}

function Protect-Secret([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $safe = $Text
    if ($Config.Username) { $safe = $safe.Replace($Config.Username, '***') }
    if ($Config.Password) { $safe = $safe.Replace($Config.Password, '***') }
    return $safe
}

function ConvertTo-CurlConfigValue([string]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Invoke-PortalLogin {
    $page       = Get-PortalPage
    $clientIp   = $page.ClientIP
    $portalHost = Get-PortalHost
    $portalPort = Get-PortalPort
    $script:LastPortalMessage = ''
    if (-not $clientIp) { $clientIp = Get-LocalIP }
    $version = Get-Random -Minimum 1000 -Maximum 10000
    $uuid = if ($page.EnableUuid -eq 1) { [guid]::NewGuid().ToString() } else { '' }
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36 Edg/156.0.0.0'
    $effectiveSuffix = if ($null -eq $page.AccountSuffix) { [string]$Config.AccountSuffix } else { [string]$page.AccountSuffix }
    $accountValue = Get-Account $effectiveSuffix $page.AccountPrefixEnabled
    if ($page.NoFilterAccAndPwd -eq 1) {
        $accountValue = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($accountValue))
    }
    $passwordValue = $Config.Password
    if ($page.NoFilterAccAndPwd -eq 1) {
        $passwordValue = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($passwordValue))
    }
    Write-Log ('portal request: GET https://{0}:{1}/eportal/portal/login page_http={2} page_curl={3} settings_loaded={4} js_version={5} configured_suffix="{6}" server_suffix="{7}" login_method={8}' -f $portalHost, $portalPort, $page.HttpCode, $page.CurlExit, $page.SettingsLoaded, $page.JsVersion, $Config.AccountSuffix, $effectiveSuffix, $page.LoginMethod)

    $tmp = Join-Path $env:TEMP ('login-' + [guid]::NewGuid().ToString('N') + '.json')
    $err = Join-Path $env:TEMP ('login-' + [guid]::NewGuid().ToString('N') + '.err')
    $curlConfig = Join-Path $env:TEMP ('login-' + [guid]::NewGuid().ToString('N') + '.cfg')
    $curlOutputPath = $tmp.Replace('\', '/')
    $curlErrorPath = $err.Replace('\', '/')
    try {
        # Keep credentials out of the process command line. The temporary config
        # is written without a BOM for Windows PowerShell 5.1 compatibility.
        $requestConfig = @(
            ('url = "https://{0}:{1}/eportal/portal/login"' -f $portalHost, $portalPort),
            'get',
            'silent',
            'show-error',
            'insecure',
            'max-time = 15',
            ('user-agent = "{0}"' -f (ConvertTo-CurlConfigValue $userAgent)),
            'write-out = "%{http_code}"',
            ('output = "{0}"' -f $curlOutputPath),
            ('stderr = "{0}"' -f $curlErrorPath),
            'data-urlencode = "callback=dr1003"',
            ('data-urlencode = "login_method={0}"' -f $page.LoginMethod),
            ('data-urlencode = "is_base64encode={0}"' -f $page.NoFilterAccAndPwd),
            ('data-urlencode = "user_account={0}"' -f (ConvertTo-CurlConfigValue $accountValue)),
            ('data-urlencode = "user_password={0}"' -f (ConvertTo-CurlConfigValue $passwordValue)),
            ('data-urlencode = "wlan_user_ip={0}"' -f $clientIp),
            'data-urlencode = "wlan_user_ipv6="',
            'data-urlencode = "wlan_user_mac=000000000000"',
            'data-urlencode = "wlan_vlan_id=0"',
            'data-urlencode = "wlan_ac_ip="',
            'data-urlencode = "wlan_ac_name="',
            'data-urlencode = "authex_enable="',
            ('data-urlencode = "jsVersion={0}"' -f $page.JsVersion),
            ('data-urlencode = "user_agent={0}"' -f (ConvertTo-CurlConfigValue $userAgent)),
            'data-urlencode = "terminal_type=1"',
            ('data-urlencode = "enable_r3={0}"' -f $page.EnableR3),
            'data-urlencode = "mac_type=0"',
            ('data-urlencode = "rcn={0}"' -f (ConvertTo-CurlConfigValue $page.Rcn)),
            'data-urlencode = "operate=portal_login"',
            'data-urlencode = "business_type=0"',
            ('data-urlencode = "uuid={0}"' -f $uuid),
            'data-urlencode = "lang=zh-cn"',
            ('data-urlencode = "v={0}"' -f $version)
        )
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($curlConfig, [string[]]$requestConfig, $utf8NoBom)
        $httpCode = (& curl.exe --config $curlConfig | Out-String).Trim()
        $curlExit = $LASTEXITCODE
        $resp = ''
        if (Test-Path $tmp -PathType Leaf) {
            $resp = Get-Content -Path $tmp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -eq $resp) { $resp = '' }
        }
        $curlError = ''
        if (Test-Path $err -PathType Leaf) {
            $curlErrorText = Get-Content -Path $err -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -ne $curlErrorText) { $curlError = $curlErrorText.Trim() }
        }
        Write-Log ('portal result: http={0} curl={1}' -f $httpCode, $curlExit)
        if ($curlError) { Write-Log ('curl error: ' + (Protect-Secret $curlError)) }
        if ($DebugMode -and $resp) { Write-Log ('portal response: ' + (Protect-Secret $resp)) }
        if ($resp -match '"result"\s*:\s*1') { return $true }
        if ($resp.Trim().Length -gt 0) {
            $cleanResponse = Protect-Secret $resp.Trim()
            $m = [regex]::Match($cleanResponse, '"msg"\s*:\s*"([^"]+)"')
            if ($m.Success) { $script:LastPortalMessage = $m.Groups[1].Value }
            Write-Log ('portal returned: ' + $cleanResponse)
        }
    } catch {
        Write-Log ('portal login exception: ' + (Protect-Secret $_.Exception.Message))
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path $err) { Remove-Item $err -Force -ErrorAction SilentlyContinue }
        if (Test-Path $curlConfig) { Remove-Item $curlConfig -Force -ErrorAction SilentlyContinue }
    }
    return $false
}

if (-not (Test-Path $ConfigPath)) {
    throw "config.ps1 not found. Run install.bat first."
}
. $ConfigPath

foreach ($requiredKey in @('Username', 'Password', 'SSID', 'WlanIface')) {
    if (-not $Config.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace([string]$Config[$requiredKey])) {
        throw "config.ps1 is missing a required value: $requiredKey"
    }
}

if ($ProbeOnly) {
    $page = Get-PortalPage
    $port = Get-PortalPort
    $serverSuffix = if ($null -eq $page.AccountSuffix) { '<unknown>' } else { [string]$page.AccountSuffix }
    Write-Log ('portal probe: host={0} port={1} page_http={2} page_curl={3} client_ip={4} js_version={5} configured_suffix="{6}" server_suffix="{7}" login_method={8} account_prefix={9}' -f (Get-PortalHost), $port, $page.HttpCode, $page.CurlExit, $page.ClientIP, $page.JsVersion, $Config.AccountSuffix, $serverSuffix, $page.LoginMethod, $page.AccountPrefixEnabled)
    Write-Host ('Portal: https://{0}:{1}' -f (Get-PortalHost), $port)
    Write-Host ('Page HTTP: {0}, curl exit: {1}, client IP: {2}' -f $page.HttpCode, $page.CurlExit, $page.ClientIP)
    Write-Host ('Portal JavaScript version: {0}' -f $page.JsVersion)
    Write-Host ('Configured suffix: {0}; server suffix: {1}' -f $Config.AccountSuffix, $serverSuffix)
    if ($page.HttpCode -eq '200' -and $page.CurlExit -eq 0) { exit 0 }
    exit 1
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\NJUPT-Net-KeepAlive', [ref]$createdNew)
if (-not $createdNew) {
    Write-Log 'another keepalive instance is already running, exiting'
    exit 0
}

try {
    Write-Log ('keepalive started, version={0}' -f $script:KeepAliveVersion)
    $nextDelay = 30
    $exitCode = 0

    while ($true) {
        try {
            if ((Test-Internet) -and -not $ForceLogin) {
                $script:FailCount = 0
                if ($Once) { break }
                Start-Sleep -Seconds 60
                continue
            }

            $wired = Test-WiredUp
            $checkLabel = if ($ForceLogin) { 'forced login check requested' } else { 'offline detected' }
            Write-Log ('{0} (wiredUp={1})' -f $checkLabel, $wired)

            if (-not $wired) {
                $wifi = Get-WifiState
                if ($wifi.State -ne 'connected' -or $wifi.SSID -ne $Config.SSID) {
                    Ensure-Wifi | Out-Null
                }
            }

            if ($ForceLogin -or -not (Test-Internet)) {
                $ok = Invoke-PortalLogin
                Start-Sleep -Seconds 5
                $online = Test-Internet
                Write-Log ('portal login attempted, ok={0}, online={1}' -f $ok, $online)

                if (-not $online) {
                    $script:FailCount++
                    if ($script:LastPortalMessage -match '\u8ba4\u8bc1\u51fa\u73b0\u5f02\u5e38|\u5bc6\u7801\u9519\u8bef|\u8d26\u53f7|\u8fd0\u8425\u5546') {
                        $script:AuthConfigFailCount++
                        Write-Log ('authentication configuration failure {0}: {1}' -f $script:AuthConfigFailCount, $script:LastPortalMessage)
                        if ($script:AuthConfigFailCount -ge 3) {
                            Write-Log 'authentication configuration failed 3 times, stopping to avoid triggering Portal limits'
                            $exitCode = 3
                            break
                        }
                    } else {
                        $script:AuthConfigFailCount = 0
                    }
                    $nextDelay = [Math]::Min(300, 30 * [Math]::Pow(2, [Math]::Min($script:FailCount, 4)))
                    if ($Once) {
                        Write-Log 'single login attempt failed'
                    } else {
                        Write-Log ('login retry in {0}s (consecutive failures: {1})' -f $nextDelay, $script:FailCount)
                    }
                } else {
                    $script:FailCount = 0
                    $script:AuthConfigFailCount = 0
                    $nextDelay = 30
                }
            }
        } catch {
            Write-Log ('error: ' + (Protect-Secret $_.Exception.Message))
        }

        if ($Once) { break }
        Start-Sleep -Seconds $nextDelay
    }
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}

if ($exitCode -ne 0) { exit $exitCode }

#Requires -Version 5.1
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.ps1'),
    [switch]$Once,
    [switch]$DebugMode,
    [switch]$ProbeOnly,
    [switch]$ForceLogin
)

$ErrorActionPreference = 'Continue'
$script:FailCount = 0
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

function Get-Account {
    return (',0,' + $Config.Username + $Config.AccountSuffix)
}

function Get-PortalHost {
    if ($Config.PortalIP) { return $Config.PortalIP }
    return '10.10.244.11'
}

function Get-PortalPort {
    if ($Config.PortalPort) { return [int]$Config.PortalPort }
    return 802
}

function Get-PortalPage {
    $tmp = Join-Path $env:TEMP ('portal-' + [guid]::NewGuid().ToString('N') + '.html')
    $err = Join-Path $env:TEMP ('portal-' + [guid]::NewGuid().ToString('N') + '.err')
    try {
        $httpCode = (& curl.exe -k -sS -m 10 -o $tmp -w '%{http_code}' ("https://{0}/a79.htm" -f (Get-PortalHost)) 2>$err | Out-String).Trim()
        $curlExit = $LASTEXITCODE
        if (Test-Path $tmp -PathType Leaf) {
            $html = Get-Content -Path $tmp -Raw -Encoding Default -ErrorAction SilentlyContinue
            $clientIp = ''
            $m = [regex]::Match($html, "v46ip\s*=\s*'([0-9.]+)'")
            if ($m.Success) { $clientIp = $m.Groups[1].Value }
            return [pscustomobject]@{
                HttpCode  = $httpCode
                CurlExit  = $curlExit
                ClientIP  = $clientIp
            }
        }
        return [pscustomobject]@{ HttpCode = $httpCode; CurlExit = $curlExit; ClientIP = '' }
    } catch {
        return [pscustomobject]@{ HttpCode = ''; CurlExit = -1; ClientIP = '' }
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path $err) { Remove-Item $err -Force -ErrorAction SilentlyContinue }
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
    if (-not $clientIp) { $clientIp = Get-LocalIP }
    $version = Get-Random -Minimum 1000 -Maximum 10000
    Write-Log ('portal request: GET https://{0}:{1}/eportal/portal/login page_http={2} page_curl={3}' -f $portalHost, $portalPort, $page.HttpCode, $page.CurlExit)

    $tmp = Join-Path $env:TEMP ('login-' + [guid]::NewGuid().ToString('N') + '.json')
    $err = Join-Path $env:TEMP ('login-' + [guid]::NewGuid().ToString('N') + '.err')
    $curlOutputPath = $tmp.Replace('\', '/')
    try {
        # Feed the query to curl through stdin so the password never appears in
        # the process command line.
        $requestConfig = @(
            ('url = "https://{0}:{1}/eportal/portal/login"' -f $portalHost, $portalPort),
            'get',
            'silent',
            'show-error',
            'insecure',
            'max-time = 15',
            'write-out = "%{http_code}"',
            ('output = "{0}"' -f $curlOutputPath),
            'data-urlencode = "callback=dr1003"',
            'data-urlencode = "login_method=1"',
            ('data-urlencode = "user_account={0}"' -f (ConvertTo-CurlConfigValue (Get-Account))),
            ('data-urlencode = "user_password={0}"' -f (ConvertTo-CurlConfigValue $Config.Password)),
            ('data-urlencode = "wlan_user_ip={0}"' -f $clientIp),
            'data-urlencode = "wlan_user_ipv6="',
            'data-urlencode = "wlan_user_mac=000000000000"',
            'data-urlencode = "wlan_ac_ip="',
            'data-urlencode = "wlan_ac_name="',
            'data-urlencode = "jsVersion=4.1.3"',
            'data-urlencode = "terminal_type=1"',
            'data-urlencode = "lang=zh-cn"',
            ('data-urlencode = "v={0}"' -f $version),
            'data-urlencode = "lang=zh"'
        )
        $httpCode = ($requestConfig | & curl.exe --config - 2>$err | Out-String).Trim()
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
        if ($resp.Trim().Length -gt 0) { Write-Log ('portal returned: ' + (Protect-Secret $resp.Trim())) }
    } catch {
        Write-Log ('portal login exception: ' + (Protect-Secret $_.Exception.Message))
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path $err) { Remove-Item $err -Force -ErrorAction SilentlyContinue }
    }
    return $false
}

if (-not (Test-Path $ConfigPath)) {
    throw "config.ps1 not found. Run install.bat first."
}
. $ConfigPath

if ($ProbeOnly) {
    $page = Get-PortalPage
    $port = Get-PortalPort
    Write-Log ('portal probe: host={0} port={1} page_http={2} page_curl={3} client_ip={4}' -f (Get-PortalHost), $port, $page.HttpCode, $page.CurlExit, $page.ClientIP)
    Write-Host ('Portal: https://{0}:{1}' -f (Get-PortalHost), $port)
    Write-Host ('Page HTTP: {0}, curl exit: {1}, client IP: {2}' -f $page.HttpCode, $page.CurlExit, $page.ClientIP)
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
    Write-Log 'keepalive started'
    $nextDelay = 30

    while ($true) {
        try {
            if ((Test-Internet) -and -not $ForceLogin) {
                $script:FailCount = 0
                if ($Once) { break }
                Start-Sleep -Seconds 60
                continue
            }

            $wired = Test-WiredUp
            Write-Log ('offline detected (wiredUp={0})' -f $wired)

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
                    $nextDelay = [Math]::Min(300, 30 * [Math]::Pow(2, [Math]::Min($script:FailCount, 4)))
                    Write-Log ('login retry in {0}s (consecutive failures: {1})' -f $nextDelay, $script:FailCount)
                } else {
                    $script:FailCount = 0
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

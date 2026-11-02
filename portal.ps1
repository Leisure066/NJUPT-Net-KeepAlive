#Requires -Version 5.1
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.ps1'),
    [switch]$Once,
    [switch]$DebugMode
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

function New-RandomText([int]$Length) {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    -join (1..$Length | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

function Get-PortalHost {
    if ($Config.PortalIP) { return $Config.PortalIP }
    return '10.10.244.11'
}

function Get-PortalClientIP {
    $tmp = Join-Path $env:TEMP ('portal-' + [guid]::NewGuid().ToString('N') + '.html')
    try {
        & curl.exe -k -s -m 10 -o $tmp ("https://{0}/a79.htm" -f (Get-PortalHost)) 2>$null | Out-Null
        if (Test-Path $tmp) {
            $html = Get-Content -Path $tmp -Raw -Encoding Default -ErrorAction SilentlyContinue
            $m = [regex]::Match($html, "v46ip\s*=\s*'([0-9.]+)'")
            if ($m.Success) { return $m.Groups[1].Value }
        }
    } catch { }
    finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
    return ''
}

function Invoke-PortalLogin {
    $encodedUser = [uri]::EscapeDataString((Get-Account))
    $encodedPwd  = [uri]::EscapeDataString($Config.Password)
    $clientIp    = Get-LocalIP
    $portalIp    = Get-PortalClientIP
    if ($portalIp) { $clientIp = $portalIp }
    $encodedUa   = [uri]::EscapeDataString('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36 Edg/156.0.0.0')
    $ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()

    $uri = "https://{0}:804/eportal/portal/login?callback=dr1003&login_method=1&is_base64encode=0&user_account={1}&user_password={2}&wlan_user_ip={3}&wlan_user_ipv6=&wlan_user_mac=000000000000&wlan_vlan_id=0&wlan_ac_ip=&wlan_ac_name=&authex_enable=&jsVersion=4.5&terminal_type=1&lang=zh-cn&user_agent={4}&enable_r3=0&mac_type=0&rcn={5}&operate=portal_login&business_type=1&program_index={6}&page_index={7}&v=6879&lang=zh" -f (Get-PortalHost), $encodedUser, $encodedPwd, $clientIp, $encodedUa, (New-RandomText 8), ((New-RandomText 6) + $ts), ((New-RandomText 6) + $ts)

    $tmp = Join-Path $env:TEMP ('login-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        & curl.exe -k -s -m 15 -o $tmp $uri 2>$null | Out-Null
        $resp = ''
        if (Test-Path $tmp) {
            $resp = Get-Content -Path $tmp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -eq $resp) { $resp = '' }
        }
        if ($DebugMode) { Write-Log ('portal response: ' + $resp) }
        if ($resp -match '"result"\s*:\s*1') { return $true }
        if ($resp.Trim().Length -gt 0) { Write-Log ('portal returned: ' + $resp.Trim()) }
    } catch {
        Write-Log 'portal login failed'
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    return $false
}

if (-not (Test-Path $ConfigPath)) {
    throw "config.ps1 not found. Run install.bat first."
}
. $ConfigPath

Write-Log 'keepalive started'

while ($true) {
    try {
        if (Test-Internet) {
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

        if (-not (Test-Internet)) {
            $ok = Invoke-PortalLogin
            Start-Sleep -Seconds 5
            $online = Test-Internet
            Write-Log ('portal login attempted, ok={0}, online={1}' -f $ok, $online)

            if (-not $online) {
                $script:FailCount++
                if ($script:FailCount -ge 3) {
                    Write-Log ('{0} consecutive failures, backing off 300s' -f $script:FailCount)
                    Start-Sleep -Seconds 300
                }
            } else {
                $script:FailCount = 0
            }
        }
    } catch {
        Write-Log ('error: ' + $_.Exception.Message)
    }

    if ($Once) { break }
    Start-Sleep -Seconds 30
}
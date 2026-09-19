# ============================================================
# cfbestip.ps1
# Windows PowerShell 5.1 compatible
# ASCII-only source
# ============================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Basic configuration
# ------------------------------------------------------------

$BaseDir = "C:\cfst"

$CfstPath = "C:\cfst\cfst.exe"
$IpFile = "C:\cfst\ip.txt"
$CsvFile = "C:\cfst\result.csv"
$LogFile = "C:\cfst\cfbestip.log"
$LockFile = "C:\cfst\cfbestip.lock"

$MaxRuntime = 1800

# ------------------------------------------------------------
# Cloudflare configuration
# Leave empty to disable DNS update.
# Upload and Telegram will still work.
# ------------------------------------------------------------

$ApiToken = ""
$ZoneId = ""
$RecordName = ""

# ------------------------------------------------------------
# Upload configuration
# ------------------------------------------------------------

$UploadUrl = "https://cfbestip.cfworkers.com/api/upload"
$AuthKey = "BUll4BfsfsfsflKr484"

# Git OpenSSL
$OpenSSLPath = "C:\Program Files\Git\mingw64\bin\openssl.exe"

# ------------------------------------------------------------
# Speed test URL
# ------------------------------------------------------------

$SpeedUrl = "https://filedownload.helo.de5.net"

# ------------------------------------------------------------
# Telegram configuration
# Leave empty to disable Telegram.
# ------------------------------------------------------------

$TgBotToken = ""
$TgChatId = ""

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[{0}] [{1}] {2}" -f $Time, $Level, $Message

    Write-Host $Line

    try {
        Add-Content `
            -LiteralPath $LogFile `
            -Value $Line `
            -Encoding UTF8
    }
    catch {
    }
}

#$Carrier = "cu"
# ip-api.com接口网络不稳定，替换掉
#try {
#    $Geo = Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=query,isp" -TimeoutSec 10
#    $Isp = "$($Geo.isp)"

#    if ($Isp -match "China Mobile|CMCC") {
#        $Carrier = "cm"
#    }
#    elseif ($Isp -match "China Unicom") {
#        $Carrier = "cu"
#    }
#    elseif ($Isp -match "China Telecom|Chinatelecom") {
#        $Carrier = "ct"
#   }

#    Write-Log "ISP: $Isp"
#    Write-Log "Carrier: $Carrier"
#}
#catch {
#    Write-Log "Carrier detection failed, use default: $Carrier" "WARN"
#}

$Carrier = "cu"

try {
    # 获取当前公网 IPv4
    $CurrentIP = (Invoke-RestMethod -Uri "https://api-ipv4.ip.sb/ip" -TimeoutSec 10).Trim()

    Write-Log "Current IP: $CurrentIP"

    # 查询当前 IP 的 ASN / 运营商
    $IpInfoUrl = "https://api.ipinfo.io/lite/" + $CurrentIP + "?token=eaa6fa8be38d33"
    $Geo = Invoke-RestMethod -Uri $IpInfoUrl -TimeoutSec 10

    $Isp = "$($Geo.as_name)"
    $IspDomain = "$($Geo.as_domain)"

    Write-Log "ISP: $Isp"
    Write-Log "ISP Domain: $IspDomain"

    if ($IspDomain -match "chinamobile\.com") {
        $Carrier = "cm"
    }
    elseif ($IspDomain -match "chinaunicom\.cn") {
        $Carrier = "cu"
    }
    elseif ($IspDomain -match "ct1000\.com") {
        $Carrier = "ct"
    }

    Write-Log "Carrier: $Carrier"
}
catch {
    Write-Log "Carrier detection failed, use default: $Carrier" "WARN"
}

function Test-Environment {
    Write-Log "Checking environment"

    if (-not (Test-Path -LiteralPath $BaseDir)) {
        New-Item `
            -ItemType Directory `
            -Path $BaseDir `
            -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $CfstPath)) {
        throw "cfst.exe not found: $CfstPath"
    }

    if (-not (Test-Path -LiteralPath $IpFile)) {
        throw "ip.txt not found: $IpFile"
    }

    if (-not (Test-Path -LiteralPath $OpenSSLPath)) {
        throw "OpenSSL not found: $OpenSSLPath"
    }

    $IpFileInfo = Get-Item -LiteralPath $IpFile

    if ($IpFileInfo.Length -eq 0) {
        throw "ip.txt is empty: $IpFile"
    }

    Write-Log "cfst.exe: $CfstPath"
    Write-Log "ip.txt: $IpFile"
    Write-Log "result.csv: $CsvFile"
    Write-Log "Speed URL: $SpeedUrl"
    Write-Log "OpenSSL: $OpenSSLPath"
}

function Acquire-Lock {
    if (Test-Path -LiteralPath $LockFile) {
        try {
            $OldLock = Get-Content `
                -LiteralPath $LockFile `
                -ErrorAction SilentlyContinue

            if ($OldLock) {
                Write-Log "Lock already exists. PID: $OldLock" "WARN"
            }
            else {
                Write-Log "Lock already exists" "WARN"
            }
        }
        catch {
            Write-Log "Lock already exists" "WARN"
        }

        return $false
    }

    try {
        $CurrentPid = $PID

        Set-Content `
            -LiteralPath $LockFile `
            -Value $CurrentPid `
            -Encoding ASCII `
            -Force

        Write-Log "Lock acquired. PID: $CurrentPid"

        return $true
    }
    catch {
        Write-Log "Failed to create lock: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Release-Lock {
    try {
        if (Test-Path -LiteralPath $LockFile) {
            Remove-Item `
                -LiteralPath $LockFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Write-Log "Lock released"
    }
    catch {
    }
}

function Test-PeakTime {
    $Now = Get-Date
    $Hour = $Now.Hour

    if ($Hour -ge 19 -and $Hour -lt 23) {
        return $true
    }

    return $false
}

function Start-CfstTest {
    Write-Log "Preparing CFST test"

    if (Test-Path -LiteralPath $CsvFile) {
        try {
            Remove-Item `
                -LiteralPath $CsvFile `
                -Force `
                -ErrorAction Stop

            Write-Log "Removed old result.csv"
        }
        catch {
            throw "Cannot remove old result.csv: $($_.Exception.Message)"
        }
    }

    $IsPeak = Test-PeakTime

    if ($IsPeak) {
        Write-Log "Peak mode detected"

        $Arguments = @(
            "-httping",
            "-cfcolo", "HKG,NRT,SIN",
            "-n", "500",
            "-t", "8",
            "-dn", "10",
            "-dt", "15",
            "-tp", "443",
            "-tl", "200",
            "-tll", "50",
            "-tlr", "0.2",
            "-sl", "0.01",
            "-p", "10",
            "-url", $SpeedUrl,
            "-o", $CsvFile
        )
    }
    else {
        Write-Log "Normal mode detected"

        $Arguments = @(
            "-httping",
            "-cfcolo", "HKG,NRT,SIN",
            "-n", "500",
            "-t", "4",
            "-dn", "10",
            "-dt", "10",
            "-tp", "443",
            "-tl", "200",
            "-tll", "50",
            "-tlr", "0",
            "-sl", "0.01",
            "-p", "10",
            "-url", $SpeedUrl,
            "-o", $CsvFile
        )
    }

    Write-Log "Starting CFST"

    try {
        $Process = Start-Process `
            -FilePath $CfstPath `
            -ArgumentList $Arguments `
            -WorkingDirectory $BaseDir `
            -PassThru `
            -NoNewWindow
    }
    catch {
        throw "Failed to start CFST: $($_.Exception.Message)"
    }

    Write-Log "CFST started. PID: $($Process.Id)"

    $StartTime = Get-Date
    $LastSize = -1
    $StableCount = 0
    $CsvReady = $false

    while ($true) {
        Start-Sleep -Seconds 2

        $Elapsed = ((Get-Date) - $StartTime).TotalSeconds

        if ($Elapsed -ge $MaxRuntime) {
            Write-Log "CFST timeout reached" "ERROR"

            try {
                if (-not $Process.HasExited) {
                    Stop-Process `
                        -Id $Process.Id `
                        -Force `
                        -ErrorAction SilentlyContinue

                    Write-Log "CFST process terminated after timeout" "WARN"
                }
            }
            catch {
            }

            throw "CFST test timeout"
        }

        if (Test-Path -LiteralPath $CsvFile) {
            try {
                $FileInfo = Get-Item -LiteralPath $CsvFile
                $CurrentSize = $FileInfo.Length

                if ($CurrentSize -gt 0) {
                    if ($CurrentSize -eq $LastSize) {
                        $StableCount++
                    }
                    else {
                        $StableCount = 0
                    }

                    $LastSize = $CurrentSize

                    Write-Log "result.csv size: $CurrentSize bytes"

                    if ($StableCount -ge 2) {
                        $CsvReady = $true
                        break
                    }
                }
            }
            catch {
            }
        }

        try {
            if ($Process.HasExited) {
                Write-Log "CFST process exited. ExitCode: $($Process.ExitCode)"

                if (Test-Path -LiteralPath $CsvFile) {
                    $FinalInfo = Get-Item -LiteralPath $CsvFile

                    if ($FinalInfo.Length -gt 0) {
                        $CsvReady = $true
                        break
                    }
                }

                throw "CFST exited without a valid result.csv"
            }
        }
        catch {
            if (
                $_.Exception.Message -eq `
                "CFST exited without a valid result.csv"
            ) {
                throw
            }
        }
    }

    if (-not $CsvReady) {
        throw "CFST did not produce a valid result.csv"
    }

    Write-Log "result.csv is ready"

    try {
        if (-not $Process.HasExited) {
            Stop-Process `
                -Id $Process.Id `
                -Force `
                -ErrorAction SilentlyContinue

            Write-Log "CFST process stopped after result.csv became stable"
        }
    }
    catch {
    }
}

function Convert-ToNumber {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return 0
    }

    $Text = [string]$Value
    $Text = $Text.Trim()

    if ($Text.Length -eq 0) {
        return 0
    }

    $Text = $Text.Replace("MB/s", "")
    $Text = $Text.Replace("Mbps", "")
    $Text = $Text.Replace("MB", "")
    $Text = $Text.Replace("ms", "")
    $Text = $Text.Replace("%", "")
    $Text = $Text.Replace(",", "")
    $Text = $Text.Trim()

    $Number = 0.0

    $Ok = [double]::TryParse(
        $Text,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$Number
    )

    if ($Ok) {
        return $Number
    }

    return 0
}

function Read-CfstResult {
    if (-not (Test-Path -LiteralPath $CsvFile)) {
        throw "result.csv not found"
    }

    $FileInfo = Get-Item -LiteralPath $CsvFile

    if ($FileInfo.Length -eq 0) {
        throw "result.csv is empty"
    }

    Write-Log "Reading result.csv"

    $Rows = $null

    try {
        $Rows = Import-Csv `
            -LiteralPath $CsvFile `
            -Encoding UTF8
    }
    catch {
        $Rows = Import-Csv `
            -LiteralPath $CsvFile
    }

    if ($null -eq $Rows) {
        throw "Failed to parse result.csv"
    }

    $Result = @()

    foreach ($Row in $Rows) {
        $Properties = @($Row.PSObject.Properties)

        if ($Properties.Count -eq 0) {
            continue
        }

        $Values = @()

        foreach ($Property in $Properties) {
            $Values += $Property.Value
        }

        if ($Values.Count -lt 6) {
            Write-Log "Invalid CSV row. Column count: $($Values.Count)" "WARN"
            continue
        }

        # Actual CFST 2.2.5 CSV order:
        #
        # 0 = IP
        # 1 = Sent
        # 2 = Received
        # 3 = Packet Loss
        # 4 = Average Latency
        # 5 = Download Speed
        # 6 = Colo / Region

        $Ip = [string]$Values[0]

        $Sent = Convert-ToNumber $Values[1]

        $Received = Convert-ToNumber $Values[2]

        $PacketLoss = Convert-ToNumber $Values[3]

        $Latency = Convert-ToNumber $Values[4]

        $Speed = Convert-ToNumber $Values[5]

        $Region = "N/A"

        if ($Values.Count -ge 7) {
            $RegionText = [string]$Values[6]

            if (-not [string]::IsNullOrWhiteSpace($RegionText)) {
                $Region = $RegionText.Trim()
            }
        }

        if ([string]::IsNullOrWhiteSpace($Ip)) {
            continue
        }

        $Result += [PSCustomObject]@{
            ip = $Ip.Trim()
            sent = $Sent
            received = $Received
            packetLoss = $PacketLoss
            latency = $Latency
            speed = $Speed
            region = $Region
            time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            carrier = $Carrier
        }
    }

    if ($Result.Count -eq 0) {
        throw "No valid records found in result.csv"
    }

    Write-Log "Parsed $($Result.Count) records"

    $RegionCount = @(
        $Result |
            Where-Object {
                $_.region -ne "N/A" -and
                -not [string]::IsNullOrWhiteSpace($_.region)
            }
    ).Count

    if ($RegionCount -gt 0) {
        Write-Log "Detected CFST region codes: $RegionCount"
    }
    else {
        Write-Log "No CFST region codes detected. Region will be N/A." "WARN"
    }

    return $Result
}

function Get-BestResult {
    param(
        [object[]]$Results
    )

    if ($null -eq $Results -or $Results.Count -eq 0) {
        throw "No test results available"
    }

    $Usable = @(
        $Results |
            Where-Object {
                $_.speed -gt 0
            }
    )

    if ($Usable.Count -eq 0) {
        $Usable = $Results
    }

    $Best = $Usable |
        Sort-Object `
            @{ Expression = { $_.packetLoss }; Ascending = $true }, `
            @{ Expression = { $_.latency }; Ascending = $true }, `
            @{ Expression = { $_.speed }; Ascending = $false } |
        Select-Object -First 1

    if ($null -eq $Best) {
        throw "Failed to select best IP"
    }

    Write-Log "Best IP: $($Best.ip)"
    Write-Log "Best latency: $($Best.latency)"
    Write-Log "Best speed: $($Best.speed)"
    Write-Log "Best packet loss: $($Best.packetLoss)"
    Write-Log "Best region: $($Best.region)"

    return $Best
}

function Update-CloudflareDns {
    param(
        [string]$Ip
    )

    if (
        [string]::IsNullOrWhiteSpace($ApiToken) -or
        [string]::IsNullOrWhiteSpace($ZoneId) -or
        [string]::IsNullOrWhiteSpace($RecordName)
    ) {
        Write-Log "Cloudflare DNS configuration is empty. DNS update skipped."
        return
    }

    if ([string]::IsNullOrWhiteSpace($Ip)) {
        Write-Log "Best IP is empty. DNS update skipped." "WARN"
        return
    }

    Write-Log "Starting Cloudflare DNS update"

    try {
        $Headers = @{
            "Authorization" = "Bearer $ApiToken"
            "Content-Type" = "application/json"
        }

        $QueryUrl = `
            "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records?type=A&name=$RecordName"

        $Response = Invoke-RestMethod `
            -Uri $QueryUrl `
            -Method Get `
            -Headers $Headers `
            -TimeoutSec 30

        if (-not $Response.success) {
            throw "Cloudflare query failed"
        }

        if ($Response.result.Count -eq 0) {
            throw "Cloudflare DNS record not found: $RecordName"
        }

        $Record = $Response.result[0]

        $RecordId = $Record.id
        $OldIp = $Record.content

        if ($OldIp -eq $Ip) {
            Write-Log "Cloudflare DNS already points to $Ip"
            return
        }

        Write-Log "Cloudflare old IP: $OldIp"
        Write-Log "Cloudflare new IP: $Ip"

        $BodyObject = @{
            type = "A"
            name = $RecordName
            content = $Ip
            ttl = 60
            proxied = $false
        }

        $Body = $BodyObject | ConvertTo-Json -Depth 10

        $UpdateUrl = `
            "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/$RecordId"

        $UpdateResponse = Invoke-RestMethod `
            -Uri $UpdateUrl `
            -Method Put `
            -Headers $Headers `
            -Body $Body `
            -TimeoutSec 30

        if (-not $UpdateResponse.success) {
            throw "Cloudflare DNS update failed"
        }

        Write-Log "Cloudflare DNS updated successfully"
    }
    catch {
        Write-Log `
            "Cloudflare DNS update failed: $($_.Exception.Message)" `
            "ERROR"
    }
}

function Upload-Results {
	
    param(
        [object[]]$Results
    )

    if ($null -eq $Results -or $Results.Count -eq 0) {
        Write-Log "No results to upload" "WARN"
        return
    }

    Write-Log "Uploading results using OpenSSL"

    try {
        if (-not (Test-Path -LiteralPath $OpenSSLPath)) {
            throw "OpenSSL not found: $OpenSSLPath"
        }

        $Uri = New-Object System.Uri($UploadUrl)

        $HostName = $Uri.Host
        $Port = $Uri.Port
        $Path = $Uri.PathAndQuery

        if ([string]::IsNullOrWhiteSpace($Path)) {
            $Path = "/"
        }

        $Data = @()

        foreach ($Item in $Results) {
            $Data += @{
                ip = $Item.ip
                speed = $Item.speed
                latency = $Item.latency
                region = $Item.region
                time = $Item.time
                carrier = $Carrier
            }
        }

#       $Json = $Data | ConvertTo-Json -Depth 20 -Compress
		$Json = ConvertTo-Json `
			-InputObject $Data `
			-Depth 20 `
			-Compress

        $Utf8 = New-Object System.Text.UTF8Encoding($false)

        $BodyBytes = $Utf8.GetBytes($Json)
        $BodyLength = $BodyBytes.Length

        $Request = ""
        $Request += "POST $Path HTTP/1.1`r`n"
        $Request += "Host: $HostName`r`n"
        $Request += "Authorization: $AuthKey`r`n"
        $Request += "Content-Type: application/json; charset=utf-8`r`n"
        $Request += "Content-Length: $BodyLength`r`n"
        $Request += "Connection: close`r`n"
        $Request += "`r`n"
        $Request += $Json

        Write-Log "OpenSSL target: $HostName`:$Port"
        Write-Log "Upload path: $Path"
        Write-Log "Upload body size: $BodyLength bytes"
		Write-Log "Upload body: [$Json]"

        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo

        $ProcessInfo.FileName = $OpenSSLPath
        $ProcessInfo.Arguments = `
            "s_client -connect ${HostName}:${Port} -servername $HostName -quiet"

        $ProcessInfo.UseShellExecute = $false
        $ProcessInfo.CreateNoWindow = $true
        $ProcessInfo.RedirectStandardInput = $true
        $ProcessInfo.RedirectStandardOutput = $true
        $ProcessInfo.RedirectStandardError = $true

        try {
            $ProcessInfo.StandardInputEncoding = $Utf8
        }
        catch {
        }

        $OpenSSLProcess = New-Object System.Diagnostics.Process
        $OpenSSLProcess.StartInfo = $ProcessInfo

        $Started = $OpenSSLProcess.Start()

        if (-not $Started) {
            throw "Failed to start OpenSSL"
        }

        $OpenSSLProcess.StandardInput.Write($Request)
        $OpenSSLProcess.StandardInput.Flush()
        $OpenSSLProcess.StandardInput.Close()

        # ============================================================
        # 直接读取 OpenSSL StandardOutput 原始字节
        # 不使用 ReadToEnd() 的字符串解码
        # 强制使用 UTF-8 解码 HTTP 响应
        # ============================================================

        $ResponseMemory = New-Object System.IO.MemoryStream

        try {
            $OpenSSLProcess.StandardOutput.BaseStream.CopyTo(
                $ResponseMemory
            )

            $ResponseBytes = $ResponseMemory.ToArray()

            $ResponseText = $Utf8.GetString(
                $ResponseBytes
            )
        }
        finally {
            $ResponseMemory.Dispose()
        }

        # ============================================================
        # StandardError 同样直接读取
        # ============================================================

        $ErrorMemory = New-Object System.IO.MemoryStream

        try {
            $OpenSSLProcess.StandardError.BaseStream.CopyTo(
                $ErrorMemory
            )

            $ErrorBytes = $ErrorMemory.ToArray()

            # OpenSSL 错误输出主要是 ASCII。
            # 如果包含 UTF-8 内容，也按 UTF-8 解码。
            $ErrorText = $Utf8.GetString(
                $ErrorBytes
            )
        }
        finally {
            $ErrorMemory.Dispose()
        }

        if (-not $OpenSSLProcess.WaitForExit(60000)) {
            try {
                $OpenSSLProcess.Kill()
            }
            catch {
            }

            throw "OpenSSL upload timeout"
        }

        $ExitCode = $OpenSSLProcess.ExitCode

        if (-not [string]::IsNullOrWhiteSpace($ErrorText)) {
            $ErrorLines = $ErrorText.Trim()

            if ($ErrorLines.Length -gt 1000) {
                $ErrorLines = $ErrorLines.Substring(
                    0,
                    1000
                )
            }

            Write-Log "OpenSSL: $ErrorLines"
        }

        if ([string]::IsNullOrWhiteSpace($ResponseText)) {
            throw `
                "OpenSSL returned an empty HTTP response. ExitCode: $ExitCode"
        }

        $ResponseText = $ResponseText.Trim()

        $StatusCode = 0

        if (
            $ResponseText -match `
            "HTTP/\d(?:\.\d)?\s+(\d{3})"
        ) {
            $StatusCode = [int]$Matches[1]
        }

        if ($StatusCode -lt 200 -or $StatusCode -ge 300) {
            $ShortResponse = $ResponseText

            if ($ShortResponse.Length -gt 1000) {
                $ShortResponse = `
                    $ShortResponse.Substring(0, 1000)
            }

            throw `
                "Upload HTTP status: $StatusCode. Response: $ShortResponse"
        }

        Write-Log `
            "Upload completed successfully. HTTP status: $StatusCode"

        $ShortResponse = $ResponseText

        if ($ShortResponse.Length -gt 1000) {
            $ShortResponse = `
                $ShortResponse.Substring(0, 1000)
        }

        Write-Log "Upload response: $ShortResponse"
    }
    catch {
        Write-Log `
            "Upload failed: $($_.Exception.Message)" `
            "ERROR"
    }
}
function Send-Telegram {
    param(
        [object]$Best
    )

    if (
        [string]::IsNullOrWhiteSpace($TgBotToken) -or
        [string]::IsNullOrWhiteSpace($TgChatId)
    ) {
        Write-Log "Telegram configuration is empty. Telegram skipped."
        return
    }

    if ($null -eq $Best) {
        Write-Log "No best result. Telegram skipped."
        return
    }

    Write-Log "Sending Telegram notification"

    try {
        $TelegramUrl = `
            "https://api.telegram.org/bot$TgBotToken/sendMessage"

        $Text = @"
CFST result

IP: $($Best.ip)
Speed: $($Best.speed) MB/s
Latency: $($Best.latency) ms
Packet Loss: $($Best.packetLoss) %
Region: $($Best.region)
Carrier: $Carrier
Time: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@

        $BodyObject = @{
            chat_id = $TgChatId
            text = $Text
        }

        $Body = $BodyObject | ConvertTo-Json -Depth 10

        $Response = Invoke-RestMethod `
            -Uri $TelegramUrl `
            -Method Post `
            -ContentType "application/json" `
            -Body $Body `
            -TimeoutSec 30

        if ($Response.ok -eq $true) {
            Write-Log "Telegram notification sent"
        }
        else {
            Write-Log `
                "Telegram API returned failure" `
                "ERROR"
        }
    }
    catch {
        Write-Log `
            "Telegram send failed: $($_.Exception.Message)" `
            "ERROR"
    }
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

$LockAcquired = $false

try {
    Write-Log "============================================================"
    Write-Log "cfbestip.ps1 started"

    Test-Environment

    $LockAcquired = Acquire-Lock

    if (-not $LockAcquired) {
        Write-Log "Another cfbestip instance is running. Exit."
        exit 0
    }

    Start-CfstTest

    $Results = @(Read-CfstResult)

    $Best = Get-BestResult -Results $Results

    Update-CloudflareDns -Ip $Best.ip

    Upload-Results -Results $Results

    Send-Telegram -Best $Best

    Write-Log "cfbestip.ps1 completed successfully"
    Write-Log "============================================================"
}
catch {
    Write-Log `
        "FATAL: $($_.Exception.Message)" `
        "ERROR"

    Write-Log "cfbestip.ps1 failed"
}
finally {
    if ($LockAcquired) {
        Release-Lock
    }
}
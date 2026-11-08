#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Status', 'Restore')]
    [string]$Action = 'Status',

    [switch]$NoPause,

    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 0

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
}
catch {
}

$scriptDir = Split-Path -Parent $PSCommandPath
$statePath = Join-Path $scriptDir 'hotspot-state.json'
$logPath = Join-Path $scriptDir 'hotspot-over-tun.log'
$tunAdapterName = 'FlClash'
$tunProfileName = 'FlClash'
$hotspotIp = '192.168.137.1'
$icssvcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
    }

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host $line }
    }
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        throw '该操作需要管理员权限。'
    }
}

function Hide-ConsoleWindow {
    try {
        if (-not ('Native.ConsoleWindow' -as [type])) {
            Add-Type -Namespace Native -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        }
        $handle = [Native.ConsoleWindow]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) {
            [Native.ConsoleWindow]::ShowWindow($handle, 0) | Out-Null
        }
    }
    catch {
    }
}

function Show-UiMessage {
    param(
        [string]$Text,
        [string]$Title = 'Hotspot over FlClash',
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information'
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $iconValue = [System.Windows.Forms.MessageBoxIcon]$Icon
        [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $iconValue) | Out-Null
    }
    catch {
    }
}

if ($Silent) {
    Hide-ConsoleWindow
}

$needsAdmin = @('Start', 'Stop', 'Restore') -contains $Action
if ($needsAdmin -and -not (Test-Admin)) {
    if (-not $Silent) {
        Write-Host '需要管理员权限，正在请求 UAC 提权...' -ForegroundColor Yellow
    }

    $argLine = '-NoProfile -ExecutionPolicy Bypass -Sta -File "{0}" -Action {1}' -f $PSCommandPath, $Action
    if ($Silent) {
        $argLine += ' -Silent'
    }
    if ($NoPause) {
        $argLine += ' -NoPause'
    }

    try {
        $startProcessArgs = @{
            FilePath = 'powershell.exe'
            Verb = 'RunAs'
            ArgumentList = $argLine
        }
        if ($Silent) {
            $startProcessArgs['WindowStyle'] = 'Hidden'
        }
        Start-Process @startProcessArgs | Out-Null
        exit 0
    }
    catch {
        $message = "提权失败: $($_.Exception.Message)"
        Write-Log $message ERROR
        if ($Silent) {
            Show-UiMessage -Text $message -Icon Error
        }
        else {
            Write-Host $message -ForegroundColor Red
            if (-not $NoPause) {
                Read-Host '按回车退出' | Out-Null
            }
        }
        exit 1
    }
}

function Initialize-WinRT {
    [void][Reflection.Assembly]::LoadWithPartialName('System.Runtime.WindowsRuntime')
    [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null

    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -like 'IAsyncOperation*' -and
            $_.GetParameters()[0].ParameterType.Name -notlike '*WithProgress*'
        } | Select-Object -First 1)

    if (-not $script:AsTaskGeneric) {
        throw '无法定位 System.WindowsRuntimeSystemExtensions.AsTask。'
    }

    $startMethod = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager].GetMethods() | Where-Object {
        $_.Name -eq 'StartTetheringAsync' -and $_.GetParameters().Count -eq 0
    } | Select-Object -First 1

    if (-not $startMethod) {
        throw '无法定位 NetworkOperatorTetheringManager.StartTetheringAsync。'
    }

    $script:TetheringResultType = $startMethod.ReturnType.GetGenericArguments()[0]
    Write-Log "WinRT 已加载；结果类型: $($script:TetheringResultType.FullName)" DEBUG
}

function Await-WinRT {
    param(
        [Parameter(Mandatory = $true)]$Operation,
        [int]$TimeoutMs = 30000,
        [string]$Label = 'WinRT'
    )

    if ($null -eq $Operation) {
        throw "$Label 返回了空操作。"
    }

    $task = $script:AsTaskGeneric.MakeGenericMethod($script:TetheringResultType).Invoke($null, @($Operation))
    try {
        if (-not $task.Wait($TimeoutMs)) {
            throw "$Label 超时（${TimeoutMs}ms）。"
        }
    }
    catch [System.AggregateException] {
        $inner = $_.Exception.InnerException
        if ($inner) {
            throw "$Label 失败: $($inner.Message)"
        }
        throw
    }

    return $task.Result
}

function Get-ConnectionProfiles {
    return [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()
}

function Get-FlClashProfile {
    $profiles = @(Get-ConnectionProfiles)
    $candidates = @($profiles | Where-Object { $_.ProfileName -eq $tunProfileName })

    foreach ($profile in $candidates) {
        $level = ''
        try {
            $level = $profile.GetNetworkConnectivityLevel().ToString()
        }
        catch {
        }
        if ($level -eq 'InternetAccess' -or $level -eq 'ConstrainedInternetAccess') {
            return $profile
        }
    }

    if ($candidates.Count -gt 0) {
        throw "连接配置 '$tunProfileName' 存在，但当前没有 InternetAccess；请检查 FlClash TUN 与节点状态。"
    }

    throw "未找到名为 '$tunProfileName' 的连接配置。请确认 FlClash 已启动且 TUN 已开启。"
}

function Get-WlanProfile {
    $profiles = @(Get-ConnectionProfiles)
    foreach ($profile in $profiles) {
        try {
            $level = $profile.GetNetworkConnectivityLevel().ToString()
            if ($profile.IsWlanConnectionProfile -and ($level -eq 'InternetAccess' -or $level -eq 'ConstrainedInternetAccess')) {
                return $profile
            }
        }
        catch {
        }
    }
    return $null
}

function Get-TunAdapterInfo {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq $tunAdapterName -or $_.InterfaceDescription -eq 'Meta Tunnel'
    } | Select-Object -First 1

    if (-not $adapter) {
        throw "未找到 FlClash TUN 网卡（$tunAdapterName / Meta Tunnel）。"
    }
    if ($adapter.Status -ne 'Up') {
        throw "FlClash TUN 网卡当前状态为 $($adapter.Status)，请先开启 TUN。"
    }

    $ipInfo = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $ipAddress = $null
    if ($ipInfo) {
        $ipAddress = $ipInfo.IPAddress
    }

    return [PSCustomObject]@{
        Name = $adapter.Name
        Description = $adapter.InterfaceDescription
        ifIndex = $adapter.ifIndex
        InterfaceGuid = [Guid]$adapter.InterfaceGuid
        Status = $adapter.Status
        IPAddress = $ipAddress
    }
}

function New-TetheringManager {
    param([Parameter(Mandatory = $true)]$Profile)

    return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($Profile)
}

function Get-TetheringState {
    param($Manager)

    if (-not $Manager) {
        return 'Unknown'
    }
    try {
        return $Manager.TetheringOperationalState.ToString()
    }
    catch {
        return 'Unknown'
    }
}

function Get-ApInfo {
    param($Manager)

    try {
        $ap = $Manager.GetCurrentAccessPointConfiguration()
        return [PSCustomObject]@{
            Ssid = [string]$ap.Ssid
            Band = [string]$ap.Band
        }
    }
    catch {
        return [PSCustomObject]@{
            Ssid = '(不可用)'
            Band = '(不可用)'
        }
    }
}

function Get-HotspotIpInfo {
    $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -eq $hotspotIp
    } | Select-Object -First 1

    if (-not $address) {
        return $null
    }

    $adapter = Get-NetAdapter -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue
    $adapterName = $address.InterfaceAlias
    $adapterDescription = ''
    if ($adapter) {
        $adapterName = $adapter.Name
        $adapterDescription = $adapter.InterfaceDescription
    }

    return [PSCustomObject]@{
        IPAddress = $address.IPAddress
        InterfaceIndex = $address.InterfaceIndex
        InterfaceAlias = $address.InterfaceAlias
        AdapterName = $adapterName
        AdapterDescription = $adapterDescription
    }
}

function Get-ProxyListener {
    $listener = Get-NetTCPConnection -State Listen -LocalPort 7890 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) {
        return $null
    }

    return [PSCustomObject]@{
        LocalAddress = $listener.LocalAddress
        LocalPort = $listener.LocalPort
        OwningProcess = $listener.OwningProcess
    }
}

function Get-IcssvcBytes {
    param([string]$Name)

    $value = (Get-ItemProperty -Path $icssvcKey -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($null -eq $value) {
        return $null
    }
    return [byte[]]$value
}

function Get-IcssvcPreferredGuid {
    $bytes = Get-IcssvcBytes -Name 'PreferredPublicInterface'
    if (-not $bytes -or $bytes.Length -lt 16) {
        return $null
    }
    return New-Object Guid (,[byte[]]$bytes)
}

function ConvertTo-Base64 {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes) {
        return $null
    }
    return [Convert]::ToBase64String($Bytes)
}

function ConvertFrom-Base64 {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    return [Convert]::FromBase64String($Text)
}

function Set-IcssvcBytes {
    param(
        [string]$Name,
        [byte[]]$Bytes
    )

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\icssvc\Settings', $true)
    if (-not $key) {
        throw '无法打开 icssvc 设置注册表键。'
    }

    try {
        $key.SetValue($Name, [byte[]]$Bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
    }
    finally {
        $key.Close()
    }
}

function Get-IcsConnections {
    if (-not (Test-Admin)) {
        throw '读取 ICS 共享状态需要管理员权限。'
    }

    $manager = $null
    try {
        $manager = New-Object -ComObject HNetCfg.HNetShare
    }
    catch {
        throw "无法创建 HNetCfg.HNetShare COM 对象: $($_.Exception.Message)"
    }

    $enumerator = $manager.EnumEveryConnection
    if ($null -eq $enumerator) {
        throw 'HNetCfg.HNetShare.EnumEveryConnection 为空；请确认以管理员身份运行且 ICS 服务正常。'
    }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($connection in $enumerator) {
        try {
            $props = $manager.NetConnectionProps($connection)
            $config = $manager.INetSharingConfigurationForINetConnection($connection)

            $results.Add([PSCustomObject]@{
                    Name = [string]$props.Name
                    DeviceName = [string]$props.DeviceName
                    Guid = [Guid]$props.Guid
                    Status = [string]$props.Status
                    MediaType = [string]$props.MediaType
                    SharingEnabled = [bool]$config.SharingEnabled
                    SharingType = [int]$config.SharingConnectionType
                    Connection = $connection
                    Config = $config
                })
        }
        catch {
            Write-Log "跳过 ICS 连接: $($_.Exception.Message)" WARN
        }
    }

    return $results.ToArray()
}

function Get-IcsSnapshot {
    try {
        $connections = Get-IcsConnections
        $snapshot = @()
        foreach ($connection in $connections) {
            $snapshot += [PSCustomObject]@{
                Name = $connection.Name
                DeviceName = $connection.DeviceName
                Guid = $connection.Guid.ToString()
                SharingEnabled = $connection.SharingEnabled
                SharingType = $connection.SharingType
            }
        }
        return $snapshot
    }
    catch {
        Write-Log "ICS 快照失败: $($_.Exception.Message)" WARN
        return $null
    }
}

function Save-StateSnapshot {
    param(
        $TunInfo,
        [string]$TetheringState,
        $ApInfo,
        $IcsSnapshot,
        [string]$IcsError
    )

    $prefBytes = Get-IcssvcBytes -Name 'PreferredPublicInterface'

    $state = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        TetheringWasOn = ($TetheringState -eq 'On')
        TetheringStateAtStart = $TetheringState
        TunProfileName = $tunProfileName
        TunInterfaceName = $TunInfo.Name
        TunInterfaceGuid = $TunInfo.InterfaceGuid.ToString()
        TunIp = $TunInfo.IPAddress
        ApSsid = $ApInfo.Ssid
        ApBand = $ApInfo.Band
        PreferredPublicInterfaceB64 = ConvertTo-Base64 -Bytes $prefBytes
        IcsSnapshotAvailable = ($null -ne $IcsSnapshot)
        IcsSnapshotError = $IcsError
        IcsConnections = $IcsSnapshot
    }

    $json = $state | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "已保存启动前快照: $statePath"
}

function Read-StateSnapshot {
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        Write-Log "读取快照失败: $($_.Exception.Message)" WARN
        return $null
    }
}

function Remove-StateSnapshot {
    if (Test-Path -LiteralPath $statePath) {
        Remove-Item -LiteralPath $statePath -Force
        Write-Log '已删除启动前快照。'
    }
}

function Wait-TetheringState {
    param(
        $Manager,
        [string]$Desired,
        [int]$TimeoutSec = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $state = Get-TetheringState -Manager $Manager

    do {
        $state = Get-TetheringState -Manager $Manager
        if ($state -eq $Desired) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw "等待热点状态变为 $Desired 超时（当前 $state）。"
}

function Wait-HotspotIp {
    param(
        [bool]$Present,
        [int]$TimeoutSec = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    do {
        $info = Get-HotspotIpInfo
        if ($Present -and $info) {
            return $info
        }
        if (-not $Present -and -not $info) {
            return $null
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Stop-Tethering {
    param($Manager)

    $state = Get-TetheringState -Manager $Manager
    if ($state -eq 'Off') {
        Write-Log '热点已经是关闭状态。'
        return
    }

    try {
        $operation = $Manager.StopTetheringAsync()
        $result = Await-WinRT -Operation $operation -TimeoutMs 30000 -Label 'StopTetheringAsync'
        $status = ''
        try {
            $status = [string]$result.Status
        }
        catch {
        }
        Write-Log "StopTetheringAsync: $status"
    }
    catch {
        Write-Log "使用当前上游管理器和停止热点失败: $($_.Exception.Message)" WARN
        $wlanProfile = Get-WlanProfile
        if ($wlanProfile) {
            $wlanManager = New-TetheringManager -Profile $wlanProfile
            $operation = $wlanManager.StopTetheringAsync()
            $null = Await-WinRT -Operation $operation -TimeoutMs 30000 -Label 'StopTetheringAsync(WLAN)'
        }
        else {
            throw
        }
    }

    $null = Wait-TetheringState -Manager $Manager -Desired 'Off' -TimeoutSec 20
}

function Start-TetheringWithProfile {
    param(
        $Profile,
        [string]$Label
    )

    $manager = New-TetheringManager -Profile $Profile
    $state = Get-TetheringState -Manager $manager
    if ($state -eq 'On') {
        Write-Log "热点已开启（$Label）。"
        return $manager
    }

    $operation = $manager.StartTetheringAsync()
    $result = Await-WinRT -Operation $operation -TimeoutMs 30000 -Label 'StartTetheringAsync'

    $status = ''
    $errorMessage = ''
    try {
        $status = [string]$result.Status
    }
    catch {
    }
    try {
        $errorMessage = [string]$result.AdditionalErrorMessage
    }
    catch {
    }
    Write-Log "StartTetheringAsync($Label): $status $errorMessage"
    try {
        $resultTypeName = 'null'
        if ($null -ne $result) {
            $resultTypeName = $result.GetType().FullName
        }
        Write-Log "StartTetheringAsync 结果类型: $resultTypeName" DEBUG
    }
    catch {
    }
    try {
        Write-Log "StartTetheringAsync StatusRaw: $($result.Status)" DEBUG
    }
    catch {
        Write-Log "StartTetheringAsync StatusRaw 读取失败: $($_.Exception.Message)" DEBUG
    }

    if ($status -eq 'Unknown') {
        Start-Sleep -Seconds 1
        if ((Get-TetheringState -Manager $manager) -ne 'On') {
            Write-Log '状态 Unknown，尝试启动 icssvc 后重试一次。' WARN
            try {
                Start-Service -Name icssvc -ErrorAction Stop
            }
            catch {
                Write-Log "启动 icssvc 失败: $($_.Exception.Message)" WARN
            }
            Start-Sleep -Seconds 1

            $operation = $manager.StartTetheringAsync()
            $result = Await-WinRT -Operation $operation -TimeoutMs 30000 -Label 'StartTetheringAsync(retry)'
            try {
                $status = [string]$result.Status
            }
            catch {
                $status = 'Unknown'
            }
            try {
                $errorMessage = [string]$result.AdditionalErrorMessage
            }
            catch {
                $errorMessage = ''
            }
            Write-Log "StartTetheringAsync(retry): $status $errorMessage"
        }
    }

    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if ((Get-TetheringState -Manager $manager) -eq 'On') {
            if ($status -notin @('Success', 'AlreadyOn')) {
                Write-Log "启动返回状态为 '$status'，但热点状态已经 On，按成功处理。" WARN
            }
            return $manager
        }
        Start-Sleep -Milliseconds 500
    }

    throw "启动热点失败: $status $errorMessage"
}

function Test-ManagedByTun {
    param($TunInfo)

    try {
        $preferred = Get-IcssvcPreferredGuid
        if ($preferred -and $preferred -eq $TunInfo.InterfaceGuid) {
            return $true
        }
    }
    catch {
    }

    try {
        $connections = Get-IcsConnections
        $public = $connections | Where-Object { $_.SharingEnabled -and $_.SharingType -eq 0 } | Select-Object -First 1
        if ($public -and $public.Guid -eq $TunInfo.InterfaceGuid) {
            return $true
        }
    }
    catch {
    }

    return $false
}

function Restore-RegistrySnapshot {
    $snapshot = Read-StateSnapshot
    if (-not $snapshot) {
        Write-Log '没有启动前快照，跳过注册表恢复。' WARN
        return
    }

    $service = Get-Service -Name icssvc -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        try {
            Stop-Service -Name icssvc -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 500
        }
        catch {
            Write-Log "icssvc 未能停止，跳过注册表恢复: $($_.Exception.Message)" WARN
            return
        }
    }

    $preferred = ConvertFrom-Base64 -Text $snapshot.PreferredPublicInterfaceB64

    if ($preferred) {
        Set-IcssvcBytes -Name 'PreferredPublicInterface' -Bytes $preferred
        Write-Log '已恢复 PreferredPublicInterface。'
    }
}

function Set-PreferredPublicInterface {
    param([Guid]$Guid)

    $service = Get-Service -Name icssvc -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        try {
            Stop-Service -Name icssvc -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 500
        }
        catch {
            throw "无法停止 icssvc 以切换上游: $($_.Exception.Message)"
        }
    }

    Set-IcssvcBytes -Name 'PreferredPublicInterface' -Bytes $Guid.ToByteArray()
    Start-Sleep -Milliseconds 500
    Write-Log "PreferredPublicInterface 已切换为 $Guid"
}

function Invoke-Start {
    Assert-Admin

    $tunProfile = Get-FlClashProfile
    $tunInfo = Get-TunAdapterInfo
    $manager = New-TetheringManager -Profile $tunProfile
    $state = Get-TetheringState -Manager $manager
    $ap = Get-ApInfo -Manager $manager

    Write-Log "启动前: 热点=$state, SSID=$($ap.Ssid), TUN=$($tunInfo.Name)/$($tunInfo.IPAddress)"

    if ($state -eq 'On' -and (Test-ManagedByTun -TunInfo $tunInfo)) {
        Write-Host '热点已经在运行，并且上游是 FlClash TUN，无需重复启动。' -ForegroundColor Green
        return
    }

    $existingIp = Get-HotspotIpInfo
    if ($existingIp -and $existingIp.AdapterDescription -notlike '*Wi-Fi Direct*') {
        throw "$hotspotIp 当前被 $($existingIp.AdapterName) / $($existingIp.AdapterDescription) 占用，请先排查网段冲突。"
    }

    if (-not (Test-Path -LiteralPath $statePath)) {
        $icsSnapshot = $null
        $icsError = ''
        try {
            $icsSnapshot = Get-IcsSnapshot
        }
        catch {
            $icsError = $_.Exception.Message
        }
        Save-StateSnapshot -TunInfo $tunInfo -TetheringState $state -ApInfo $ap -IcsSnapshot $icsSnapshot -IcsError $icsError
    }
    else {
        Write-Log "已有启动前快照，沿用: $statePath"
    }

    if ($state -eq 'On') {
        Write-Log '热点当前已开启，先停止以切换上游。'
        Stop-Tethering -Manager $manager
        $null = Wait-TetheringState -Manager $manager -Desired 'Off' -TimeoutSec 20
        $null = Wait-HotspotIp -Present $false -TimeoutSec 20
    }

    Set-PreferredPublicInterface -Guid $tunInfo.InterfaceGuid

    $startError = $null
    try {
        $manager = Start-TetheringWithProfile -Profile $tunProfile -Label 'FlClash TUN'
    }
    catch {
        $startError = $_.Exception.Message
        Write-Log "以 TUN 为上游启动热点失败: $startError" ERROR
    }

    if ($startError) {
        try {
            if ($manager) {
                Stop-Tethering -Manager $manager
            }
        }
        catch {
        }
        try {
            Restore-RegistrySnapshot
        }
        catch {
        }
        throw "热点启动失败: $startError。可改用手机手动代理 $hotspotIp`:7890（需先关闭 TUN）。"
    }

    $null = Wait-TetheringState -Manager $manager -Desired 'On' -TimeoutSec 20
    $ipInfo = Wait-HotspotIp -Present $true -TimeoutSec 20
    if (-not $ipInfo) {
        try {
            Stop-Tethering -Manager $manager
            Restore-RegistrySnapshot
        }
        catch {
        }
        throw "热点状态为 On，但未出现 $hotspotIp；已停止热点并恢复启动前状态。"
    }

    $preferred = Get-IcssvcPreferredGuid
    if (-not $preferred -or $preferred -ne $tunInfo.InterfaceGuid) {
        try {
            Stop-Tethering -Manager $manager
            Restore-RegistrySnapshot
        }
        catch {
        }
        throw "热点已启动，但 ICS 上游没有保持为 TUN（当前: $preferred）；已停止热点并恢复。"
    }

    $ap = Get-ApInfo -Manager $manager
    $clients = 0
    try {
        $clients = [int]$manager.ClientCount
    }
    catch {
    }
    $listener = Get-ProxyListener

    Write-Host ''
    Write-Host '热点已开启，并已切换到 FlClash TUN 上游。' -ForegroundColor Green
    Write-Host "  SSID: $($ap.Ssid)    频段: $($ap.Band)"
    Write-Host "  热点网关: $($ipInfo.IPAddress) ($($ipInfo.AdapterName))"
    Write-Host "  TUN: $($tunInfo.Name) / $($tunInfo.IPAddress)    客户端数: $clients"
    if ($listener) {
        Write-Host "  7890: $($listener.LocalAddress):$($listener.LocalPort) (PID $($listener.OwningProcess))"
    }
    else {
        Write-Host '  7890: 未监听（TUN 模式仍可工作，但请确认 FlClash 正常）' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '注意：脚本接管期间不要用 Windows 设置页开关热点；停止请运行 Stop-Hotspot.cmd。' -ForegroundColor Yellow
    Write-Log 'Start 完成。'
}

function Invoke-StopCore {
    param([bool]$RemoveState = $true)

    Assert-Admin

    $manager = $null
    try {
        $manager = New-TetheringManager -Profile (Get-FlClashProfile)
    }
    catch {
        $wlanProfile = Get-WlanProfile
        if ($wlanProfile) {
            $manager = New-TetheringManager -Profile $wlanProfile
        }
    }

    if ($manager) {
        Stop-Tethering -Manager $manager
        $null = Wait-TetheringState -Manager $manager -Desired 'Off' -TimeoutSec 20
        $null = Wait-HotspotIp -Present $false -TimeoutSec 20
    }
    else {
        Write-Log '找不到可用的连接配置，跳过热点停止调用。' WARN
    }

    Restore-RegistrySnapshot

    if ($RemoveState) {
        Remove-StateSnapshot
    }
    else {
        Write-Log '保留启动前快照，供 Restore 使用。'
    }
}

function Invoke-Stop {
    Invoke-StopCore -RemoveState $true
    Write-Host '热点已停止，ICS 状态已恢复；FlClash TUN 保持运行。' -ForegroundColor Green
    Write-Log 'Stop 完成。'
}

function Invoke-Restore {
    Assert-Admin

    $snapshot = Read-StateSnapshot
    if (-not $snapshot) {
        Write-Host '没有可恢复的启动前快照。' -ForegroundColor Yellow
        return
    }

    Invoke-StopCore -RemoveState $false

    if ($snapshot.TetheringWasOn) {
        $tunActive = $false
        try {
            $null = Get-TunAdapterInfo
            $tunActive = $true
        }
        catch {
        }

        if ($tunActive) {
            Write-Host '启动前热点是开启的，但 FlClash TUN 仍在运行；为避免再次冲突，未自动开启热点。' -ForegroundColor Yellow
            Write-Host '请先关闭 TUN，再重新运行 Restore-Hotspot。' -ForegroundColor Yellow
            Write-Log 'Restore 保留快照：TUN 仍开启。'
            return
        }

        $wlanProfile = Get-WlanProfile
        if (-not $wlanProfile) {
            throw '找不到可用的 WLAN 连接配置，无法恢复普通热点。'
        }

        $manager = Start-TetheringWithProfile -Profile $wlanProfile -Label 'WLAN'
        $null = Wait-TetheringState -Manager $manager -Desired 'On' -TimeoutSec 20
        $ipInfo = Wait-HotspotIp -Present $true -TimeoutSec 20
        if (-not $ipInfo) {
            throw "恢复普通热点失败：未出现 $hotspotIp。"
        }
        Write-Host "已恢复普通热点（WLAN 上游，网关 $($ipInfo.IPAddress)）。" -ForegroundColor Green
    }

    Remove-StateSnapshot
    Write-Log 'Restore 完成。'
}

function Show-Status {
    $tunProfile = $null
    try {
        $tunProfile = Get-FlClashProfile
    }
    catch {
    }

    $managerProfile = $tunProfile
    if (-not $managerProfile) {
        $managerProfile = Get-WlanProfile
    }

    $manager = $null
    if ($managerProfile) {
        try {
            $manager = New-TetheringManager -Profile $managerProfile
        }
        catch {
        }
    }

    $tunInfo = $null
    try {
        $tunInfo = Get-TunAdapterInfo
    }
    catch {
    }

    $state = Get-TetheringState -Manager $manager
    $ap = Get-ApInfo -Manager $manager
    $ipInfo = Get-HotspotIpInfo
    $listener = Get-ProxyListener
    $clients = 0
    if ($manager) {
        try {
            $clients = [int]$manager.ClientCount
        }
        catch {
        }
    }

    $preferredGuid = $null
    try {
        $preferredGuid = Get-IcssvcPreferredGuid
    }
    catch {
    }

    $preferredName = ''
    if ($preferredGuid) {
        $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceGuid -eq $preferredGuid
        } | Select-Object -First 1
        if ($adapter) {
            $preferredName = "$($adapter.Name) / $($adapter.InterfaceDescription)"
        }
        else {
            $preferredName = $preferredGuid.ToString()
        }
    }

    Write-Host '=== Hotspot over FlClash TUN 状态 ===' -ForegroundColor Cyan
    Write-Host ("热点状态: {0}" -f $state)
    Write-Host ("AP: SSID={0}  频段={1}  客户端数={2}" -f $ap.Ssid, $ap.Band, $clients)
    if ($ipInfo) {
        Write-Host ("热点网关: {0} ({1} / {2})" -f $ipInfo.IPAddress, $ipInfo.AdapterName, $ipInfo.AdapterDescription)
    }
    else {
        Write-Host '热点网关: 未出现 192.168.137.1'
    }

    if ($tunInfo) {
        Write-Host ("TUN: {0} ({1})  IP={2}  GUID={3}" -f $tunInfo.Name, $tunInfo.Description, $tunInfo.IPAddress, $tunInfo.InterfaceGuid)
        $isTunUpstream = $preferredGuid -and $preferredGuid -eq $tunInfo.InterfaceGuid
        Write-Host ("TUN 上游: {0}" -f $(if ($isTunUpstream) { '是' } else { '否' }))
    }
    else {
        Write-Host 'TUN: 未检测到 FlClash TUN（请开启 FlClash TUN）' -ForegroundColor Yellow
    }

    Write-Host ("ICS PreferredPublicInterface: {0}" -f $preferredName)
    if ($listener) {
        Write-Host ("7890 监听: {0}:{1} (PID {2})" -f $listener.LocalAddress, $listener.LocalPort, $listener.OwningProcess)
    }
    else {
        Write-Host '7890 监听: 无' -ForegroundColor Yellow
    }

    if (Test-Admin) {
        try {
            $connections = Get-IcsConnections
            $enabled = @($connections | Where-Object { $_.SharingEnabled })
            if ($enabled.Count -eq 0) {
                Write-Host 'ICS 共享: 无已启用连接'
            }
            else {
                foreach ($connection in $enabled) {
                    $type = 'UNKNOWN'
                    if ($connection.SharingType -eq 0) { $type = 'PUBLIC' }
                    elseif ($connection.SharingType -eq 1) { $type = 'PRIVATE' }
                    Write-Host ("ICS 共享: {0} = {1} ({2})" -f $connection.Name, $type, $connection.DeviceName)
                }
            }
        }
        catch {
            Write-Host ("ICS 共享: 读取失败 - {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host 'ICS 共享: 非管理员，跳过 COM 读取'
    }

    $snapshot = Read-StateSnapshot
    if ($snapshot) {
        Write-Host ("启动前快照: {0}  热点原本={1}" -f $snapshot.Timestamp, $(if ($snapshot.TetheringWasOn) { '开' } else { '关' }))
        if ($tunInfo -and $snapshot.TunInterfaceGuid) {
            $savedTunGuid = $null
            try {
                $savedTunGuid = [Guid]$snapshot.TunInterfaceGuid
            }
            catch {
            }
            if ($savedTunGuid -and $savedTunGuid -ne $tunInfo.InterfaceGuid) {
                Write-Host '提示: TUN 接口 GUID 与快照不一致（FlClash 可能重启过），请重新执行 Start。' -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host '启动前快照: 无'
    }

    if (Get-Process -Name SystemSettings -ErrorAction SilentlyContinue) {
        Write-Host '提示: Windows 设置页正在运行，它可能重写 ICS 上游；脚本接管期间请关闭设置页。' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '使用 Start-Hotspot.cmd / Stop-Hotspot.cmd / Status-Hotspot.cmd 管理。'
}

try {
    Initialize-WinRT

    switch ($Action) {
        'Status' { Show-Status }
        'Start' { Invoke-Start }
        'Stop' { Invoke-Stop }
        'Restore' { Invoke-Restore }
    }
}
catch {
    $script:ExitCode = 1
    $message = $_.Exception.Message
    Write-Log "操作失败: $message" ERROR
    if ($Silent) {
        Show-UiMessage -Text "操作失败:`n`n$message" -Icon Error
    }
    else {
        Write-Host "操作失败: $message" -ForegroundColor Red
    }
}
finally {
    if (-not $Silent -and -not $NoPause -and $Host.Name -eq 'ConsoleHost') {
        Write-Host ''
        try {
            Read-Host '按回车退出' | Out-Null
        }
        catch {
        }
    }
}

exit $script:ExitCode

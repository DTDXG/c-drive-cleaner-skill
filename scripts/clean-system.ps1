<#
.SYNOPSIS
逐项执行 C 盘的第 2、3 层系统清理。
.DESCRIPTION
先报告再清理；每次只能选择一个 Action。所有第 3 层动作（包括只读的
PageFile）必须显式提供 AcknowledgeIrreversible。所有修改均受 ShouldProcess
保护；WhatIf 不停止服务、不删除文件、不更改配置，也不写审计日志。
WhatIf 下只读文件、注册表和 CIM；外部工具也只演练，以免工具自行写日志。
通过 common.ps1 统一校验白名单、重解析点、删除、外部命令和日志。
外部工具操作的审计 Bytes=0 表示释放量未计量，实际空间应在完成后重新扫描。
不接管所有权，不手工删除组件存储，不固定假设 VSS 的 /On 卷。
Windows.old 优先使用系统设置；选择执行时调用系统磁盘清理的 /AUTOCLEAN。
UpdateCache 采用微软文档中“停止服务后清理 SoftwareDistribution\Download”的方法，
不是系统清理界面；临时禁用更新服务启动类型，最后先还原启动类型、再恢复原运行状态。
.PARAMETER Action
单个动作：ComponentStore、UpdateCache、DeliveryOptimization、RecycleBin、
CrashDumps、WindowsOld、Hibernate、ShadowStorage、ReservedStorage 或 PageFile。
.PARAMETER AcknowledgeIrreversible
确认第 3 层动作的后果；不能代替备份，也不跳过 ShouldProcess 确认。
.PARAMETER Mode
仅用于 Hibernate，必须显式选择 Off 或 Reduced。Off 同时禁用休眠、快速启动和
混合睡眠；Reduced 只保留支持快速启动的精简休眠文件，不保留完整休眠。
.PARAMETER ForVolume
仅用于 ShadowStorage，默认 C:。也可用别名 For；必须存在实际的 VSS 存储关联。
.PARAMETER OnVolume
仅用于 ShadowStorage，也可用别名 On。省略时只接受唯一的实际关联；
无盘符的存储卷会使用 CIM 返回的卷 GUID 路径。
.PARAMETER MaxSize
仅用于 ShadowStorage，例如 10GB、500MB、10%。省略时仅列出，不调整。
缩小上限可能立即、永久删除旧还原点和卷影副本。
.PARAMETER DisableReservedStorage
仅用于 ReservedStorage。默认只查状态；只有此开关才请求禁用保留存储。
不保证立即释放空间，默认建议保持启用。
.PARAMETER OriginalUserSid
提权前记录的原用户 SID，须与 OriginalUserProfile 成对传入。
也可在提权前设置 CLEANER_ORIGINAL_USER_SID/CLEANER_ORIGINAL_USER_PROFILE。
.PARAMETER OriginalUserProfile
提权前记录的原用户目录，与 SID 交由共享上下文核实。回收站只处理原用户与
当前用户 SID 相同且身份已核实的账户，不会改用另一管理员账户的回收站。
.EXAMPLE
.\clean-system.ps1 -Action ComponentStore -WhatIf
演练“先分析，再仅对明确可回收且建议清理的组件执行清理”的流程；不启动 DISM。
.EXAMPLE
.\clean-system.ps1 -Action UpdateCache -WhatIf
报告更新状态和下载目录，演练临时禁用服务启动、停止服务、清空内容并恢复服务的整个事务。
.EXAMPLE
.\clean-system.ps1 -Action Hibernate -Mode Reduced -AcknowledgeIrreversible -WhatIf
报告休眠文件大小，演练切换精简休眠文件。
.EXAMPLE
.\clean-system.ps1 -Action ShadowStorage -ForVolume C: -OnVolume C: -MaxSize 10GB -AcknowledgeIrreversible -WhatIf
先列出实际关联，再演练对匹配关联调整上限。
.EXAMPLE
.\clean-system.ps1 -Action ReservedStorage -DisableReservedStorage -AcknowledgeIrreversible -WhatIf
读取版本，演练查询状态及有条件禁用保留存储；不启动 DISM。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ComponentStore', 'UpdateCache', 'DeliveryOptimization', 'RecycleBin',
        'CrashDumps', 'WindowsOld', 'Hibernate', 'ShadowStorage', 'ReservedStorage', 'PageFile')]
    [string]$Action,

    [switch]$AcknowledgeIrreversible,

    [ValidateSet('Off', 'Reduced')]
    [string]$Mode,

    [Alias('For')]
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$ForVolume = 'C:',

    [Alias('On')]
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$OnVolume,

    [ValidatePattern('^(?i:([1-9][0-9]*(MB|GB|TB))|(([1-9][0-9]?|100)%))$')]
    [string]$MaxSize,

    [switch]$DisableReservedStorage,

    [string]$OriginalUserSid,

    [string]$OriginalUserProfile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "common.ps1")

# 这里只适配共享函数的结构化返回值，不实现路径白名单或重解析点规则。
function Get-SystemProperty {
    param([object]$InputObject, [string[]]$Names, [switch]$Required)
    foreach ($name in $Names) {
        if ($null -eq $InputObject) { break }
        if ($InputObject -is [hashtable]) {
            if ($InputObject.ContainsKey($name) -and $null -ne $InputObject[$name]) {
                return $InputObject[$name]
            }
        }
        elseif ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($name) -and $null -ne $InputObject[$name]) {
                return $InputObject[$name]
            }
        }
        else {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) {
                return $property.Value
            }
        }
    }
    if ($Required) { throw ("缺少必要属性：{0}" -f ($Names -join '/')) }
    return $null
}

function Assert-SystemTarget {
    param([string]$LiteralPath, [string]$Category, [switch]$RequireDirectDelete)
    $decisions = @(Test-SafeTarget -LiteralPath $LiteralPath -Category $Category -ErrorAction Stop)
    $allowed = $false
    $recognized = $false
    $reason = '共享校验未返回明确的安全判定。'
    foreach ($decision in $decisions) {
        if ($decision -is [bool]) {
            $allowed = $decision
            $recognized = $true
        }
        else {
            if ($RequireDirectDelete -and (Get-SystemProperty $decision @('ExternalOnly')) -eq $true) {
                throw "共享白名单类别 '$Category' 标记为 ExternalOnly，拒绝直接删除 '$LiteralPath'。"
            }
            $value = Get-SystemProperty $decision @('IsSafe', 'Safe', 'Allowed', 'Success')
            if ($value -is [bool]) {
                $allowed = $value
                $recognized = $true
            }
            $message = Get-SystemProperty $decision @('Reason', 'Message')
            if ($null -ne $message) { $reason = [string]$message }
        }
        if ($recognized -and -not $allowed) { break }
    }
    if (-not $recognized -or -not $allowed) {
        throw "拒绝访问清理目标 '$LiteralPath'（$Category）：$reason"
    }
}

function Write-SystemAudit {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([string]$Operation, [string]$Path, [string]$Result, [long]$Bytes = 0)
    if ($WhatIfPreference) { return }
    if ($PSCmdlet.ShouldProcess($Path, '写入清理审计日志')) {
        try {
            Write-CleanerLog -Action $Operation -Path $Path -Result $Result -Bytes $Bytes | Out-Null
        }
        catch {
            Write-Warning ("审计日志写入失败：{0}" -f $_.Exception.Message)
        }
    }
}

function Invoke-SystemExternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$ReadOnly
    )
    # 外部工具的只读查询也可能写系统诊断日志，WhatIf 时完全不启动外部进程。
    if ($WhatIfPreference) {
        [void]$PSCmdlet.ShouldProcess($FilePath, $Description)
        return
    }
    if (-not $ReadOnly -and -not $PSCmdlet.ShouldProcess($FilePath, $Description)) { return }
    # 实际调用只会发生在非 WhatIf 路径；修改命令另受调用处事务确认保护。
    $items = @(Invoke-External -FilePath $FilePath -ArgumentList $ArgumentList `
        -Description $Description -SuccessExitCodes @(0, 3010) -WhatIf:$false -Confirm:$false -ErrorAction Stop)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $items) {
        if ($item -is [string]) {
            $lines.Add($item)
            continue
        }
        $exitCode = Get-SystemProperty $item @('ExitCode')
        if ($null -ne $exitCode -and [int]$exitCode -ne 0 -and [int]$exitCode -ne 3010) {
            throw ("外部命令失败，退出码 {0}：{1}" -f $exitCode, $Description)
        }
        if ($null -ne $exitCode -and [int]$exitCode -eq 3010) {
            Write-Warning '系统工具要求重新启动；请重启后再检查空间和系统状态。'
        }
        $outputText = Get-SystemProperty $item @('Output', 'StdOut', 'StandardOutput', 'Text')
        if ($null -ne $outputText) {
            foreach ($line in @($outputText)) { $lines.Add([string]$line) }
        }
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-SystemTargetReport {
    param([string]$LiteralPath, [string]$Category)
    $exists = Test-Path -LiteralPath $LiteralPath -ErrorAction Stop
    $measurement = $null
    $fileBytes = $null
    if ($exists) {
        Assert-SystemTarget -LiteralPath $LiteralPath -Category $Category
        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            $measurement = Get-DirectorySize -LiteralPath $LiteralPath -ErrorAction Stop
        }
        else { $fileBytes = [long]$item.Length }
    }
    [pscustomobject]@{
        Action = $Action
        Path = $LiteralPath
        Exists = $exists
        FileBytes = $fileBytes
        DirectoryMeasurement = $measurement
        Note = '目录大小以共享扫描结果为准；跳过项为未知，逻辑大小不等于可释放空间。'
    }
}

function Get-SystemFreedBytes {
    param([object[]]$Results)
    [long]$total = 0
    foreach ($result in $Results) {
        $value = Get-SystemProperty $result @('FreedBytes', 'BytesFreed', 'ReleasedBytes', 'RemovedBytes')
        if ($null -ne $value) { $total += [long]$value }
    }
    return $total
}

function Assert-UpdateServiceStopped {
    param([string[]]$Name)
    foreach ($serviceName in $Name) {
        if ([string](Get-Service -Name $serviceName -ErrorAction Stop).Status -ne 'Stopped') {
            throw "服务 $serviceName 已重新启动或正在过渡，取消删除并恢复原服务状态。"
        }
    }
}

function Clear-SystemDirectoryContent {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string]$LiteralPath,
        [string]$Category,
        [string[]]$RequireStoppedServices = @(),
        [switch]$RequireUpdateIdle
    )
    Assert-SystemTarget -LiteralPath $LiteralPath -Category $Category -RequireDirectDelete
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) { return }
    if ($PSCmdlet.ShouldProcess($LiteralPath, '清空已识别的系统清理目录内容，保留根目录')) {
        if ($RequireUpdateIdle) {
            # 停服务之后、删除之前重查；此处不可使用可能重新启动服务的 COM/BITS 查询。
            $activity = Get-WindowsUpdateActivity
            if ($activity.IsBusy) {
                throw ("删除前检测到更新活动或待重启状态，取消清理：{0}" -f ($activity.Reasons -join '; '))
            }
        }
        Assert-UpdateServiceStopped -Name $RequireStoppedServices
        $serviceDeletionGuard = @{ Failure = $null }
        if ($RequireStoppedServices.Count -gt 0) {
            $sharedRemoveLeaf = Get-Command -Name Remove-CleanerLeaf -CommandType Function -ErrorAction Stop
            # 仅在本次调用的局部作用域包装共享叶项删除入口；路径和句柄安全仍由共享函数负责。
            # Remove-SafeItem 会捕获逐项异常，所以必须锁存失败，禁止其后所有实际删除。
            function Remove-CleanerLeaf {
                [CmdletBinding(SupportsShouldProcess = $true)]
                param([string]$LiteralPath, [string]$Category, [DateTime]$CutoffUtc, [bool]$IsDirectory, $Context)
                if ($null -ne $serviceDeletionGuard.Failure) { throw $serviceDeletionGuard.Failure }
                try {
                    Assert-UpdateServiceStopped -Name $RequireStoppedServices
                    if ($PSCmdlet.ShouldProcess($LiteralPath, '在更新服务保持停止时删除文件或空目录')) {
                        $outcome = & $sharedRemoveLeaf @PSBoundParameters
                        Assert-UpdateServiceStopped -Name $RequireStoppedServices
                        return $outcome
                    }
                }
                catch {
                    $serviceDeletionGuard.Failure = $_
                    throw
                }
            }
        }
        try {
            # 只传清理根目录；共享函数负责整个枚举/逐项校验/空子目录删除，并保留此根。
            Remove-SafeItem -LiteralPath $LiteralPath -Category $Category `
                -MinAgeHours 0 -Confirm:$false -ErrorAction Stop
            if ($null -ne $serviceDeletionGuard.Failure) { throw $serviceDeletionGuard.Failure }
        }
        catch {
            # 服务保护失败必须到达事务 finally，不能降级为普通跳过或报告清理成功。
            if ($null -ne $serviceDeletionGuard.Failure) { throw $serviceDeletionGuard.Failure }
            $reason = $_.Exception.Message
            Write-Warning ("跳过 '{0}'：{1}" -f $LiteralPath, $reason)
            Write-SystemAudit -Operation $Action -Path $LiteralPath -Result 'Skipped' -Confirm:$false
            [pscustomobject]@{
                Path = $LiteralPath; FreedBytes = [long]0
                SkippedItems = @([pscustomobject]@{ Path = $LiteralPath; Reason = $reason })
            }
        }
        Assert-UpdateServiceStopped -Name $RequireStoppedServices
    }
}

function Get-WindowsUpdateActivity {
    param([switch]$UseWindowsUpdateApi)
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    # 保守判断：待重启、安装会话以及更新/组件维护进程均视为不适合清理。
    $markers = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\UpdateInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress'
    )
    foreach ($marker in $markers) {
        try {
            if (Test-Path -LiteralPath $marker -ErrorAction Stop) { $reasons.Add("存在更新/待重启标记：$marker") }
        }
        catch { $reasons.Add("无法检查更新标记：$marker") }
    }
    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        foreach ($name in @('PendingFileRenameOperations', 'PendingFileRenameOperations2')) {
            $pending = @(Get-SystemProperty $sessionManager @($name) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
            if ($pending.Count -gt 0) { $reasons.Add("存在待重启文件操作：$name") }
        }
    }
    catch { $reasons.Add("无法检查待重启文件操作：$($_.Exception.Message)") }
    try {
        $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
        foreach ($name in @('SystemSetupInProgress', 'OOBEInProgress', 'SystemUpdateInProgress')) {
            $value = Get-SystemProperty $setup @($name)
            if ($null -ne $value -and [int]$value -ne 0) { $reasons.Add("系统安装标记 $name=$value") }
        }
        $processNames = @('TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker', 'UsoClient',
            'wuauclt', 'dism', 'DismHost', 'setuphost', 'WindowsUpdateBox', 'msiexec')
        $active = @(Get-Process -ErrorAction Stop | Where-Object { $processNames -contains $_.ProcessName })
        foreach ($process in $active) { $reasons.Add("存在维护进程：$($process.ProcessName)") }
    }
    catch { $reasons.Add("无法完整检查系统维护状态：$($_.Exception.Message)") }

    if ($UseWindowsUpdateApi -and $reasons.Count -eq 0) {
        # COM/BITS 查询可能启动服务，故只在用户批准的服务事务内部调用；绝不在 WhatIf 调用。
        $session = $null
        $installer = $null
        $downloader = $null
        $systemInfo = $null
        try {
            $systemInfo = New-Object -ComObject 'Microsoft.Update.SystemInfo' -ErrorAction Stop
            if ((Get-SystemProperty $systemInfo @('RebootRequired') -Required) -ne $false) {
                $reasons.Add('Windows Update 报告需要重新启动。')
            }
            $session = New-Object -ComObject 'Microsoft.Update.Session' -ErrorAction Stop
            $installer = $session.CreateUpdateInstaller()
            $downloader = $session.CreateUpdateDownloader()
            if ((Get-SystemProperty $installer @('IsBusy') -Required) -ne $false) { $reasons.Add('Windows Update 安装器正在工作。') }
            if ((Get-SystemProperty $downloader @('IsBusy') -Required) -ne $false) { $reasons.Add('Windows Update 下载器正在工作。') }
            $bitsCommand = Get-Command -Name Get-BitsTransfer -CommandType Cmdlet,Function -ErrorAction Stop
            $jobs = @(& $bitsCommand -AllUsers -ErrorAction Stop)
            foreach ($job in $jobs) {
                $jobState = [string](Get-SystemProperty $job @('JobState') -Required)
                if ($jobState -notin @('Transferred', 'Acknowledged', 'Cancelled')) {
                    $displayName = Get-SystemProperty $job @('DisplayName', 'JobId')
                    $reasons.Add("存在未完成的 BITS 传输：$displayName [$jobState]")
                }
            }
        }
        catch { $reasons.Add("无法证明更新当前空闲，跳过清理：$($_.Exception.Message)") }
        finally {
            foreach ($comObject in @($downloader, $installer, $session, $systemInfo)) {
                if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject)
                }
            }
        }
    }
    [pscustomobject]@{ IsBusy = ($reasons.Count -gt 0); Reasons = @($reasons.ToArray()) }
}

function Get-UpdateServiceSnapshot {
    # 用共享函数的演练令牌取得 OriginalStatus/OriginalStartType，并复用
    # Running+Disabled 和过渡状态保护；这里不修改服务或启动类型，也不写日志。
    return (Stop-ServiceTemporarily -Name @('bits', 'wuauserv') -DisableStartup `
        -Context $context -WhatIf -Confirm:$false -ErrorAction Stop)
}

function Restore-SystemServiceState {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([object[]]$State = @())
    $errors = New-Object 'System.Collections.Generic.List[string]'
    for ($index = $State.Count - 1; $index -ge 0; $index--) {
        $token = $State[$index]
        if ($null -eq $token -or (Get-SystemProperty $token @('WasWhatIf')) -eq $true) { continue }
        if ((Get-SystemProperty $token @('Changed')) -ne $true -and
            (Get-SystemProperty $token @('StartupChanged')) -ne $true) { continue }
        $serviceName = [string](Get-SystemProperty $token @('Name'))
        $originalStatus = [string](Get-SystemProperty $token @('OriginalStatus'))
        if (-not $PSCmdlet.ShouldProcess($serviceName, '恢复服务并核验启动类型和运行状态；失败时重试一次')) { continue }
        $originalStartType = [string](Get-SystemProperty $token @('OriginalStartType', 'OriginalStartMode'))
        $expectedStartMode = $originalStartType
        if ($expectedStartMode -eq 'Automatic') { $expectedStartMode = 'Auto' }
        $verified = $false
        $succeeded = $false
        $failure = ''
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            $verified = $false
            $attemptErrors = New-Object 'System.Collections.Generic.List[string]'
            try {
                # 必须使用调用方持有的实际令牌，不能用预览快照替代部分完成的停止事务。
                Restore-ServiceState -State @($token) -Context $context -Confirm:$false -ErrorAction Stop | Out-Null
            }
            catch { $attemptErrors.Add($_.Exception.Message) }
            try {
                if ($serviceName -notmatch '^[A-Za-z0-9_.-]+$' -or $originalStatus -notin @('Running', 'Paused', 'Stopped') -or
                    $expectedStartMode -notin @('Auto', 'Manual', 'Disabled')) {
                    throw '缺少有效的服务名称或原启动类型，无法核验恢复结果。'
                }
                $configuration = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $serviceName + "'") -ErrorAction Stop
                $actualStartMode = [string](Get-SystemProperty $configuration @('StartMode') -Required)
                if ($actualStartMode -eq 'Automatic') { $actualStartMode = 'Auto' }
                $actualStatus = [string](Get-Service -Name $serviceName -ErrorAction Stop).Status
                $verified = $actualStartMode -eq $expectedStartMode -and $actualStatus -eq $originalStatus
                if ($actualStartMode -ne $expectedStartMode) {
                    # 即使共享恢复函数已经标记 Restored，也须让下一次按实测偏差重试启动类型。
                    $token | Add-Member -NotePropertyName StartupChanged -NotePropertyValue $true -Force
                    $token | Add-Member -NotePropertyName OriginalStartMode -NotePropertyValue $expectedStartMode -Force
                }
                if (-not $verified) {
                    throw ("核验不符：当前启动类型={0}，运行状态={1}" -f $actualStartMode, $actualStatus)
                }
            }
            catch { $attemptErrors.Add($_.Exception.Message) }
            # 共享恢复成功且独立核验通过才算完成；任何失败都保留令牌并重试一次。
            if ($verified -and $attemptErrors.Count -eq 0) { $succeeded = $true; break }
            $token | Add-Member -NotePropertyName Restored -NotePropertyValue $false -Force
            $failure = $attemptErrors -join '; '
        }
        if (-not $succeeded) {
            $errors.Add(("{0}（原启动类型={1}，原运行状态={2}）：{3}；请手动恢复此服务。" -f
                $serviceName, $originalStartType, $originalStatus, $failure))
        }
    }
    if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
}

function Restore-UpdateServiceSnapshot {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([object[]]$Snapshot, [object[]]$State = @())
    if (-not $PSCmdlet.ShouldProcess('wuauserv/BITS', '先还原启动类型，再恢复更新查询前的服务状态')) {
        return $false
    }
    $errors = New-Object 'System.Collections.Generic.List[string]'
    try {
        # 两阶段独立；第一阶段失败不能阻止查询前状态的恢复。
        Restore-SystemServiceState -State $State -Confirm:$false -ErrorAction Stop
    }
    catch { $errors.Add('停止事务恢复：' + $_.Exception.Message) }
    try {
        $queryStates = @()
        foreach ($saved in $Snapshot) {
            # COM/BITS 查询可能启动原本停止的服务。复制预览快照作为查询的恢复令牌，
            # 不改变原快照，也不把实际 WhatIf 调用转换成可修改服务的事务。
            $token = $saved.PSObject.Copy()
            $token.Changed = $true
            $token.WasWhatIf = $false
            $token.Restored = $false
            foreach ($changed in $State) {
                if ($null -ne $changed -and $changed.Name -eq $token.Name -and
                    (Get-SystemProperty $changed @('StartupChanged')) -eq $true) {
                    # 第一阶段仍未还原的启动类型必须交给第二阶段继续尝试。
                    $token.StartupChanged = $true
                }
            }
            $queryStates += $token
        }
        Restore-SystemServiceState -State $queryStates -Confirm:$false -ErrorAction Stop
    }
    catch { $errors.Add('查询前状态恢复：' + $_.Exception.Message) }
    if ($errors.Count -gt 0) {
        Write-Warning ("恢复更新服务失败：{0}" -f ($errors -join [Environment]::NewLine))
        Write-SystemAudit -Operation 'RestoreUpdateService' -Path 'wuauserv/BITS' -Result 'Failed' -Confirm:$false
        return $false
    }
    return $true
}

function Get-VolumeReferenceKey {
    param([object]$Reference)
    $deviceId = Get-SystemProperty $Reference @('DeviceID')
    if ($null -eq $deviceId) { $deviceId = [string]$Reference }
    $match = [regex]::Match([string]$deviceId, '(?i)Volume\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}')
    if ($match.Success) { return $match.Value.ToLowerInvariant() }
    throw "无法识别 CIM 返回的卷引用：$deviceId"
}

function Get-ShadowStorageAssociations {
    $volumes = @(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop)
    $stores = @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop)
    foreach ($store in $stores) {
        $forKey = Get-VolumeReferenceKey (Get-SystemProperty $store @('Volume') -Required)
        $onKey = Get-VolumeReferenceKey (Get-SystemProperty $store @('DiffVolume') -Required)
        $forMatches = @($volumes | Where-Object { (Get-VolumeReferenceKey $_) -eq $forKey })
        $onMatches = @($volumes | Where-Object { (Get-VolumeReferenceKey $_) -eq $onKey })
        if ($forMatches.Count -ne 1 -or $onMatches.Count -ne 1) {
            throw '无法唯一解析 VSS 的 /For 或 /On 卷；拒绝猜测关联。'
        }
        $for = $forMatches[0]
        $on = $onMatches[0]
        $forSpec = [string](Get-SystemProperty $for @('DriveLetter', 'DeviceID') -Required)
        $onSpec = [string](Get-SystemProperty $on @('DriveLetter', 'DeviceID') -Required)
        if ([string]::IsNullOrEmpty($forSpec)) { $forSpec = [string](Get-SystemProperty $for @('DeviceID') -Required) }
        if ([string]::IsNullOrEmpty($onSpec)) { $onSpec = [string](Get-SystemProperty $on @('DeviceID') -Required) }
        [pscustomobject]@{
            ForVolume = $forSpec
            OnVolume = $onSpec
            UsedBytes = [Nullable[long]](Get-SystemProperty $store @('UsedSpace'))
            AllocatedBytes = [Nullable[long]](Get-SystemProperty $store @('AllocatedSpace'))
            MaxBytes = [Nullable[uint64]](Get-SystemProperty $store @('MaxSpace'))
        }
    }
}

$levelThree = @('RecycleBin', 'CrashDumps', 'WindowsOld', 'Hibernate',
    'ShadowStorage', 'ReservedStorage', 'PageFile')
$risks = @{
    RecycleBin = '回收站中的文件将永久删除，无法再通过回收站恢复。'
    CrashDumps = '错误报告和崩溃转储将永久删除，可能丢失故障诊断证据。'
    WindowsOld = '以前的 Windows 安装将被删除，失去系统版本回退能力。优先在“设置 → 系统 → 存储 → 临时文件”清理。'
    Hibernate = 'Off 会禁用休眠、快速启动和混合睡眠；Reduced 不支持完整休眠。'
    ShadowStorage = '缩小 VSS 上限可能立即永久删除旧还原点及卷影副本。'
    ReservedStorage = '禁用保留存储可能影响更新可用空间，不保证立即释放容量；默认不建议。'
    PageFile = '本动作只报告：修改页面文件会影响提交上限、崩溃转储，通常需重启验证。'
}
if ($levelThree -contains $Action -and -not $AcknowledgeIrreversible) {
    throw ("动作 {0} 必须显式提供 -AcknowledgeIrreversible。{1}" -f $Action, $risks[$Action])
}
if ($PSBoundParameters.ContainsKey('Mode') -and $Action -ne 'Hibernate') {
    throw '-Mode 只能用于 Hibernate。'
}
foreach ($name in @('ForVolume', 'OnVolume', 'MaxSize')) {
    if ($PSBoundParameters.ContainsKey($name) -and $Action -ne 'ShadowStorage') {
        throw "-$name 只能用于 ShadowStorage。"
    }
}
if ($PSBoundParameters.ContainsKey('DisableReservedStorage') -and $Action -ne 'ReservedStorage') {
    throw '-DisableReservedStorage 只能用于 ReservedStorage。'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw '此脚本只能在 Windows 上运行；请在 Windows PowerShell 5.1 或 PowerShell 7 中执行。'
}
if ($Action -ne 'PageFile') { Assert-Admin }
$contextParameters = @{}
if ($PSBoundParameters.ContainsKey('OriginalUserSid') -or $PSBoundParameters.ContainsKey('OriginalUserProfile')) {
    if ([string]::IsNullOrWhiteSpace($OriginalUserSid) -or [string]::IsNullOrWhiteSpace($OriginalUserProfile)) {
        throw '-OriginalUserSid 与 -OriginalUserProfile 必须成对提供。'
    }
    $contextParameters['OriginalUserSid'] = $OriginalUserSid
    $contextParameters['OriginalUserProfile'] = $OriginalUserProfile
}
$context = Get-CleanerContext @contextParameters
$windowsRoot = [Environment]::GetFolderPath('Windows')
$systemRoot = [IO.Path]::GetPathRoot($windowsRoot)
$systemDrive = $systemRoot.TrimEnd('\')
$system32 = Join-Path $windowsRoot 'System32'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $system32 = Join-Path $windowsRoot 'Sysnative'
}
$dism = Join-Path $system32 'dism.exe'
$operationPath = $systemDrive

try {
    if ($levelThree -contains $Action) { Write-Warning $risks[$Action] }
    switch ($Action) {
        'ComponentStore' {
            $operationPath = 'Windows component store'
            $analysis = Invoke-SystemExternal -FilePath $dism `
                -ArgumentList @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore', '/English') `
                -Description '只读分析组件存储' -ReadOnly
            if ($WhatIfPreference) {
                [void]$PSCmdlet.ShouldProcess($operationPath, '实际运行先 AnalyzeComponentStore；仅有可回收包且建议清理时才 StartComponentCleanup')
                break
            }
            Write-Output $analysis
            $countMatch = [regex]::Match($analysis, '(?im)^\s*Number of Reclaimable Packages\s*:\s*(\d+)\s*$')
            $recommended = [regex]::IsMatch($analysis, '(?im)^\s*Component Store Cleanup Recommended\s*:\s*Yes\s*$')
            if (-not $countMatch.Success -or [long]$countMatch.Groups[1].Value -le 0 -or -not $recommended) {
                Write-Warning '未得到“有可回收包且建议清理”的明确分析结果，跳过组件清理。'
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Skipped' -Confirm:$false
                break
            }
            if ($PSCmdlet.ShouldProcess($operationPath, '运行 DISM StartComponentCleanup；保留更新卸载能力')) {
                $output = Invoke-SystemExternal -FilePath $dism `
                    -ArgumentList @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/English') `
                    -Description '清理可回收组件；保留更新卸载能力' -Confirm:$false
                Write-Output $output
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Success' -Confirm:$false
            }
        }
        'UpdateCache' {
            $operationPath = Join-Path $windowsRoot 'SoftwareDistribution\Download'
            $report = Get-SystemTargetReport -LiteralPath $operationPath -Category 'WindowsUpdate'
            Write-Output $report
            if (-not $report.Exists) { break }
            # WindowsUpdate 仅授权此精确目录的内容；仍在停服务前验证直接删除权限。
            Assert-SystemTarget -LiteralPath $operationPath -Category 'WindowsUpdate' -RequireDirectDelete
            $snapshot = @(Get-UpdateServiceSnapshot)
            $activity = Get-WindowsUpdateActivity
            if ($activity.IsBusy) {
                Write-Warning ($activity.Reasons -join [Environment]::NewLine)
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Skipped' -Confirm:$false
                break
            }
            if ($PSCmdlet.ShouldProcess($operationPath, '检查更新空闲，临时禁用并停止 BITS/wuauserv，清空下载内容，最后还原启动类型和运行状态')) {
                # 在进入事务前取得最终快照；若此步失败，尚未改状态，不做恢复。
                $snapshot = @(Get-UpdateServiceSnapshot)
                # 在任何服务修改前持有集合；停止函数抛错或被取消也不会丢失恢复令牌。
                $serviceStates = New-Object System.Collections.ArrayList
                $operationError = $null
                $results = @()
                $busy = $false
                $restored = $false
                try {
                    $activity = Get-WindowsUpdateActivity -UseWindowsUpdateApi
                    $busy = $activity.IsBusy
                    if ($busy) {
                        Write-Warning ($activity.Reasons -join [Environment]::NewLine)
                    }
                    else {
                        Assert-SystemTarget -LiteralPath $operationPath -Category 'WindowsUpdate' -RequireDirectDelete
                        # common.ps1 的 -StateCollection 必须在修改前登记令牌，并原地更新字段。
                        Stop-ServiceTemporarily -Name @('bits', 'wuauserv') -StateCollection $serviceStates `
                            -DisableStartup -Context $context -Confirm:$false -ErrorAction Stop | Out-Null
                        $results = @(Clear-SystemDirectoryContent -LiteralPath $operationPath `
                            -Category 'WindowsUpdate' -RequireStoppedServices @('bits', 'wuauserv') `
                            -RequireUpdateIdle -Confirm:$false)
                    }
                }
                catch [System.Management.Automation.PipelineStoppedException] { throw }
                catch { $operationError = $_ }
                finally {
                    # 同一 ShouldProcess 事务已批准恢复；不能再次询问而留下已停服务。
                    # PipelineStoppedException 继续传播，恢复始终在 finally 内执行。
                    $restored = Restore-UpdateServiceSnapshot -Snapshot $snapshot -State $serviceStates -Confirm:$false
                }
                if ($null -ne $operationError) { throw $operationError }
                if (-not $restored) { throw '更新服务未完全恢复到原状态，请立即人工检查 wuauserv 和 BITS。' }
                if ($busy) {
                    Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Skipped' -Confirm:$false
                }
                else {
                    Write-Output $results
                    Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Success' `
                        -Bytes (Get-SystemFreedBytes $results) -Confirm:$false
                }
            }
        }
        'DeliveryOptimization' {
            $operationPath = 'Delivery Optimization cache'
            $activity = Get-WindowsUpdateActivity
            if ($activity.IsBusy) {
                Write-Warning ($activity.Reasons -join [Environment]::NewLine)
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Skipped' -Confirm:$false
                break
            }
            $commands = @(Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)
            if ($commands.Count -eq 0) {
                Write-Warning '此系统没有 Delete-DeliveryOptimizationCache。请使用“设置 → 系统 → 存储 → 临时文件 → 传递优化文件”或“磁盘清理”，脚本不手工删除受保护的缓存目录。'
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Skipped' -Confirm:$false
                break
            }
            $command = $commands[0]
            if ($command.CommandType -notin @('Cmdlet', 'Function')) { throw '传递优化清理接口不是系统 cmdlet。' }
            if ($PSCmdlet.ShouldProcess($operationPath, '检查更新空闲后通过 Delete-DeliveryOptimizationCache 清理；检查所启动的更新服务按原状态恢复')) {
                $snapshot = @(Get-UpdateServiceSnapshot)
                $operationError = $null
                $cleaned = $false
                $restored = $false
                try {
                    $activity = Get-WindowsUpdateActivity -UseWindowsUpdateApi
                    if ($activity.IsBusy) {
                        Write-Warning ($activity.Reasons -join [Environment]::NewLine)
                    }
                    else {
                        $parameters = @{ ErrorAction = 'Stop' }
                        if ($command.Parameters.ContainsKey('Force')) { $parameters['Force'] = $true }
                        if ($command.Parameters.ContainsKey('Confirm')) { $parameters['Confirm'] = $false }
                        if ($command.Parameters.ContainsKey('WhatIf')) { $parameters['WhatIf'] = $false }
                        & $command @parameters
                        $cleaned = $true
                    }
                }
                catch [System.Management.Automation.PipelineStoppedException] { throw }
                catch { $operationError = $_ }
                finally {
                    $restored = Restore-UpdateServiceSnapshot -Snapshot $snapshot -Confirm:$false -WhatIf:$false
                }
                if ($null -ne $operationError) { throw $operationError }
                if (-not $restored) { throw '更新状态查询后的服务恢复失败，请立即人工检查 wuauserv 和 BITS。' }
                if ($cleaned) {
                    Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Success' -Confirm:$false
                }
                else {
                    Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Skipped' -Confirm:$false
                }
            }
        }
        'RecycleBin' {
            $originalSid = Get-SystemProperty $context @('OriginalUserSid', 'UserSid', 'OriginalSid')
            if ((Get-SystemProperty $context @('OriginalUserVerified')) -ne $true) {
                throw '原用户身份未核实。请传入提权前记录的 -OriginalUserSid 和 -OriginalUserProfile，或使用共享上下文约定的环境变量。'
            }
            $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if ([string]::IsNullOrEmpty([string]$originalSid) -or [string]$originalSid -ne $currentSid) {
                throw '无法确认原用户与当前用户 SID 一致；请以原用户同账户提权后清理，避免误清管理员回收站。'
            }
            $operationPath = Join-Path (Join-Path $systemRoot '$Recycle.Bin') $currentSid
            $report = Get-SystemTargetReport -LiteralPath $operationPath -Category 'RecycleBin'
            Write-Output $report
            if (-not $report.Exists) { break }
            $command = Get-Command -Name Clear-RecycleBin -CommandType Cmdlet,Function -ErrorAction Stop
            if ($PSCmdlet.ShouldProcess($operationPath, '永久清空当前原用户在系统盘的回收站')) {
                Assert-SystemTarget -LiteralPath $operationPath -Category 'RecycleBin'
                & $command -DriveLetter $systemDrive.Substring(0, 1) -Force -Confirm:$false -WhatIf:$false -ErrorAction Stop
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Success' -Confirm:$false
            }
        }
        'CrashDumps' {
            $programData = [Environment]::GetFolderPath('CommonApplicationData')
            $targets = @(
                [pscustomobject]@{ Path = (Join-Path $programData 'Microsoft\Windows\WER'); Category = 'WER' },
                [pscustomobject]@{ Path = (Join-Path $windowsRoot 'Minidump'); Category = 'CrashDump' },
                [pscustomobject]@{ Path = (Join-Path $windowsRoot 'LiveKernelReports'); Category = 'CrashDump' },
                [pscustomobject]@{ Path = (Join-Path $windowsRoot 'MEMORY.DMP'); Category = 'CrashDump' }
            )
            $existing = @()
            foreach ($target in $targets) {
                $report = Get-SystemTargetReport -LiteralPath $target.Path -Category $target.Category
                Write-Output $report
                if ($report.Exists) { $existing += $target }
            }
            $operationPath = ($targets | ForEach-Object { $_.Path }) -join '; '
            if ($existing.Count -gt 0 -and $PSCmdlet.ShouldProcess($operationPath, '永久删除错误报告和崩溃转储，保留目录本身')) {
                foreach ($target in $existing) {
                    $path = $target.Path
                    Assert-SystemTarget -LiteralPath $path -Category $target.Category -RequireDirectDelete
                    if (Test-Path -LiteralPath $path -PathType Container) {
                        Clear-SystemDirectoryContent -LiteralPath $path -Category $target.Category -Confirm:$false
                    }
                    else {
                        try {
                            Remove-SafeItem -LiteralPath $path -Category $target.Category -MinAgeHours 0 -Confirm:$false
                        }
                        catch {
                            Write-Warning ("跳过转储 '{0}'：{1}" -f $path, $_.Exception.Message)
                            Write-SystemAudit -Operation $Action -Path $path -Result 'Skipped' -Confirm:$false
                        }
                    }
                }
            }
        }
        'WindowsOld' {
            $operationPath = Join-Path $systemRoot 'Windows.old'
            $report = Get-SystemTargetReport -LiteralPath $operationPath -Category 'WindowsOld'
            Write-Output $report
            Write-Warning '优先使用“设置 → 系统 → 存储 → 临时文件 → 以前的 Windows 安装”，或“磁盘清理 → 清理系统文件”。本脚本执行时使用系统 cleanmgr /AUTOCLEAN；此命令也可能清理升级相关的其他残留。'
            if (-not $report.Exists) { break }
            $cleanmgr = Join-Path $system32 'cleanmgr.exe'
            if (-not (Test-Path -LiteralPath $cleanmgr -PathType Leaf)) {
                Write-Warning '此系统没有 cleanmgr.exe，请使用上述系统设置入口；脚本不会接管权限强删 Windows.old。'
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Skipped' -Confirm:$false
                break
            }
            if ($PSCmdlet.ShouldProcess($operationPath, '调用系统磁盘清理删除旧系统安装；永久失去版本回退能力')) {
                Assert-SystemTarget -LiteralPath $operationPath -Category 'WindowsOld'
                Write-Output (Invoke-SystemExternal -FilePath $cleanmgr -ArgumentList @('/AUTOCLEAN', '/D', $systemDrive.Substring(0, 1)) `
                    -Description '系统磁盘清理：清除旧 Windows 安装及升级残留' -Confirm:$false)
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Success' -Confirm:$false
                Write-Warning '系统磁盘清理可能显示界面或继续在后台运行；请在完成后重新扫描，不把逻辑目录大小当作已释放容量。'
            }
        }
        'Hibernate' {
            $operationPath = Join-Path $systemRoot 'hiberfil.sys'
            $exists = Test-Path -LiteralPath $operationPath -ErrorAction Stop
            $bytes = $null
            if ($exists) { $bytes = [long](Get-Item -LiteralPath $operationPath -Force -ErrorAction Stop).Length }
            Write-Output ([pscustomobject]@{ Action = $Action; Path = $operationPath; Exists = $exists; FileBytes = $bytes; Mode = $Mode })
            if (-not $PSBoundParameters.ContainsKey('Mode')) { throw '已报告休眠文件；请显式指定 -Mode Off 或 -Mode Reduced。' }
            $arguments = @('/h', 'off')
            if ($Mode -eq 'Reduced') { $arguments = @('/h', '/type', 'reduced') }
            if ($PSCmdlet.ShouldProcess($operationPath, "将休眠模式设为 $Mode；$($risks[$Action])")) {
                Write-Output (Invoke-SystemExternal -FilePath (Join-Path $system32 'powercfg.exe') `
                    -ArgumentList $arguments -Description "设置休眠模式 $Mode" -Confirm:$false)
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Success' -Confirm:$false
                if ($Mode -eq 'Reduced') {
                    Write-Warning '精简文件不支持完整休眠；若系统当前未启用休眠或不支持此模式，powercfg 会报错，脚本不会自动追加其他配置更改。'
                }
            }
        }
        'ShadowStorage' {
            $operationPath = $ForVolume
            $vssadmin = Join-Path $system32 'vssadmin.exe'
            Write-Output (Invoke-SystemExternal -FilePath $vssadmin `
                -ArgumentList @('list', 'shadowstorage', "/For=$ForVolume") `
                -Description '只读列出卷影存储关联' -ReadOnly)
            $associations = @(Get-ShadowStorageAssociations)
            Write-Output $associations
            $selected = @($associations | Where-Object { $_.ForVolume -ieq $ForVolume })
            if ($PSBoundParameters.ContainsKey('OnVolume')) {
                $selected = @($selected | Where-Object { $_.OnVolume -ieq $OnVolume })
            }
            if (-not $PSBoundParameters.ContainsKey('MaxSize')) {
                Write-Warning '未指定 -MaxSize，只报告，不调整卷影存储。'
                break
            }
            if ($selected.Count -ne 1) { throw '没有唯一匹配的实际 VSS 关联；请根据列表显式提供 -ForVolume 和 -OnVolume，脚本不会创建或猜测关联。' }
            $association = $selected[0]
            $operationPath = "/For=$($association.ForVolume) /On=$($association.OnVolume)"
            Write-Warning '缩小上限可能立即永久删除旧还原点和卷影副本；即使只调整配额，也不能视为可回滚操作。'
            if ($PSCmdlet.ShouldProcess($operationPath, "将实际 VSS 关联上限调整为 $MaxSize")) {
                # 执行前重新查询，拒绝确认等待期间已改变的关联。
                $current = @(Get-ShadowStorageAssociations | Where-Object {
                    $_.ForVolume -ieq $association.ForVolume -and $_.OnVolume -ieq $association.OnVolume
                })
                if ($current.Count -ne 1) { throw '实际 VSS 关联已经改变，取消操作。' }
                Write-Output (Invoke-SystemExternal -FilePath $vssadmin `
                    -ArgumentList @('resize', 'shadowstorage', "/For=$($association.ForVolume)",
                        "/On=$($association.OnVolume)", "/MaxSize=$MaxSize") `
                    -Description '按实际关联调整卷影存储上限，可能删除旧还原点' -Confirm:$false)
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Success' -Confirm:$false
            }
        }
        'ReservedStorage' {
            $operationPath = 'Windows reserved storage'
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $build = Get-SystemProperty $os @('BuildNumber')
            $productType = Get-SystemProperty $os @('ProductType')
            Write-Output ([pscustomobject]@{
                Action = $Action; WindowsVersion = (Get-SystemProperty $os @('Version'))
                Build = $build; Caption = (Get-SystemProperty $os @('Caption'))
            })
            if ([int]$build -lt 19041 -or [int]$productType -ne 1) {
                Write-Warning '仅支持 Windows 10 2004（19041）及以上客户端版本和 Windows 11；此系统不执行保留存储操作。'
                break
            }
            $stateText = Invoke-SystemExternal -FilePath $dism `
                -ArgumentList @('/Online', '/Get-ReservedStorageState', '/English') `
                -Description '只读查询保留存储状态' -ReadOnly
            if ($WhatIfPreference) {
                if ($DisableReservedStorage) {
                    [void]$PSCmdlet.ShouldProcess($operationPath, '实际运行先确认状态已启用且无更新进行，再禁用保留存储；不保证立即释放容量')
                }
                break
            }
            Write-Output $stateText
            if (-not $DisableReservedStorage) {
                Write-Warning '只查询状态；默认建议保持启用。确需禁用时必须额外指定 -DisableReservedStorage。'
                break
            }
            if ([regex]::IsMatch($stateText, '(?im)^\s*Reserved storage is disabled\.?\s*$')) {
                Write-Warning '保留存储已经禁用，无需修改。'
                break
            }
            if (-not [regex]::IsMatch($stateText, '(?im)^\s*Reserved storage is enabled\.?\s*$')) {
                throw '无法明确识别当前保留存储状态，拒绝禁用。'
            }
            $activity = Get-WindowsUpdateActivity
            if ($activity.IsBusy) {
                Write-Warning ($activity.Reasons -join [Environment]::NewLine)
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Skipped' -Confirm:$false
                break
            }
            if ($PSCmdlet.ShouldProcess($operationPath, '禁用保留存储；不保证立即释放容量，可能影响更新空间')) {
                Write-Output (Invoke-SystemExternal -FilePath $dism `
                    -ArgumentList @('/Online', '/Set-ReservedStorageState', '/State:Disabled', '/English') `
                    -Description '显式禁用保留存储' -Confirm:$false)
                Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Success' -Confirm:$false
            }
        }
        'PageFile' {
            $queryErrors = New-Object 'System.Collections.Generic.List[string]'
            $computer = $null
            $settings = $null
            $usage = $null
            $recovery = $null
            try { $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
            catch { $queryErrors.Add("计算机配置未知：$($_.Exception.Message)") }
            try { $settings = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop) }
            catch { $queryErrors.Add("页面文件配置未知：$($_.Exception.Message)") }
            try { $usage = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop) }
            catch { $queryErrors.Add("页面文件用量未知：$($_.Exception.Message)") }
            try { $recovery = @(Get-CimInstance -ClassName Win32_OSRecoveryConfiguration -ErrorAction Stop) }
            catch { $queryErrors.Add("崩溃转储配置未知：$($_.Exception.Message)") }
            Write-Output ([pscustomobject]@{
                Action = $Action
                AutomaticManagedPagefile = (Get-SystemProperty $computer @('AutomaticManagedPagefile'))
                PhysicalMemoryBytes = (Get-SystemProperty $computer @('TotalPhysicalMemory'))
                Settings = $settings
                Usage = $usage
                CrashDumpConfiguration = $recovery
                UnknownItems = @($queryErrors.ToArray())
                Recommendation = '建议保持系统管理。缩小会降低内存提交上限；移到 D 盘可能影响崩溃转储。应在系统高级设置中调整，重启后验证；本脚本不自动修改。'
                Units = 'PageFileSetting 的 InitialSize/MaximumSize 和 PageFileUsage 的 AllocatedBaseSize/CurrentUsage/PeakUsage 单位为 MB。'
            })
        }
    }
}
catch {
    Write-SystemAudit -Operation $Action -Path $operationPath -Result 'Failed' -Confirm:$false
    throw
}

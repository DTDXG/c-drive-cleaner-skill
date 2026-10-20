<#
.SYNOPSIS
按扫描报告中的编号，一次执行用户已确认的 C 盘清理项。
.DESCRIPTION
仅接受 SchemaVersion 3 报告；先完整校验，再依次调用白名单处理器。
须先向用户说明完整范围并取得确认；Items 本身表示这份已取得的授权。
不自动提权，不扩大权限重试。空间收益按 C: 空闲变化估算，可能受后台活动影响。
兼容 Windows PowerShell 5.1 / PowerShell 7；非 Windows 只允许测试提取纯函数。
.PARAMETER ReportPath
scan.ps1 生成的 JSON 报告路径。
.PARAMETER Items
用户已确认的 ConfirmationItems 整数编号。
.PARAMETER AcknowledgeIrreversible
已逐项确认不可逆后果的编号；必须覆盖所有选中的不可逆项，不能含未选编号。
.PARAMETER MaxReportAgeHours
报告最大年龄（小时），默认 24，范围 1..168；按扫描开始时间计算。
.PARAMETER ResultPath
新的 JSON 结果文件路径，绝不覆盖；省略时在共享日志目录生成唯一名称。
.PARAMETER SkipRescan
跳过执行后的 Quick 扫描。
.EXAMPLE
& '.\scripts\apply-plan.ps1' -ReportPath '.\scan.json' -Items @(1,2,8) -AcknowledgeIrreversible @(8) -WhatIf
演练全部所选项，不运行外部工具、不改服务、不删除，也不写结果或审计日志。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ReportPath,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][int[]]$Items,
    [int[]]$AcknowledgeIrreversible = @(),
    [ValidateRange(1, 168)][int]$MaxReportAgeHours = 24,
    [string]$ResultPath,
    [switch]$SkipRescan
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw '此脚本仅支持 Windows；请在 Windows PowerShell 5.1 或 PowerShell 7 中执行。'
}
. (Join-Path $PSScriptRoot 'common.ps1')

# 这些校验函数不调用处理器、不读取 Windows 状态，供测试仅通过 AST 加载。
function Get-PlanProperty {
    param($InputObject, [string]$Name, $Default = $null, [switch]$Required)
    if ($null -ne $InputObject) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($Name)) { return ,($InputObject[$Name]) }
        }
        else {
            $property = $InputObject.PSObject.Properties[$Name]
            if ($null -ne $property) { return ,($property.Value) }
        }
    }
    if ($Required) { throw ('报告缺少必要字段：' + $Name) }
    return ,$Default
}

function Assert-PlanReport {
    param($Report, [int[]]$Items, [int[]]$Acknowledged = @(), $Context,
        [ValidateRange(1, 168)][int]$MaxAgeHours = 24,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [string]$ComputerName = [Environment]::MachineName)
    $version = Get-PlanProperty $Report 'SchemaVersion' -Required
    if ($version -isnot [int] -and $version -isnot [long]) { throw '报告版本必须为整数 3。' }
    if ($version -ne 3) { throw '只接受 SchemaVersion 3 的扫描报告，请重新扫描。' }
    $all = Get-PlanProperty $Report 'ConfirmationItems' -Required
    if ($null -eq $all -or $all -isnot [System.Collections.IList]) { throw 'ConfirmationItems 必须为数组。' }
    foreach ($name in @('StartedAtUtc', 'CompletedAtUtc')) {
        $value = Get-PlanProperty $Report $name -Required
        $timestamp = [DateTimeOffset]::MinValue
        # 较新的 PowerShell 7 会把 JSON 时间自动转换为 DateTime；保留其时区信息。
        if ($value -is [DateTime] -or $value -is [DateTimeOffset]) { $timestamp = [DateTimeOffset]$value }
        elseif ($value -isnot [string] -or -not [DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$timestamp)) { throw ('报告时间无效：' + $name) }
        if ($timestamp -gt $Now) { throw ('报告时间晚于当前时间：' + $name) }
        if ($name -eq 'StartedAtUtc') { $started = $timestamp }
        else { $completed = $timestamp }
    }
    if ($completed -lt $started) { throw '报告完成时间早于开始时间。' }
    if (($Now - $started).TotalHours -gt $MaxAgeHours) {
        throw ('报告已过期（超过 {0} 小时），请重新扫描并核对确认项。' -f $MaxAgeHours)
    }
    $machine = Get-PlanProperty $Report 'ComputerName' -Required
    if ($machine -isnot [string] -or [string]::IsNullOrWhiteSpace($machine) -or $machine -ine $ComputerName) {
        throw '报告机器名与当前计算机不匹配，拒绝执行。'
    }
    $identity = Get-PlanProperty $Report 'Context' -Required
    $sid = Get-PlanProperty $identity 'OriginalUserSid' -Required
    $currentSid = [string](Get-PlanProperty $Context 'OriginalUserSid' -Required)
    if ($sid -isnot [string] -or [string]::IsNullOrWhiteSpace($currentSid) -or $sid -ine $currentSid) {
        throw '报告原用户 SID 与当前上下文不匹配，拒绝执行。'
    }
    if ((Get-PlanProperty $Context 'OriginalUserVerified' $false) -ne $true -or
        (Get-PlanProperty $Context 'CurrentUserSid' '') -ine $currentSid) {
        throw '当前原用户身份未核实；请使用扫描时的同一账户（可同账户提权）。'
    }
    $profile = Get-PlanProperty $identity 'OriginalUserProfile' -Required
    $currentProfile = [string](Get-PlanProperty $Context 'OriginalUserProfile' -Required)
    if ($profile -isnot [string] -or [string]::IsNullOrWhiteSpace($currentProfile) -or
        $profile.TrimEnd('\') -ine $currentProfile.TrimEnd('\')) { throw '报告原用户目录与当前上下文不匹配。' }
    if ((Get-PlanProperty $Report 'WhatIf' $false) -ne $false) { throw '不能执行演练报告，请重新扫描。' }
    if (@($Items).Count -eq 0) { throw '至少需要一个已确认编号。' }
    if (@($Items | Select-Object -Unique).Count -ne $Items.Count) { throw 'Items 含重复编号，拒绝重复执行。' }
    $byId = @{}
    foreach ($item in $all) {
        $id = Get-PlanProperty $item 'Id' -Required
        if (($id -isnot [int] -and $id -isnot [long]) -or $id -le 0 -or $id -gt [int]::MaxValue -or $byId.ContainsKey([int]$id)) {
            throw '报告确认编号必须为不重复的正整数。'
        }
        $byId[[int]$id] = $item
    }
    $unknown = @($Items | Where-Object { -not $byId.ContainsKey($_) })
    if ($unknown.Count -gt 0) { throw ('报告不存在以下编号：' + ($unknown -join '、')) }
    $extra = @($Acknowledged | Where-Object { $_ -notin $Items })
    if ($extra.Count -gt 0) { throw ('不可逆确认含未选中的编号：' + ($extra -join '、')) }
    $missing = @()
    foreach ($id in $Items) {
        $item = $byId[$id]
        foreach ($name in @('Irreversible', 'RequiresAdmin')) {
            if ((Get-PlanProperty $item $name -Required) -isnot [bool]) { throw ('确认项 {0} 的 {1} 必须为布尔值。' -f $id, $name) }
        }
        $title = Get-PlanProperty $item 'Title' -Required
        if ($title -isnot [string] -or [string]::IsNullOrWhiteSpace($title)) { throw ('确认项标题无效：' + $id) }
        if ($item.Irreversible -and $id -notin $Acknowledged) { $missing += $id }
    }
    if ($missing.Count -gt 0) { throw ('缺少不可逆后果确认，请在 -AcknowledgeIrreversible 中列出编号：' + ($missing -join '、')) }
    foreach ($id in $Items) { $byId[$id] }
}

function Resolve-PlanHandler {
    param([string]$HandlerScript, [string]$ScriptsRoot)
    # 严格比较完整相对名称；从不把 JSON 路径直接用于执行或路径拼接。
    if ($HandlerScript -ceq 'scripts/clean-cache.ps1') { return (Join-Path $ScriptsRoot 'clean-cache.ps1') }
    if ($HandlerScript -ceq 'scripts/clean-system.ps1') { return (Join-Path $ScriptsRoot 'clean-system.ps1') }
    throw ('处理器不在执行白名单内：' + $HandlerScript)
}

function Get-PlanHandlerParameters {
    param([string]$HandlerScript, $HandlerParameters, [string]$ScriptsRoot)
    $handler = Resolve-PlanHandler $HandlerScript $ScriptsRoot
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($handler, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0 -or $null -eq $ast.ParamBlock) { throw ('无法解析处理器参数块：' + $handler) }
    if ($HandlerParameters -is [System.Collections.IDictionary]) { $names = @($HandlerParameters.Keys) }
    elseif ($HandlerParameters -is [pscustomobject]) { $names = @($HandlerParameters.PSObject.Properties | ForEach-Object { $_.Name }) }
    else { throw 'HandlerParameters 必须为参数对象。' }
    $definitions = @{}
    foreach ($parameter in $ast.ParamBlock.Parameters) { $definitions[$parameter.Name.VariablePath.UserPath] = $parameter }
    $validated = @{}
    foreach ($name in $names) {
        if ($name -isnot [string] -or -not $definitions.ContainsKey($name)) { throw ('未知的处理器参数：' + $name) }
        $definition = $definitions[$name]
        $canonicalName = $definition.Name.VariablePath.UserPath
        if ($validated.ContainsKey($canonicalName)) { throw ('处理器参数重复：' + $canonicalName) }
        $value = Get-PlanProperty $HandlerParameters $name
        if ($null -eq $value) { throw ('处理器参数不能为空：' + $name) }
        $type = $definition.StaticType
        if ($type -eq [string[]]) {
            $values = @($value)
            if ($values.Count -eq 0) { throw ('处理器参数不能为空数组：' + $name) }
            foreach ($element in $values) {
                if ($element -isnot [string] -or [string]::IsNullOrWhiteSpace($element)) { throw ('处理器参数必须为非空字符串：' + $name) }
            }
            $value = [string[]]$values
        }
        elseif ($type -eq [string]) {
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw ('处理器参数必须为非空字符串：' + $name) }
        }
        elseif ($type -eq [double]) {
            if ($value -isnot [ValueType] -or $value -is [bool] -or $value -is [char]) { throw ('处理器参数必须为数字：' + $name) }
            $value = [double]$value
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw ('处理器参数必须为有限数字：' + $name) }
        }
        elseif ($type -eq [System.Management.Automation.SwitchParameter]) {
            if ($value -isnot [bool]) { throw ('处理器开关必须为布尔值：' + $name) }
        }
        else { throw ('尚未支持的处理器参数类型：' + $name) }
        foreach ($attribute in $definition.Attributes) {
            if ($attribute -isnot [Management.Automation.Language.AttributeAst]) { continue }
            # 只读取本地脚本的常量约束，不编译或执行报告中的任何内容。
            $arguments = @($attribute.PositionalArguments | ForEach-Object { $_.SafeGetValue() })
            switch ($attribute.TypeName.Name) {
                'ValidateSet' {
                    foreach ($element in @($value)) {
                        if ($element -notin $arguments) { throw ('参数 {0} 的值不在 ValidateSet 内：{1}' -f $name, $element) }
                    }
                }
                'ValidateRange' {
                    if ($value -lt $arguments[0] -or $value -gt $arguments[1]) { throw ('参数值超出 ValidateRange：' + $name) }
                }
                'ValidatePattern' {
                    if ($value -notmatch $arguments[0]) { throw ('参数值不符合 ValidatePattern：' + $name) }
                }
            }
        }
        $validated[$canonicalName] = $value
    }
    # 缓存处理器省略 Category 会处理全部类别，因此必须显式指定扫描的选择器。
    $selector = 'Action'
    if ($HandlerScript -ceq 'scripts/clean-cache.ps1') { $selector = 'Category' }
    if (-not $validated.ContainsKey($selector)) { throw ('处理器缺少明确选择器：' + $selector) }
    return $validated
}

function New-PlanExecutionItems {
    param([object[]]$Selected, [int[]]$Acknowledged = @(), [string]$ScriptsRoot)
    foreach ($item in $Selected) {
        $handlerName = Get-PlanProperty $item 'HandlerScript' -Required
        if ($handlerName -isnot [string]) { throw 'HandlerScript 必须为白名单字符串。' }
        $handler = Resolve-PlanHandler $handlerName $ScriptsRoot
        $parameters = Get-PlanHandlerParameters $handlerName (Get-PlanProperty $item 'HandlerParameters' -Required) $ScriptsRoot
        # 不允许报告里的参数另行指定账户，身份仅来自已经核实的共享上下文。
        if ($parameters.ContainsKey('OriginalUserSid') -or $parameters.ContainsKey('OriginalUserProfile')) {
            throw ('编号 {0} 含账户覆盖参数，请重新扫描。' -f $item.Id)
        }
        $needsAdmin = $false; $needsAcknowledgement = $false
        if ($handlerName -ceq 'scripts/clean-cache.ps1') {
            $needsAdmin = @($parameters.Category | Where-Object { $_ -in @('WindowsTemp', 'SystemLogs') }).Count -gt 0
        }
        else {
            $needsAdmin = $parameters.Action -ne 'PageFile'
            $needsAcknowledgement = $parameters.Action -in @('RecycleBin', 'CrashDumps', 'WindowsOld', 'Hibernate', 'ShadowStorage', 'ReservedStorage', 'PageFile')
            if ($parameters.ContainsKey('AcknowledgeIrreversible') -and $item.Id -notin $Acknowledged) {
                $parameters.Remove('AcknowledgeIrreversible')
            }
            if ($needsAcknowledgement -and (-not $item.Irreversible -or $item.Id -notin $Acknowledged -or
                -not $parameters.ContainsKey('AcknowledgeIrreversible') -or -not $parameters.AcknowledgeIrreversible)) {
                throw ('编号 {0} 的不可逆标记、扫描参数或后果确认不完整。' -f $item.Id)
            }
        }
        if ($needsAdmin -and -not $item.RequiresAdmin) { throw ('编号 {0} 的管理员要求与处理器不符，请重新扫描。' -f $item.Id) }
        # 不补入 MinAgeHours，不改扫描参数；省略时由处理器采用自己的安全默认值。
        [pscustomobject]@{ Id = $item.Id; Title = $item.Title; HandlerScript = $handlerName; HandlerPath = $handler
            Parameters = $parameters; RequiresAdmin = $item.RequiresAdmin; Irreversible = $item.Irreversible }
    }
}

function Get-PlanOrderedItems {
    param([object[]]$Plan)
    $Plan | Sort-Object @{ Expression = { [bool]$_.Irreversible } }, @{ Expression = {
        if ($_.HandlerScript -ceq 'scripts/clean-cache.ps1' -and -not $_.RequiresAdmin) { 0 }
        elseif ($_.HandlerScript -ceq 'scripts/clean-cache.ps1') { 1 }
        else { 2 }
    } }, Id
}

function Get-PlanRerunCommand {
    param([string]$ScriptPath, [string]$ReportPath, [int[]]$Items, [int[]]$Acknowledged = @(),
        [int]$MaxAgeHours = 24, [switch]$SkipRescan, [switch]$WhatIfRun)
    $command = "& '" + $ScriptPath.Replace("'", "''") + "' -ReportPath '" + $ReportPath.Replace("'", "''") + "' -Items @(" + ($Items -join ',') + ')'
    $ack = @($Acknowledged | Where-Object { $_ -in $Items } | Select-Object -Unique)
    if ($ack.Count -gt 0) { $command += ' -AcknowledgeIrreversible @(' + ($ack -join ',') + ')' }
    $command += ' -MaxReportAgeHours ' + $MaxAgeHours
    if ($SkipRescan) { $command += ' -SkipRescan' }
    if ($WhatIfRun) { $command += ' -WhatIf' }
    return $command
}

function Get-PlanFreeBytes {
    try {
        $free = (Get-PSDrive -Name C -PSProvider FileSystem -ErrorAction Stop).Free
        if ($null -ne $free) { return [long]$free }
    }
    catch { }
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($null -ne $disk.FreeSpace) { return [long]$disk.FreeSpace }
    }
    catch { }
    return $null
}

function Get-PlanOutcome {
    param([string]$HandlerScript, [object[]]$Records, [bool]$Failed, [bool]$WhatIfRun, [string]$Action = '')
    $messages = New-Object 'System.Collections.Generic.List[string]'
    $states = @(); $targetExists = @(); $hasError = $false; $hasSkipped = $false; $hasProgress = $false; $hasWarning = $false
    foreach ($record in $Records) {
        if ($record -is [Management.Automation.ErrorRecord]) {
            $messages.Add('错误：' + $record.Exception.Message); $hasError = $true; continue
        }
        if ($record -is [Management.Automation.WarningRecord]) {
            $messages.Add('警告：' + $record.Message); $hasWarning = $true
            if ($record.Message -match '跳过|无法.*检查|无法可靠|此系统没有|待重启|正在运行|更新活动|状态不明|存在维护进程|系统安装标记|正在工作|未完成的 BITS') { $hasSkipped = $true }
            continue
        }
        $state = Get-PlanProperty $record 'Result' ''
        $exists = Get-PlanProperty $record 'Exists'
        if ($exists -is [bool]) { $targetExists += $exists }
        if ($state -in @('done', 'partial', 'skipped', 'failed')) { $states += $state }
        if ($state -in @('done', 'partial') -or (Get-PlanProperty $record 'DeletedCount' 0) -gt 0) { $hasProgress = $true }
        foreach ($reason in @(Get-PlanProperty $record 'SkippedReasons' @())) { $messages.Add([string]$reason); $hasSkipped = $true }
        foreach ($skip in @(Get-PlanProperty $record 'SkippedItems' @())) {
            $messages.Add([string](Get-PlanProperty $skip 'Reason' '处理器跳过此项，详见审计日志。')); $hasSkipped = $true
        }
    }
    $result = 'done'
    if ($WhatIfRun) { $messages.Add('WhatIf 演练，未执行修改，也未写入文件或日志。') }
    if ($Failed -or 'failed' -in $states -or $hasError) { $result = 'failed' }
    elseif ($WhatIfRun) { $result = 'skipped' }
    elseif ($states.Count -gt 0) {
        if ('partial' -in $states -or ('done' -in $states -and ('skipped' -in $states -or $hasSkipped))) { $result = 'partial' }
        elseif ('done' -notin $states) { $result = 'skipped' }
    }
    elseif ($hasSkipped) {
        $result = 'skipped'
        if ($hasProgress) { $result = 'partial' }
    }
    elseif ($Action -in @('UpdateCache', 'RecycleBin', 'CrashDumps', 'WindowsOld') -and $targetExists.Count -gt 0 -and
        $true -notin $targetExists) {
        $result = 'skipped'; $messages.Add('处理器报告目标均不存在，无需清理。')
    }
    elseif ($hasWarning -and $HandlerScript -ceq 'scripts/clean-system.ps1') {
        # 系统脚本没有统一汇总对象；有警告时保守标为 partial，避免声称全部完成。
        $result = 'partial'; $messages.Add('系统处理器带警告返回，请核对上述说明及审计日志。')
    }
    if ($messages.Count -eq 0) { $messages.Add('处理器已返回，未报告错误；释放量为 C: 空闲变化估算。') }
    return [pscustomobject]@{ Result = $result; Messages = @($messages.ToArray() | Select-Object -Unique) }
}

function Invoke-PlanItem {
    param($Item, [bool]$WhatIfRun)
    $records = New-Object 'System.Collections.Generic.List[object]'
    $failed = $false
    $before = Get-PlanFreeBytes
    try {
        $handler = $Item.HandlerPath; $parameters = $Item.Parameters
        # 及时收集管道输出，后续抛错也不丢失此前的汇总及错误；不修改处理器参数。
        & $handler @parameters -Confirm:$false -WhatIf:$WhatIfRun 2>&1 3>&1 | ForEach-Object { $records.Add($_) }
    }
    catch { $failed = $true; $records.Add($_) }
    $after = Get-PlanFreeBytes
    $freed = $null
    if ($WhatIfRun) { $freed = [long]0 }
    elseif ($null -ne $before -and $null -ne $after) { $freed = [long]$after - [long]$before }
    $outcome = Get-PlanOutcome $Item.HandlerScript $records.ToArray() $failed $WhatIfRun (Get-PlanProperty $Item.Parameters 'Action' '')
    if ($null -eq $freed) { $outcome.Messages += '无法测量 C: 空闲变化，实际释放量未知。' }
    [pscustomobject]@{ Id = $Item.Id; Title = $Item.Title; Result = $outcome.Result; FreedBytes = $freed; Messages = @($outcome.Messages) }
}

function Invoke-PlanItems {
    param([object[]]$Plan, [bool]$IsAdmin, [bool]$WhatIfRun, [string]$RerunCommand)
    foreach ($item in $Plan) {
        if ($item.RequiresAdmin -and -not $IsAdmin) {
            [pscustomobject]@{ Id = $item.Id; Title = $item.Title; Result = 'skipped'; FreedBytes = [long]0
                Messages = @('跳过：需要管理员权限；请以扫描时的同一账户打开管理员终端执行：', $RerunCommand) }
            continue
        }
        # 每项独立捕获；测量或汇总异常也不能中断其他已确认项目。
        try { Invoke-PlanItem $item $WhatIfRun }
        catch {
            [pscustomobject]@{ Id = $item.Id; Title = $item.Title; Result = 'failed'; FreedBytes = $null
                Messages = @('此项执行或汇总失败，未扩大权限重试：' + $_.Exception.Message) }
        }
    }
}

function Get-PlanNewFilePath {
    param([string]$Path, $Context)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($fullPath -notmatch '^[A-Za-z]:\\' -or $fullPath.Substring(2).Contains(':')) {
        throw '结果只接受本地盘符上的普通文件路径，不接受网络路径、提供程序路径或备用数据流。'
    }
    $check = Test-CleanerPathChain -LiteralPath $fullPath -AllowMissing
    if (-not $check.IsSafe) { throw ('结果路径不安全：' + $check.Reason) }
    $forbidden = Get-CleanerForbiddenReason -LiteralPath $fullPath -Context $Context
    if ($forbidden) { throw ('结果路径不安全：' + $forbidden) }
    if (Test-Path -LiteralPath $fullPath) { throw ('结果路径已存在，拒绝覆盖：' + $fullPath) }
    return $fullPath
}

function New-PlanResultFile {
    param([string]$Path, $Context)
    $guards = New-Object 'System.Collections.Generic.List[object]'
    try {
        $directory = [IO.Path]::GetDirectoryName($Path)
        $missing = New-Object 'System.Collections.Generic.Stack[string]'
        $candidate = $directory
        while (-not [IO.Directory]::Exists($candidate)) {
            $missing.Push($candidate); $candidate = [IO.Path]::GetDirectoryName($candidate)
            if (-not $candidate) { throw '找不到结果目录的本地祖先。' }
        }
        while ($missing.Count -gt 0) {
            $next = $missing.Pop()
            $guards.Add((Open-CleanerParentGuards -LiteralPath $next))
            [void][IO.Directory]::CreateDirectory($next)
            $check = Test-CleanerPathChain -LiteralPath $next
            if (-not $check.IsSafe) { throw $check.Reason }
        }
        $guards.Add((Open-CleanerParentGuards -LiteralPath $Path))
        $checkedPath = Get-PlanNewFilePath $Path $Context
        # 执行前占用新文件，避免清理之后才发现路径冲突；CreateNew 防止竞态覆盖。
        $stream = [IO.File]::Open($checkedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        return [pscustomobject]@{ Stream = $stream; Guards = $guards }
    }
    catch {
        foreach ($group in $guards) { foreach ($handle in $group.Handles) { $handle.Dispose() } }
        throw
    }
}

function Format-PlanBytes {
    param($Bytes)
    if ($null -eq $Bytes) { return '未知' }
    if ([Math]::Abs([double]$Bytes) -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ([Math]::Abs([double]$Bytes) -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} 字节' -f $Bytes)
}

$context = Get-CleanerContext
$reportFile = Get-Item -LiteralPath $ReportPath -ErrorAction Stop
if ($reportFile.PSIsContainer -or $reportFile.PSProvider.Name -ne 'FileSystem') { throw 'ReportPath 必须为扫描 JSON 文件。' }
$resolvedReportPath = $reportFile.FullName
try { $report = Get-Content -LiteralPath $resolvedReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { throw ('无法读取扫描 JSON 报告：' + $_.Exception.Message) }
$selected = @(Assert-PlanReport -Report $report -Items $Items -Acknowledged $AcknowledgeIrreversible -Context $context -MaxAgeHours $MaxReportAgeHours)
$plan = @(Get-PlanOrderedItems @(New-PlanExecutionItems $selected $AcknowledgeIrreversible $PSScriptRoot))
$logDirectory = Split-Path -Path $context.LogPath -Parent
if ([string]::IsNullOrWhiteSpace($logDirectory)) { throw '共享上下文未提供日志目录。' }
if ([string]::IsNullOrWhiteSpace($ResultPath)) { $ResultPath = Join-Path $logDirectory ('apply-plan-' + [guid]::NewGuid().ToString('N') + '.json') }
$resolvedResultPath = Get-PlanNewFilePath $ResultPath $context
$whatIfRun = [bool]$WhatIfPreference
$isAdmin = [bool]$context.IsAdmin
$adminItems = @($plan | Where-Object { $_.RequiresAdmin -and -not $isAdmin })
$rerunCommand = $null
if ($adminItems.Count -gt 0) {
    $rerunCommand = Get-PlanRerunCommand -ScriptPath $PSCommandPath -ReportPath $resolvedReportPath -Items @($adminItems.Id) `
        -Acknowledged $AcknowledgeIrreversible -MaxAgeHours $MaxReportAgeHours -SkipRescan:$SkipRescan -WhatIfRun:$whatIfRun
}
if (-not $whatIfRun -and -not $PSCmdlet.ShouldProcess(($Items -join '、'), '执行已确认的清理计划并创建结果文件')) { return }
$startedAt = [DateTime]::UtcNow
$freeBefore = Get-PlanFreeBytes
$results = New-Object 'System.Collections.Generic.List[object]'
$resultFile = $null; $rescanPath = $null; $freeAfter = $null
try {
    if (-not $whatIfRun) {
        $resultFile = New-PlanResultFile $resolvedResultPath $context
        Write-CleanerLog -Action 'ApplyPlan/Start' -Path $resolvedReportPath -Result 'Started' `
            -Message ('已确认编号：' + ($Items -join '、')) -Context $context -Confirm:$false -ErrorAction Stop
    }
    Invoke-PlanItems $plan $isAdmin $whatIfRun $rerunCommand | ForEach-Object { $results.Add($_) }
    if (-not $SkipRescan -and -not $whatIfRun) {
        $newScanPath = Join-Path $logDirectory ('scan-after-plan-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            & (Join-Path $PSScriptRoot 'scan.ps1') -Quick -OutputPath $newScanPath -Confirm:$false | Out-Null
            if (-not (Test-Path -LiteralPath $newScanPath -PathType Leaf)) { throw '复扫未生成报告。' }
            $rescanPath = $newScanPath
        }
        catch { Write-Warning ('清理后复扫失败，已保留逐项结果：' + $_.Exception.Message) }
    }
}
finally {
    $freeAfter = Get-PlanFreeBytes
    $finishedAt = [DateTime]::UtcNow
    if (-not $whatIfRun -and $null -ne $resultFile) {
        try {
            $result = [ordered]@{ SchemaVersion = 1; ReportPath = $resolvedReportPath; StartedAt = $startedAt.ToString('o')
                FinishedAt = $finishedAt.ToString('o'); IsAdmin = $isAdmin; Items = @($results.ToArray())
                FreeBytesBefore = $freeBefore; FreeBytesAfter = $freeAfter; RescanReportPath = $rescanPath }
            $writer = [IO.StreamWriter]::new($resultFile.Stream, [Text.UTF8Encoding]::new($true), 1024, $true)
            try { $writer.Write(($result | ConvertTo-Json -Depth 12)); $writer.Flush() }
            finally { $writer.Dispose() }
        }
        finally {
            $resultFile.Stream.Dispose()
            foreach ($group in $resultFile.Guards) { foreach ($handle in $group.Handles) { $handle.Dispose() } }
            Write-CleanerAudit -Action 'ApplyPlan/End' -Path $resolvedReportPath -Result 'Finished' `
                -Message ('逐项结果文件：' + $resolvedResultPath) -Context $context -Confirm:$false
        }
    }
}
$rows = @($results.ToArray() | ForEach-Object {
    [pscustomobject]@{ Id = $_.Id; Title = $_.Title; '结果' = $_.Result; '实际释放' = Format-PlanBytes $_.FreedBytes; '说明' = ($_.Messages -join '；') }
})
Write-Host ($rows | Format-Table -Wrap | Out-String -Width 240)
$counts = @{}
foreach ($state in @('done', 'partial', 'skipped', 'failed')) { $counts[$state] = @($results.ToArray() | Where-Object { $_.Result -eq $state }).Count }
Write-Host ('合计 {0} 项：完成 {1}，部分完成 {2}，跳过 {3}，失败 {4}。' -f $results.Count, $counts.done, $counts.partial, $counts.skipped, $counts.failed)
$delta = $null
if ($null -ne $freeBefore -and $null -ne $freeAfter) { $delta = [long]$freeAfter - [long]$freeBefore }
Write-Host ('C: 执行前可用 {0}；执行后可用 {1}；空闲变化 {2}。逐项及总量均为估算，后台活动可能造成偏差，负值表示可用空间减少。' -f (Format-PlanBytes $freeBefore), (Format-PlanBytes $freeAfter), (Format-PlanBytes $delta))
if ($rerunCommand) {
    Write-Host '需要管理员的编号已跳过；以扫描时的同一账户打开管理员 PowerShell 后，一次运行以下命令（编号仍按原报告）：'
    Write-Host $rerunCommand
}
if ($whatIfRun) { Write-Host 'WhatIf 演练结束：未写结果或审计日志，未复扫。' }
else {
    Write-Host ('JSON 结果：' + $resolvedResultPath)
    Write-Host ('审计日志：' + $context.LogPath)
    if ($rescanPath) { Write-Host ('复扫报告：' + $rescanPath) }
}

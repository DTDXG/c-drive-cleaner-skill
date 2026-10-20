$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptsRoot = Join-Path $repoRoot 'scripts'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'apply-plan.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors.Message -join '；') }
foreach ($name in @('Get-PlanProperty', 'Assert-PlanReport', 'Resolve-PlanHandler', 'Get-PlanHandlerParameters',
    'New-PlanExecutionItems', 'Get-PlanOrderedItems', 'Get-PlanRerunCommand', 'Get-PlanOutcome', 'Invoke-PlanItem', 'Invoke-PlanItems')) {
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definitions.Count -ne 1) { throw ('函数定义缺失或重复：' + $name) }
    # 仅加载函数定义；绝不执行脚本体、Windows 查询或清理处理器。
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw ('断言失败：' + $Message) }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($null -eq $Expected) { Assert-True ($null -eq $Actual) $Message }
    else { Assert-True ($Actual -ceq $Expected) ($Message + '；实际值：' + $Actual) }
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught -and $caught -match $Pattern) ($Message + '；实际错误：' + $caught)
}
function New-TestPlanItem {
    param([int]$Id = 1, [string]$Selector = 'UserTemp')
    $system = $Selector -in @('ComponentStore', 'UpdateCache', 'RecycleBin', 'CrashDumps', 'Hibernate')
    $irreversible = $Selector -in @('RecycleBin', 'CrashDumps', 'Hibernate')
    $handler = 'scripts/clean-cache.ps1'; $parameters = @{ Category = $Selector }
    if ($system) { $handler = 'scripts/clean-system.ps1'; $parameters = @{ Action = $Selector } }
    if ($irreversible) { $parameters.AcknowledgeIrreversible = $true }
    if ($Selector -eq 'Hibernate') { $parameters.Mode = 'Reduced' }
    return [pscustomobject]@{ Id = $Id; Title = '测试项目' + $Id; HandlerScript = $handler
        HandlerParameters = $parameters; RequiresAdmin = ($system -or $Selector -in @('WindowsTemp', 'SystemLogs')); Irreversible = $irreversible }
}
$now = [DateTimeOffset]::Parse('2026-10-20T12:00:00Z')
$context = [pscustomobject]@{ OriginalUserSid = 'S-1-5-21-test'; CurrentUserSid = 'S-1-5-21-test'
    OriginalUserProfile = 'C:\Users\测试用户'; OriginalUserVerified = $true; IsAdmin = $false }
function New-TestReport {
    return [pscustomobject]@{ SchemaVersion = 3; ComputerName = '测试电脑'
        StartedAtUtc = $now.AddHours(-1).ToString('o'); CompletedAtUtc = $now.AddMinutes(-30).ToString('o')
        Context = [pscustomobject]@{ OriginalUserSid = $context.OriginalUserSid; OriginalUserProfile = $context.OriginalUserProfile }
        ConfirmationItems = @((New-TestPlanItem 1 UserTemp), (New-TestPlanItem 2 RecycleBin), (New-TestPlanItem 3 CrashDumps)) }
}
function Get-TestSelection {
    param($Report, [int[]]$Ids = @(1), [int[]]$Ack = @(), [int]$MaxAge = 24)
    Assert-PlanReport -Report $Report -Items $Ids -Acknowledged $Ack -Context $context -Now $now -ComputerName '测试电脑' -MaxAgeHours $MaxAge
}
$report = New-TestReport
Assert-Equal @(Get-TestSelection $report).Count 1 '正常选择仅返回所选项'
$jsonReport = $report | ConvertTo-Json -Depth 10 | ConvertFrom-Json
Assert-Equal @(Get-TestSelection $jsonReport).Count 1 '真实 JSON 往返后的报告兼容'
$jsonPlan = @(New-PlanExecutionItems @(Get-TestSelection $jsonReport @(1,2) @(2)) @(2) $scriptsRoot)
Assert-Equal $jsonPlan.Count 2 'JSON 参数对象正确读取'
$report.StartedAtUtc = [DateTimeOffset]::Parse('2026-10-20T18:00:00+07:00')
$report.CompletedAtUtc = [DateTimeOffset]::Parse('2026-10-20T18:30:00+07:00')
Assert-Equal @(Get-TestSelection $report).Count 1 'DateTimeOffset 时区保留'
$report.StartedAtUtc = $now.AddHours(-1).UtcDateTime
$report.CompletedAtUtc = $now.AddMinutes(-30).UtcDateTime
Assert-Equal @(Get-TestSelection $report).Count 1 '新版 PowerShell 自动转换的 DateTime 兼容'
Assert-Rejected { Get-TestSelection $report @(99) } '99' '未知编号拒绝'
Assert-Rejected { Get-TestSelection $report @(2,3) } '2、3' '一次列出所有缺少不可逆确认的编号'
Assert-Rejected { Get-TestSelection $report @(1) @(2) } '未选中.*2' '确认未选中的编号拒绝'
Assert-Equal @(Get-TestSelection $report @(1,2,3) @(2,3)).Count 3 '完整确认允许全部所选项'
Assert-Rejected { Get-TestSelection $report @(1,1) } '重复' '重复执行编号拒绝'
Assert-Rejected { Get-TestSelection $report @() } '至少需要' '空选择拒绝'
$report.StartedAtUtc = $now.AddHours(-25).ToString('o')
Assert-Rejected { Get-TestSelection $report } '过期' '过期报告拒绝'
Assert-Equal @(Get-TestSelection $report @(1) @() 26).Count 1 '年龄限制可显式放宽'
$report.StartedAtUtc = $now.AddHours(-24).ToString('o')
Assert-Equal @(Get-TestSelection $report).Count 1 '最大年龄边界允许'
$report = New-TestReport; $report.CompletedAtUtc = $now.AddMinutes(1).ToString('o')
Assert-Rejected { Get-TestSelection $report } '晚于' '未来时间拒绝'
$report = New-TestReport; $report.StartedAtUtc = '不是日期'
Assert-Rejected { Get-TestSelection $report } '时间无效' '无效时间拒绝'
$report = New-TestReport; $report.SchemaVersion = 2
Assert-Rejected { Get-TestSelection $report } 'SchemaVersion 3' '旧版报告拒绝'
$report = New-TestReport; $report.PSObject.Properties.Remove('ConfirmationItems')
Assert-Rejected { Get-TestSelection $report } 'ConfirmationItems' '缺少确认清单拒绝'
$report = New-TestReport; $report.ComputerName = '另一台电脑'
Assert-Rejected { Get-TestSelection $report } '机器名' '机器不匹配拒绝'
$report = New-TestReport; $report.Context.OriginalUserSid = '另一个用户'
Assert-Rejected { Get-TestSelection $report } 'SID' 'SID 不匹配拒绝'
$report = New-TestReport; $report.Context.OriginalUserProfile = 'C:\Users\其他用户'
Assert-Rejected { Get-TestSelection $report } '目录' '原用户目录不匹配拒绝'
$report = New-TestReport; $report.ConfirmationItems[0].RequiresAdmin = 'false'
Assert-Rejected { Get-TestSelection $report } '布尔值' '字符串不能冒充权限布尔值'
$report = New-TestReport; $report.ConfirmationItems[1].Id = 1
Assert-Rejected { Get-TestSelection $report } '不重复' '重复报告编号拒绝'
$report = New-TestReport; $report.ConfirmationItems[0].Id = 1.5
Assert-Rejected { Get-TestSelection $report } '正整数' '小数报告编号拒绝'

foreach ($handler in @('../x.ps1', '/tmp/x.ps1', 'C:\x.ps1', '\\server\x.ps1', 'scripts/migrate.ps1',
    'scripts/../clean-cache.ps1', 'scripts\clean-cache.ps1', './scripts/clean-cache.ps1', 'scripts/clean-cache.ps1 ')) {
    Assert-Rejected { Resolve-PlanHandler $handler $scriptsRoot } '白名单' ('拒绝非白名单路径：' + $handler)
}
Assert-Equal (Resolve-PlanHandler 'scripts/clean-cache.ps1' $scriptsRoot) (Join-Path $scriptsRoot 'clean-cache.ps1') '白名单路径仅在脚本目录解析'
function Get-TestParameters {
    param($Parameters, [string]$Handler = 'scripts/clean-cache.ps1')
    Get-PlanHandlerParameters $Handler $Parameters $scriptsRoot
}
Assert-Rejected { Get-TestParameters @{ Category = 'UserTemp'; Unexpected = 'x' } } '未知' '未知参数拒绝'
foreach ($name in @('WhatIf', 'Confirm', 'ErrorAction', 'C', 'Cat')) {
    $parameters = @{ Category = 'UserTemp' }; $parameters[$name] = $false
    Assert-Rejected { Get-TestParameters $parameters } '未知' ('禁止公共参数和缩写注入：' + $name)
}
Assert-Rejected { Get-TestParameters @{ Category = 'Everything' } } 'ValidateSet' '无效缓存类别拒绝'
Assert-Rejected { Get-TestParameters @{ Category = @('UserTemp', 'Everything') } } 'ValidateSet' '数组中每个枚举值都检查'
Assert-Rejected { Get-TestParameters @{ Category = @() } } '空数组' '空类别拒绝'
Assert-Rejected { Get-TestParameters @{} } '明确选择器' '不能省略类别而清理全部'
Assert-Rejected { Get-TestParameters ([pscustomobject]@{}) } '明确选择器' 'JSON 空对象也拒绝省略类别'
Assert-Rejected { Get-TestParameters @{ Category = 'UserTemp'; MinAgeHours = -1 } } 'ValidateRange' '年龄范围下限验证'
Assert-Rejected { Get-TestParameters @{ Category = 'UserTemp'; MinAgeHours = 876001 } } 'ValidateRange' '年龄范围上限验证'
Assert-Rejected { Get-TestParameters @{ Category = 'UserTemp'; MinAgeHours = [double]::NaN } } '有限数字' '非有限数字拒绝'
Assert-Rejected { Get-TestParameters @{ Category = 'UserTemp'; MinAgeHours = '0' } } '数字' '不能用字符串伪装数字'
$parameters = Get-TestParameters @{ Category = 'UserTemp' }
Assert-True (-not $parameters.ContainsKey('MinAgeHours')) '不向报告注入年龄阈值'
$parameters = Get-TestParameters @{ Category = 'UserTemp'; MinAgeHours = 0 }
Assert-Equal $parameters.MinAgeHours 0 '报告明确带有合法零阈值时才保留'
$parameters = Get-TestParameters @{ Category = @('UserTemp', 'BrowserCache'); MinAgeHours = 48 }
Assert-Equal $parameters.Category.Count 2 '合法数组保留'
Assert-Equal $parameters.MinAgeHours 48 '原阈值保留'
Assert-Rejected { Get-TestParameters @{ Action = 'Unknown' } 'scripts/clean-system.ps1' } 'ValidateSet' '系统动作枚举验证'
Assert-Rejected { Get-TestParameters @{ Action = 'Hibernate'; Mode = 'Full' } 'scripts/clean-system.ps1' } 'ValidateSet' '休眠模式枚举验证'
Assert-Rejected { Get-TestParameters @{ Action = 'Hibernate'; AcknowledgeIrreversible = 'true' } 'scripts/clean-system.ps1' } '布尔值' '开关类型验证'
Assert-Rejected { Get-TestParameters @{ Action = 'ShadowStorage'; MaxSize = '0GB' } 'scripts/clean-system.ps1' } 'ValidatePattern' '同时验证实际参数块的模式约束'
Assert-Rejected { Get-TestParameters @{ Action = 'ShadowStorage'; OnVolume = 'C: /evil' } 'scripts/clean-system.ps1' } 'ValidatePattern' '卷名注入拒绝'

$report = New-TestReport
$plan = @(New-PlanExecutionItems @(Get-TestSelection $report @(1,2) @(2)) @(2) $scriptsRoot)
Assert-True $plan[1].Parameters.AcknowledgeIrreversible '仅明确确认的不可逆开关传入处理器'
Assert-True (-not $plan[0].Parameters.ContainsKey('MinAgeHours')) '执行计划保持扫描省略的阈值'
$item = New-TestPlanItem 1 ComponentStore; $item.HandlerParameters.AcknowledgeIrreversible = $true
$plan = @(New-PlanExecutionItems @($item) @() $scriptsRoot)
Assert-True (-not $plan[0].Parameters.ContainsKey('AcknowledgeIrreversible')) '不传入未经编号确认的开关'
$item = New-TestPlanItem 1 RecycleBin; $item.Irreversible = $false
Assert-Rejected { New-PlanExecutionItems @($item) @() $scriptsRoot } '不可逆' '不能通过伪造标记绕过不可逆确认'
$item = New-TestPlanItem 1 WindowsTemp; $item.RequiresAdmin = $false
Assert-Rejected { New-PlanExecutionItems @($item) @() $scriptsRoot } '管理员' '不能伪造系统缓存的权限要求'
$item = New-TestPlanItem 1 ComponentStore; $item.HandlerParameters.OriginalUserSid = '其他用户'
Assert-Rejected { New-PlanExecutionItems @($item) @() $scriptsRoot } '账户覆盖' '不能通过处理器参数另换账户'
$ordered = @(Get-PlanOrderedItems @((New-TestPlanItem 1 RecycleBin), (New-TestPlanItem 2 ComponentStore),
    (New-TestPlanItem 3 WindowsTemp), (New-TestPlanItem 4 UserTemp), (New-TestPlanItem 5 BrowserCache), (New-TestPlanItem 6 CrashDumps)))
Assert-Equal ($ordered.Id -join ',') '4,5,3,2,1,6' '用户缓存最先，系统项目随后，不可逆项目最后'
$command = Get-PlanRerunCommand -ScriptPath "C:\skill's folder\scripts\apply-plan.ps1" -ReportPath "C:\用户's\report.json" `
    -Items @(2,3) -Acknowledged @(1,3) -MaxAgeHours 36 -SkipRescan
Assert-True ($command.Contains("skill''s folder") -and $command.Contains("用户''s")) '重跑命令路径正确转义'
Assert-True ($command.Contains('-Items @(2,3)') -and $command.Contains('-AcknowledgeIrreversible @(3)')) '重跑命令仅包含跳过项的确认编号'
Assert-True ($command.EndsWith('-MaxReportAgeHours 36 -SkipRescan')) '重跑保留年龄限制及复扫选择'
Assert-True (-not $command.Contains('-ResultPath')) '重跑使用新结果文件，避免复用已存在路径'

# 以下仅使用内存中的假处理器，验证流捕获、故障隔离与 WhatIf 转发。
$script:handlerCalls = 0; $script:measurements = 0
function Get-PlanFreeBytes { $script:measurements++; return [long](1000 + 100 * $script:measurements) }
function Invoke-TestHandler {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Category)
    $script:handlerCalls++
    Assert-True ($ConfirmPreference -eq 'None') '处理器不重复询问已确认内容'
    if ($Category -eq 'AlwaysThrow') { throw '模拟演练前置校验失败' }
    if ($WhatIfPreference) {
        [pscustomobject]@{ Category = $Category; Result = 'skipped'; SkippedReasons = @('演练'); WhatIf = $true }
        return
    }
    if ($Category -eq 'Throw') { throw '模拟此项失败' }
    if ($Category -eq 'ThrowAfterOutput') {
        [pscustomobject]@{ Result = 'partial'; SkippedReasons = @('异常前已返回的记录') }
        throw '模拟输出后失败'
    }
    Write-Warning '模拟占用跳过'
    [pscustomobject]@{ Category = $Category; Result = 'partial'; SkippedReasons = @('模拟占用'); FreedBytes = 999999 }
}
$item = [pscustomobject]@{ Id = 1; Title = '模拟项目'; HandlerScript = 'scripts/clean-cache.ps1'; HandlerPath = 'Invoke-TestHandler'; Parameters = @{ Category = 'UserTemp' } }
$row = Invoke-PlanItem $item $false
Assert-Equal $row.Result 'partial' '保留缓存处理器的部分完成状态'
Assert-Equal $row.FreedBytes 100 '使用卷空闲变化，不冒称处理器报告字节为实际释放'
Assert-True (($row.Messages -join ' ') -match '模拟占用') '捕获跳过原因和警告'
$item.Parameters.Category = 'Throw'
$row = Invoke-PlanItem $item $false
Assert-Equal $row.Result 'failed' '处理器异常记录为失败'
Assert-True (($row.Messages -join ' ') -match '模拟此项失败') '异常内容保留'
$item.Parameters.Category = 'UserTemp'
$row = Invoke-PlanItem $item $false
Assert-Equal $row.Result 'partial' '前一项失败后仍可执行下一项'
$row = Invoke-PlanItem $item $true
Assert-Equal $row.Result 'skipped' '演练仍调用处理器并标为未执行修改'
Assert-Equal $row.FreedBytes 0 '演练不报告释放收益'
Assert-Equal $script:handlerCalls 4 '包括失败和演练在内每项只执行一次'
Assert-Equal $script:measurements 8 '每项前后各测量一次'
$item.Parameters.Category = 'AlwaysThrow'
$row = Invoke-PlanItem $item $true
Assert-Equal $row.Result 'failed' '演练也保留处理器前置校验失败'
$item.Parameters.Category = 'ThrowAfterOutput'
$row = Invoke-PlanItem $item $false
Assert-Equal $row.Result 'failed' '输出后抛错仍标记失败'
Assert-True (($row.Messages -join ' ') -match '异常前已返回的记录' -and ($row.Messages -join ' ') -match '模拟输出后失败') '抛错前的输出和异常一起保留'
$batch = @(foreach ($id in 1..4) {
    $category = 'UserTemp'; if ($id -eq 3) { $category = 'Throw' }
    [pscustomobject]@{ Id = $id; Title = '批次项目' + $id; HandlerScript = 'scripts/clean-cache.ps1'
        HandlerPath = 'Invoke-TestHandler'; Parameters = @{ Category = $category }; RequiresAdmin = ($id -eq 2) }
})
$callsBefore = $script:handlerCalls
$rows = @(Invoke-PlanItems $batch $false $false '管理员重跑命令')
Assert-Equal ($rows.Result -join ',') 'partial,skipped,failed,partial' '普通权限批次跳过管理员项目且失败不影响后项'
Assert-Equal ($script:handlerCalls - $callsBefore) 3 '管理员项目完全不调用处理器，其他项目各一次'
Assert-True ($rows[1].Messages -contains '管理员重跑命令') '管理员跳过项保留精确重跑命令'
$callsBefore = $script:handlerCalls
$rows = @(Invoke-PlanItems $batch $true $true '')
Assert-Equal ($script:handlerCalls - $callsBefore) 4 '有管理员权限的演练调用所有处理器'
Assert-Equal ($rows.Result -join ',') 'skipped,skipped,skipped,skipped' '完整批次演练均不执行修改'
$outcome = Get-PlanOutcome 'scripts/clean-system.ps1' @([pscustomobject]@{ Exists = $false; Path = 'C:\不存在' }) $false $false 'UpdateCache'
Assert-Equal $outcome.Result 'skipped' '目标不存在的系统项不能声称清理完成'
$outcome = Get-PlanOutcome 'scripts/clean-system.ps1' @([pscustomobject]@{ DeletedCount = 2; SkippedItems = @(@{ Reason = '占用' }) }) $false $false 'CrashDumps'
Assert-Equal $outcome.Result 'partial' '系统项部分删除和跳过合并为部分完成'
$outcome = Get-PlanOutcome 'scripts/clean-system.ps1' @([Management.Automation.WarningRecord]::new('存在维护进程：TiWorker')) $false $false 'UpdateCache'
Assert-Equal $outcome.Result 'skipped' '维护活动导致系统处理器跳过时正确报告'
Write-Host ('T3 执行计划测试通过：{0} 项断言；仅通过 AST 加载函数和内存模拟，未执行脚本体、清理或外部工具。' -f $script:assertions)

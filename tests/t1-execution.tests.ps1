$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/common.ps1')
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/clean-cache.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw '清理器解析失败。' }
$functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($definition in $functions) { . ([scriptblock]::Create($definition.Extent.Text)) }
$initialization = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Variable.VariablePath.UserPath -eq 'name' })[0]
$dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Variable.VariablePath.UserPath -eq 'name' })[1]
$summary = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Variable.VariablePath.UserPath -eq 'row' })[0]
$developer = @($functions | Where-Object { $_.Name -eq 'Clear-CacheDeveloperTools' })[0]
$toolAssignment = @($developer.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$tools' })[0]
$toolLoop = @($developer.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Variable.VariablePath.UserPath -eq 'tool' })[0]
$script:checks = 0
$script:warningCalls = 0
function Write-Warning { [CmdletBinding()] param([string]$Message) $script:warningCalls++ }
function Write-Information { [CmdletBinding()] param($MessageData) }
function Assert-T1 {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('断言失败：' + $Message) }
    $script:checks++
}
function Assert-T1Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-T1 $threw $Message
}
function Reset-T1Summary {
    param([string[]]$Names)
    $script:CacheCleanerSummary = [ordered]@{}
    $script:CacheCleanerBlockedApps = @{}
    $Category = $Names
    . ([scriptblock]::Create($initialization.Extent.Text))
}
$script:CacheCleanerContext = [pscustomobject]@{ Variables = @{ LOCALAPPDATA = 'C:\Users\测试\AppData\Local'; APPDATA = 'C:\Users\测试\AppData\Roaming' } }
$script:CacheCleanerLogPath = '模拟日志'
$script:CacheCleanerCmdlet = [pscustomobject]@{}
$script:CacheCleanerCmdlet | Add-Member ScriptMethod ShouldProcess { param($target, $action) return (-not $WhatIfPreference) }
$MinAgeHours = 24
$cacheSystemRoot = 'C:\Windows'
$script:auditCalls = 0
function Write-CleanerLog { $script:auditCalls++; throw '测试禁止真实日志写入。' }
# 后续实际执行分支的审计只记录在内存；WhatIf 测试会另行使用真实审计入口。
$realWriteCacheAudit = (Get-Command Write-CacheAudit).ScriptBlock
function Write-CacheAudit { }

& {
    Reset-T1Summary @('AppCache', 'BrowserCache')
    $script:processQueries = 0
    function Get-Process { $script:processQueries++; [pscustomobject]@{ ProcessName = 'Code' } }
    Assert-T1 (-not (Test-CacheAppStopped AppCache @('Code') '路径一' 'VS Code' -WarningAction SilentlyContinue)) '运行中的应用未跳过'
    Assert-T1 (Test-CacheAppStopped AppCache @('slack') '路径二' 'Slack') '一个应用阻止了另一个应用'
    Assert-T1 (-not (Test-CacheAppStopped AppCache @('Code') '路径三' 'VS Code' -WarningAction SilentlyContinue)) '同一应用的后续目标未保留'
    Assert-T1 ($script:processQueries -eq 2) '已阻止的应用不应再次获得清理机会'
    function Get-Process { throw '模拟进程查询失败' }
    Assert-T1 (-not (Test-CacheAppStopped BrowserCache @('firefox') '路径四' 'Firefox' -WarningAction SilentlyContinue)) '进程查询失败未跳过浏览器'
    Assert-T1 ($script:CacheCleanerSummary.BrowserCache.SkippedItems[0].Reason -match '无法可靠查询') '进程查询失败原因不明确'
}
& {
    Reset-T1Summary @('BrowserCache')
    $collected = [Collections.Generic.List[object]]::new()
    function Get-Process { }
    function Resolve-CacheTargetPaths { param($Name, $Pattern) $Pattern.Replace('*', 'Default') }
    function Remove-CacheTarget { param($Name, $LiteralPath, $ProcessNames, $App) $collected.Add(@{ Path = $LiteralPath; Processes = $ProcessNames; App = $App }) }
    Clear-CacheBrowsers
    $entries = (Get-CleanerTargets).Categories.BrowserCache.Targets
    Assert-T1 ($collected.Count -eq $entries.Count) '浏览器执行器没有覆盖全部白名单路径'
    foreach ($entry in $entries) {
        Assert-T1 (@($collected | Where-Object { $_.Path -eq $entry.Path.Replace('*', 'Default') -and $_.Processes[0] -eq $entry.ProcessNames[0] }).Count -eq 1) ('浏览器路径或进程不一致：' + $entry.Path)
    }
    $collected.Clear()
    function Get-Process { [pscustomobject]@{ ProcessName = 'brave' } }
    Clear-CacheBrowsers -WarningAction SilentlyContinue
    Assert-T1 ($collected.Count -eq ($entries.Count - 2)) 'Brave 运行时没有只跳过 Brave'
}
& {
    Reset-T1Summary @('AppCache')
    function Test-CleanerPathChain { [pscustomobject]@{ IsSafe = $true; Exists = $true } }
    function Join-Path { param($Path, $ChildPath) $Path + '\' + $ChildPath }
    function Get-CleanerChildren {
        [pscustomobject]@{ FullName = 'C:\缓存\普通版本'; PSIsContainer = $true; Attributes = [IO.FileAttributes]::Directory }
        [pscustomobject]@{ FullName = 'C:\缓存\联接'; PSIsContainer = $true; Attributes = [IO.FileAttributes]::ReparsePoint }
        [pscustomobject]@{ FullName = 'C:\缓存\文件'; PSIsContainer = $false; Attributes = [IO.FileAttributes]::Normal }
    }
    $paths = @(Resolve-CacheTargetPaths AppCache '%LOCALAPPDATA%\JetBrains\*\caches' -WarningAction SilentlyContinue)
    Assert-T1 ($paths.Count -eq 1 -and $paths[0] -eq 'C:\缓存\普通版本\caches') '单段通配符跟随了重解析点或匹配到文件'
    Assert-T1Throws { Resolve-CacheTargetPaths AppCache '%LOCALAPPDATA%\*\*\caches' } '多个通配段未拒绝'
}
& {
    Reset-T1Summary @('SystemLogs', 'AppCache')
    $script:removedAges = [Collections.Generic.List[double]]::new()
    function Test-Path { $true }
    function Test-SafeTarget { [pscustomobject]@{ IsSafe = $true } }
    function Remove-SafeItem {
        param($LiteralPath, $Category, [double]$MinAgeHours, $Context, $Confirm)
        $script:removedAges.Add($MinAgeHours)
        [pscustomobject]@{ Bytes = 1024; DeletedCount = 1; IsComplete = $true; SkippedItems = @() }
    }
    $MinAgeHours = 0
    Remove-CacheTarget SystemLogs 'C:\Windows\Logs\CBS'
    $MinAgeHours = 400
    Remove-CacheTarget SystemLogs 'C:\Windows\Logs\WindowsUpdate'
    Assert-T1 ($script:removedAges.Count -eq 2 -and $script:removedAges[0] -eq 168 -and $script:removedAges[1] -eq 400) '日志执行器未强制最短年龄'
    function Get-Process { [pscustomobject]@{ ProcessName = 'Code' } }
    Remove-CacheTarget AppCache 'C:\缓存' @('Code') 'VS Code' -WarningAction SilentlyContinue
    Assert-T1 ($script:removedAges.Count -eq 2) '确认后仍运行的应用被清理'
    $WhatIfPreference = $true
    Remove-CacheTarget SystemLogs 'C:\Windows\Logs\CBS' -WarningAction SilentlyContinue
    Assert-T1 ($script:removedAges.Count -eq 2) 'WhatIf 调用了删除入口'
}
& {
    $script:leafCalls = 0; $script:adminChecks = 0
    $script:fileAge = 100
    function Assert-Admin { $script:adminChecks++ }
    function Test-SafeTarget { param($LiteralPath) [pscustomobject]@{ IsSafe = $true; ExternalOnly = $false; Path = $LiteralPath } }
    function Get-CleanerEntryMetadata { [pscustomobject]@{ IsDirectory = $false; LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-$script:fileAge); Attributes = 0; LinkCount = 1; AllocatedBytes = 1024 } }
    function Write-CleanerAudit { }
    function Remove-CleanerLeaf { $script:leafCalls++; [pscustomobject]@{ Success = $true; Bytes = 1024; LogicalBytes = 1024 } }
    $result = Remove-SafeItem 'C:\Windows\Logs\CBS\CbsPersist_1.log' SystemLogs -MinAgeHours 0 -Context $script:CacheCleanerContext -Confirm:$false
    Assert-T1 ($script:leafCalls -eq 0 -and $result.SkippedCount -eq 1) '直接调用共享删除器绕过了 168 小时限制'
    $script:fileAge = 200
    $result = Remove-SafeItem 'C:\Windows\Logs\CBS\CbsPersist_1.log' SystemLogs -MinAgeHours 0 -Context $script:CacheCleanerContext -Confirm:$false
    Assert-T1 ($script:leafCalls -eq 1 -and $result.DeletedCount -eq 1 -and $script:adminChecks -eq 2) '旧归档日志或管理员复查处理错误'
    function Assert-Admin { throw '模拟非管理员' }
    Assert-T1Throws { Remove-SafeItem 'C:\Windows\Logs\CBS\CbsPersist_1.log' SystemLogs -MinAgeHours 0 -Context $script:CacheCleanerContext } '直接共享删除未检查管理员'
}
& {
    Reset-T1Summary @('SystemLogs', 'ShaderCache')
    $script:executedCategories = [Collections.Generic.List[string]]::new()
    function Assert-Admin { throw '模拟非管理员' }
    function Clear-CacheWhitelistCategory { param($Name) $script:executedCategories.Add($Name) }
    . ([scriptblock]::Create($dispatch.Extent.Text)) -WarningAction SilentlyContinue
    Assert-T1 ($script:executedCategories.Count -eq 1 -and $script:executedCategories[0] -eq 'ShaderCache') '非管理员未只跳过 SystemLogs'
    Assert-T1 ($script:CacheCleanerSummary.SystemLogs.SkippedItems[0].Reason -match '管理员') '非管理员跳过原因不明确'
}
& {
    Reset-T1Summary @('DevCache')
    $WhatIfPreference = $true
    $script:externalCalls = 0; $script:discoveryCalls = 0
    function Invoke-External { $script:externalCalls++; throw '不应调用外部工具' }
    function Get-Command { $script:discoveryCalls++; throw '不应发现工具' }
    function Write-CacheAudit { & $realWriteCacheAudit @args }
    Clear-CacheDeveloperTools -WarningAction SilentlyContinue -InformationAction SilentlyContinue
    Assert-T1Throws { Invoke-CachePathQuery 'go.exe' @('env', 'GOCACHE') } '路径查询允许 WhatIf 启动外部工具'
    Assert-T1 ($script:externalCalls -eq 0 -and $script:discoveryCalls -eq 0 -and $script:auditCalls -eq 0) 'WhatIf 有外部调用或日志写入'
    Assert-T1 ($script:CacheCleanerSummary.DevCache.SkippedCount -eq 7) 'WhatIf 未列出全部开发工具计划'
}

# 仅提取官方工具执行循环；身份校验不在 Linux 上伪造，工具、句柄及路径结果全部模拟。
foreach ($scenario in @('成功', '查询失败', '查询输出歧义', '不安全路径', '配置变化', '祖先保护失败', '命令失败', '第二命令失败', '后置校验失败', '未安装')) {
    & {
        Reset-T1Summary @('DevCache')
        . ([scriptblock]::Create($toolAssignment.Extent.Text))
        $script:installed = @('yarn', 'pnpm', 'go')
        if ($scenario -ne '成功') { $script:installed = @('go') }
        if ($scenario -in @('配置变化', '查询输出歧义')) { $script:installed = @('yarn') }
        if ($scenario -eq '未安装') { $script:installed = @() }
        $script:externalCalls = [Collections.Generic.List[string]]::new()
        $script:cleanCalls = [Collections.Generic.List[string]]::new()
        $script:queries = @{}; $script:guardCalls = 0; $script:disposed = 0; $script:space = 1000
        $script:afterClean = $false
        $script:warningCalls = 0
        function Get-Command {
            param($Name, $CommandType)
            if ($script:installed -contains $Name) { [pscustomobject]@{ Source = ($Name + '.exe') } }
        }
        function Test-SafeTarget {
            param($LiteralPath, $Category, $Context, [switch]$AllowMissing)
            $allowed = $LiteralPath -match '^C:\\Users\\测试\\(AppData\\Local\\(Yarn|pnpm|go-build)|go\\pkg\\mod)(\\|$)'
            if ($scenario -eq '后置校验失败' -and $script:afterClean) { $allowed = $false }
            [pscustomobject]@{ IsSafe = $allowed; Reason = '模拟路径检查' }
        }
        function Open-CleanerParentGuards {
            param($LiteralPath)
            $script:guardCalls++
            if ($scenario -eq '祖先保护失败' -and $script:guardCalls -eq 2) { throw '模拟祖先保护失败' }
            $handle = [pscustomobject]@{}
            $handle | Add-Member ScriptMethod Dispose { $script:disposed++ }
            [pscustomobject]@{ Handles = @($handle) }
        }
        function Get-CacheSystemFreeBytes { $script:space += 10; $script:space }
        function Invoke-External {
            [CmdletBinding(SupportsShouldProcess = $true)]
            param($FilePath, $ArgumentList, $Description, $Context)
            $key = $FilePath + ' ' + ($ArgumentList -join ' ')
            $script:externalCalls.Add($key)
            $isQuery = ($ArgumentList[0] -eq 'env') -or (($ArgumentList -join ' ') -in @('cache dir', 'store path'))
            if ($isQuery) {
                if (-not $script:queries.ContainsKey($key)) { $script:queries[$key] = 0 }
                $script:queries[$key]++
                if ($scenario -eq '查询失败' -and $ArgumentList[-1] -eq 'GOMODCACHE') { throw '模拟查询失败' }
                $path = switch ($ArgumentList -join ' ') {
                    'cache dir' { 'C:\Users\测试\AppData\Local\Yarn\Cache' }
                    'store path' { 'C:\Users\测试\AppData\Local\pnpm\store\v3' }
                    'env GOCACHE' { 'C:\Users\测试\AppData\Local\go-build' }
                    'env GOMODCACHE' { 'C:\Users\测试\go\pkg\mod' }
                }
                if ($scenario -eq '不安全路径' -and $ArgumentList[-1] -eq 'GOMODCACHE') { $path = 'D:\未知\模块' }
                if ($scenario -eq '配置变化' -and $script:queries[$key] -gt 1) { $path = 'C:\Users\测试\AppData\Local\Yarn\Berry\cache' }
                if ($scenario -eq '查询输出歧义') { $path += "`nC:\其他缓存" }
                [pscustomobject]@{ ExitCode = 0; StandardOutput = $path; Skipped = $false }
                return
            }
            $script:cleanCalls.Add($key)
            $script:afterClean = $true
            if ($scenario -eq '命令失败') { throw '模拟清理命令失败' }
            if ($scenario -eq '第二命令失败' -and $ArgumentList[-1] -eq '-modcache') { throw '模拟第二条命令失败' }
            [pscustomobject]@{ ExitCode = 0; Skipped = $false }
        }
        . ([scriptblock]::Create($toolLoop.Extent.Text)) -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        if ($scenario -eq '成功') {
            Assert-T1 (($script:cleanCalls -join '|') -eq 'yarn.exe cache clean|pnpm.exe store prune|go.exe clean -cache|go.exe clean -modcache') '官方清理命令或执行顺序错误'
            Assert-T1 ($script:guardCalls -eq 4 -and $script:disposed -eq 4) '成功路径没有释放全部祖先保护'
            Assert-T1 ($script:CacheCleanerSummary.DevCache.EstimatedFreedBytes -eq 40) '官方工具没有按系统卷空间变化估算'
            Assert-T1 ($script:queries['go.exe env GOCACHE'] -eq 2 -and $script:queries['go.exe env GOMODCACHE'] -eq 2) 'Go 两类路径未在确认后重查'
        }
        elseif ($scenario -in @('命令失败', '后置校验失败')) {
            Assert-T1 ($script:cleanCalls.Count -eq 1) ($scenario + ' 后仍执行了第二条 Go 命令')
            Assert-T1 ($script:disposed -eq 2) ($scenario + ' 后未释放句柄')
        }
        elseif ($scenario -eq '第二命令失败') {
            Assert-T1 ($script:cleanCalls.Count -eq 2 -and $script:disposed -eq 2) '第二条 Go 命令失败后未释放句柄'
            Assert-T1 ($script:CacheCleanerSummary.DevCache.ProcessedCount -eq 1 -and $script:CacheCleanerSummary.DevCache.EstimatedFreedBytes -eq 10) '部分成功的 Go 清理丢失了已完成的统计'
        }
        else {
            Assert-T1 ($script:cleanCalls.Count -eq 0) ($scenario + ' 仍执行了清理命令')
            $expectedDisposals = 0
            if ($scenario -in @('配置变化', '祖先保护失败')) { $expectedDisposals = 1 }
            Assert-T1 ($script:disposed -eq $expectedDisposals) ($scenario + ' 的句柄释放数错误')
        }
        if ($scenario -eq '未安装') { Assert-T1 ($script:externalCalls.Count -eq 0 -and $script:warningCalls -eq 0 -and $script:CacheCleanerSummary.DevCache.SkippedItems[0].Reason -eq '工具未安装') '未安装工具没有静默报告为不存在' }
    }
}
& {
    Reset-T1Summary @('AppCache', 'ShaderCache', 'InetCache', 'DevCache')
    $script:CacheCleanerSummary.AppCache.Result = 'done'
    Add-CacheSkip AppCache '模拟文件' '文件占用' -Quiet
    Add-CacheSkip InetCache '模拟目录' '应用运行' -Quiet
    $script:CacheCleanerSummary.ShaderCache.FreedBytes = 2048
    $script:CacheCleanerSummary.DevCache.Result = 'done'
    $script:CacheCleanerSummary.DevCache.EstimatedFreedBytes = 4096
    $rows = @(. ([scriptblock]::Create($summary.Extent.Text)))
    Assert-T1 ($rows.Count -eq 4) '未按类别输出单一汇总对象'
    Assert-T1 ($rows[0].Result -eq 'partial' -and $rows[1].Result -eq 'done' -and $rows[2].Result -eq 'skipped') '汇总状态没有区分完成、部分完成和跳过'
    Assert-T1 ($rows[1].FreedBytesEstimate -eq 2048 -and $rows[3].FreedBytesEstimate -eq 4096) '汇总释放量字段错误'
    Assert-T1 ($rows[0].SkippedReasons -contains '文件占用' -and $rows[2].SkippedReasons -contains '应用运行') '汇总跳过原因丢失'
    Assert-T1 ($null -ne $rows[0].PSObject.Properties['SkippedItems'] -and $null -ne $rows[0].PSObject.Properties['FreedBytes']) '旧汇总字段被删除'
}
Write-Host ('T1 执行安全测试通过：{0} 项断言；全程仅使用内存模拟，未启动工具、删除或写审计。' -f $script:checks)

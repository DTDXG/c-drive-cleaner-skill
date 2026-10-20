$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/common.ps1')
$targets = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'scripts/targets.psd1')
$script:checks = 0
function Assert-T1 {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('断言失败：' + $Message) }
    $script:checks++
}
$context = [pscustomobject]@{
    OriginalUserVerified = $true
    Variables = @{
        USERPROFILE = 'C:\Users\测试用户'
        LOCALAPPDATA = 'C:\Users\测试用户\AppData\Local'
        APPDATA = 'C:\Users\测试用户\AppData\Roaming'
        SystemRoot = 'C:\Windows'; SystemDrive = 'C:'
        ProgramData = 'C:\ProgramData'; ProgramFiles = 'C:\Program Files'
        'ProgramFiles(x86)' = 'C:\Program Files (x86)'; ProgramW6432 = 'C:\Program Files'
    }
    SyncRoots = @(); ProtectedMachineRoots = @('C:\Program Files', 'C:\Program Files (x86)')
}
$newCategories = @('AppCache', 'ShaderCache', 'InetCache', 'SystemLogs')
$addedDevPaths = @(
    '%LOCALAPPDATA%\Yarn\Cache', '%LOCALAPPDATA%\Yarn\Berry\cache'
    '%LOCALAPPDATA%\pnpm\store', '%LOCALAPPDATA%\pnpm-store'
    '%LOCALAPPDATA%\go-build', '%USERPROFILE%\go\pkg\mod'
)
$newTargets = @()
foreach ($name in $newCategories) {
    Assert-T1 ($targets.Categories.ContainsKey($name)) ('缺少类别 ' + $name)
    $definition = $targets.Categories[$name]
    Assert-T1 ($definition.ExternalOnly -eq $false) ($name + ' 应允许共享删除器处理')
    Assert-T1 ($definition.RequiresOriginalUser -eq ($name -ne 'SystemLogs')) ($name + ' 的原用户要求错误')
    $newTargets += @($definition.Targets)
    foreach ($entry in $definition.Targets) {
        $expectedScope = 'Contents'
        if ($name -eq 'SystemLogs') { $expectedScope = 'SelectedFiles' }
        Assert-T1 ($entry.Scope -eq $expectedScope) ($name + ' 的作用范围错误')
    }
}
foreach ($path in $addedDevPaths) {
    $matches = @($targets.Categories.DevCache.Targets | Where-Object { $_.Path -eq $path })
    Assert-T1 ($matches.Count -eq 1) ('缺少开发缓存白名单 ' + $path)
    $newTargets += $matches
}
Assert-T1 ($targets.Categories.DevCache.ExternalOnly -eq $true) '开发缓存必须继续只允许官方工具处理'
foreach ($entry in $newTargets) {
    Assert-T1 ($entry.Path -match '^%(APPDATA|LOCALAPPDATA|USERPROFILE|SystemRoot)%\\') ('路径没有使用允许的根占位符：' + $entry.Path)
    foreach ($token in [regex]::Matches($entry.Path, '%([^%]+)%')) {
        Assert-T1 ($token.Groups[1].Value -in @('APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'SystemRoot')) ('不允许的占位符：' + $entry.Path)
    }
    $expanded = Expand-CleanerPath -Pattern $entry.Path -Context $context
    foreach ($rule in @($targets.ForbiddenPaths) + @($targets.ProtectedRoots)) {
        $protected = Expand-CleanerPath -Pattern $rule -Context $context
        Assert-T1 (-not (Test-CleanerPattern -Path $protected -Pattern $expanded)) ('新增路径等于或覆盖禁止区/保护根：' + $entry.Path + ' / ' + $rule)
    }
    foreach ($rule in $targets.ForbiddenPaths) {
        $forbidden = Expand-CleanerPath -Pattern $rule -Context $context
        Assert-T1 (-not (Test-CleanerPattern -Path $expanded -Pattern $forbidden)) ('新增路径落入禁止区：' + $entry.Path)
    }
    foreach ($process in $entry['ProcessNames']) {
        Assert-T1 ($process -match '^[A-Za-z0-9_-]+$' -and $process -notmatch '\.exe$') ('无效的进程名称：' + $process)
    }
}
$inet = @($targets.Categories.InetCache.Targets)
Assert-T1 ($inet.Count -eq 1 -and $inet[0].ExcludeChildren -contains 'Content.Outlook') 'INetCache 必须排除 Content.Outlook'
foreach ($entry in $targets.Categories.SystemLogs.Targets) {
    Assert-T1 (-not $entry.Recursive) '系统日志只能筛选直接文件'
    foreach ($pattern in $entry.FilePatterns) {
        Assert-T1 (-not ('CBS.log' -like $pattern)) ('系统日志筛选可能匹配 CBS.log：' + $pattern)
    }
}
foreach ($name in @('yarn', 'yarn.cmd', 'pnpm', 'pnpm.cmd', 'pnpm.exe', 'go', 'go.exe')) {
    Assert-T1 ($targets.UserScopedExecutables -contains $name) ('缺少原用户可执行文件限制：' + $name)
}
foreach ($entry in $targets.Categories.BrowserCache.Targets) {
    Assert-T1 ($entry.ProcessNames.Count -eq 1 -and $entry.ProcessNames[0] -in @('brave', 'chrome', 'msedge', 'firefox', 'opera')) ('浏览器缺少准确的进程门控：' + $entry.Path)
}
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/clean-cache.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-T1 ($parseErrors.Count -eq 0) 'clean-cache.ps1 解析失败'
$categoryParameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Category' })[0]
$validateSet = @($categoryParameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0]
$allowed = @($validateSet.PositionalArguments | ForEach-Object { $_.SafeGetValue() })
$defaults = @($categoryParameter.DefaultValue.SafeGetValue())
foreach ($name in $newCategories) {
    Assert-T1 ($allowed -contains $name) ('ValidateSet 缺少 ' + $name)
    Assert-T1 ($defaults -contains $name) ('默认类别缺少 ' + $name)
}

# 只替换文件系统元数据读取；实际白名单、禁止区及排除规则仍调用共享校验器。
& {
    function Test-CleanerPathChain {
        param([string]$LiteralPath, [switch]$AllowMissing)
        $attributes = [IO.FileAttributes]::Directory
        if ($LiteralPath -match '\.(log|cab|etl|tmp)$') { $attributes = [IO.FileAttributes]::Normal }
        [pscustomobject]@{ IsSafe = $true; Path = $LiteralPath; Exists = $true; Attributes = $attributes; Reason = 'OK' }
    }
    function Get-CleanerEntryMetadata {
        param([string]$LiteralPath)
        [pscustomobject]@{ Attributes = (Test-CleanerPathChain $LiteralPath).Attributes }
    }
    $root = Expand-CleanerPath $inet[0].Path $context
    foreach ($relative in @('Content.Outlook', 'content.outlook\附件.tmp', 'Content.Outlook\深层\附件.tmp')) {
        $safe = Test-SafeTarget -LiteralPath ($root + '\' + $relative) -Category InetCache -Context $context
        Assert-T1 (-not $safe.IsSafe -and $safe.Reason -match '明确保留') ('排除目录或后代获得了清理授权：' + $relative)
    }
    foreach ($relative in @('', '\Content.IE5', '\Content.OutlookOther\缓存.tmp')) {
        Assert-T1 ((Test-SafeTarget -LiteralPath ($root + $relative) -Category InetCache -Context $context).IsSafe) ('普通 INetCache 内容被误拒绝：' + $relative)
    }
    foreach ($path in @('C:\Windows\Logs\CBS\CBS.log', 'C:\Windows\Logs\CBS\其他.log', 'C:\Windows\Logs\CBS\嵌套\CbsPersist_1.log')) {
        Assert-T1 (-not (Test-SafeTarget -LiteralPath $path -Category SystemLogs -Context $context).IsSafe) ('系统日志超出筛选范围：' + $path)
    }
    foreach ($path in @('C:\Windows\Logs\CBS\CbsPersist_1.log', 'C:\Windows\Logs\CBS\CbsPersist_1.cab', 'C:\Windows\Logs\WindowsUpdate\旧.etl')) {
        Assert-T1 ((Test-SafeTarget -LiteralPath $path -Category SystemLogs -Context $context).IsSafe) ('系统日志合法文件被拒绝：' + $path)
    }
    foreach ($entry in $newTargets) {
        $path = (Expand-CleanerPath $entry.Path $context).Replace('*', '示例版本')
        Assert-T1 ((Test-SafeTarget -LiteralPath $path -Category $(if ($addedDevPaths -contains $entry.Path) { 'DevCache' } else {
            @($newCategories | Where-Object { $targets.Categories[$_].Targets.Path -contains $entry.Path })[0]
        }) -Context $context).IsSafe) ('新增根路径未通过共享校验：' + $entry.Path)
    }
}
Write-Host ('T1 白名单测试通过：{0} 项断言；targets.psd1 已成功载入。' -f $script:checks)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scanPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/scan.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scanPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw ($parseErrors.Message -join '; ') }
$pureNames = @('Get-ScanProperty', 'Get-ScanDispositionRules', 'Get-ScanDisposition', 'Get-ScanSizeAggregate',
    'Merge-ScanImpact', 'Get-ScanConfirmationItems', 'Get-ScanManualSize', 'Get-ScanManualItems', 'Get-ScanAdvisory')
foreach ($name in $pureNames) {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($definition.Count -ne 1) { throw "纯函数定义缺失或重复：$name" }
    # 仅执行函数定义，绝不执行拒绝非 Windows 的脚本体。
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw "失败：$Message" }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:assertions++
    if ($null -eq $Expected) {
        if ($null -ne $Actual) { throw "失败：$Message；预期 null，实际 $Actual" }
    }
    elseif ($Actual -ne $Expected) { throw "失败：$Message；预期 $Expected，实际 $Actual" }
}
function New-TestEntry {
    param([string]$Selector = '', [string]$Path = 'C:\cache', $Bytes = 100, [string]$Category = 'temp', [string]$Action = 'delete')
    $cacheNames = @('UserTemp', 'WindowsTemp', 'ThumbnailCache', 'BrowserCache', 'DevCache', 'AppCache', 'ShaderCache', 'InetCache', 'SystemLogs')
    $parameters = @{}; $handler = ''
    if ($Selector) {
        if ($Selector -in $cacheNames) { $parameters.Category = $Selector; $handler = 'scripts/clean-cache.ps1' }
        else { $parameters.Action = $Selector; $handler = 'scripts/clean-system.ps1' }
    }
    if ($Selector -eq 'Hibernate') { $parameters.Mode = 'Reduced' }
    if ($Selector -eq 'ShadowStorage') { $parameters.ForVolume = 'C:'; $parameters.OnVolume = 'D:'; $parameters.MaxSize = '10%' }
    $entry = [pscustomobject]@{ EntryKey = $Path.ToLowerInvariant(); Name = $Selector + $Path; Path = $Path; Category = $Category
        Action = $Action; HandlerScript = $handler; HandlerParameters = $parameters; ExecutionCommand = '测试命令'
        EstimatedReclaimableBytes = $Bytes; AllocatedBytes = $Bytes; LogicalBytes = $Bytes; KnownAllocatedBytes = 12
        Status = 'ok'; ExcludedFromLocalTotals = $false; SafetyBlocked = $false; OriginalUserOnly = $true
        Details = [pscustomobject]@{ AssociationResolved = $true }; MigrationWhatIf = $null }
    Set-TestDisposition $entry
    return $entry
}
function Set-TestDisposition {
    param($Entry)
    $classification = Get-ScanDisposition $Entry
    foreach ($field in @('Disposition', 'Impact', 'ManualReason', 'ManualSteps', 'DefaultSelected', 'Irreversible')) {
        $Entry | Add-Member -NotePropertyName $field -NotePropertyValue $classification.$field -Force
    }
}
$defaults = @('UserTemp', 'WindowsTemp', 'ThumbnailCache', 'BrowserCache', 'DevCache', 'AppCache', 'ShaderCache', 'InetCache', 'SystemLogs',
    'ComponentStore', 'UpdateCache', 'DeliveryOptimization')
foreach ($selector in $defaults) {
    $entry = New-TestEntry $selector
    Assert-Equal $entry.Disposition 'ai' "$selector 分类"
    Assert-True $entry.DefaultSelected "$selector 默认选中"
    Assert-True (-not $entry.Irreversible) "$selector 可再生或无数据损失"
    Assert-Equal $entry.Impact.DataLoss 'regenerable' "$selector 损失类型"
    Assert-True ($entry.Impact.Summary -match '[\u4e00-\u9fff]') "$selector 中文影响"
}
foreach ($selector in @('RecycleBin', 'CrashDumps', 'WindowsOld', 'Hibernate', 'ShadowStorage')) {
    $entry = New-TestEntry $selector
    Assert-Equal $entry.Disposition 'ai' "$selector 单独确认分类"
    Assert-True (-not $entry.DefaultSelected) "$selector 绝不能默认选中"
    Assert-True $entry.Irreversible "$selector 不可逆标志"
    Assert-Equal $entry.Impact.DataLoss 'irreversible' "$selector 数据损失"
    Assert-True (-not $entry.Impact.Reversible) "$selector 影响不可逆"
}
$entry = New-TestEntry ShadowStorage
$entry.Details.AssociationResolved = $false; Set-TestDisposition $entry
Assert-Equal $entry.Disposition 'manual' 'VSS 关联未核实需人工'
$entry = New-TestEntry RecycleBin
$entry.OriginalUserOnly = $false; Set-TestDisposition $entry
Assert-Equal $entry.Disposition 'keep' '其他用户回收站汇总不得授权'
$entry = New-TestEntry Hibernate
$entry.HandlerParameters.Mode = 'Off'; Set-TestDisposition $entry
Assert-Equal $entry.Disposition 'manual' '只能建议 Reduced'
foreach ($category in @('user-files', 'wsl', 'wsl-vhdx', 'docker-vhdx', 'emulator-vdisk', 'docker-data', 'developer-cache',
    'chat-data', 'chat-history', 'chat-attachments', 'games', 'ai-models')) {
    $entry = New-TestEntry '' 'C:\data' 100 $category 'migrate'
    Assert-Equal $entry.Disposition 'manual' "$category 迁移需人工"
    Assert-True ($entry.ManualSteps.Count -ge 3) "$category 具体步骤"
    Assert-True ($entry.ManualSteps[0] -match '^1\. ') "$category 步骤编号"
}
foreach ($category in @('pagefile', 'reserved-storage', 'large-file', 'old-installers', 'installed-software', 'unknown-manual')) {
    $entry = New-TestEntry '' 'C:\data' 100 $category 'manual'
    Assert-Equal $entry.Disposition 'manual' "$category 人工分类"
    Assert-True ($entry.ManualReason.Length -gt 0 -and $entry.ManualSteps.Count -ge 3) "$category 原因和步骤"
}
foreach ($category in @('cloud-onedrive', 'cloud-sync')) {
    $entry = New-TestEntry '' 'C:\data' 100 $category 'system-tool'
    $entry.ExcludedFromLocalTotals = $true; Set-TestDisposition $entry
    Assert-Equal $entry.Disposition 'manual' "$category 客户端人工操作"
    Assert-True (($entry.ManualSteps -join ' ') -match '释放空间|仅在线') "$category 释放本地副本"
}
foreach ($category in @('root-summary', 'profile-summary', 'appdata-summary', 'recycle-bin-summary', 'protected', 'installed-or-shared-data')) {
    $entry = New-TestEntry '' 'C:\data' 100 $category 'keep'
    Assert-Equal $entry.Disposition 'keep' "$category 保留"
}
$entry = New-TestEntry BrowserCache
$entry.SafetyBlocked = $true; Set-TestDisposition $entry
Assert-Equal $entry.Disposition 'keep' '安全失败保留'
foreach ($status in @('not-found', 'reparse-point')) {
    $entry = New-TestEntry BrowserCache
    $entry.Status = $status; Set-TestDisposition $entry
    Assert-Equal $entry.Disposition 'keep' "$status 保留"
}
$entry = New-TestEntry BrowserCache
$entry.ExcludedFromLocalTotals = $true; Set-TestDisposition $entry
Assert-Equal $entry.Disposition 'keep' '排除项保留'
$entry = New-TestEntry '' 'C:\data' 100 'user-files' 'migrate'
$entry.MigrationWhatIf = "& '.\scripts\migrate.ps1' -Item UserFolder -Folder Downloads -Destination 'D:\UserData\Downloads' -VerifyHash -WhatIf"
Set-TestDisposition $entry
Assert-True ($entry.ManualSteps[0].Contains($entry.MigrationWhatIf)) '保留准确迁移演练命令'
$manual = @(Get-ScanManualItems @($entry))
Assert-Equal $manual[0].Id 'M1' '人工编号'
Assert-Equal $manual[0].EstimatedBytes 100 '人工大小'

$parent = New-TestEntry BrowserCache 'C:\cache' 1000
$child = New-TestEntry BrowserCache 'C:\CACHE\child' 600
$sibling = New-TestEntry BrowserCache 'C:\cache-other' 200
$lower = New-TestEntry UserTemp 'C:\temp' 500
$irreversible = New-TestEntry CrashDumps 'C:\dumps' 999999
$unknown = New-TestEntry AppCache 'C:\apps' $null
# 参数顺序不同仍为同一个选择器。
$parent.HandlerParameters = @{ Category = 'BrowserCache'; MinAgeHours = 24 }
$child.HandlerParameters = @{ MinAgeHours = 24; Category = 'BrowserCache' }
$sibling.HandlerParameters = @{ Category = 'BrowserCache'; MinAgeHours = 24 }
$groups = @(Get-ScanConfirmationItems @($parent, $child, $sibling, $lower, $irreversible, $unknown))
Assert-Equal $groups.Count 4 '同一执行器及参数归并'
Assert-Equal $groups[0].EstimatedReclaimableBytes 1200 '父子不重复统计，前缀相似的兄弟仍计入'
Assert-Equal $groups[0].EntryKeys.Count 3 '回指全部原始条目'
Assert-Equal $groups[0].Paths.Count 3 '保留全部路径'
Assert-Equal $groups[2].EstimatedReclaimableBytes $null '未知排在可逆组末尾'
Assert-Equal $groups[3].Irreversible $true '高收益不可逆组仍在最后'
Assert-True (-not $groups[3].DefaultSelected) '不可逆组永不默认选中'
for ($i = 0; $i -lt $groups.Count; $i++) { Assert-Equal $groups[$i].Id ($i + 1) '确认项连续整数编号' }
$unknownChild = New-TestEntry BrowserCache 'C:\cache\unknown' $null
$unknownChild.HandlerParameters = $parent.HandlerParameters
$group = @(Get-ScanConfirmationItems @($parent, $unknownChild))[0]
Assert-Equal $group.EstimatedReclaimableBytes $null '即使父已知，组内任一未知也使总量未知'
Assert-Equal $group.KnownLowerBoundBytes 1000 '已知下限不重复相加'
$known = New-TestEntry AppCache 'C:\known' 200
$group = @(Get-ScanConfirmationItems @($known, $unknown))[0]
Assert-Equal $group.EstimatedReclaimableBytes $null '部分未知不生成可释放总量'
Assert-Equal $group.KnownLowerBoundBytes 212 '单独保留已知大小下限'
$aggregate = Get-ScanSizeAggregate @($child, $parent, $parent, $sibling)
Assert-Equal $aggregate.TotalBytes 1200 '聚合顺序及重复路径不影响去重'
$parent.Impact.RequiresClosedApps = @('chrome'); $child.Impact.RequiresClosedApps = @('firefox')
$child.Impact.RequiresAdmin = $true; $child.Impact.RequiresRestart = $true
$group = @(Get-ScanConfirmationItems @($parent, $child))[0]
Assert-Equal $group.Impact.RequiresClosedApps.Count 2 '合并关闭程序'
Assert-True ($group.RequiresAdmin -and $group.Impact.RequiresRestart) '合并管理员和重启要求'

$healthy = @{ TotalBytes = 200GB; FreeBytes = 80GB }
$single = @{ Disks = @(@{ Number = 0 }); Volumes = @(@{ DriveLetter = 'C'; DiskNumber = 0; DriveType = 'Fixed' })
    SystemDiskNumber = 0; HasDataVolume = $false; DataVolumesOnSystemDisk = $false; SystemDiskPartitionCount = 3 }
$sameDisk = @{ Disks = @(@{ Number = 0 }); Volumes = @(@{ DriveLetter = 'C'; DiskNumber = 0; DriveType = 'Fixed' }, @{ DriveLetter = 'D'; DiskNumber = 0; DriveType = 'Fixed' })
    SystemDiskNumber = 0; HasDataVolume = $true; DataVolumesOnSystemDisk = $true; SystemDiskPartitionCount = 4 }
$independent = @{ HasDataVolume = $true; DataVolumesOnSystemDisk = $false; SystemDiskNumber = 0 }
$advice = @(Get-ScanAdvisory $healthy $single $true @{})
Assert-Equal $advice.Count 1 '单卷且空间充足只建议数据卷'
Assert-Equal $advice[0].Id 'no-data-volume' '单卷规则'
Assert-True (($advice[0].Steps -join ' ') -match '先完成独立备份') '分区前明确备份'
$advice = @(Get-ScanAdvisory $healthy $sameDisk $true @{})
Assert-Equal $advice.Count 1 '同盘数据卷只建议独立备份'
Assert-Equal $advice[0].Id 'same-disk-backup' '同盘数据卷规则'
Assert-Equal @(Get-ScanAdvisory $healthy $independent $true @{}).Count 0 '独立数据卷不触发磁盘警告'
$advice = @(Get-ScanAdvisory @{ TotalBytes = 100GB; FreeBytes = 15GB } $independent $true @{})
Assert-Equal $advice[0].Id 'low-space' '绝对可用空间不足'
Assert-Equal $advice[0].Severity 'critical' '空间告急等级'
$advice = @(Get-ScanAdvisory @{ TotalBytes = 1TB; FreeBytes = 50GB } $independent $true @{})
Assert-Equal $advice[0].Id 'low-space' '相对可用空间不足'
$advice = @(Get-ScanAdvisory $healthy $independent $false @{})
Assert-Equal $advice[0].Id 'storage-sense' '存储感知关闭'
Assert-Equal @(Get-ScanAdvisory @{} @{} $null @{}).Count 0 '无证据不触发建议'
$evidence = @{ UserFolderBytes = 11GB; DevelopmentBytes = 6GB; InstalledSoftwareBytes = 21GB; HibernationBytes = 9GB }
$advice = @(Get-ScanAdvisory $healthy $independent $true $evidence)
Assert-Equal $advice.Count 4 '占用阈值建议全部触发'
foreach ($id in @('user-folders', 'development', 'software-placement', 'hibernate-reduced')) {
    Assert-True ($id -in @($advice.Id)) "$id 阈值规则"
}
Assert-Equal @(Get-ScanAdvisory $healthy $independent $true @{ UserFolderBytes = 10GB; DevelopmentBytes = 5GB; InstalledSoftwareBytes = 20GB; HibernationBytes = 8GB }).Count 0 '阈值边界不超出时不触发'
# 适配层仅通过假上下文/假查询测试，不访问 Windows 或执行脚本体。
foreach ($name in @('Get-ScanRecommendation', 'Get-ScanMigrationWhatIf', 'Get-ScanFileInventory', 'Get-ScanInstalledSoftware', 'Get-ScanDiskLayout', 'Complete-ScanDiskLayout')) {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$script:testSafe = $true; $script:checkedCategory = ''; $script:issues = @()
function Test-SafeTarget {
    param([string]$LiteralPath, [string]$Category, $Context)
    $script:checkedCategory = $Category
    return [pscustomobject]@{ IsSafe = $script:testSafe; Reason = '测试安全结论' }
}
function Test-CleanerPathChain {
    param([string]$LiteralPath)
    return [pscustomobject]@{ IsSafe = $script:testSafe; Reason = '测试路径结论' }
}
function Add-ScanIssue {
    param([string]$Path, [string]$Stage, [string]$Message)
    $script:issues += $Stage
}
$context = @{ OriginalUserSid = 'S-1-5-21-test'; CurrentUserSid = 'S-1-5-21-test'; OriginalUserVerified = $true
    SystemRoot = 'C:\Windows'; SystemDrive = 'C:'; Variables = @{ ProgramData = 'C:\ProgramData' } }
$slugs = @{ AppCache = 'app-cache'; ShaderCache = 'shader-cache'; InetCache = 'inet-cache'; SystemLogs = 'system-logs'
    BrowserCache = 'browser-cache'; DevCache = 'developer-cache' }
foreach ($selector in $slugs.Keys) {
    $entry = New-TestEntry $selector 'C:\safe-cache' 100 $slugs[$selector]
    $entry | Add-Member -NotePropertyName Notes -NotePropertyValue ''
    $recommendation = Get-ScanRecommendation $entry $context
    Assert-Equal $recommendation.HandlerParameters.Category $selector "$selector 准确缓存选择器"
    Assert-Equal $script:checkedCategory $selector "$selector 必须通过共享白名单检查"
    $script:testSafe = $false
    $recommendation = Get-ScanRecommendation $entry $context
    Assert-True ($recommendation.SafetyBlocked -and $recommendation.Action -eq 'keep') "$selector 安全失败不能执行"
    $script:testSafe = $true
}
$entry = New-TestEntry ShadowStorage 'C:\System Volume Information' 100 'shadowstorage' 'system-tool'
$entry.Details = @{ AssociationResolved = $true; ForVolume = 'C:'; OnVolume = 'E:'; ProposedMaxSize = '512MB' }
$entry | Add-Member -NotePropertyName Notes -NotePropertyValue ''
$recommendation = Get-ScanRecommendation $entry $context
Assert-Equal $recommendation.HandlerParameters.OnVolume 'E:' 'VSS 不假设同盘关联'
Assert-Equal $recommendation.HandlerParameters.MaxSize '512MB' 'VSS 使用已核实的保守上限'
$entry.Details.AssociationResolved = $false
Assert-Equal (Get-ScanRecommendation $entry $context).Action 'manual' 'VSS 无关联不生成执行器'
$entry = New-TestEntry RecycleBin 'C:\$Recycle.Bin\S-1-5-21-test' 100 'recycle-bin' 'system-tool'
$entry | Add-Member -NotePropertyName Notes -NotePropertyValue ''
Assert-Equal (Get-ScanRecommendation $entry $context).HandlerParameters.Action 'RecycleBin' '只给原用户回收站选择器'
$script:ScanKnownFolders = @{ Downloads = 'C:\Users\test\Downloads' }
$entry = New-TestEntry '' 'C:\Users\test\Downloads' 100 'user-files' 'migrate'
$command = Get-ScanMigrationWhatIf $entry $context
Assert-Equal $command "& '.\scripts\migrate.ps1' -Item UserFolder -Folder Downloads -Destination 'D:\UserData\Downloads' -VerifyHash -WhatIf" 'Known Folder 准确迁移演练'
$entry = New-TestEntry '' 'C:\Users\test\.m2\repository' 100 'developer-cache' 'migrate'
$command = Get-ScanMigrationWhatIf $entry $context
Assert-True ($command -match '-Cache maven' -and $command -match '-WhatIf$' -and $command -notmatch '-Source') '开发缓存演练只改未来配置'
$entry = New-TestEntry '' 'C:\WSL\Ubuntu' 100 'wsl' 'migrate'
$entry.Details = @{ DistributionName = "Dev'Ubuntu" }
$command = Get-ScanMigrationWhatIf $entry $context
Assert-True ($command.Contains("-Distro 'Dev''Ubuntu'") -and $command.EndsWith('-VerifyHash -WhatIf')) '发行版名称正确引用'
$entry.Details = @{}
Assert-Equal (Get-ScanMigrationWhatIf $entry $context) $null '不得猜测发行版名称'
$entry = New-TestEntry BrowserCache
$entry | Add-Member -NotePropertyName ReparsePoints -NotePropertyValue @($entry.Path)
Set-TestDisposition $entry
Assert-Equal $entry.Disposition 'keep' '根重解析点即使状态不同也保留'
$entry = New-TestEntry '' 'C:\partial' 100 'user-files' 'migrate'
$entry.Status = 'partial'; $entry.KnownAllocatedBytes = 123
Assert-Equal (Get-ScanManualSize $entry) $null '人工清单也不把部分下限当完整大小'
$Quick = $true
foreach ($inventory in @((Get-ScanFileInventory @('C:\Users\test')), (Get-ScanInstalledSoftware 'S-1-test'))) {
    Assert-Equal $inventory.Status 'skipped' 'Quick 跳过新清单'
    Assert-Equal $inventory.EstimatedBytes $null 'Quick 清单大小未知'
}
$layout = Get-ScanDiskLayout
foreach ($field in @('Disks', 'Volumes', 'SystemDiskNumber', 'HasDataVolume', 'DataVolumesOnSystemDisk', 'SystemDiskPartitionCount')) {
    Assert-Equal $layout.$field $null "Quick 磁盘布局 $field 未知"
}
$layout = Complete-ScanDiskLayout ([pscustomobject]@{ Volumes = @([pscustomobject]@{ DriveLetter = 'C'; DiskNumber = 0; DriveType = 'Fixed' },
    [pscustomobject]@{ DriveLetter = 'D'; DiskNumber = 0; DriveType = 'Fixed' }); HasDataVolume = $null
    SystemDiskNumber = $null; DataVolumesOnSystemDisk = $null; SystemDiskPartitionCount = $null }) @(@{ DiskNumber = 0 }, @{ DiskNumber = 0 })
Assert-True ($layout.HasDataVolume -and $layout.DataVolumesOnSystemDisk -and $layout.SystemDiskPartitionCount -eq 2) '从卷证据派生同盘布局'

foreach ($name in @('Add-ScanRegisteredCaches', 'Measure-ScanCacheSelection', 'Invoke-ScanQuery', 'Set-ScanShadowStorage')) {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
& {
    $script:ScanTargets = @{}; $script:testDefinitions = @{ Categories = @{} }
    function Get-CleanerTargets { return $script:testDefinitions }
    function Expand-ScanTargetPattern { param([string]$Pattern, $Context); return $Pattern }
    function Add-ScanTarget {
        param($Name, $LiteralPath, $Category, $Action, $HandlerScript, $Estimate, $Priority, $Risk, $Notes)
        $script:ScanTargets[$LiteralPath.TrimEnd('\').ToLowerInvariant()] = [pscustomobject]@{ Path = $LiteralPath; Category = $Category
            Action = $Action; HandlerScript = $HandlerScript; Estimate = $Estimate; Notes = $Notes; MetadataOnly = $false; Details = $null }
    }
    Add-ScanRegisteredCaches $context
    Assert-Equal $script:ScanTargets.Count 0 '缺少新类别时不注册任何目标'
    foreach ($selector in @('AppCache', 'ShaderCache', 'InetCache', 'SystemLogs', 'BrowserCache', 'DevCache')) {
        $script:testDefinitions.Categories[$selector] = @{ Targets = @(@{ Path = 'C:\cache\' + $selector; Scope = 'Contents'; App = 'test'; ProcessNames = @('test-app') }) }
    }
    $script:testDefinitions.Categories.InetCache.Targets[0].ExcludeChildren = @('Content.Outlook')
    $script:testDefinitions.Categories.DevCache.Targets += @{ Path = 'C:\Users\test\.gradle\caches\modules-2\files-2.1'; Scope = 'Contents' }
    Add-ScanRegisteredCaches $context
    Assert-Equal $script:ScanTargets.Count 6 '读取全部已存在类别，Gradle 保持迁移建议'
    foreach ($entry in $script:ScanTargets.Values) {
        Assert-Equal $entry.Action 'delete' '白名单缓存注册删除动作'
        Assert-Equal $entry.HandlerScript 'scripts/clean-cache.ps1' '白名单缓存执行器'
        Assert-Equal $entry.Estimate 'allocated-upper-bound' '白名单缓存上限类型'
        Assert-Equal $entry.RequiredProcesses[0] 'test-app' '可选进程元数据'
    }
    Assert-Equal $script:ScanTargets['c:\cache\inetcache'].CacheDefinition.ExcludeChildren[0] 'Content.Outlook' '保留排除元数据'
}
& {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Expand-ScanTargetPattern' }, $true))
    . ([scriptblock]::Create($definition[0].Extent.Text))
    function Expand-CleanerPath { param([string]$Pattern, $Context); return $Pattern.Replace('%LOCALAPPDATA%', 'C:\User') }
    function Join-Path { param([string]$Path, [string]$ChildPath); return $Path.TrimEnd('\') + '\' + $ChildPath }
    function Get-ScanChildren {
        param([string]$LiteralPath)
        Assert-Equal $LiteralPath 'C:\User\Profiles' '只枚举通配符所在父目录'
        [pscustomobject]@{ Name = 'A'; FullName = 'C:\User\Profiles\A'; PSIsContainer = $true; Attributes = 0 }
        [pscustomobject]@{ Name = 'Link'; FullName = 'C:\User\Profiles\Link'; PSIsContainer = $true; Attributes = [IO.FileAttributes]::ReparsePoint }
        [pscustomobject]@{ Name = 'file'; FullName = 'C:\User\Profiles\file'; PSIsContainer = $false; Attributes = 0 }
    }
    $paths = @(Expand-ScanTargetPattern '%LOCALAPPDATA%\Profiles\*\Cache' $context)
    Assert-Equal $paths.Count 1 '通配符不进入重解析点或文件'
    Assert-Equal $paths[0] 'C:\User\Profiles\A\Cache' '仅展开单个路径段'
}
& {
    function Get-CleanerChildren {
        param([string]$LiteralPath)
        [pscustomobject]@{ Name = 'CbsPersist_1.log'; FullName = 'C:\logs\CbsPersist_1.log'; PSIsContainer = $false }
        [pscustomobject]@{ Name = 'CBS.log'; FullName = 'C:\logs\CBS.log'; PSIsContainer = $false }
        [pscustomobject]@{ Name = 'Content.Outlook'; FullName = 'C:\logs\Content.Outlook'; PSIsContainer = $true }
    }
    function Get-DirectorySize {
        param([string]$LiteralPath)
        Assert-True ($LiteralPath -notmatch 'CBS\.log|Content.Outlook') '不计量未选中日志或保留的附件'
        return [pscustomobject]@{ LogicalBytes = 10; AllocatedBytes = 16; EstimatedReclaimableBytes = 8; KnownLogicalBytes = 10
            KnownAllocatedBytes = 16; Skipped = @(); ReparsePoints = @() }
    }
    $entry = [pscustomobject]@{ Path = 'C:\logs'; CacheCategory = 'SystemLogs'; CacheDefinition = @{ Scope = 'SelectedFiles'; FilePatterns = @('CbsPersist_*.log') }
        Skipped = @(); ReparsePoints = @(); LogicalBytes = $null; AllocatedBytes = $null; KnownLogicalBytes = $null; KnownAllocatedBytes = $null
        EstimatedReclaimableBytes = $null; EstimateKind = 'unknown'; KnownSizeKind = 'unknown'; Status = 'pending'; Notes = '' }
    Measure-ScanCacheSelection $entry
    Assert-Equal $entry.Status 'ok' '筛选计量完成'
    Assert-Equal $entry.AllocatedBytes 16 '只统计匹配的持久化日志'
    Assert-Equal $entry.EstimatedReclaimableBytes 8 '沿用共享库的硬链接排除收益'
    $entry.CacheCategory = 'InetCache'; $entry.CacheDefinition = @{ Scope = 'Contents'; ExcludeChildren = @('Content.Outlook', 'CBS.log') }
    $entry.LogicalBytes = $null; $entry.AllocatedBytes = $null
    Measure-ScanCacheSelection $entry
    Assert-Equal $entry.AllocatedBytes 16 '计量排除 Outlook 附件内容'
}
& {
    $WhatIfPreference = $true
    function Invoke-External { throw 'WhatIf 不应运行外部命令' }
    $entry = New-TestEntry '' 'C:\System Volume Information' $null 'shadowstorage' 'system-tool'
    $entry | Add-Member -NotePropertyName Notes -NotePropertyValue ''
    Set-ScanShadowStorage $entry $true
    Assert-Equal $entry.Status 'skipped' 'WhatIf 跳过 VSS 外部查询及后续解析'
}
Write-Host ("PASS t2-scan-logic: {0} assertions; AST-only loading; no script body executed." -f $script:assertions)

<#
.SYNOPSIS
只读诊断 C 盘占用，生成 JSON 报告和按预计可释放量排序的摘要。
.DESCRIPTION
扫描系统项、所有可见用户以及常见国内软件、游戏、开发工具的数据位置。
目录大小使用 common.ps1 的 Get-DirectorySize，不跟随重解析点；未知值用
JSON null 表示，拒绝访问不会当成零。目录汇总与专项条目可能包含相同文件，
不可相加。OneDrive 单独标注，排除在本地清理估算之外，不读取文件内容。
除创建报告及其父目录、共享外部命令审计日志外，不修改文件、注册表、服务或系统设置。
DISM 和 VSS 仅使用查询命令；-WhatIf 不运行外部命令、不写报告。
DISM 并不总是提供精确可释放字节数；报告区分精确值、估算上限和未知。
.PARAMETER OutputPath
新建 JSON 报告的路径。默认使用共享上下文的日志目录和唯一文件名。
为避免覆盖用户文件，目标文件已存在时停止，不提供覆盖选项。
.PARAMETER Top
控制台显示的条目数，默认 25。JSON 始终包含全部发现的条目。
.PARAMETER Quick
跳过目录递归大小统计、深层软件数据分类和耗时的 DISM 分析；仍读取文件
元数据、常见目录位置、注册表及 VSS 状态。跳过的大小标为未知。
.EXAMPLE
.\scripts\scan.ps1 -Top 30
.EXAMPLE
.\scripts\scan.ps1 -Quick -OutputPath 'D:\清理报告\scan.json'
.EXAMPLE
.\scripts\scan.ps1 -Quick -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$Top = 25,

    [Parameter()]
    [switch]$Quick
)

if ($env:OS -ne 'Windows_NT') { throw '此脚本只能在 Windows 上运行。' }
. (Join-Path $PSScriptRoot 'common.ps1')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ScanTargets = @{}
$script:ScanIssues = New-Object 'System.Collections.Generic.List[object]'
$script:ScanDriveRoot = 'C:\'
$script:ScanCloudRoots = New-Object 'System.Collections.Generic.List[string]'
$script:ScanProfileEnvironment = @{}

function Get-ScanProperty {
    param($Object, [string[]]$Names, $Default = $null)
    if ($null -ne $Object) {
        foreach ($name in $Names) {
            if ($Object -is [System.Collections.IDictionary]) {
                if ($Object -is [hashtable]) { $hasProperty = $Object.ContainsKey($name) }
                else { $hasProperty = $Object.Contains($name) }
                if ($hasProperty -and $null -ne $Object[$name]) { return $Object[$name] }
            }
            else {
                $property = $Object.PSObject.Properties[$name]
                if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
            }
        }
    }
    return $Default
}

function Add-ScanIssue {
    param([string]$Path, [string]$Stage, [string]$Message)
    $script:ScanIssues.Add([pscustomobject]@{ Path = $Path; Stage = $Stage; Message = $Message })
}

function Test-ScanDiscoveryPath {
    param([string]$LiteralPath)
    foreach ($cloudRoot in $script:ScanCloudRoots) {
        if ($LiteralPath -ieq $cloudRoot -or $LiteralPath.StartsWith($cloudRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    # 复用共享检查中的全路径链校验，不实现第二套重解析点/白名单规则。
    # WindowsTemp 无原用户身份前置要求；只读发现允许“链校验已通过、但不
    # 允许清理”的明确结论。其他失败（含未知原因）一律不枚举、不读内容。
    # 共享接口没有独立的只读校验函数，因此这里只识别现有明确拒绝原因。
    $check = Test-SafeTarget -LiteralPath $LiteralPath -Category WindowsTemp
    if ((Get-ScanProperty $check @('IsSafe', 'Safe', 'Allowed') $false) -eq $true) { return $true }
    $reason = [string](Get-ScanProperty $check @('Reason', 'Message') '共享检查未返回原因。')
    if ($reason -match '^路径不在此类别白名单内|^永久禁止区：|^禁止整棵目录操作：|^禁止盘符根目录。$') {
        return $true
    }
    Add-ScanIssue $LiteralPath 'DiscoveryGuard' $reason
    return $false
}

function Get-ScanChildren {
    param([string]$LiteralPath)
    # 只发现下一层；不使用 -Recurse。实际大小和跳过清单由共享库负责。
    try {
        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        $attributes = Get-ScanProperty $item @('Attributes') 0
        if (-not $item.PSIsContainer -or ($attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        if ($LiteralPath -notmatch '^Registry::' -and -not (Test-ScanDiscoveryPath $LiteralPath)) { return }
        $enumerationErrors = @()
        Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue -ErrorVariable enumerationErrors
        foreach ($failure in $enumerationErrors) {
            Add-ScanIssue $LiteralPath 'Discovery' $failure.Exception.Message
        }
    }
    catch [System.Management.Automation.ItemNotFoundException] { return }
    catch { Add-ScanIssue $LiteralPath 'Discovery' $_.Exception.Message }
}

function Add-ScanTarget {
    param(
        [string]$Name, [string]$LiteralPath, [string]$Category,
        [ValidateSet('delete', 'system-tool', 'migrate', 'manual', 'keep')][string]$Action = 'keep',
        [ValidateRange(0, 3)][int]$Risk = 0,
        [string]$HandlerScript = '', [string]$Notes = '',
        [ValidateSet('none', 'allocated-upper-bound', 'logical-upper-bound')][string]$Estimate = 'none',
        [int]$Priority = 10, [switch]$IncludeMissing, [switch]$MetadataOnly
    )
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return }
    if ($LiteralPath -notmatch '^C:[\\/]') { return }
    try {
        $path = [IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
        if ($path -ieq 'C:') { $path = 'C:\' }
    }
    catch { Add-ScanIssue $LiteralPath 'Path' $_.Exception.Message; return }
    # 迁到其他卷的目录无需扫描；报告只诊断 C 盘。
    if ($path -notmatch '^C:\\') { return }
    $exists = $true
    $metadataError = $null
    $metadata = $null
    try { $metadata = Get-Item -LiteralPath $path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { $exists = $false }
    catch { $metadataError = $_.Exception.Message }
    if (-not $exists -and -not $IncludeMissing) { return }
    $key = $path.ToLowerInvariant()
    if ($script:ScanTargets.ContainsKey($key) -and $script:ScanTargets[$key].Priority -gt $Priority) { return }
    $script:ScanTargets[$key] = [pscustomobject]@{
        Name = $Name; Path = $path; Category = $Category; Action = $Action; Risk = $Risk
        HandlerScript = $HandlerScript; HandlerParameters = @{}; ExecutionCommand = $null; Notes = $Notes; Estimate = $Estimate; Priority = $Priority
        Exists = $exists; Metadata = $metadata; MetadataError = $metadataError
        MetadataOnly = [bool]$MetadataOnly; LogicalBytes = $null; AllocatedBytes = $null
        KnownLogicalBytes = $null; KnownAllocatedBytes = $null; KnownSizeKind = 'unknown'
        EstimatedReclaimableBytes = $null; EstimateKind = 'unknown'; Status = 'pending'
        Skipped = @(); ReparsePoints = @(); ExcludedFromLocalTotals = $false
        OverlapsOtherEntries = $false; Details = $null
    }
}

function Add-ScanInventoryChildren {
    param([string]$LiteralPath, [string]$Category, [string]$NamePrefix)
    foreach ($child in @(Get-ScanChildren $LiteralPath)) {
        if ($child.PSIsContainer) {
            Add-ScanTarget -Name ($NamePrefix + $child.Name) -LiteralPath $child.FullName -Category $Category `
                -Notes '目录汇总；未识别的数据仅报告。使用卸载、软件设置或已验证的迁移流程。' -Priority 0
        }
    }
}

function Get-ScanRegistryValue {
    param([string]$LiteralPath, [string]$Name)
    try {
        $properties = Get-ItemProperty -LiteralPath $LiteralPath -ErrorAction Stop
        return Get-ScanProperty $properties @($Name)
    }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
    catch { Add-ScanIssue $LiteralPath 'Registry' $_.Exception.Message; return $null }
}

function Expand-ScanProfilePath {
    param([string]$Text, [string]$Profile)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $value = $Text.Trim().Trim('"')
    $replacements = @{
        '%USERPROFILE%' = $Profile; '%LOCALAPPDATA%' = (Join-Path $Profile 'AppData\Local')
        '%APPDATA%' = (Join-Path $Profile 'AppData\Roaming'); '%HOMEDRIVE%%HOMEPATH%' = $Profile
    }
    if ($script:ScanProfileEnvironment.ContainsKey($Profile)) {
        foreach ($token in $script:ScanProfileEnvironment[$Profile].psbase.Keys) {
            $replacements[$token] = $script:ScanProfileEnvironment[$Profile][$token]
        }
    }
    foreach ($token in $replacements.psbase.Keys) {
        $replacement = $replacements[$token]
        $value = [regex]::Replace($value, [regex]::Escape($token),
            [System.Text.RegularExpressions.MatchEvaluator]({ param($match) $replacement }.GetNewClosure()),
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $value = [Environment]::ExpandEnvironmentVariables($value)
    if ($value -match '%[^%]+%|\$\{[^}]+\}') { return $null }
    return $value
}

function Add-ScanCloudRoot {
    param([string]$LiteralPath)
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or $LiteralPath -notmatch '^C:\\') { return }
    $path = $LiteralPath.TrimEnd('\')
    if (-not $script:ScanCloudRoots.Contains($path)) { $script:ScanCloudRoots.Add($path) }
    Add-ScanTarget -Name 'OneDrive 同步目录（不纳入本地清理量）' -LiteralPath $path -Category 'cloud-onedrive' `
        -Action system-tool -Risk 1 -Priority 100 -HandlerScript '' `
        -Notes '只用 OneDrive 客户端“释放空间”。删除会同步到云端。云占位不计本地占用；已下载文件仍可能占用空间。' `
        -MetadataOnly
}

function Find-ScanVirtualDisks {
    param([string]$LiteralPath, [string]$Name, [string]$Category)
    if ($Quick) { return }
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue([pscustomobject]@{ Path = $LiteralPath; Depth = 0 })
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 400) {
        $current = $queue.Dequeue()
        foreach ($child in @(Get-ScanChildren $current.Path)) {
            $visited++
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if (-not $child.PSIsContainer -and $child.Extension -match '^(?i:\.vhdx?|\.vdi|\.qcow2)$') {
                Add-ScanTarget -Name ($Name + '：' + $child.Name) -LiteralPath $child.FullName -Category $Category `
                    -Action migrate -Risk 3 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound -Priority 40 `
                    -Notes '虚拟磁盘逻辑长度可能远大于稀疏实际占用。不能直接删除；使用软件迁移/导出导入，压缩前退出并备份。'
            }
            elseif ($child.PSIsContainer -and $current.Depth -lt 3) {
                $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $current.Depth + 1 })
            }
        }
    }
    if ($queue.Count -gt 0) { Add-ScanIssue $LiteralPath 'DiscoveryLimit' '达到虚拟磁盘位置发现上限；目录总大小仍由共享库统计。' }
}

function Read-ScanSmallText {
    param([string]$LiteralPath, [long]$MaximumBytes = 65536)
    try {
        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -gt $MaximumBytes -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ([long]$item.Attributes -band 0x441000)) { return $null }
        if (-not (Test-ScanDiscoveryPath $LiteralPath)) { return $null }
        return Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
    catch { Add-ScanIssue $LiteralPath 'Configuration' $_.Exception.Message; return $null }
}

function Add-ScanToolConfiguredPaths {
    param([string]$Profile, [string]$Local, [string]$Roaming)
    $label = Split-Path -Path $Profile -Leaf
    $configurations = @(
        @((Join-Path $Profile '.npmrc'), '(?im)^\s*cache\s*=\s*(.+?)\s*$', 'npm 缓存'),
        @((Join-Path $Roaming 'pip\pip.ini'), '(?im)^\s*cache-dir\s*=\s*(.+?)\s*$', 'pip 缓存'),
        @((Join-Path $Profile 'pip\pip.ini'), '(?im)^\s*cache-dir\s*=\s*(.+?)\s*$', 'pip 旧版缓存')
    )
    foreach ($configuration in $configurations) {
        $text = Read-ScanSmallText $configuration[0]
        if ($text -and $text -match $configuration[1]) {
            $path = Expand-ScanProfilePath $matches[1] $Profile
            if ([IO.Path]::IsPathRooted($path)) {
                Add-ScanTarget -Name ($label + '：配置文件中的 ' + $configuration[2]) -LiteralPath $path `
                    -Category 'developer-cache' -Action system-tool -Risk 1 -HandlerScript 'scripts/clean-cache.ps1' `
                    -Estimate allocated-upper-bound -Notes ('来源：' + $configuration[0] + '；只使用工具官方清理命令。')
            }
        }
    }
    # 只解析 .condarc 中简单的 pkgs_dirs 列表；复杂 YAML 保留未知，不执行配置。
    $condarcPath = Join-Path $Profile '.condarc'
    $condarc = Read-ScanSmallText $condarcPath
    if ($condarc) {
        $inPackages = $false
        foreach ($line in ($condarc -split '\r?\n')) {
            if ($line -match '^pkgs_dirs\s*:\s*(?:#.*)?$') { $inPackages = $true; continue }
            if ($line -match '^\S' -and $line -notmatch '^\s*-') { $inPackages = $false }
            if ($inPackages -and $line -match '^\s*-\s*["'']?([A-Za-z]:[\\/].*?)["'']?\s*$') {
                Add-ScanTarget -Name ($label + '：conda 已配置包缓存') -LiteralPath $matches[1] -Category 'developer-cache' `
                    -Action system-tool -Risk 1 -HandlerScript 'scripts/clean-cache.ps1' -Estimate allocated-upper-bound `
                    -Notes ('来源：' + $condarcPath + '；使用 conda 官方清理，不删除环境。')
            }
        }
    }
    $mavenPath = Join-Path $Profile '.m2\settings.xml'
    $maven = Read-ScanSmallText $mavenPath
    if ($maven) {
        $reader = $null; $stringReader = $null
        try {
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
            $stringReader = [IO.StringReader]::new($maven)
            $reader = [Xml.XmlReader]::Create($stringReader, $settings)
            $document = [Xml.XmlDocument]::new()
            $document.XmlResolver = $null; $document.Load($reader)
            $repository = $document.SelectSingleNode('/*[local-name()="settings"]/*[local-name()="localRepository"]')
            if ($null -ne $repository) {
                $path = $repository.InnerText.Replace('${user.home}', $Profile)
                Add-ScanTarget -Name ($label + '：Maven 已配置本地仓库') -LiteralPath (Expand-ScanProfilePath $path $Profile) `
                    -Category 'developer-cache' -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' `
                    -Estimate allocated-upper-bound -Notes '可能有仅本机存在的构建产物；迁移 localRepository，不整体删除 .m2。'
            }
        }
        catch { Add-ScanIssue $mavenPath 'Configuration' $_.Exception.Message }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $stringReader) { $stringReader.Dispose() }
        }
    }
}

function Add-ScanApplicationParts {
    param([string]$LiteralPath, [string]$AppName)
    if ($Quick) { return }
    # 仅在已识别的软件目录内，按已知名称区分聊天库、附件和缓存。
    # 限制深度与枚举数量；这不是任意用户目录的递归全文搜索。
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue([pscustomobject]@{ Path = $LiteralPath; Depth = 0 })
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 1200) {
        $current = $queue.Dequeue()
        foreach ($child in @(Get-ScanChildren $current.Path)) {
            if (-not $child.PSIsContainer) { continue }
            $visited++
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Add-ScanTarget -Name ($AppName + '：重解析点') -LiteralPath $child.FullName -Category 'reparse-point' -Priority 60
                continue
            }
            if ($child.Name -match '^(?i:cache|caches|code cache|gpucache|dawncache|temp|tmp|webcache|cache_data)$') {
                Add-ScanTarget -Name ($AppName + '：缓存') -LiteralPath $child.FullName -Category 'app-cache' `
                    -Action system-tool -Risk 1 -HandlerScript '' -Priority 30 -Estimate allocated-upper-bound `
                    -Notes '使用软件内置缓存清理，先关闭应用；未列入删除白名单，不能直接递归删除。'
                continue
            }
            if ($child.Name -match '^(?i:filestorage|filerecv|files|file|image|images|video|videos|attachment|attachments|resource|download|downloads)$') {
                Add-ScanTarget -Name ($AppName + '：附件/下载') -LiteralPath $child.FullName -Category 'chat-attachments' `
                    -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' -Priority 30 -Estimate allocated-upper-bound `
                    -Notes '可能包含唯一附件；在应用设置里变更位置并复制校验，保留可靠备份后才处理源数据。'
                continue
            }
            if ($child.Name -match '^(?i:msg|msgattach|msgstore|msgdb|db|database|databases|nt_db|message|messages)$') {
                Add-ScanTarget -Name ($AppName + '：聊天记录/数据库') -LiteralPath $child.FullName -Category 'chat-history' `
                    -Action migrate -Risk 3 -HandlerScript 'scripts/migrate.ps1' -Priority 30 -Estimate allocated-upper-bound `
                    -Notes '不能当缓存删除；使用该版本官方备份/迁移，验证记录与附件完整。'
                continue
            }
            if ($current.Depth -lt 3) {
                $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $current.Depth + 1 })
            }
        }
    }
    if ($queue.Count -gt 0) { Add-ScanIssue $LiteralPath 'DiscoveryLimit' '达到专项分类的枚举上限；目录总大小仍由共享库统计。' }
}

function Add-ScanUserTargets {
    param([string]$Profile, [string]$Sid)
    $label = Split-Path -Path $Profile -Leaf
    $local = Join-Path $Profile 'AppData\Local'
    $roaming = Join-Path $Profile 'AppData\Roaming'
    if ($Profile -ieq $script:ScanOriginalProfile) {
        $local = [string](Get-ScanProperty $context @('LocalAppData') $local)
    }
    Add-ScanTarget -Name ('用户目录：' + $label) -LiteralPath $Profile -Category 'profile-summary' -Priority 0
    # 联接/符号链接用户目录只列出本身，不进入发现阶段。
    try {
        $profileItem = Get-Item -LiteralPath $Profile -Force -ErrorAction Stop
        if ($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    }
    catch { Add-ScanIssue $Profile 'Profile' $_.Exception.Message; return }
    if ($Sid) {
        $userHive = 'Registry::HKEY_USERS\' + $Sid
        $userShellKey = $userHive + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $configuredLocal = Expand-ScanProfilePath (Get-ScanRegistryValue $userShellKey 'Local AppData') $Profile
        $configuredRoaming = Expand-ScanProfilePath (Get-ScanRegistryValue $userShellKey 'AppData') $Profile
        if ($configuredLocal) { $local = $configuredLocal }
        if ($configuredRoaming) { $roaming = $configuredRoaming }
        $script:ScanProfileEnvironment[$Profile] = @{ '%LOCALAPPDATA%' = $local; '%APPDATA%' = $roaming }
        foreach ($variable in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
            $cloudPath = Expand-ScanProfilePath (Get-ScanRegistryValue ($userHive + '\Environment') $variable) $Profile
            if ($cloudPath) { $script:ScanProfileEnvironment[$Profile]['%' + $variable + '%'] = $cloudPath }
        }
    }
    Add-ScanTarget -Name ($label + '：AppData\Local') -LiteralPath $local -Category 'appdata-summary' -Priority 0
    Add-ScanTarget -Name ($label + '：AppData\Roaming') -LiteralPath $roaming -Category 'appdata-summary' -Priority 0
    Add-ScanInventoryChildren $local 'appdata-local' ($label + ' Local：')
    Add-ScanInventoryChildren $roaming 'appdata-roaming' ($label + ' Roaming：')

    $documents = New-Object 'System.Collections.Generic.List[string]'
    $documents.Add((Join-Path $Profile 'Documents'))
    foreach ($folder in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')) {
        Add-ScanTarget -Name ($label + '：' + $folder) -LiteralPath (Join-Path $Profile $folder) -Category 'user-files' `
            -Action migrate -Risk 1 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
            -Notes '通过文件夹属性→位置→移动，或复制校验后切换；预计释放是迁移完成且确认备份后清理源数据的上限。'
    }
    if (-not [string]::IsNullOrWhiteSpace($Sid)) {
        $hive = 'Registry::HKEY_USERS\' + $Sid
        $shellKey = $hive + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        foreach ($valueName in @('Personal', 'Desktop', 'My Pictures', 'My Video', 'My Music', '{374DE290-123F-4565-9164-39C4925E467B}')) {
            $configured = Expand-ScanProfilePath (Get-ScanRegistryValue $shellKey $valueName) $Profile
            if ($configured) {
                if ($valueName -eq 'Personal' -and -not $documents.Contains($configured)) { $documents.Add($configured) }
                Add-ScanTarget -Name ($label + '：已配置用户文件夹 ' + $valueName) -LiteralPath $configured -Category 'user-files' `
                    -Action migrate -Risk 1 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound
            }
        }
        foreach ($account in @(Get-ScanChildren ($hive + '\Software\Microsoft\OneDrive\Accounts'))) {
            $cloud = Get-ScanRegistryValue $account.PSPath 'UserFolder'
            if ($cloud) { Add-ScanCloudRoot (Expand-ScanProfilePath $cloud $Profile) }
        }
        foreach ($valueName in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
            $cloud = Get-ScanRegistryValue ($hive + '\Environment') $valueName
            if ($cloud) { Add-ScanCloudRoot (Expand-ScanProfilePath $cloud $Profile) }
        }
        foreach ($distro in @(Get-ScanChildren ($hive + '\Software\Microsoft\Windows\CurrentVersion\Lxss'))) {
            $base = Get-ScanRegistryValue $distro.PSPath 'BasePath'
            if ($base) {
                $base = Expand-ScanProfilePath $base $Profile
                if (-not $base) { continue }
                if ($base.StartsWith('\\?\')) { $base = $base.Substring(4) }
                Add-ScanTarget -Name ($label + '：WSL 发行版') -LiteralPath $base -Category 'wsl' `
                    -Action migrate -Risk 3 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
                    -Notes '仅使用 export/import 并验证；禁止直接删除虚拟磁盘。'
                if ($base -match '^C:\\') { Find-ScanVirtualDisks $base ($label + ' WSL') 'wsl-vhdx' }
            }
        }
    }
    foreach ($child in @(Get-ScanChildren $Profile)) {
        if ($child.PSIsContainer -and $child.Name -match '^OneDrive(?:\s*-.*)?$') { Add-ScanCloudRoot $child.FullName }
    }

    Add-ScanTarget -Name ($label + '：用户临时文件') -LiteralPath (Join-Path $local 'Temp') -Category 'temp' `
        -Action delete -Risk 0 -HandlerScript 'scripts/clean-cache.ps1' -Estimate allocated-upper-bound `
        -Notes '上限；实际执行须跳过近期和被占用文件。'
    $configuredTemp = $null
    if ($Sid) { $configuredTemp = Get-ScanRegistryValue ('Registry::HKEY_USERS\' + $Sid + '\Environment') 'TEMP' }
    if (-not $configuredTemp -and $Profile -ieq $script:ScanOriginalProfile) {
        $configuredTemp = Get-ScanProperty $context @('OriginalTempPath', 'UserTempPath', 'TempPath', 'Temp')
    }
    if ($configuredTemp) {
        Add-ScanTarget -Name ($label + '：已配置临时目录') -LiteralPath (Expand-ScanProfilePath $configuredTemp $Profile) -Category 'temp' `
            -Action delete -Risk 0 -HandlerScript 'scripts/clean-cache.ps1' -Estimate allocated-upper-bound `
            -Notes '自定义 TEMP；执行前仍须由共享白名单确认原用户及目录。'
    }
    $explorer = Join-Path $local 'Microsoft\Windows\Explorer'
    foreach ($file in @(Get-ScanChildren $explorer)) {
        if (-not $file.PSIsContainer -and $file.Name -like 'thumbcache_*.db') {
            Add-ScanTarget -Name ($label + '：缩略图缓存') -LiteralPath $file.FullName -Category 'thumbnail-cache' `
                -Action delete -Risk 0 -HandlerScript 'scripts/clean-cache.ps1' -Estimate allocated-upper-bound
        }
    }
    foreach ($browser in @('Google\Chrome\User Data', 'Microsoft\Edge\User Data')) {
        foreach ($browserProfile in @(Get-ScanChildren (Join-Path $local $browser))) {
            if (-not $browserProfile.PSIsContainer -or $browserProfile.Name -notmatch '^(Default|Profile \d+|Guest Profile|System Profile)$') { continue }
            foreach ($cacheName in @('Cache', 'Code Cache', 'GPUCache', 'Network\Cache')) {
                Add-ScanTarget -Name ($label + '：浏览器 ' + $browserProfile.Name + ' ' + $cacheName) `
                    -LiteralPath (Join-Path $browserProfile.FullName $cacheName) -Category 'browser-cache' `
                    -Action delete -Risk 0 -HandlerScript 'scripts/clean-cache.ps1' -Estimate allocated-upper-bound `
                    -Notes '仅缓存；书签、密码、Cookie 和其余用户数据保留。'
            }
        }
    }

    $chatCandidates = @(
        @('微信', (Join-Path $roaming 'Tencent\WeChat')),
        @('微信新版', (Join-Path $roaming 'Tencent\xwechat')),
        @('微信本地数据', (Join-Path $local 'Tencent\WeChat')),
        @('QQ', (Join-Path $roaming 'Tencent\QQ')),
        @('QQ NT', (Join-Path $local 'Tencent\QQ')),
        @('企业微信', (Join-Path $roaming 'Tencent\WXWork')),
        @('企业微信', (Join-Path $local 'WXWork')),
        @('企业微信', (Join-Path $local 'Tencent\WXWork')),
        @('钉钉', (Join-Path $roaming 'DingTalk')),
        @('钉钉', (Join-Path $local 'DingTalk')),
        @('钉钉', (Join-Path $roaming 'Alibaba\DingTalk')),
        @('飞书', (Join-Path $roaming 'LarkShell')),
        @('飞书', (Join-Path $local 'Feishu')),
        @('飞书', (Join-Path $roaming 'Bytedance\Feishu'))
    )
    foreach ($doc in $documents) {
        $chatCandidates += ,@('微信聊天数据', (Join-Path $doc 'WeChat Files'))
        $chatCandidates += ,@('微信 4.x 聊天数据', (Join-Path $doc 'xwechat_files'))
        $chatCandidates += ,@('QQ 聊天数据', (Join-Path $doc 'Tencent Files'))
        $chatCandidates += ,@('企业微信聊天数据', (Join-Path $doc 'WXWork'))
    }
    if ($Sid) {
        $wechatKey = 'Registry::HKEY_USERS\' + $Sid + '\Software\Tencent\WeChat'
        $savePath = Expand-ScanProfilePath (Get-ScanRegistryValue $wechatKey 'FileSavePath') $Profile
        if ($savePath -and $savePath -ne 'MyDocument:') {
            if ((Split-Path -Path $savePath -Leaf) -match '^(WeChat Files|xwechat_files)$') {
                $chatCandidates += ,@('微信已配置数据目录', $savePath)
            }
            else {
                $chatCandidates += ,@('微信已配置数据目录', (Join-Path $savePath 'WeChat Files'))
                $chatCandidates += ,@('微信新版已配置数据目录', (Join-Path $savePath 'xwechat_files'))
            }
        }
    }
    # 旧版微信使用短文本记录真实存储位置；只读取已知配置文件，不读取聊天内容。
    $wechatConfig = Join-Path $roaming 'Tencent\WeChat\All Users\config\3ebffe94.ini'
    $configText = Read-ScanSmallText $wechatConfig 8192
    if ($configText) {
        $savePath = ($configText -split '\r?\n' | Select-Object -First 1).Trim()
        if ($savePath -and $savePath -ne 'MyDocument:') {
            $savePath = Expand-ScanProfilePath $savePath $Profile
            if ($savePath) {
                if ((Split-Path -Path $savePath -Leaf) -match '^(WeChat Files|xwechat_files)$') {
                    $chatCandidates += ,@('微信配置文件中的数据目录', $savePath)
                }
                else { $chatCandidates += ,@('微信配置文件中的数据目录', (Join-Path $savePath 'WeChat Files')) }
            }
        }
    }
    foreach ($candidate in $chatCandidates) {
        Add-ScanTarget -Name ($label + '：' + $candidate[0]) -LiteralPath $candidate[1] -Category 'chat-data' `
            -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
            -Notes '按实际版本使用软件存储设置；可能同时包含记录、附件和缓存，不能整目录清理。'
        if ($script:ScanTargets.ContainsKey(([string]$candidate[1]).TrimEnd('\').ToLowerInvariant())) {
            Add-ScanApplicationParts $candidate[1] $candidate[0]
        }
    }

    $dataCandidates = @(
        @('百度网盘', 'Baidu\BaiduNetdisk', 'local'), @('百度网盘', 'baidu\BaiduNetdisk', 'roaming'),
        @('百度网盘下载', 'BaiduNetdiskDownload', 'profile'),
        @('阿里云盘', 'alipan', 'roaming'), @('阿里云盘', 'aDrive', 'roaming'),
        @('阿里云盘', 'AliyunDrive', 'local'), @('阿里云盘下载', 'aliyundrive', 'profile'),
        @('夸克网盘', 'quark-cloud-drive', 'roaming'), @('夸克网盘', 'QuarkCloudDrive', 'local'),
        @('夸克网盘下载', 'QuarkCloudDrive', 'profile'),
        @('迅雷', 'Thunder Network', 'local'), @('迅雷', 'Thunder Network', 'roaming'),
        @('迅雷下载', 'Downloads\Thunder', 'profile'),
        @('搜狗输入法', 'SogouPY', 'roaming'), @('搜狗输入法', 'SogouPY.users', 'roaming'),
        @('搜狗输入法', 'SogouInput', 'local'), @('百度输入法', 'Baidu\BaiduPinyin', 'roaming'),
        @('百度输入法', 'Baidu\BaiduInput', 'local')
    )
    foreach ($candidate in $dataCandidates) {
        $base = $Profile
        if ($candidate[2] -eq 'local') { $base = $local }
        if ($candidate[2] -eq 'roaming') { $base = $roaming }
        $path = Join-Path $base $candidate[1]
        Add-ScanTarget -Name ($label + '：' + $candidate[0]) -LiteralPath $path -Category 'domestic-app-data' `
            -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
            -Notes '下载内容、词库、账号数据不能当缓存删除；优先在软件设置内清理缓存或迁移。'
        if ($script:ScanTargets.ContainsKey($path.ToLowerInvariant())) { Add-ScanApplicationParts $path $candidate[0] }
    }

    $developerTargets = @(
        @('npm 缓存', 'npm-cache', 'local', 'developer-cache', 'system-tool', 1),
        @('npm 旧版缓存', 'npm-cache', 'roaming', 'developer-cache', 'system-tool', 1),
        @('pip 缓存', 'pip\Cache', 'local', 'developer-cache', 'system-tool', 1),
        @('conda 包缓存', '.conda\pkgs', 'profile', 'developer-cache', 'system-tool', 1),
        @('Anaconda 包缓存', 'anaconda3\pkgs', 'profile', 'developer-cache', 'system-tool', 1),
        @('Miniconda 包缓存', 'miniconda3\pkgs', 'profile', 'developer-cache', 'system-tool', 1),
        @('Maven 下载仓库', '.m2\repository', 'profile', 'developer-cache', 'migrate', 2),
        @('Gradle 下载缓存', '.gradle\caches', 'profile', 'developer-cache', 'migrate', 2),
        @('Gradle wrapper 分发缓存', '.gradle\wrapper\dists', 'profile', 'developer-cache', 'migrate', 1),
        @('NuGet 包缓存', '.nuget\packages', 'profile', 'developer-cache', 'system-tool', 1),
        @('NuGet HTTP 缓存', 'NuGet\v3-cache', 'local', 'developer-cache', 'system-tool', 1),
        @('Android SDK', 'Android\Sdk', 'local', 'android-sdk', 'migrate', 2),
        @('Android 模拟器 AVD', '.android\avd', 'profile', 'emulator-data', 'migrate', 2),
        @('Hugging Face 缓存/模型', '.cache\huggingface', 'profile', 'ai-models', 'migrate', 2),
        @('Ollama 模型', '.ollama\models', 'profile', 'ai-models', 'migrate', 2),
        @('LM Studio 模型', '.lmstudio\models', 'profile', 'ai-models', 'migrate', 2),
        @('LM Studio 旧版模型', '.cache\lm-studio\models', 'profile', 'ai-models', 'migrate', 2),
        @('ModelScope 模型', '.cache\modelscope', 'profile', 'ai-models', 'migrate', 2),
        @('PyTorch 模型缓存', '.cache\torch', 'profile', 'ai-models', 'migrate', 2),
        @('iTunes 手机备份', 'Apple Computer\MobileSync\Backup', 'roaming', 'mobile-backup', 'migrate', 3),
        @('iTunes 商店版手机备份', 'Apple\MobileSync\Backup', 'profile', 'mobile-backup', 'migrate', 3),
        @('iTunes 本地手机备份', 'Apple Computer\MobileSync\Backup', 'local', 'mobile-backup', 'migrate', 3),
        @('Docker Desktop 数据', 'Docker', 'local', 'docker-data', 'migrate', 3),
        @('Docker 用户配置', '.docker', 'profile', 'docker-configuration', 'keep', 0),
        @('WSL 新版磁盘目录', 'wsl', 'local', 'wsl', 'migrate', 3)
    )
    foreach ($candidate in $developerTargets) {
        $base = $Profile
        if ($candidate[2] -eq 'local') { $base = $local }
        if ($candidate[2] -eq 'roaming') { $base = $roaming }
        $handler = 'scripts/migrate.ps1'
        if ($candidate[4] -eq 'system-tool') { $handler = 'scripts/clean-cache.ps1' }
        if ($candidate[4] -eq 'keep') { $handler = '' }
        Add-ScanTarget -Name ($label + '：' + $candidate[0]) -LiteralPath (Join-Path $base $candidate[1]) -Category $candidate[3] `
            -Action $candidate[4] -Risk $candidate[5] -HandlerScript $handler -Estimate allocated-upper-bound `
            -Notes '缓存使用工具官方命令；Maven/Gradle 可能有本地产物，不整体删除 .m2/.gradle。模型、备份、VHDX 只做经过验证的迁移。'
    }
    # 已加载用户的环境变量可覆盖默认位置。未加载的用户配置不加载 hive。
    $configuredEnvironment = @{
        'NPM_CONFIG_CACHE' = 'npm 缓存'; 'PIP_CACHE_DIR' = 'pip 缓存'; 'CONDA_PKGS_DIRS' = 'conda 包缓存'
        'GRADLE_USER_HOME' = 'Gradle 用户目录'; 'NUGET_PACKAGES' = 'NuGet 包缓存'
        'ANDROID_HOME' = 'Android SDK'; 'ANDROID_SDK_ROOT' = 'Android SDK'
        'HF_HOME' = 'Hugging Face 数据'; 'HF_HUB_CACHE' = 'Hugging Face 模型'
        'HUGGINGFACE_HUB_CACHE' = 'Hugging Face 模型'; 'OLLAMA_MODELS' = 'Ollama 模型'
    }
    foreach ($variable in $configuredEnvironment.psbase.Keys) {
        $configured = $null
        if ($Sid) { $configured = Get-ScanRegistryValue ('Registry::HKEY_USERS\' + $Sid + '\Environment') $variable }
        if (-not $configured -and $Profile -ieq $env:USERPROFILE) {
            $configured = [Environment]::GetEnvironmentVariable($variable)
        }
        foreach ($part in @(([string]$configured) -split ';')) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            Add-ScanTarget -Name ($label + '：已配置 ' + $configuredEnvironment[$variable]) `
                -LiteralPath (Expand-ScanProfilePath $part $Profile) -Category 'configured-development-data' `
                -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
                -Notes ('来源：环境变量 ' + $variable + '；更改工具配置并验证，不能直接整目录删除。')
        }
    }
    foreach ($package in @(Get-ScanChildren (Join-Path $local 'Packages'))) {
        if (-not $package.PSIsContainer -or ($package.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        Add-ScanTarget -Name ($label + '：WSL 虚拟磁盘 ' + $package.Name) `
            -LiteralPath (Join-Path $package.FullName 'LocalState\ext4.vhdx') -Category 'wsl-vhdx' `
            -Action migrate -Risk 3 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
            -Notes '禁止直接删除 VHDX；使用 WSL 导出/导入。压缩需要退出、备份和版本检查。'
    }
    foreach ($relative in @('Docker\wsl\data\ext4.vhdx', 'Docker\wsl\disk\docker_data.vhdx', 'Docker\wsl\main\ext4.vhdx')) {
        Add-ScanTarget -Name ($label + '：Docker Desktop 虚拟磁盘') -LiteralPath (Join-Path $local $relative) -Category 'docker-vhdx' `
            -Action migrate -Risk 3 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
            -Notes '用 Docker Desktop 设置更改磁盘位置；禁止直接删除 VHDX，卷清理必须单独确认。'
    }
    Find-ScanVirtualDisks (Join-Path $local 'Docker\wsl') ($label + ' Docker') 'docker-vhdx'
    Find-ScanVirtualDisks (Join-Path $local 'wsl') ($label + ' WSL') 'wsl-vhdx'
    Add-ScanToolConfiguredPaths $Profile $local $roaming
}

function ConvertTo-ScanBytes {
    param([string]$Text)
    if ($Text -notmatch '(?i)([0-9]+(?:[.,][0-9]+)*)\s*(bytes?|[kmgtpe]i?b|字节|千字节|兆字节|吉字节)') { return $null }
    $numberText = $matches[1]
    $unit = $matches[2].ToUpperInvariant()
    if ($numberText -match '^\d{1,3}(,\d{3})+(\.\d+)?$') { $numberText = $numberText.Replace(',', '') }
    elseif ($numberText.Contains(',') -and -not $numberText.Contains('.')) { $numberText = $numberText.Replace(',', '.') }
    $number = 0.0
    if (-not [double]::TryParse($numberText, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    $powers = @{ B = 0; BYTE = 0; BYTES = 0; '字节' = 0; KB = 1; KIB = 1; '千字节' = 1
        MB = 2; MIB = 2; '兆字节' = 2; GB = 3; GIB = 3; '吉字节' = 3; TB = 4; TIB = 4; PB = 5; PIB = 5; EB = 6; EIB = 6 }
    if (-not $powers.ContainsKey($unit)) { return $null }
    $bytes = $number * [math]::Pow(1024, $powers[$unit])
    if ($bytes -gt [long]::MaxValue) { return $null }
    return [long][math]::Round($bytes)
}

function Invoke-ScanQuery {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$Description)
    if ($WhatIfPreference) { return [pscustomobject]@{ Status = 'skipped'; Output = ''; Reason = '-WhatIf 跳过外部命令。' } }
    try {
        $results = @(Invoke-External -FilePath $FilePath -ArgumentList $ArgumentList -Description $Description -Confirm:$false -ErrorAction Stop)
        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($result in $results) {
            if ($result -is [string]) { $lines.Add($result); continue }
            $exitCode = Get-ScanProperty $result @('ExitCode') 0
            $output = Get-ScanProperty $result @('Output', 'StandardOutput', 'StdOut', 'Text')
            if ($exitCode -ne 0) { throw ('外部命令退出码：' + $exitCode + '；' + (@($output) -join ' ')) }
            foreach ($line in @($output)) { if ($null -ne $line) { $lines.Add([string]$line) } }
        }
        $output = $lines.ToArray() -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($output)) { throw '共享外部命令包装器未返回可解析输出。' }
        return [pscustomobject]@{ Status = 'ok'; Output = $output; Reason = '' }
    }
    catch {
        Add-ScanIssue $FilePath 'ExternalQuery' $_.Exception.Message
        return [pscustomobject]@{ Status = 'unknown'; Output = ''; Reason = $_.Exception.Message }
    }
}

function Set-ScanComponentStore {
    param($Entry, [bool]$IsAdmin)
    $Entry.Status = 'unknown'
    if (-not $IsAdmin) { $Entry.Notes += ' 非管理员：DISM 可回收量未知。'; return }
    if ($Quick) { $Entry.Status = 'skipped'; $Entry.Notes += ' -Quick 跳过 DISM 分析。'; return }
    $query = Invoke-ScanQuery 'dism.exe' @('/Online', '/English', '/Cleanup-Image', '/AnalyzeComponentStore') '只读分析 Windows 组件存储'
    $Entry.Status = $query.Status
    if ($query.Status -ne 'ok') { $Entry.Notes += ' ' + $query.Reason; return }
    $logical = $null; $actual = $null; $backup = $null; $cache = $null; $packages = $null; $recommended = $null; $explicit = $null
    foreach ($line in ($query.Output -split '\r?\n')) {
        if ($line -match '^\s*Windows Explorer Reported Size of Component Store\s*:\s*(.+)$') { $logical = ConvertTo-ScanBytes $matches[1] }
        if ($line -match '^\s*Actual Size of Component Store\s*:\s*(.+)$') { $actual = ConvertTo-ScanBytes $matches[1] }
        if ($line -match '^\s*Backups and Disabled Features\s*:\s*(.+)$') { $backup = ConvertTo-ScanBytes $matches[1] }
        if ($line -match '^\s*Cache and Temporary Data\s*:\s*(.+)$') { $cache = ConvertTo-ScanBytes $matches[1] }
        if ($line -match '^\s*Number of Reclaimable Packages\s*:\s*(\d+)') { $packages = [int]$matches[1] }
        if ($line -match '^\s*Component Store Cleanup Recommended\s*:\s*(Yes|No)') { $recommended = ($matches[1] -eq 'Yes') }
        if ($line -match '^\s*(?:Reclaimable (?:Space|Size)|Size of Reclaimable Packages)\s*:\s*(.+)$') { $explicit = ConvertTo-ScanBytes $matches[1] }
    }
    $Entry.LogicalBytes = $logical; $Entry.AllocatedBytes = $actual
    $Entry.Details = [pscustomobject]@{
        ReclaimablePackages = $packages; CleanupRecommended = $recommended
        BackupsAndDisabledFeaturesBytes = $backup; CacheAndTemporaryDataBytes = $cache; RawOutput = $query.Output
    }
    if ($null -ne $explicit) { $Entry.EstimatedReclaimableBytes = $explicit; $Entry.EstimateKind = 'dism-reported' }
    elseif ($null -ne $packages -and $packages -eq 0 -and $recommended -eq $false) {
        $Entry.EstimatedReclaimableBytes = 0; $Entry.EstimateKind = 'dism-no-cleanup-recommended'
    }
    elseif ($recommended -eq $true -and $null -ne $backup -and $null -ne $cache) {
        $Entry.EstimatedReclaimableBytes = [long]($backup + $cache)
        $Entry.EstimateKind = 'upper-bound'
        $Entry.Notes += ' DISM 未提供精确可回收字节；备份/禁用功能加临时缓存仅为候选上限，不保证实际释放。'
    }
    if ($null -eq $actual -or $null -eq $Entry.EstimatedReclaimableBytes) { $Entry.Status = 'partial' }
}

function Set-ScanShadowStorage {
    param($Entry, [bool]$IsAdmin)
    $Entry.Status = 'unknown'
    if (-not $IsAdmin) { $Entry.Notes += ' 非管理员：卷影存储量未知。'; return }
    $query = Invoke-ScanQuery 'vssadmin.exe' @('list', 'shadowstorage', '/for=C:') '只读查询 C 盘卷影副本存储'
    $Entry.Status = $query.Status
    if ($query.Status -ne 'ok') { $Entry.Notes += ' ' + $query.Reason; return }
    $records = New-Object 'System.Collections.Generic.List[object]'
    $storageVolume = $null; $used = $null; $allocated = $null; $maximum = $null
    foreach ($line in (($query.Output + "`nFor volume:") -split '\r?\n')) {
        if ($line -match '(?i)^\s*(For volume|对于卷|针对卷)\s*[:：]') {
            if ($null -ne $used -or $null -ne $storageVolume) {
                $records.Add([pscustomobject]@{ StorageVolume = $storageVolume; UsedBytes = $used; AllocatedBytes = $allocated; MaximumBytes = $maximum })
            }
            $storageVolume = $null; $used = $null; $allocated = $null; $maximum = $null
        }
        if ($line -match '(?i)(Shadow Copy Storage volume|卷影副本存储卷)\s*[:：]\s*(.+)$') { $storageVolume = $matches[2].Trim() }
        if ($line -match '(?i)(Used Shadow Copy Storage space|已使用的卷影副本存储空间|使用的卷影副本存储空间)\s*[:：]\s*(.+)$') { $used = ConvertTo-ScanBytes $matches[2] }
        if ($line -match '(?i)(Allocated Shadow Copy Storage space|分配的卷影副本存储空间|已分配的卷影副本存储空间)\s*[:：]\s*(.+)$') { $allocated = ConvertTo-ScanBytes $matches[2] }
        if ($line -match '(?i)(Maximum Shadow Copy Storage space|最大的卷影副本存储空间|最大卷影副本存储空间)\s*[:：]\s*(.+)$') { $maximum = ConvertTo-ScanBytes $matches[2] }
    }
    $Entry.Details = [pscustomobject]@{ Associations = @($records.ToArray()); RawOutput = $query.Output }
    $localRecords = @($records | Where-Object { $_.StorageVolume -match '(?i)\(C:\)' })
    if ($records.Count -gt 0 -and $localRecords.Count -gt 0 -and @($localRecords | Where-Object { $null -eq $_.UsedBytes -or $null -eq $_.AllocatedBytes }).Count -eq 0) {
        $Entry.LogicalBytes = [long](($localRecords | Measure-Object UsedBytes -Sum).Sum)
        $Entry.AllocatedBytes = [long](($localRecords | Measure-Object AllocatedBytes -Sum).Sum)
        $Entry.EstimatedReclaimableBytes = $Entry.AllocatedBytes
        $Entry.EstimateKind = 'upper-bound'
    }
    elseif ($records.Count -gt 0 -and $localRecords.Count -eq 0 -and @($records | Where-Object { -not $_.StorageVolume -or $_.StorageVolume -notmatch '\([A-Za-z]:\)' }).Count -eq 0) {
        $Entry.LogicalBytes = 0; $Entry.AllocatedBytes = 0; $Entry.EstimatedReclaimableBytes = 0
        $Entry.EstimateKind = 'stored-on-other-volume'
    }
    elseif ($query.Output -match '(?i)No items found|找不到任何项目|未找到任何项目|没有找到任何项目') {
        $Entry.LogicalBytes = 0; $Entry.AllocatedBytes = 0; $Entry.EstimatedReclaimableBytes = 0
        $Entry.EstimateKind = 'no-shadowstorage'
    }
    else { $Entry.Status = 'unknown'; $Entry.Notes += ' 当前语言/输出无法可靠解析；请查看 Details.RawOutput，未知不记为零。' }
}

function Measure-ScanEntry {
    param($Entry)
    if (-not $Entry.Exists) { $Entry.Status = 'not-found'; return }
    if ($Entry.MetadataError) {
        $Entry.Status = 'unknown'; $Entry.Skipped = @($Entry.MetadataError); return
    }
    $item = $Entry.Metadata
    if ($null -eq $item) { $Entry.Status = 'unknown'; return }
    foreach ($cloudRoot in $script:ScanCloudRoots) {
        if ($Entry.Path -ieq $cloudRoot -or $Entry.Path.StartsWith($cloudRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $Entry.ExcludedFromLocalTotals = $true; $Entry.Status = 'cloud-excluded'
            $Entry.Action = 'system-tool'; $Entry.HandlerScript = ''; $Entry.Risk = 1
            $Entry.EstimatedReclaimableBytes = 0; $Entry.EstimateKind = 'excluded'
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $Entry.ReparsePoints = @($Entry.Path) }
            $Entry.Notes += ' OneDrive 路径不计本地清理量，不递归统计以免把云占位逻辑大小误当物理占用；实际占用未知。'
            return
        }
    }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $Entry.Status = 'reparse-point'; $Entry.ReparsePoints = @($Entry.Path)
        $Entry.Action = 'keep'; $Entry.EstimatedReclaimableBytes = 0; $Entry.EstimateKind = 'excluded'
        $Entry.HandlerScript = ''
        $Entry.Notes += ' 重解析点单列；未进入目标，大小未知。'
        return
    }
    if (-not $item.PSIsContainer) { $Entry.LogicalBytes = [long]$item.Length }
    if ($Entry.MetadataOnly -or ($Quick -and $item.PSIsContainer)) {
        $Entry.Status = 'skipped'
        $Entry.Notes += ' 已跳过递归大小统计。'
        return
    }
    try {
        $size = Get-DirectorySize -LiteralPath $Entry.Path
        $logical = Get-ScanProperty $size @('LogicalBytes', 'LogicalSizeBytes', 'LogicalSize', 'TotalBytes')
        $allocated = Get-ScanProperty $size @('AllocatedBytes', 'ActualBytes', 'ActualSizeBytes', 'ActualSize', 'SizeOnDiskBytes', 'SizeOnDisk')
        if ($null -ne $logical -and $item.PSIsContainer) { $Entry.LogicalBytes = [long]$logical }
        if ($null -ne $allocated) { $Entry.AllocatedBytes = [long]$allocated }
        $Entry.KnownLogicalBytes = Get-ScanProperty $size @('KnownLogicalBytes') $logical
        $Entry.KnownAllocatedBytes = Get-ScanProperty $size @('KnownAllocatedBytes') $allocated
        $Entry.KnownSizeKind = 'complete'
        $Entry.Skipped = @(Get-ScanProperty $size @('Skipped', 'SkippedItems', 'Errors') @())
        $Entry.ReparsePoints = @(Get-ScanProperty $size @('ReparsePoints', 'ReparseItems') @())
        $Entry.ReparsePoints += @($Entry.Skipped | Where-Object {
            (Get-ScanProperty $_ @('Reason', 'Message') '') -match '重解析点|(?i:reparse|junction|symbolic link)'
        })
        $Entry.Status = 'ok'
        $complete = [bool](Get-ScanProperty $size @('IsComplete') ($Entry.Skipped.Count -eq 0))
        if (-not $complete -or $Entry.Skipped.Count -gt 0) {
            $Entry.Status = 'partial'; $Entry.Notes += ' 有无法访问/跳过的条目；已知大小仅为下限，可释放量未知。'
            $Entry.KnownSizeKind = 'lower-bound'
            $Entry.LogicalBytes = $null; $Entry.AllocatedBytes = $null
            $Entry.EstimatedReclaimableBytes = $null; $Entry.EstimateKind = 'unknown'
            return
        }
        if ($null -eq $Entry.LogicalBytes -and $null -eq $Entry.AllocatedBytes) {
            $Entry.Status = 'unknown'; $Entry.KnownSizeKind = 'unknown'
        }
        if ($Entry.Action -eq 'keep') { $Entry.EstimatedReclaimableBytes = 0; $Entry.EstimateKind = 'keep' }
        elseif ($complete -and $Entry.Skipped.Count -eq 0 -and $Entry.Estimate -eq 'allocated-upper-bound' -and $null -ne $Entry.AllocatedBytes) {
            $Entry.EstimatedReclaimableBytes = [long](Get-ScanProperty $size @('EstimatedReclaimableBytes') $Entry.AllocatedBytes)
            $Entry.EstimateKind = 'upper-bound'
        }
        elseif ($complete -and $Entry.Skipped.Count -eq 0 -and $Entry.Estimate -eq 'logical-upper-bound' -and $null -ne $Entry.LogicalBytes) {
            $Entry.EstimatedReclaimableBytes = $Entry.LogicalBytes; $Entry.EstimateKind = 'logical-upper-bound'
        }
        if ($null -eq $Entry.AllocatedBytes) { $Entry.Notes += ' 实际占用未知；不以逻辑大小冒充磁盘释放量。' }
    }
    catch {
        $Entry.Status = 'unknown'; $Entry.Skipped = @($_.Exception.Message)
        Add-ScanIssue $Entry.Path 'Measurement' $_.Exception.Message
    }
}

function Format-ScanBytes {
    param($Bytes)
    if ($null -eq $Bytes) { return 'unknown' }
    if ([double]$Bytes -ge 1TB) { return ('{0:N2} TiB' -f ([double]$Bytes / 1TB)) }
    if ([double]$Bytes -ge 1GB) { return ('{0:N2} GiB' -f ([double]$Bytes / 1GB)) }
    if ([double]$Bytes -ge 1MB) { return ('{0:N1} MiB' -f ([double]$Bytes / 1MB)) }
    return ('{0:N0} B' -f [double]$Bytes)
}


function Format-ScanSize {
    param($Bytes, $KnownBytes, [string]$KnownSizeKind)
    if ($KnownSizeKind -eq 'lower-bound' -and $null -ne $KnownBytes) {
        return ('unknown (partial >= {0})' -f (Format-ScanBytes $KnownBytes))
    }
    return Format-ScanBytes $Bytes
}

function Get-ScanRecommendation {
    param($Entry, $Context)
    # 选择器只用于已实现的清理范围。迁移仍需用户选择目标、工具和具体数据，
    # 不把泛化的 migrate.ps1 链接伪装成可以直接执行的命令。
    $result = [pscustomobject]@{
        Action = $Entry.Action; HandlerScript = ''; HandlerParameters = @{}
        ExecutionCommand = $null; Notes = $Entry.Notes
    }
    if ($Entry.Action -eq 'keep') { return $result }
    if ($Entry.Action -eq 'migrate') {
        $result.Notes += ' 人工迁移指引；须先核对迁移脚本支持的 Item/Source 和目标位置，未提供直接执行命令。'
        return $result
    }
    $result.Action = 'manual'
    if ($Entry.ExcludedFromLocalTotals -or $Entry.Status -in @('reparse-point', 'not-found')) { return $result }
    $path = $Entry.Path.TrimEnd('\')
    $windows = ([string](Get-ScanProperty $Context @('SystemRoot') $env:SystemRoot)).TrimEnd('\')
    $systemDrive = ([string](Get-ScanProperty $Context @('SystemDrive') $env:SystemDrive)).TrimEnd('\')
    $variables = Get-ScanProperty $Context @('Variables')
    $programData = ([string](Get-ScanProperty $variables @('ProgramData') $env:ProgramData)).TrimEnd('\')
    $systemActions = @{}
    if ($windows) {
        $systemActions[$windows + '\WinSxS'] = 'ComponentStore'
        $systemActions[$windows + '\SoftwareDistribution\Download'] = 'UpdateCache'
        foreach ($relative in @('Minidump', 'MEMORY.DMP', 'LiveKernelReports')) {
            $systemActions[$windows + '\' + $relative] = 'CrashDumps'
        }
        $systemActions[$windows + '\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'] = 'DeliveryOptimization'
    }
    if ($programData) {
        $systemActions[$programData + '\Microsoft\Windows\WER'] = 'CrashDumps'
        $systemActions[$programData + '\Microsoft\Windows\DeliveryOptimization\Cache'] = 'DeliveryOptimization'
    }
    if ($systemDrive) {
        $systemActions[$systemDrive + '\Windows.old'] = 'WindowsOld'
        $systemActions[$systemDrive + '\hiberfil.sys'] = 'Hibernate'
    }
    if ($Entry.HandlerScript -eq 'scripts/clean-system.ps1' -and $systemActions.ContainsKey($path)) {
        $action = $systemActions[$path]
        $result.Action = 'system-tool'; $result.HandlerScript = 'scripts/clean-system.ps1'
        $result.HandlerParameters['Action'] = $action
        $result.ExecutionCommand = 'scripts/clean-system.ps1 -Action ' + $action
        if ($action -eq 'Hibernate') {
            $result.HandlerParameters['Mode'] = 'Reduced'; $result.ExecutionCommand += ' -Mode Reduced'
        }
        if ($action -in @('CrashDumps', 'WindowsOld', 'Hibernate')) {
            $result.HandlerParameters['AcknowledgeIrreversible'] = $true
            $result.ExecutionCommand += ' -AcknowledgeIrreversible'
        }
        $result.Notes += ' 执行器仍会检查权限、更新状态和工具可用性；选择器可能处理同类的其他路径。'
        return $result
    }
    $cacheCategory = ''
    if ($Entry.HandlerScript -eq 'scripts/clean-cache.ps1') {
        switch ($Entry.Category) {
            'temp' {
                if ($windows -and $path -ieq ($windows + '\Temp')) { $cacheCategory = 'WindowsTemp' }
                else {
                    $temp = [string](Get-ScanProperty $Context @('OriginalTempPath', 'UserTempPath', 'TempPath', 'Temp'))
                    if ($temp -and $path -ieq $temp.TrimEnd('\')) { $cacheCategory = 'UserTemp' }
                }
            }
            'thumbnail-cache' { $cacheCategory = 'ThumbnailCache' }
            'browser-cache' { $cacheCategory = 'BrowserCache' }
            'developer-cache' { $cacheCategory = 'DevCache' }
        }
    }
    if ($cacheCategory) {
        # 原用户白名单检查同时阻止为其他可见用户或自定义数据目录推荐清理。
        try {
            $check = Test-SafeTarget -LiteralPath $path -Category $cacheCategory -Context $Context
            if ((Get-ScanProperty $check @('IsSafe', 'Safe', 'Allowed') $false) -eq $true) {
                $result.Action = $Entry.Action; $result.HandlerScript = 'scripts/clean-cache.ps1'
                $result.HandlerParameters['Category'] = $cacheCategory
                $result.ExecutionCommand = 'scripts/clean-cache.ps1 -Category ' + $cacheCategory
                $result.Notes += ' 按原用户身份运行；浏览器须完全退出。开发缓存须由工具解析实际位置并通过安全检查，工具不可用或配置不符会跳过。'
                return $result
            }
            $result.Notes += ' 未通过清理范围检查：' + [string](Get-ScanProperty $check @('Reason', 'Message') '无明确安全结论。')
        }
        catch { $result.Notes += ' 无法核对清理范围：' + $_.Exception.Message }
    }
    $result.Notes += ' 此条目没有覆盖整项的脚本清理选择器；请按上述说明在系统/软件界面人工处理，勿直接递归删除。'
    if ($Entry.Category -eq 'recycle-bin') {
        $result.Notes += ' 此处是所有用户汇总；clean-system.ps1 -Action RecycleBin 仅处理原用户，不能用于估算整项清理收益。'
    }
    return $result
}

# 上下文由共享库管理；本脚本不实现提权、白名单或日志系统。
$context = Get-CleanerContext
$script:ScanOriginalProfile = [string](Get-ScanProperty $context @('OriginalUserProfile', 'OriginalProfilePath', 'UserProfile', 'UserProfilePath') '')
if ([string]::IsNullOrWhiteSpace($script:ScanOriginalProfile)) { throw '共享上下文未提供原用户目录，已停止。' }
$originalSid = [string](Get-ScanProperty $context @('OriginalUserSid', 'OriginalUserSID', 'UserSid', 'UserSID', 'Sid') '')
$isAdmin = [bool](Get-ScanProperty $context @('IsAdmin', 'IsAdministrator') $false)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $logDirectory = [string](Get-ScanProperty $context @('LogDirectory', 'LogDir') '')
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logPath = [string](Get-ScanProperty $context @('LogPath', 'LogFilePath') '')
        if ($logPath) {
            if ([IO.Path]::HasExtension($logPath)) { $logDirectory = Split-Path -Path $logPath -Parent }
            else { $logDirectory = $logPath }
        }
    }
    if ([string]::IsNullOrWhiteSpace($logDirectory)) { throw '共享上下文未提供日志目录，请指定 -OutputPath。' }
    $OutputPath = Join-Path $logDirectory ('scan-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8)))
}
$reportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ($reportPath -notmatch '^[A-Za-z]:\\' -or $reportPath.Substring(2).Contains(':')) {
    throw '报告只接受本地盘符上的普通文件路径，不接受网络路径、提供程序路径或备用数据流。'
}
if (Test-Path -LiteralPath $reportPath) { throw ('报告路径已存在，为避免覆盖已停止：' + $reportPath) }

$startedAt = [DateTime]::UtcNow
$baseline = [ordered]@{ Drive = 'C:'; TotalBytes = $null; FreeBytes = $null; AvailableFreeBytes = $null; Status = 'unknown'; Error = $null }
try {
    $drive = [IO.DriveInfo]::new($script:ScanDriveRoot)
    $baseline.TotalBytes = [long]$drive.TotalSize; $baseline.FreeBytes = [long]$drive.TotalFreeSpace
    $baseline.AvailableFreeBytes = [long]$drive.AvailableFreeSpace; $baseline.Status = 'ok'
}
catch { $baseline.Error = $_.Exception.Message; Add-ScanIssue 'C:' 'Baseline' $_.Exception.Message }

Write-Host '正在只读发现系统项、用户目录和已知软件数据位置…'
$systemTargets = @(
    @('休眠文件', 'C:\hiberfil.sys', 'hibernation', 'system-tool', 3, 'allocated-upper-bound', '禁用休眠同时影响快速启动和混合睡眠；也可评估 reduced 模式。'),
    @('页面文件', 'C:\pagefile.sys', 'pagefile', 'keep', 3, 'none', '默认保留系统管理；迁移影响提交上限、崩溃转储，并需重启验证。'),
    @('交换文件', 'C:\swapfile.sys', 'pagefile', 'keep', 3, 'none', '系统管理，不直接删除。'),
    @('Windows 临时目录', 'C:\Windows\Temp', 'temp', 'delete', 0, 'allocated-upper-bound', '实际清理跳过近期和被占用文件。'),
    @('Windows 更新目录汇总', 'C:\Windows\SoftwareDistribution', 'windows-update-summary', 'system-tool', 2, 'none', '由存储感知/磁盘清理处理；更新进行时跳过，不把整个目录大小当可释放量。'),
    @('Windows 更新下载缓存', 'C:\Windows\SoftwareDistribution\Download', 'windows-update', 'system-tool', 2, 'allocated-upper-bound', '仅通过受支持的系统清理流程；更新进行时跳过。'),
    @('旧系统 Windows.old', 'C:\Windows.old', 'upgrade-residue', 'system-tool', 3, 'allocated-upper-bound', '清理后无法回退旧系统，必须独立确认。'),
    @('升级残留 $WINDOWS.~BT', 'C:\$WINDOWS.~BT', 'upgrade-residue', 'system-tool', 3, 'allocated-upper-bound', '使用系统磁盘清理；可能失去升级回退能力。'),
    @('升级残留 $WINDOWS.~WS', 'C:\$WINDOWS.~WS', 'upgrade-residue', 'system-tool', 3, 'allocated-upper-bound', '使用系统工具，不直接删除。'),
    @('升级残留 $WinREAgent', 'C:\$WinREAgent', 'upgrade-residue', 'system-tool', 3, 'allocated-upper-bound', '更新/恢复相关残留，仅评估系统清理。'),
    @('升级日志/残留 Windows10Upgrade', 'C:\Windows10Upgrade', 'upgrade-residue', 'system-tool', 2, 'allocated-upper-bound', '确认升级完成后使用系统工具。'),
    @('传递优化缓存', 'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache', 'delivery-optimization', 'system-tool', 1, 'allocated-upper-bound', '使用存储感知/磁盘清理。'),
    @('传递优化服务缓存', 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache', 'delivery-optimization', 'system-tool', 1, 'allocated-upper-bound', '使用系统工具；不更改服务状态。'),
    @('Windows 搜索索引', 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows', 'search-index', 'system-tool', 2, 'none', '用索引选项调整范围、重建或官方位置设置；重建不能保证长期释放。'),
    @('回收站（所有用户）', 'C:\$Recycle.Bin', 'recycle-bin', 'system-tool', 3, 'allocated-upper-bound', '永久清空不可恢复，须独立确认；权限不足会保留未知。'),
    @('Windows 错误报告', 'C:\ProgramData\Microsoft\Windows\WER', 'error-reports', 'system-tool', 3, 'allocated-upper-bound', '有诊断价值，删除不可逆，须独立确认。'),
    @('小型崩溃转储', 'C:\Windows\Minidump', 'crash-dump', 'system-tool', 3, 'allocated-upper-bound', '有诊断价值，删除不可逆，须独立确认。'),
    @('内存转储', 'C:\Windows\MEMORY.DMP', 'crash-dump', 'system-tool', 3, 'allocated-upper-bound', '有诊断价值，删除不可逆，须独立确认。'),
    @('内核实时转储', 'C:\Windows\LiveKernelReports', 'crash-dump', 'system-tool', 3, 'allocated-upper-bound', '有诊断价值，删除不可逆，须独立确认。')
)
foreach ($target in $systemTargets) {
    $handler = 'scripts/clean-system.ps1'
    if ($target[3] -eq 'delete') { $handler = 'scripts/clean-cache.ps1' }
    if ($target[3] -eq 'keep') { $handler = '' }
    Add-ScanTarget -Name $target[0] -LiteralPath $target[1] -Category $target[2] -Action $target[3] -Risk $target[4] `
        -Estimate $target[5] -Notes $target[6] -HandlerScript $handler -IncludeMissing
}
Add-ScanTarget -Name 'Windows 组件存储（DISM）' -LiteralPath 'C:\Windows\WinSxS' -Category 'component-store' `
    -Action system-tool -Risk 2 -HandlerScript 'scripts/clean-system.ps1' -IncludeMissing -MetadataOnly `
    -Notes '不递归累加硬链接；逻辑大小取 DISM Explorer 报告值，可能重复计数。实际大小取 DISM Actual Size，清理不得添加 ResetBase。'
Add-ScanTarget -Name 'VSS / 系统还原点' -LiteralPath 'C:\System Volume Information' -Category 'shadowstorage' `
    -Action system-tool -Risk 3 -HandlerScript 'scripts/clean-system.ps1' -IncludeMissing -MetadataOnly `
    -Notes '不枚举受保护目录，使用 vssadmin list shadowstorage。预计上限是 C 盘上已分配的存储，缩小可能立即丢失旧还原点。'

foreach ($root in @('C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData', 'C:\Users')) {
    Add-ScanTarget -Name ('目录汇总：' + $root) -LiteralPath $root -Category 'root-summary' -Priority 0
    if ($root -ne 'C:\Users') { Add-ScanInventoryChildren $root 'installed-or-shared-data' '' }
}
foreach ($protected in @('C:\Windows\Installer', 'C:\Windows\System32', 'C:\Windows\System32\DriverStore', 'C:\Windows\servicing',
        'C:\Recovery', 'C:\Program Files\WindowsApps', 'C:\ProgramData\Package Cache')) {
    Add-ScanTarget -Name ('保留/禁止直接处理：' + $protected) -LiteralPath $protected -Category 'protected' -Priority 90 `
        -MetadataOnly -Notes '仅列出位置，不对禁止区提出删除或迁移操作。'
}
$searchData = Get-ScanRegistryValue 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Search' 'DataDirectory'
if ($searchData) {
    Add-ScanTarget -Name '搜索索引（注册表配置位置）' -LiteralPath ([Environment]::ExpandEnvironmentVariables($searchData)) `
        -Category 'search-index' -Action system-tool -Risk 2 -HandlerScript 'scripts/clean-system.ps1' `
        -Notes '通过 Windows 索引选项配置，不直接删除数据库。'
}

# ProfileList 可发现其他用户；不加载离线注册表 hive，不提权到其他账户。
$profiles = @{}
foreach ($key in @(Get-ScanChildren 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')) {
    $profilePath = Get-ScanRegistryValue $key.PSPath 'ProfileImagePath'
    if ($profilePath) {
        $profilePath = [Environment]::ExpandEnvironmentVariables([string]$profilePath).TrimEnd('\')
        if ($profilePath -match '^C:\\') { $profiles[$profilePath] = [string]$key.PSChildName }
    }
}
foreach ($directory in @(Get-ScanChildren 'C:\Users')) {
    if ($directory.PSIsContainer -and -not $profiles.ContainsKey($directory.FullName)) { $profiles[$directory.FullName] = '' }
}
if ($script:ScanOriginalProfile -match '^C:\\' -and -not $profiles.ContainsKey($script:ScanOriginalProfile)) {
    $profiles[$script:ScanOriginalProfile] = $originalSid
}
foreach ($profile in @($profiles.psbase.Keys | Sort-Object)) {
    Write-Verbose ('发现用户目录：' + $profile)
    Add-ScanUserTargets $profile $profiles[$profile]
}
foreach ($variable in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
    Add-ScanCloudRoot ([Environment]::GetEnvironmentVariable($variable))
}

$largeTargets = @(
    @('Steam 默认库', 'C:\Program Files (x86)\Steam\steamapps', 'games', 2),
    @('Steam 默认库', 'C:\Program Files\Steam\steamapps', 'games', 2),
    @('WeGame 游戏', 'C:\WeGameApps', 'games', 2),
    @('WeGame 客户端/游戏', 'C:\Program Files (x86)\Tencent\WeGame', 'games', 2),
    @('WeGame 客户端/游戏', 'C:\Program Files\Tencent\WeGame', 'games', 2),
    @('Epic 游戏', 'C:\Program Files\Epic Games', 'games', 2),
    @('Xbox 游戏', 'C:\XboxGames', 'games', 2),
    @('爱思助手手机备份', 'C:\Program Files (x86)\i4Tools7\backup', 'mobile-backup', 3),
    @('爱思助手手机备份', 'C:\Program Files\i4Tools7\backup', 'mobile-backup', 3),
    @('爱思助手手机备份', 'C:\i4Tools7\backup', 'mobile-backup', 3),
    @('夜神模拟器', 'C:\Program Files\Nox', 'emulator-data', 2),
    @('逍遥模拟器', 'C:\Program Files\Microvirt', 'emulator-data', 2),
    @('雷电模拟器', 'C:\leidian', 'emulator-data', 2),
    @('雷电模拟器', 'C:\LDPlayer', 'emulator-data', 2),
    @('蓝叠模拟器', 'C:\ProgramData\BlueStacks_nxt', 'emulator-data', 2),
    @('蓝叠模拟器旧版', 'C:\ProgramData\BlueStacks', 'emulator-data', 2),
    @('腾讯手游助手', 'C:\Program Files\TxGameAssistant', 'emulator-data', 2),
    @('Docker 系统数据', 'C:\ProgramData\Docker', 'docker-data', 3),
    @('Docker Desktop 系统数据', 'C:\ProgramData\DockerDesktop', 'docker-data', 3),
    @('百度网盘共享缓存', 'C:\ProgramData\BaiduNetdisk', 'domestic-app-data', 2),
    @('百度网盘默认下载', 'C:\BaiduNetdiskDownload', 'download-data', 2),
    @('迅雷默认下载', 'C:\TDDownload', 'download-data', 2),
    @('迅雷下载目录', 'C:\迅雷下载', 'download-data', 2),
    @('Anaconda 共享包缓存', 'C:\ProgramData\anaconda3\pkgs', 'developer-cache', 1),
    @('Miniconda 共享包缓存', 'C:\ProgramData\miniconda3\pkgs', 'developer-cache', 1)
)
foreach ($target in $largeTargets) {
    Add-ScanTarget -Name $target[0] -LiteralPath $target[1] -Category $target[2] -Action migrate -Risk $target[3] `
        -Estimate allocated-upper-bound -HandlerScript 'scripts/migrate.ps1' `
        -Notes '通过软件设置、游戏库移动或卸载重装迁移；备份/模型/虚拟磁盘不得当缓存删除。'
}
# Steam 注册表位置和 libraryfolders.vdf；只读取配置，不启动客户端。
$steamRoots = New-Object 'System.Collections.Generic.List[string]'
foreach ($key in @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam')) {
    $install = Get-ScanRegistryValue $key 'InstallPath'
    if ($install) { $steamRoots.Add([string]$install) }
}
foreach ($sid in @($profiles.psbase.Values | Where-Object { $_ } | Select-Object -Unique)) {
    $install = Get-ScanRegistryValue ('Registry::HKEY_USERS\' + $sid + '\Software\Valve\Steam') 'SteamPath'
    if ($install) { $steamRoots.Add([string]$install) }
}
$steamRoots.Add('C:\Program Files (x86)\Steam'); $steamRoots.Add('C:\Program Files\Steam')
foreach ($steamRoot in @($steamRoots | Select-Object -Unique)) {
    if ($steamRoot -notmatch '^C:[\\/]') { continue }
    Add-ScanTarget -Name 'Steam 库（配置位置）' -LiteralPath (Join-Path $steamRoot 'steamapps') -Category 'games' `
        -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound -Notes '通过 Steam 存储管理移动游戏库。'
    $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
    $vdfText = Read-ScanSmallText $vdf 2MB
    if ($vdfText) {
        foreach ($line in ($vdfText -split '\r?\n')) {
            if ($line -match '"(?:path|\d+)"\s+"([A-Za-z]:\\[^\"]*)"') {
                $library = $matches[1].Replace('\\', '\')
                Add-ScanTarget -Name 'Steam 已配置游戏库' -LiteralPath (Join-Path $library 'steamapps') -Category 'games' `
                    -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound -Notes '通过 Steam 存储管理移动。'
            }
        }
    }
}
foreach ($manifest in @(Get-ScanChildren 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests')) {
    if ($manifest.PSIsContainer -or $manifest.Extension -ne '.item' -or $manifest.Length -gt 2MB -or
        ($manifest.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
    try {
        $text = Read-ScanSmallText $manifest.FullName 2MB
        if (-not $text) { continue }
        $game = $text | ConvertFrom-Json -ErrorAction Stop
        $gameName = Get-ScanProperty $game @('DisplayName', 'AppName') '已安装游戏'
        Add-ScanTarget -Name ('Epic：' + $gameName) -LiteralPath (Get-ScanProperty $game @('InstallLocation') '') -Category 'games' `
            -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound -Notes '来源：Epic 安装清单；使用官方迁移/卸载重装。'
    }
    catch { Add-ScanIssue $manifest.FullName 'Configuration' $_.Exception.Message }
}

# 对多版本软件使用卸载信息识别真实安装位置，不启动程序、不猜测卸载命令。
$uninstallKeys = @(
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($sid in @($profiles.psbase.Values | Where-Object { $_ } | Select-Object -Unique)) {
    $uninstallKeys += 'Registry::HKEY_USERS\' + $sid + '\Software\Microsoft\Windows\CurrentVersion\Uninstall'
}
foreach ($uninstallKey in $uninstallKeys) {
    foreach ($key in @(Get-ScanChildren $uninstallKey)) {
        try {
            $application = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $name = [string](Get-ScanProperty $application @('DisplayName') '')
            $install = [string](Get-ScanProperty $application @('InstallLocation') '')
            if (-not $install -or $name -notmatch '(?i:Steam|WeGame|Epic Games|Xbox|i4Tools|爱思|Nox|夜神|MEmu|逍遥|LDPlayer|雷电|BlueStacks|蓝叠|手游助手|Android Studio|Anaconda|Miniconda|微信|WeChat|Weixin|QQ|企业微信|钉钉|DingTalk|飞书|Feishu|Lark|百度网盘|BaiduNetdisk|阿里云盘|AliyunDrive|夸克网盘|Quark|迅雷|Thunder|搜狗输入法|百度输入法)') { continue }
            Add-ScanTarget -Name ('已安装：' + $name) -LiteralPath $install -Category 'known-application-installation' `
                -Action migrate -Risk 2 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound -Priority 5 `
                -Notes '来源：只读卸载注册表。安装文件通过卸载重装到 D 盘；数据另走应用设置，不能直接删除 Program Files 下的目录。'
            if ($name -match '(?i:i4Tools|爱思)') {
                foreach ($relative in @('backup', 'Data\Backup')) {
                    Add-ScanTarget -Name ($name + '：手机备份') -LiteralPath (Join-Path $install $relative) -Category 'mobile-backup' `
                        -Action migrate -Risk 3 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
                        -Notes '手机备份可能只有一份；软件设置变更位置，复制验证后保留可靠备份。'
                }
            }
            if ($name -match '(?i:Nox|夜神|MEmu|逍遥|LDPlayer|雷电|BlueStacks|蓝叠|手游助手)') {
                Find-ScanVirtualDisks $install $name 'emulator-vdisk'
            }
        }
        catch { Add-ScanIssue $key.PSPath 'InstalledApplication' $_.Exception.Message }
    }
}

Write-Host '正在读取大小；完整扫描可能较慢，-Quick 可跳过目录递归统计。'
foreach ($entry in @($script:ScanTargets.psbase.Values | Sort-Object Path)) {
    Write-Verbose ('统计：' + $entry.Path)
    if ($entry.Category -eq 'component-store') { Set-ScanComponentStore $entry $isAdmin }
    elseif ($entry.Category -eq 'shadowstorage') { Set-ScanShadowStorage $entry $isAdmin }
    else { Measure-ScanEntry $entry }
}
# 各条目独立展示，明确标注父子重叠；不生成会重复计数的“总可释放量”。
$entries = @($script:ScanTargets.psbase.Values)
$reparseRecords = @{}
foreach ($entry in $entries) {
    foreach ($point in @($entry.ReparsePoints)) {
        if ($point -is [string]) { $pointPath = $point; $reason = '重解析点：未跟随。' }
        else {
            $pointPath = [string](Get-ScanProperty $point @('Path', 'LiteralPath') '')
            $reason = [string](Get-ScanProperty $point @('Reason', 'Message') '重解析点：未跟随。')
        }
        if ($pointPath -match '^C:\\') { $reparseRecords[$pointPath] = $reason }
    }
}
foreach ($pointPath in @($reparseRecords.psbase.Keys)) {
    if ($script:ScanTargets.ContainsKey($pointPath.TrimEnd('\').ToLowerInvariant())) { continue }
    $entries += [pscustomobject]@{
        Name = '重解析点（未跟随）'; Path = $pointPath; Category = 'reparse-point'; Action = 'keep'; Risk = 0
        HandlerScript = ''; HandlerParameters = @{}; ExecutionCommand = $null
        Notes = $reparseRecords[$pointPath]; LogicalBytes = $null; AllocatedBytes = $null
        KnownLogicalBytes = $null; KnownAllocatedBytes = $null; KnownSizeKind = 'unknown'
        EstimatedReclaimableBytes = 0; EstimateKind = 'excluded'; Status = 'reparse-point'; Skipped = @()
        ReparsePoints = @($pointPath); ExcludedFromLocalTotals = $true; OverlapsOtherEntries = $false; Details = $null
    }
}
$entryByPath = @{}
foreach ($entry in $entries) { $entryByPath[$entry.Path.TrimEnd('\')] = $entry }
foreach ($entry in $entries) {
    $parentPath = $entry.Path.TrimEnd('\')
    while ($parentPath.LastIndexOf('\') -gt 2) {
        $parentPath = $parentPath.Substring(0, $parentPath.LastIndexOf('\'))
        if ($entryByPath.ContainsKey($parentPath)) {
            $entry.OverlapsOtherEntries = $true; $entryByPath[$parentPath].OverlapsOtherEntries = $true
        }
    }
}
foreach ($entry in $entries) {
    $recommendation = Get-ScanRecommendation $entry $context
    $entry.Action = $recommendation.Action; $entry.HandlerScript = $recommendation.HandlerScript
    $entry.HandlerParameters = $recommendation.HandlerParameters; $entry.ExecutionCommand = $recommendation.ExecutionCommand
    $entry.Notes = $recommendation.Notes
}
$sortedEntries = @($entries | Sort-Object -Property @(
    @{ Expression = { if ($null -eq $_.EstimatedReclaimableBytes) { -1.0 } else { [double]$_.EstimatedReclaimableBytes } }; Descending = $true },
    @{ Expression = { $_.Path }; Descending = $false }
))
$publicEntries = @($sortedEntries | Select-Object Name, Path, Category, LogicalBytes, AllocatedBytes, KnownLogicalBytes, KnownAllocatedBytes, KnownSizeKind, EstimatedReclaimableBytes,
    EstimateKind, Action, Risk, HandlerScript, HandlerParameters, ExecutionCommand, Status, Notes, Skipped, ReparsePoints, ExcludedFromLocalTotals, OverlapsOtherEntries, Details)
$report = [ordered]@{
    SchemaVersion = 2; StartedAtUtc = $startedAt.ToString('o'); CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
    ComputerName = $env:COMPUTERNAME; Quick = [bool]$Quick; WhatIf = [bool]$WhatIfPreference
    Context = [ordered]@{ OriginalUserSid = $originalSid; OriginalUserProfile = $script:ScanOriginalProfile; IsAdmin = $isAdmin; PowerShellVersion = $PSVersionTable.PSVersion.ToString() }
    Baseline = $baseline; SizeUnit = 'bytes'; UnknownValue = $null
    AccountingNotes = @(
        '目录汇总、子目录、文件条目存在重叠；不能相加，不提供重复计数的总可释放量。',
        'upper-bound 是成功清理/迁移后可能释放的上限；近期、占用文件、备份、硬链接与系统策略会减少实际释放。',
        '拒绝访问/长路径/解析失败/Quick 跳过的值为 null；partial 的 KnownLogicalBytes/KnownAllocatedBytes 只是已知下限，KnownSizeKind 为 lower-bound，总量和可释放量仍为 null。',
        '按 EstimatedReclaimableBytes 降序排列，未知排在末尾；已知下限不当作可释放量参与排序。',
        'ExecutionCommand/HandlerParameters 只列出覆盖该路径的清理选择器；同一 Category/Action 可能处理多个条目，仍须满足身份、白名单、进程和更新状态检查。manual/migrate 条目按 Notes 人工操作。',
        'OneDrive 根目录不递归计量且不计本地清理量；云占位不等于本地大小，已下载数据可由客户端释放空间。',
        'WinSxS 使用 DISM 数据；DISM 通常只报告候选组件和包数，估算上限不代表精确可回收量。',
        '扫描只发现默认位置、可访问的注册表和已知配置；不加载其他用户 hive，未知自定义位置可能遗漏。'
    )
    Entries = $publicEntries; DiscoveryIssues = @($script:ScanIssues.ToArray()); OneDriveRoots = @($script:ScanCloudRoots.ToArray())
}

$rows = @($sortedEntries | Where-Object { $_.Status -ne 'not-found' } | Select-Object -First $Top | ForEach-Object {
    [pscustomobject]@{
        '名称' = $_.Name; '逻辑大小' = Format-ScanSize $_.LogicalBytes $_.KnownLogicalBytes $_.KnownSizeKind; '实际占用' = Format-ScanSize $_.AllocatedBytes $_.KnownAllocatedBytes $_.KnownSizeKind
        '预计可释放' = Format-ScanBytes $_.EstimatedReclaimableBytes; '动作' = $_.Action; '风险' = $_.Risk
        '状态' = $_.Status; '执行选择器' = $_.ExecutionCommand; '路径' = $_.Path
    }
})
Write-Host ('C 盘基线：总量 {0}，可用 {1}' -f (Format-ScanBytes $baseline.TotalBytes), (Format-ScanBytes $baseline.FreeBytes))
Write-Host ($rows | Format-Table -AutoSize | Out-String -Width 240)
Write-Host '预计量为单项上限，父子条目不能相加；partial >= 为已知下限，总量及可释放量仍 unknown。按可释放量排序，未知在后；manual/migrate 请按 JSON Notes 人工处理。'

if ($PSCmdlet.ShouldProcess($reportPath, '创建 JSON 扫描报告（必要时创建父目录）')) {
    $parent = Split-Path -Path $reportPath -Parent
    $json = $report | ConvertTo-Json -Depth 16
    # CreateNew 拒绝覆盖已有文件；所有报告写入集中在本 ShouldProcess 分支内。
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][IO.Directory]::CreateDirectory($parent) }
    $stream = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer = $null
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($true))
        $writer.Write($json)
        $writer.Flush()
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        else { $stream.Dispose() }
    }
    Write-Host ('JSON 报告：' + $reportPath)
}

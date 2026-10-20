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
.PARAMETER LargeFileCount
原用户目录中展示的大文件数量，默认 30，0 表示不发现大文件。
.PARAMETER LargeFileMinMB
大文件逻辑大小门槛，默认 500 MiB；不含 AppData、同步目录和重解析点。
.PARAMETER InstallerAgeDays
下载/桌面中安装包和归档的最短年龄，默认 30 天。
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
    [switch]$Quick,

    [ValidateRange(0, 500)]
    [int]$LargeFileCount = 30,

    [ValidateRange(1, 1048576)]
    [int]$LargeFileMinMB = 500,

    [ValidateRange(0, 36500)]
    [int]$InstallerAgeDays = 30
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
$script:ScanExtraEntries = New-Object 'System.Collections.Generic.List[object]'
$script:ScanKnownFolders = @{}

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
    Add-ScanTarget -Name '同步目录（仅用客户端释放本地副本）' -LiteralPath $path -Category 'cloud-onedrive' `
        -Action system-tool -Risk 1 -Priority 100 -HandlerScript '' `
        -Notes '只用同步客户端“释放空间/仅在线”。删除会同步到云端。云占位不计本地占用；已下载文件仍可能占用空间。' `
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
        $folderPath = Join-Path $Profile $folder
        if ($Profile -ieq $script:ScanOriginalProfile -and $folder -ne 'Music') {
            if (-not $script:ScanKnownFolders.ContainsKey($folder)) { continue }
            $folderPath = $script:ScanKnownFolders[$folder]
        }
        Add-ScanTarget -Name ($label + '：' + $folder) -LiteralPath $folderPath -Category 'user-files' `
            -Action migrate -Risk 1 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound `
            -Notes '通过文件夹属性→位置→移动，或复制校验后切换；预计释放是迁移完成且确认备份后清理源数据的上限。'
    }
    if (-not [string]::IsNullOrWhiteSpace($Sid)) {
        $hive = 'Registry::HKEY_USERS\' + $Sid
        $shellKey = $hive + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        foreach ($valueName in @('Personal', 'Desktop', 'My Pictures', 'My Video', 'My Music', '{374DE290-123F-4565-9164-39C4925E467B}')) {
            $configured = Expand-ScanProfilePath (Get-ScanRegistryValue $shellKey $valueName) $Profile
            if ($configured) {
                if ($Profile -ieq $script:ScanOriginalProfile -and $configured -notin @($script:ScanKnownFolders.Values)) { continue }
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
                $wslKey = $base.TrimEnd('\').ToLowerInvariant()
                if ($script:ScanTargets.ContainsKey($wslKey)) {
                    $script:ScanTargets[$wslKey].Details = [pscustomobject]@{ DistributionName = Get-ScanRegistryValue $distro.PSPath 'DistributionName' }
                }
                if ($base -match '^C:\\') { Find-ScanVirtualDisks $base ($label + ' WSL') 'wsl-vhdx' }
            }
        }
    }
    foreach ($child in @(Get-ScanChildren $Profile)) {
        if (-not $child.PSIsContainer) { continue }
        foreach ($pattern in (Get-CleanerTargets).SyncDirectoryNames) {
            if ($child.Name -like $pattern) { Add-ScanCloudRoot $child.FullName; break }
        }
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
        @('Yarn 缓存', 'Yarn\Cache', 'local', 'developer-cache', 'system-tool', 1),
        @('Yarn 旧版缓存', '.cache\yarn', 'profile', 'developer-cache', 'system-tool', 1),
        @('pnpm store', 'pnpm-store', 'local', 'developer-cache', 'system-tool', 1),
        @('pnpm store 新版', 'pnpm\store', 'local', 'developer-cache', 'system-tool', 1),
        @('pnpm 旧版 store', '.pnpm-store', 'profile', 'developer-cache', 'system-tool', 1),
        @('Go 构建缓存', 'go-build', 'local', 'developer-cache', 'system-tool', 1),
        @('Go 模块缓存', 'go\pkg\mod', 'profile', 'developer-cache', 'system-tool', 1),
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

function Expand-ScanTargetPattern {
    param([string]$Pattern, $Context)
    $expanded = Expand-CleanerPath -Pattern $Pattern -Context $Context
    if ($expanded -notmatch '^C:\\') { return }
    $paths = @('C:\')
    foreach ($segment in $expanded.Substring(3).Split([char]'\')) {
        $next = @()
        foreach ($parent in $paths) {
            if ($segment -match '[*?]') {
                foreach ($child in @(Get-ScanChildren $parent)) {
                    if ($child.PSIsContainer -and $child.Name -like $segment -and -not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $next += $child.FullName }
                }
            }
            else { $next += Join-Path $parent $segment }
        }
        $paths = $next
    }
    return $paths
}

function Add-ScanRegisteredCaches {
    param($Context)
    $definitions = (Get-CleanerTargets).Categories
    $slugs = @{ AppCache = 'app-cache'; ShaderCache = 'shader-cache'; InetCache = 'inet-cache'; SystemLogs = 'system-logs'
        BrowserCache = 'browser-cache'; DevCache = 'developer-cache' }
    foreach ($name in @('AppCache', 'ShaderCache', 'InetCache', 'SystemLogs', 'BrowserCache', 'DevCache')) {
        if (-not $definitions.ContainsKey($name)) { continue }
        foreach ($target in @($definitions[$name].Targets)) {
            try {
                foreach ($path in @(Expand-ScanTargetPattern $target.Path $Context)) {
                    # Gradle 白名单还供迁移使用，clean-cache 没有对应的官方清理动作。
                    if ($name -eq 'DevCache' -and $path -match '(?i)\\\.gradle(?:\\|$)') { continue }
                    Add-ScanTarget -Name ('白名单缓存：' + $name + ' ' + (Get-ScanProperty $target @('App') '')) `
                        -LiteralPath $path -Category $slugs[$name] -Action delete -HandlerScript 'scripts/clean-cache.ps1' `
                        -Estimate allocated-upper-bound -Priority 45 -Risk 1 `
                        -Notes '按 targets.psd1 原用户白名单发现；估算为上限，执行时仍检查进程、年龄和排除子项。'
                    $key = $path.TrimEnd('\').ToLowerInvariant()
                    if ($script:ScanTargets.ContainsKey($key)) {
                        $entry = $script:ScanTargets[$key]
                        $entry | Add-Member -NotePropertyName RequiredProcesses -NotePropertyValue @(Get-ScanProperty $target @('ProcessNames') @()) -Force
                        $entry | Add-Member -NotePropertyName CacheDefinition -NotePropertyValue $target -Force
                        $entry | Add-Member -NotePropertyName CacheCategory -NotePropertyValue $name -Force
                        $excluded = @(Get-ScanProperty $target @('ExcludeChildren') @())
                        $entry.Details = [pscustomobject]@{ Scope = $target.Scope; FilePatterns = @(Get-ScanProperty $target @('FilePatterns') @())
                            ExcludeChildren = $excluded; App = Get-ScanProperty $target @('App') }
                        if ($excluded.Count -gt 0) {
                            $entry.Notes += ' 计量仅覆盖未排除的子项。'
                        }
                    }
                }
            }
            catch { Add-ScanIssue $name 'RegisteredCache' $_.Exception.Message }
        }
    }
}

function New-ScanInventoryEntry {
    param([string]$Key, [string]$Name, [string]$Category, [string]$Path, $Bytes, $Details)
    return [pscustomobject]@{
        EntryKey = $Key; Name = $Name; Path = $Path; Category = $Category; Action = 'manual'; Risk = 2
        HandlerScript = ''; HandlerParameters = @{}; ExecutionCommand = $null; Notes = '只读清单，必须人工检查。'
        LogicalBytes = $Bytes; AllocatedBytes = $null; KnownLogicalBytes = $Bytes; KnownAllocatedBytes = $null
        KnownSizeKind = 'unknown'; EstimatedReclaimableBytes = $null; EstimateKind = 'unknown'; Status = $(if ($null -eq $Bytes) { 'unknown' } else { 'ok' })
        Skipped = @(); ReparsePoints = @(); ExcludedFromLocalTotals = $false; OverlapsOtherEntries = $false
        Details = $Details; ManualEstimatedBytes = $Bytes
    }
}

function Test-ScanInventoryPath {
    param([string]$LiteralPath, [switch]$Root)
    if ($LiteralPath -notmatch '^C:\\') { return $false }
    foreach ($cloud in $script:ScanCloudRoots) {
        if ($LiteralPath -ieq $cloud -or $LiteralPath.StartsWith($cloud + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $chain = Test-CleanerPathChain -LiteralPath $LiteralPath
    if (-not $chain.IsSafe) { Add-ScanIssue $LiteralPath 'InventoryGuard' $chain.Reason; return $false }
    $permitted = @()
    if ($Root) { $permitted = @($script:ScanOriginalProfile) }
    $reason = Get-CleanerForbiddenReason -LiteralPath $chain.Path -Context $context -PermittedContainerRoots $permitted
    if ($reason) { return $false }
    $boundary = Get-CleanerUserPathReason -LiteralPath $chain.Path -Context $context
    if ($boundary) { Add-ScanIssue $LiteralPath 'InventoryGuard' $boundary; return $false }
    return $true
}

function Get-ScanFileInventory {
    param([string[]]$Roots, [switch]$Installers)
    $status = 'ok'; $files = New-Object 'System.Collections.Generic.List[object]'
    if ($Quick) { return [pscustomobject]@{ Status = 'skipped'; EstimatedBytes = $null; Files = @(); Examined = 0; Reason = '-Quick 跳过发现，大小未知。' } }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $seen = @{}; $examined = 0
    foreach ($root in $Roots) { if ($root -match '^C:\\') { $queue.Enqueue([pscustomobject]@{ Path = $root; Depth = 0 }) } }
    $appDataRoots = @(($script:ScanOriginalProfile.TrimEnd('\') + '\AppData'),
        (Get-ScanProperty $context @('LocalAppData') ''), (Get-ScanProperty $context @('AppData') '')) | Where-Object { $_ }
    $cutoff = [DateTime]::UtcNow.AddDays(-$InstallerAgeDays)
    while ($queue.Count -gt 0 -and $watch.Elapsed.TotalSeconds -lt 20 -and $examined -lt 50000) {
        $current = $queue.Dequeue()
        if ($seen.ContainsKey($current.Path)) { continue }; $seen[$current.Path] = $true
        $inAppData = $false
        foreach ($appData in $appDataRoots) {
            if ($current.Path -ieq $appData -or $current.Path.StartsWith($appData.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $inAppData = $true; break }
        }
        if (-not $Installers -and $inAppData) { continue }
        if (-not (Test-ScanInventoryPath $current.Path -Root)) { $status = 'partial'; continue }
        $guards = $null
        try {
            # 流式、逐级发现，不使用递归；时间/条目上限在每个条目前检查。
            $guards = Open-CleanerParentGuards -LiteralPath ($current.Path.TrimEnd('\') + '\_scan_inventory_guard_')
            foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($current.Path)) {
                if ($watch.Elapsed.TotalSeconds -ge 20 -or $examined -ge 50000) { $status = 'partial'; break }
                $examined++
                $inAppData = $false
                foreach ($appData in $appDataRoots) {
                    if ($path -ieq $appData -or $path.StartsWith($appData.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $inAppData = $true; break }
                }
                if (-not $Installers -and $inAppData) { continue }
                if (-not (Test-ScanInventoryPath $path)) { $status = 'partial'; continue }
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $status = 'partial'; continue }
                if ($item.PSIsContainer) {
                    if ($current.Depth -lt 32) { $queue.Enqueue([pscustomobject]@{ Path = $item.FullName; Depth = $current.Depth + 1 }) }
                    else { $status = 'partial' }
                    continue
                }
                if ($Installers) {
                    if ($item.Extension -notmatch '^(?i:\.exe|\.msi|\.msix|\.msixbundle|\.appx|\.iso|\.img|\.zip|\.7z|\.rar)$' -or $item.LastWriteTimeUtc -ge $cutoff) { continue }
                }
                elseif ($item.Length -lt ([long]$LargeFileMinMB * 1MB)) { continue }
                $files.Add([pscustomobject]@{ Path = $item.FullName; LogicalBytes = [long]$item.Length; LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o') })
                if (-not $Installers -and $files.Count -gt [math]::Max(100, $LargeFileCount * 2)) {
                    $largest = @($files | Sort-Object LogicalBytes -Descending | Select-Object -First $LargeFileCount)
                    $files.Clear(); foreach ($file in $largest) { $files.Add($file) }
                }
            }
        }
        catch { $status = 'partial'; Add-ScanIssue $current.Path 'FileInventory' $_.Exception.Message }
        finally { if ($null -ne $guards) { foreach ($handle in $guards.Handles) { $handle.Dispose() } } }
    }
    if ($queue.Count -gt 0 -or $watch.Elapsed.TotalSeconds -ge 20 -or $examined -ge 50000) {
        $status = 'partial'; Add-ScanIssue ($Roots -join ';') 'InventoryLimit' '达到 20 秒、50000 条目或深度上限；发现不完整，已知文件仅为下限。'
    }
    $selected = @($files | Sort-Object @{ Expression = { $_.LogicalBytes }; Descending = $true }, Path)
    if (-not $Installers) { $selected = @($selected | Select-Object -First $LargeFileCount) }
    $aggregate = Get-ScanSizeAggregate $selected 'LogicalBytes' 'LogicalBytes'
    $total = $aggregate.TotalBytes
    if ($status -ne 'ok') { $total = $null }
    return [pscustomobject]@{ Status = $status; EstimatedBytes = $total; KnownLowerBoundBytes = $aggregate.KnownLowerBoundBytes
        Files = $selected; Examined = $examined; Reason = '逻辑大小，只用于人工审阅，不等同可释放空间；可能与其他清单重叠。' }
}

function Get-ScanInstalledSoftware {
    param([string]$OriginalSid)
    if ($Quick) { return [pscustomobject]@{ Status = 'skipped'; EstimatedBytes = $null; Items = @(); Reason = '-Quick 跳过软件清单，大小未知。' } }
    $items = New-Object 'System.Collections.Generic.List[object]'
    $status = 'ok'; $seen = @{}; $watch = [Diagnostics.Stopwatch]::StartNew(); $examined = 0
    foreach ($hiveName in @('LocalMachine', 'Users')) {
        foreach ($viewName in @('Registry64', 'Registry32')) {
            $base = $null; $root = $null
            $subkey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            if ($hiveName -eq 'Users') { $subkey = $OriginalSid + '\Software\Microsoft\Windows\CurrentVersion\Uninstall' }
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$hiveName, [Microsoft.Win32.RegistryView]::$viewName)
                $root = $base.OpenSubKey($subkey, $false)
                if ($null -eq $root) { continue }
                foreach ($name in $root.GetSubKeyNames()) {
                    if ($watch.Elapsed.TotalSeconds -ge 15 -or $examined -ge 10000) { $status = 'partial'; break }
                    $examined++; $key = $null
                    try {
                        $key = $root.OpenSubKey($name, $false)
                        if ($null -eq $key) { throw '无法读取软件注册信息。' }
                        $display = [string]$key.GetValue('DisplayName', '')
                        if (-not $display -or $key.GetValue('SystemComponent', 0) -eq 1 -or $key.GetValue('ParentKeyName', '')) { continue }
                        if ($display -match '(?i)Microsoft Visual C\+\+|Microsoft Windows Desktop Runtime|Microsoft ASP\.NET|\.NET.*(?:Runtime|运行时|Host|Targeting|Framework)|Windows.*(?:SDK|Software Development Kit)|Windows Software Development Kit|Windows Driver|\bDriver\b|\bDrivers\b|驱动') { continue }
                        $location = ([string]$key.GetValue('InstallLocation', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)).Trim().Trim('"')
                        if ($location) { $location = Expand-CleanerPath -Pattern $location -Context $context }
                        if ($location -and $location -notmatch '^C:[\\/]') { continue }
                        $sizeKB = $key.GetValue('EstimatedSize', $null)
                        if (-not $location -and $null -eq $sizeKB) { continue }
                        $bytes = $null
                        if ($null -ne $sizeKB -and [double]$sizeKB -ge 0) { $bytes = [long]([double]$sizeKB * 1KB) }
                        $identity = $display + '|' + $location
                        if ($seen.ContainsKey($identity)) { continue }; $seen[$identity] = $true
                        $items.Add([pscustomobject]@{ Name = $display; Path = $location; EstimatedBytes = $bytes; SizeKind = 'vendor-reported'
                            LocationVerified = [bool]$location; RegistryKey = $hiveName + '\' + $subkey + '\' + $name })
                    }
                    catch { $status = 'partial'; Add-ScanIssue $name 'InstalledSoftware' $_.Exception.Message }
                    finally { if ($null -ne $key) { $key.Dispose() } }
                }
            }
            catch { $status = 'partial'; Add-ScanIssue $subkey 'InstalledSoftware' $_.Exception.Message }
            finally { if ($null -ne $root) { $root.Dispose() }; if ($null -ne $base) { $base.Dispose() } }
        }
    }
    if ($status -ne 'ok') { Add-ScanIssue 'Uninstall' 'InstalledSoftware' '软件清单不完整；厂商报告大小总量未知。' }
    $known = [long]0; $unknown = $false
    foreach ($item in $items) { if ($null -eq $item.EstimatedBytes) { $unknown = $true } else { $known += $item.EstimatedBytes } }
    $total = $null
    if ($status -eq 'ok' -and -not $unknown) { $total = $known }
    return [pscustomobject]@{ Status = $status; EstimatedBytes = $total; KnownLowerBoundBytes = $known
        Items = @($items | Sort-Object @{ Expression = { $_.EstimatedBytes }; Descending = $true }, Name)
        Reason = '厂商 EstimatedSize（KB）报告，未声明安装位置的项目不能确认在 C:，不等同实际占用。' }
}

function Complete-ScanDiskLayout {
    param($Layout, [object[]]$Partitions)
    $system = @($Layout.Volumes | Where-Object { $_.DriveLetter -eq 'C' })
    if ($system.Count -ne 1 -or $null -eq $system[0].DiskNumber) { throw '不能唯一确定 C: 的物理磁盘。' }
    $Layout.SystemDiskNumber = $system[0].DiskNumber
    $data = @($Layout.Volumes | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'C' -and $_.DriveType -eq 'Fixed' })
    $Layout.HasDataVolume = $data.Count -gt 0
    if (@($data | Where-Object { $null -eq $_.DiskNumber }).Count -eq 0) {
        $Layout.DataVolumesOnSystemDisk = ($data.Count -gt 0 -and @($data | Where-Object { $_.DiskNumber -ne $Layout.SystemDiskNumber }).Count -eq 0)
    }
    $Layout.SystemDiskPartitionCount = @($Partitions | Where-Object { $_.DiskNumber -eq $Layout.SystemDiskNumber }).Count
    return $Layout
}

function Get-ScanDiskLayout {
    $layout = [ordered]@{ Disks = $null; Volumes = $null; SystemDiskNumber = $null; HasDataVolume = $null
        DataVolumesOnSystemDisk = $null; SystemDiskPartitionCount = $null }
    if ($Quick) { return [pscustomobject]$layout }
    try {
        $disks = @(Get-Disk -ErrorAction Stop); $partitions = @(Get-Partition -ErrorAction Stop); $volumes = @(Get-Volume -ErrorAction Stop)
        $layout.Disks = @($disks | ForEach-Object { [pscustomobject]@{ Number = $_.Number; FriendlyName = $_.FriendlyName
            SizeBytes = $_.Size; BusType = [string]$_.BusType; MediaType = Get-ScanProperty $_ @('MediaType') } })
        $layout.Volumes = @(foreach ($volume in $volumes) {
            $matches = @($partitions | Where-Object { $_.DriveLetter -and $_.DriveLetter -eq $volume.DriveLetter })
            $number = $null; if ($matches.Count -eq 1) { $number = $matches[0].DiskNumber }
            [pscustomobject]@{ DriveLetter = [string]$volume.DriveLetter; FileSystem = $volume.FileSystem
                SizeBytes = $volume.Size; FreeBytes = $volume.SizeRemaining; DiskNumber = $number; DriveType = [string]$volume.DriveType }
        })
        return Complete-ScanDiskLayout ([pscustomobject]$layout) $partitions
    }
    catch { Add-ScanIssue 'DiskLayout' 'StorageCmdlets' $_.Exception.Message }
    try {
        $disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)
        $partitions = @(Get-CimInstance Win32_DiskPartition -ErrorAction Stop)
        $volumes = @(Get-CimInstance Win32_LogicalDisk -ErrorAction Stop)
        $layout.Disks = @($disks | ForEach-Object { [pscustomobject]@{ Number = $_.Index; FriendlyName = $_.Model
            SizeBytes = $_.Size; BusType = Get-ScanProperty $_ @('InterfaceType'); MediaType = Get-ScanProperty $_ @('MediaType') } })
        $layout.Volumes = @(foreach ($volume in $volumes) {
            $matches = @(Get-CimAssociatedInstance -InputObject $volume -Association Win32_LogicalDiskToPartition -ErrorAction Stop)
            $number = $null; if ($matches.Count -eq 1) { $number = $matches[0].DiskIndex }
            $type = [string]$volume.DriveType; if ($volume.DriveType -eq 3) { $type = 'Fixed' }
            [pscustomobject]@{ DriveLetter = $volume.DeviceID.TrimEnd(':'); FileSystem = $volume.FileSystem
                SizeBytes = $volume.Size; FreeBytes = $volume.FreeSpace; DiskNumber = $number; DriveType = $type }
        })
        $partitionData = @($partitions | ForEach-Object { [pscustomobject]@{ DiskNumber = $_.DiskIndex } })
        return Complete-ScanDiskLayout ([pscustomobject]$layout) $partitionData
    }
    catch {
        Add-ScanIssue 'DiskLayout' 'CimFallback' $_.Exception.Message
        foreach ($key in @($layout.Keys)) { $layout[$key] = $null }
        return [pscustomobject]$layout
    }
}

function Get-ScanMigrationWhatIf {
    param($Entry, $Context)
    # 只为已经能核实准确 Item 的原用户数据生成演练行；不猜测发行版或源目录。
    if (-not (Get-ScanProperty $Context @('OriginalUserVerified') $false)) { return $null }
    $path = $Entry.Path.TrimEnd('\'); $parameters = $null; $safeCategory = ''
    if ($Entry.Category -eq 'user-files') {
        foreach ($folder in @($script:ScanKnownFolders.Keys | Sort-Object)) {
            if ($path -ieq $script:ScanKnownFolders[$folder].TrimEnd('\')) {
                $parameters = '-Item UserFolder -Folder ' + $folder + " -Destination 'D:\UserData\" + $folder + "' -VerifyHash"
                $safeCategory = 'UserFolder'; break
            }
        }
    }
    elseif ($Entry.Category -in @('developer-cache', 'configured-development-data')) {
        $cache = ''
        if ($path -match '(?i)npm') { $cache = 'npm' }
        elseif ($path -match '(?i)(^|\\)pip(\\|$)') { $cache = 'pip' }
        elseif ($path -match '(?i)conda') { $cache = 'conda' }
        elseif ($path -match '(?i)\\\.gradle(?:\\|$)') { $cache = 'gradle' }
        elseif ($path -match '(?i)\\\.m2\\repository$') { $cache = 'maven' }
        if ($cache) { $parameters = '-Item DevCache -Cache ' + $cache + " -Destination 'D:\DevCache\" + $cache + "'"; $safeCategory = 'DevCacheMigration' }
    }
    elseif ($Entry.Category -in @('chat-data', 'chat-attachments')) {
        $app = ''; if ($path -match '(?i)\\(?:WeChat Files|xwechat_files)(?:\\|$)') { $app = 'WeChat' }
        elseif ($path -match '(?i)\\Tencent Files(?:\\|$)') { $app = 'QQ' }
        if ($app) {
            $parameters = '-Item AppData -App ' + $app + " -Source '" + $path.Replace("'", "''") + "' -Destination 'D:\ChatData\" + $app + "' -VerifyHash"
            $safeCategory = 'AppData'
        }
    }
    elseif ($Entry.Category -eq 'wsl') {
        $distro = [string](Get-ScanProperty $Entry.Details @('DistributionName') '')
        if ($distro -and $distro -notin @('docker-desktop', 'docker-desktop-data')) {
            $destinationName = [regex]::Replace($distro, '[^\w.-]', '_')
            $parameters = "-Item WSL -Distro '" + $distro.Replace("'", "''") + "' -Destination 'D:\WSL\" + $destinationName + "' -VerifyHash"
            $safeCategory = 'WSL'
        }
    }
    if (-not $parameters) { return $null }
    try {
        $check = Test-SafeTarget -LiteralPath $path -Category $safeCategory -Context $Context
        if (-not $check.IsSafe) { return $null }
        return "& '.\scripts\migrate.ps1' " + $parameters + ' -WhatIf'
    }
    catch { return $null }
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

function Get-ScanVolumeReferenceKey {
    param($Reference)
    $text = [string](Get-ScanProperty $Reference @('DeviceID') $Reference)
    $match = [regex]::Match($text, '(?i)Volume\{[0-9a-f-]{36}\}')
    if (-not $match.Success) { throw '无法识别 VSS 卷引用。' }
    return $match.Value.ToLowerInvariant()
}

function Set-ScanShadowStorage {
    param($Entry, [bool]$IsAdmin)
    $Entry.Status = 'unknown'
    if (-not $IsAdmin) { $Entry.Notes += ' 非管理员：卷影存储量和关联未知。'; return }
    $query = Invoke-ScanQuery 'vssadmin.exe' @('list', 'shadowstorage', '/for=C:') '只读查询 C 盘卷影副本存储'
    $Entry.Status = $query.Status
    if ($query.Status -ne 'ok') { $Entry.Notes += ' ' + $query.Reason; return }
    try {
        $volumes = @(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop)
        $system = @($volumes | Where-Object { $_.DriveLetter -ieq 'C:' })
        if ($system.Count -ne 1) { throw '无法唯一核实 C: 卷。' }
        $systemKey = Get-ScanVolumeReferenceKey $system[0]
        $records = @(foreach ($store in @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop)) {
            if ((Get-ScanVolumeReferenceKey $store.Volume) -ne $systemKey) { continue }
            $onKey = Get-ScanVolumeReferenceKey $store.DiffVolume
            $onVolumes = @($volumes | Where-Object { (Get-ScanVolumeReferenceKey $_) -eq $onKey })
            if ($onVolumes.Count -ne 1) { throw '不能唯一核实卷影副本的实际存储卷。' }
            $on = $onVolumes[0]
            $onSpec = [string](Get-ScanProperty $on @('DriveLetter') '')
            if ([string]::IsNullOrWhiteSpace($onSpec)) { $onSpec = [string](Get-ScanProperty $on @('DeviceID') '') }
            if ([string]::IsNullOrWhiteSpace($onSpec)) { throw '实际存储卷没有可用的盘符或卷 GUID 路径。' }
            [pscustomobject]@{ ForVolume = 'C:'; OnVolume = $onSpec; StorageVolume = $onSpec
                UsedBytes = Get-ScanProperty $store @('UsedSpace'); AllocatedBytes = Get-ScanProperty $store @('AllocatedSpace')
                MaximumBytes = Get-ScanProperty $store @('MaxSpace'); VolumeSizeBytes = Get-ScanProperty $on @('Capacity') }
        })
        $Entry.Details = [pscustomobject]@{ Associations = $records; RawOutput = $query.Output
            AssociationResolved = $false; ForVolume = $null; OnVolume = $null; ProposedMaxSize = $null }
        if ($records.Count -eq 0) {
            $Entry.LogicalBytes = 0; $Entry.AllocatedBytes = 0; $Entry.EstimatedReclaimableBytes = 0
            $Entry.EstimateKind = 'no-shadowstorage'; return
        }
        if ($records.Count -ne 1) { throw '存在多个关联，需人工选择，不生成调整选择器。' }
        $record = $records[0]
        if ($null -eq $record.AllocatedBytes -or $null -eq $record.VolumeSizeBytes -or
            $null -eq $system[0].Capacity -or $record.AllocatedBytes -lt 320MB) {
            throw '分配量或卷容量不明确，或低于安全建议的 320 MB 下限，不生成调整选择器。'
        }
        $limit = [math]::Min([double]$record.VolumeSizeBytes, [double]$system[0].Capacity) * 0.10
        if ($limit -lt 320MB) { throw '卷容量不足以建议保守 VSS 上限，保持人工处理。' }
        $maxSize = '10%'; $proposedBytes = $limit
        if ($record.AllocatedBytes -lt $limit -or $record.VolumeSizeBytes -lt $system[0].Capacity) {
            $megabytes = [long][math]::Floor([math]::Min($record.AllocatedBytes, $limit) / 1MB)
            $maxSize = [string]$megabytes + 'MB'; $proposedBytes = $megabytes * 1MB
        }
        $Entry.Details.AssociationResolved = $true; $Entry.Details.ForVolume = 'C:'
        $Entry.Details.OnVolume = $record.OnVolume; $Entry.Details.ProposedMaxSize = $maxSize
        if ($record.OnVolume -ieq 'C:') {
            $Entry.LogicalBytes = $record.UsedBytes; $Entry.AllocatedBytes = [long]$record.AllocatedBytes
            $Entry.EstimatedReclaimableBytes = [long][math]::Max(0, $record.AllocatedBytes - $proposedBytes)
            $Entry.EstimateKind = 'upper-bound'
        }
        else {
            $Entry.LogicalBytes = 0; $Entry.AllocatedBytes = 0; $Entry.EstimatedReclaimableBytes = 0
            $Entry.EstimateKind = 'stored-on-other-volume'
        }
        $Entry.Notes += ' 只建议现有关联的保守上限；并非删除整项，实际释放需执行后验证。'
    }
    catch {
        if ($null -ne $Entry.Details) { $Entry.Details.AssociationResolved = $false }
        $Entry.Status = 'unknown'; $Entry.Notes += ' ' + $_.Exception.Message
        Add-ScanIssue $Entry.Path 'ShadowAssociation' $_.Exception.Message
    }
}

function Measure-ScanCacheSelection {
    param($Entry)
    try {
        $check = Test-SafeTarget -LiteralPath $Entry.Path -Category $Entry.CacheCategory -Context $context
        if (-not $check.IsSafe) { throw $check.Reason }
        $definition = $Entry.CacheDefinition
        $selectedFiles = $definition.Scope -eq 'SelectedFiles'
        $excluded = @(Get-ScanProperty $definition @('ExcludeChildren') @())
        $sizes = New-Object 'System.Collections.Generic.List[object]'
        foreach ($child in @(Get-CleanerChildren -LiteralPath $Entry.Path)) {
            if ($child.Name -in $excluded) { continue }
            if ($selectedFiles) {
                if ($child.PSIsContainer) { continue }
                $matched = $false
                foreach ($pattern in @($definition.FilePatterns)) { if ($child.Name -like $pattern) { $matched = $true; break } }
                if (-not $matched) { continue }
            }
            $size = Get-DirectorySize -LiteralPath $child.FullName
            $sizes.Add([pscustomobject]@{ Path = $child.FullName; LogicalBytes = $size.LogicalBytes; AllocatedBytes = $size.AllocatedBytes
                EstimatedReclaimableBytes = $size.EstimatedReclaimableBytes; KnownLogicalBytes = $size.KnownLogicalBytes
                KnownAllocatedBytes = $size.KnownAllocatedBytes })
            $Entry.Skipped += @($size.Skipped)
            $Entry.ReparsePoints += @($size.ReparsePoints)
        }
        $logical = Get-ScanSizeAggregate @($sizes.ToArray()) 'LogicalBytes' 'KnownLogicalBytes'
        $allocated = Get-ScanSizeAggregate @($sizes.ToArray()) 'AllocatedBytes' 'KnownAllocatedBytes'
        $reclaimable = Get-ScanSizeAggregate @($sizes.ToArray())
        $Entry.KnownLogicalBytes = $logical.KnownLowerBoundBytes; $Entry.KnownAllocatedBytes = $allocated.KnownLowerBoundBytes
        if ($Entry.Skipped.Count -gt 0 -or $null -eq $logical.TotalBytes -or $null -eq $allocated.TotalBytes) {
            $Entry.Status = 'partial'; $Entry.KnownSizeKind = 'lower-bound'; return
        }
        $Entry.LogicalBytes = $logical.TotalBytes; $Entry.AllocatedBytes = $allocated.TotalBytes
        $Entry.EstimatedReclaimableBytes = $reclaimable.TotalBytes; $Entry.EstimateKind = 'upper-bound'
        $Entry.Status = 'ok'; $Entry.KnownSizeKind = 'complete'
        $Entry.Notes += ' 大小仅限白名单文件名/未排除子项，不是整个目录；实际清理还受年龄和占用限制。'
    }
    catch { $Entry.Status = 'unknown'; $Entry.Skipped += $_.Exception.Message; Add-ScanIssue $Entry.Path 'CacheSelection' $_.Exception.Message }
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
    $definition = Get-ScanProperty $Entry @('CacheDefinition')
    if ($null -ne $definition -and ($definition.Scope -eq 'SelectedFiles' -or @(Get-ScanProperty $definition @('ExcludeChildren') @()).Count -gt 0)) {
        Measure-ScanCacheSelection $Entry; return
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

# 以下分类、聚合和建议函数只处理输入数据，可从 AST 提取后跨平台测试。
function Get-ScanDispositionRules {
    $rules = @{}
    # Key、标题、影响、数据损失、管理员、风险、需关闭程序、重启、附带影响。
    $rows = @(
        @('UserTemp', '用户临时文件', '清除闲置临时文件，应用需要时会重新生成。', 'regenerable', $false, 'low', @(), $false, @('近期或占用文件会跳过。')),
        @('WindowsTemp', 'Windows 临时文件', '清除系统临时文件，正在使用或更新中的项目会跳过。', 'regenerable', $true, 'low', @(), $false, @('安装或更新活动、待重启或状态不明时跳过。')),
        @('ThumbnailCache', '缩略图缓存', '清除缩略图缓存，下次打开文件夹时会重新生成预览。', 'regenerable', $false, 'low', @('explorer'), $false, @('首次显示缩略图可能较慢。')),
        @('BrowserCache', '浏览器缓存', '清除浏览器网页缓存，书签和密码保留但页面需重新下载。', 'regenerable', $false, 'low', @('所有相关浏览器'), $false, @('首次访问网页可能较慢并消耗流量。')),
        @('DevCache', '开发工具缓存', '由官方工具清理可再下载的包缓存，下次构建可能需要联网下载。', 'regenerable', $false, 'medium', @('开发工具、构建和包管理进程'), $false, @('离线构建可能失败；配置不符或工具不可用时跳过。')),
        @('AppCache', '应用缓存', '清除白名单应用缓存，应用下次启动时会重新生成或下载。', 'regenerable', $false, 'low', @('相关应用'), $false, @('首次启动或加载可能较慢。')),
        @('ShaderCache', '着色器缓存', '清除着色器缓存，游戏和图形应用会重新编译着色器。', 'regenerable', $false, 'low', @('游戏和图形应用'), $false, @('首次启动可能出现短暂卡顿。')),
        @('InetCache', 'Internet 临时缓存', '清除 Internet 临时缓存，相关页面和应用资源需重新下载。', 'regenerable', $false, 'low', @('浏览器和使用 Internet 缓存的应用'), $false, @('离线网页资源可能需要重新下载。')),
        @('SystemLogs', '系统日志缓存', '清除白名单内的旧日志，将失去这些日志的历史排障信息但系统会继续生成新日志。', 'regenerable', $true, 'medium', @(), $false, @('历史日志不能重建；新的日志会继续生成。')),
        @('ComponentStore', 'Windows 组件存储', '通过 DISM 清理已替代组件，保留当前系统组件且不使用 ResetBase。', 'regenerable', $true, 'medium', @(), $false, @('操作耗时，执行器会重新分析清理价值。')),
        @('UpdateCache', 'Windows 更新下载缓存', '清除更新下载缓存，后续更新需要时会重新下载。', 'regenerable', $true, 'medium', @(), $false, @('暂时停止并恢复更新服务；更新活动或待重启时跳过。')),
        @('DeliveryOptimization', '传递优化缓存', '清除传递优化下载缓存，更新资源可能需要重新下载。', 'regenerable', $true, 'low', @(), $false, @('更新活动或状态不明时跳过。')),
        @('RecycleBin', '原用户回收站', '永久清空原用户 C 盘回收站，内容无法从回收站恢复。', 'irreversible', $true, 'high', @(), $false, @('只处理已核实的原用户，不处理其他用户回收站。')),
        @('CrashDumps', '崩溃转储和错误报告', '永久清除崩溃转储和错误报告，将失去对应故障诊断现场。', 'irreversible', $true, 'high', @(), $false, @('正在排障时请先备份转储。')),
        @('WindowsOld', '旧系统 Windows.old', '清理旧系统后将失去相应版本回退能力和其中未备份的数据。', 'irreversible', $true, 'high', @(), $false, @('先检查旧用户文件并备份。')),
        @('Hibernate', '休眠文件精简模式', '改为 Reduced 后保留快速启动，但不能完整休眠或使用混合睡眠。', 'irreversible', $true, 'medium', @(), $false, @('可恢复完整休眠配置，精简前的休眠状态不能恢复；实际释放量未知。')),
        @('ShadowStorage', '卷影副本存储上限', '缩小已核实关联的 VSS 上限可能立即永久删除旧快照和还原点。', 'irreversible', $true, 'high', @(), $false, @('丢失的旧快照和还原点不可恢复；上限不代表保证收益。'))
    )
    foreach ($row in $rows) {
        $rules[$row[0]] = @{ Disposition = 'ai'; Title = $row[1]; Summary = $row[2]; DataLoss = $row[3]
            RequiresAdmin = $row[4]; RiskLevel = $row[5]; RequiresClosedApps = $row[6]
            RequiresRestart = $row[7]; SideEffects = $row[8]; Reason = ''; Steps = @() }
    }
    $manualRows = @(
        @('user-files', '用户文件夹需要核对目标容量并切换系统位置。', @('在资源管理器打开此文件夹，检查重要文件并备份到另一物理磁盘或云端。', '确认 D: 是可用的数据卷且空间充足；右键文件夹→属性→位置→移动，选择 D:\UserData 下对应文件夹。', '打开迁移后的文件验证可读，再到设置→系统→存储→更改新内容的保存位置选择数据卷；保留旧副本直到备份验证完成。')),
        @('cloud-onedrive', '同步文件删除会传播到云端，必须由客户端释放本地副本。', @('打开同步客户端，确认同步完成且无错误，并在网页端抽查文件可下载。', '在资源管理器中右键已同步文件夹→OneDrive→释放空间，其他同步软件选择“仅在线”。', '确认文件出现云朵图标；抽查仍可下载，离线需要的文件选择“始终保留在此设备上”。')),
        @('virtual-disk', '虚拟磁盘需要先备份并退出虚拟机，再按所属软件流程迁移或压缩。', @('打开虚拟机、WSL 或 Docker，核对磁盘所属实例，并把重要数据备份到另一物理磁盘。', 'Docker Desktop：设置→Resources→Advanced→Disk image location 选择数据卷；WSL 先运行 wsl --list --verbose 核对发行版名称。', '退出 Docker 和虚拟机；WSL 在保存工作后运行 wsl --shutdown；使用所属软件支持的导出、迁移或压缩功能，禁止直接删除 VHD/VHDX。', '重新启动实例，验证用户、业务文件、容器及卷；比较 C: 空闲变化并保留原磁盘和备份。')),
        @('pagefile', '页面文件影响提交上限和崩溃转储，默认保持系统管理。', @('运行 SystemPropertiesAdvanced.exe→性能“设置”→高级→虚拟内存“更改”，记录当前系统管理配置。', '仅在确认内存、峰值提交量和崩溃转储需求后由管理员评估其他卷配置；不要删除 pagefile.sys 或 swapfile.sys。', '如人工变更，按界面提示重启，检查任务管理器→性能→内存→已提交及事件查看器；异常时恢复原配置。')),
        @('shadowstorage-manual', '实际 VSS 关联或可用上限未可靠解析，不能猜测存储卷。', @('以管理员身份打开终端，运行 vssadmin list shadowstorage /for=C:，核对“对于卷”和“卷影副本存储卷”。', '运行 Get-CimInstance Win32_ShadowStorage 和 Get-CimInstance Win32_Volume 交叉核对关联与容量；关联不明确时保留。', '确认独立备份可恢复并重新完整扫描；只有关联解析成功后才能单独确认 A 区项，缩小会永久丢失旧快照和还原点。')),
        @('reserved-storage', '保留存储服务于系统更新，默认保留，禁用也不保证立即释放。', @('以管理员身份打开终端，运行 DISM /Online /Get-ReservedStorageState 查看状态。', '打开设置→系统→存储→显示更多类别→系统和保留空间，核对实际占用；优先清理其他可确认项。', '保留默认设置；如确需调整，先完成系统备份并由管理员查阅适用 Windows 版本的官方流程，更新后验证可用空间。')),
        @('large-file', '大文件可能是唯一副本，需要逐个判断保留、移动或自行删除。', @('在资源管理器定位此文件，核对用途、修改时间和是否有另一物理磁盘上的备份。', '需要保留时复制到 D:\UserData 的专用目录，打开并核对大小，重要文件比较 Get-FileHash；验证后再决定是否删除 C: 旧副本。', '确认无用时在资源管理器自行删除；需要离线使用或无法判断时保留。')),
        @('old-installers', '旧安装包和归档可能仍有安装或恢复用途，必须逐个检查。', @('在资源管理器打开列出的下载和桌面目录，切换“详细信息”，按修改日期和大小排序，逐个核对下方文件清单。', '确认可重新下载或内容已有备份后，自行选择无用安装包/归档删除；需保留的复制到 D:\Installers 并打开验证。', '保留唯一安装介质、授权文件和重要归档；验证备份后再处理 C: 旧副本，不要批量清空下载或桌面。')),
        @('installed-software', '软件大小由厂商报告，卸载影响应用及其数据，需先核对备份。', @('打开设置→应用→已安装的应用（Windows 10 为“应用和功能”），按名称找到此软件并核对大小和用途。', '先导出设置和重要数据；选择“卸载”，或仅在应用提供“移动”按钮/官方库移动功能时使用它。', '需要继续使用时重新安装，在安装器允许时选择 D:\Apps 下的专用目录，再验证应用和数据；Program Files 绝不能靠复制目录移动。')),
        @('developer-cache', '开发缓存迁移涉及工具配置，不能直接删除整个仓库。', @('关闭 IDE 和构建任务，运行对应工具的配置查询确认实际缓存位置，并备份本机独有包和构建产物。', '在工具设置中把未来缓存位置改到 D:\DevCache 下的专用目录；只改配置不会移动或释放现有缓存。', '执行一次下载/构建，检查新路径和离线需求；旧数据在核验备份和工具清理范围前保留。')),
        @('chat-data', '聊天记录和附件可能只有一份，需要软件内备份和位置切换。', @('打开微信/QQ→设置→文件管理或存储管理，核对当前路径和版本，使用应用内备份功能备份聊天记录。', '关闭应用后复制并校验受支持的文件数据；在应用设置中将存储位置切换到 D:\ChatData 的专用目录。', '重新打开应用，抽查近期和旧记录、图片、视频和附件；保留原目录及独立备份，不把聊天库当缓存删除。')),
        @('manual', '没有可覆盖整项的安全执行选择器，需要使用系统或应用界面逐步处理。', @('在资源管理器或软件设置中核对列出的路径、内容用途和占用，无法判断的数据保留。', '打开所属软件的存储/缓存设置，使用官方清理或位置迁移功能；系统项在设置→系统→存储→临时文件中核对，未列出的项目保留。', '处理前备份重要数据，完成后重开应用验证功能，并比较 C: 空闲空间；禁止直接递归删除系统或软件安装目录。')),
        @('migrate', '迁移需要确认目标、复制校验和应用切换，每步都需人工验证。', @('在所属软件设置中核对数据路径，关闭写入并备份到另一物理磁盘或云端，确认 D: 的容量和文件系统。', '使用软件自带的存储位置、游戏库移动或导出/导入功能，选择 D: 的专用目录；先复制并校验，保留旧源。', '切换后启动软件并抽查数据，验证独立备份可恢复后才另行决定旧源处理；迁移本身不等于已释放空间。'))
    )
    foreach ($row in $manualRows) {
        $rules[$row[0]] = @{ Disposition = 'manual'; Title = ''; Summary = '需要人工核对用途和备份后逐步处理，保留旧副本直到验证完成。'
            DataLoss = 'none'; RequiresAdmin = ($row[0] -in @('pagefile', 'reserved-storage')); RiskLevel = 'medium'
            RequiresClosedApps = @(); RequiresRestart = ($row[0] -eq 'pagefile'); SideEffects = @('人工操作前核对备份及完整作用范围。')
            Reason = $row[1]; Steps = $row[2] }
    }
    $rules['keep'] = @{ Disposition = 'keep'; Title = ''; Summary = '此项仅报告或保留，不获得清理或迁移授权。'
        DataLoss = 'none'; RequiresAdmin = $false; RiskLevel = 'low'; RequiresClosedApps = @(); RequiresRestart = $false
        SideEffects = @(); Reason = ''; Steps = @() }
    return $rules
}

function Get-ScanDisposition {
    param($Entry)
    $rules = Get-ScanDispositionRules
    $category = [string](Get-ScanProperty $Entry @('Category') '')
    $action = [string](Get-ScanProperty $Entry @('Action') 'keep')
    $parameters = Get-ScanProperty $Entry @('HandlerParameters') @{}
    $selector = [string](Get-ScanProperty $parameters @('Category', 'Action') '')
    $key = 'keep'
    $blocked = [bool](Get-ScanProperty $Entry @('SafetyBlocked') $false) -or
        (Get-ScanProperty $Entry @('Status') '') -in @('not-found', 'reparse-point')
    $rootReparse = @(Get-ScanProperty $Entry @('ReparsePoints') @() | Where-Object {
        [string](Get-ScanProperty $_ @('Path', 'LiteralPath') $_) -ieq [string](Get-ScanProperty $Entry @('Path') '')
    }).Count -gt 0
    $blocked = $blocked -or $rootReparse
    $cloud = $category -in @('cloud-onedrive', 'cloud-sync')
    if (-not $blocked -and (-not (Get-ScanProperty $Entry @('ExcludedFromLocalTotals') $false) -or $cloud)) {
        if ($cloud) { $key = 'cloud-onedrive' }
        elseif ($category -match 'summary$' -or $category -eq 'protected') { $key = 'keep' }
        elseif ($category -in @('pagefile', 'reserved-storage')) { $key = $category }
        elseif ($action -eq 'migrate') { $key = 'migrate' }
        elseif ($selector -and $rules.ContainsKey($selector) -and $rules[$selector].Disposition -eq 'ai' -and
            (Get-ScanProperty $Entry @('HandlerScript') '') -in @('scripts/clean-cache.ps1', 'scripts/clean-system.ps1')) {
            $key = $selector
            if ($selector -eq 'Hibernate' -and (Get-ScanProperty $parameters @('Mode') '') -ne 'Reduced') { $key = 'manual' }
            if ($selector -eq 'RecycleBin' -and -not (Get-ScanProperty $Entry @('OriginalUserOnly') $false)) { $key = 'keep' }
            if ($selector -eq 'ShadowStorage' -and -not (Get-ScanProperty (Get-ScanProperty $Entry @('Details')) @('AssociationResolved') $false)) { $key = 'manual' }
        }
        elseif ($action -ne 'keep') { $key = 'manual' }
        if ($key -in @('migrate', 'manual')) {
            if ($category -eq 'shadowstorage') { $key = 'shadowstorage-manual' }
            elseif ($category -match 'vhdx|vdisk|^wsl$|^docker-data$') { $key = 'virtual-disk' }
            elseif ($category -in @('chat-data', 'chat-attachments', 'chat-history')) { $key = 'chat-data' }
            elseif ($rules.ContainsKey($category) -and $rules[$category].Disposition -eq 'manual') { $key = $category }
        }
    }
    $rule = $rules[$key]
    $steps = @(); $index = 0
    foreach ($step in @($rule.Steps)) { $index++; $steps += ('{0}. {1}' -f $index, $step) }
    $migrationCommand = Get-ScanProperty $Entry @('MigrationWhatIf')
    if ($rule.Disposition -eq 'manual' -and $migrationCommand) {
        $steps = @('1. 确认数据卷容量并备份到另一物理磁盘；在 skill 根目录打开原用户 PowerShell，先演练：' + $migrationCommand)
        $index = 1
        foreach ($step in @($rule.Steps)) { $index++; $steps += ('{0}. {1}' -f $index, $step) }
    }
    if ($rule.Disposition -eq 'manual' -and $category -eq 'old-installers') {
        $fileList = @(Get-ScanProperty (Get-ScanProperty $Entry @('Details')) @('Files') @())
        if ($fileList.Count -gt 0) {
            $index++
            $lines = @($fileList | ForEach-Object { $_.Path + '（逻辑大小 ' + [string]$_.LogicalBytes + ' 字节）' })
            $steps += ('{0}. 优先审阅最大的 20 个候选文件（最多列 20 个）：{1}{2}' -f $index, [Environment]::NewLine, ($lines -join [Environment]::NewLine))
        }
    }
    $closed = @($rule.RequiresClosedApps) + @(Get-ScanProperty $Entry @('RequiredProcesses') @())
    $irreversible = $rule.DataLoss -eq 'irreversible'
    return [pscustomobject]@{
        Disposition = $rule.Disposition; DefaultSelected = ($rule.Disposition -eq 'ai' -and -not $irreversible)
        Irreversible = $irreversible; Title = $rule.Title
        Impact = [pscustomobject]@{ Summary = $rule.Summary; DataLoss = $rule.DataLoss; Reversible = (-not $irreversible)
            RequiresClosedApps = @($closed | Sort-Object -Unique); RequiresRestart = [bool]$rule.RequiresRestart
            RequiresAdmin = [bool]$rule.RequiresAdmin; RiskLevel = $rule.RiskLevel; SideEffects = @($rule.SideEffects) }
        ManualReason = $rule.Reason; ManualSteps = @($steps)
    }
}

function Get-ScanSizeAggregate {
    param([object[]]$Entries, [string]$SizeProperty = 'EstimatedReclaimableBytes', [string]$LowerBoundProperty = 'KnownAllocatedBytes')
    $roots = New-Object 'System.Collections.Generic.List[object]'
    $unknown = $false; [long]$total = 0; [long]$known = 0
    foreach ($entry in $Entries) {
        if ($null -eq (Get-ScanProperty $entry @($SizeProperty))) { $unknown = $true }
    }
    foreach ($entry in @($Entries | Sort-Object @{ Expression = { ([string](Get-ScanProperty $_ @('Path') '')).Length } }, Path)) {
        $path = ([string](Get-ScanProperty $entry @('Path') '')).Replace('/', '\').TrimEnd('\')
        $overlap = $false
        foreach ($root in $roots) {
            if ($path -ieq $root.Path -or ($root.Path -and $path.StartsWith($root.Path + '\', [StringComparison]::OrdinalIgnoreCase))) { $overlap = $true; break }
        }
        if ($overlap) { continue }
        $roots.Add([pscustomobject]@{ Path = $path })
        $size = Get-ScanProperty $entry @($SizeProperty)
        if ($null -ne $size) { $total += [long]$size; $known += [long]$size }
        else { $lower = Get-ScanProperty $entry @($LowerBoundProperty); if ($null -ne $lower) { $known += [long]$lower } }
    }
    $reported = $null
    if (-not $unknown) { $reported = $total }
    return [pscustomobject]@{ TotalBytes = $reported; KnownLowerBoundBytes = $known }
}

function Merge-ScanImpact {
    param([object[]]$Impacts)
    $loss = 'none'; $risk = 'low'; $admin = $false; $restart = $false; $reversible = $true
    $ranks = @{ none = 0; regenerable = 1; irreversible = 2; low = 0; medium = 1; high = 2 }
    foreach ($impact in $Impacts) {
        if ($ranks[$impact.DataLoss] -gt $ranks[$loss]) { $loss = $impact.DataLoss }
        if ($ranks[$impact.RiskLevel] -gt $ranks[$risk]) { $risk = $impact.RiskLevel }
        $admin = $admin -or $impact.RequiresAdmin; $restart = $restart -or $impact.RequiresRestart
        $reversible = $reversible -and $impact.Reversible
    }
    return [pscustomobject]@{ Summary = (@($Impacts | ForEach-Object { $_.Summary } | Select-Object -Unique) -join ' ')
        DataLoss = $loss; Reversible = $reversible; RequiresClosedApps = @($Impacts | ForEach-Object { $_.RequiresClosedApps } | Sort-Object -Unique)
        RequiresRestart = $restart; RequiresAdmin = $admin; RiskLevel = $risk
        SideEffects = @($Impacts | ForEach-Object { $_.SideEffects } | Select-Object -Unique) }
}

function Get-ScanConfirmationItems {
    param([object[]]$Entries)
    $groups = @{}
    foreach ($entry in @($Entries | Where-Object { $_.Disposition -eq 'ai' })) {
        $parameters = Get-ScanProperty $entry @('HandlerParameters') @{}
        $pairs = @($parameters.Keys | Sort-Object | ForEach-Object { @($_, $parameters[$_]) | ConvertTo-Json -Compress -Depth 8 })
        $key = $entry.HandlerScript + '|' + ($pairs -join '|')
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object 'System.Collections.Generic.List[object]' }
        $groups[$key].Add($entry)
    }
    $items = @(foreach ($key in @($groups.Keys | Sort-Object)) {
        $members = @($groups[$key].ToArray()); $first = $members[0]
        $aggregate = Get-ScanSizeAggregate $members
        $impact = Merge-ScanImpact @($members | ForEach-Object { $_.Impact })
        $classification = Get-ScanDisposition $first
        [pscustomobject]@{ Id = 0; Title = $classification.Title; HandlerScript = $first.HandlerScript
            HandlerParameters = $first.HandlerParameters; ExecutionCommand = $first.ExecutionCommand
            Paths = @($members.Path | Sort-Object -Unique); EstimatedReclaimableBytes = $aggregate.TotalBytes
            KnownLowerBoundBytes = $aggregate.KnownLowerBoundBytes
            DefaultSelected = ($impact.DataLoss -ne 'irreversible' -and @($members | Where-Object { -not $_.DefaultSelected }).Count -eq 0)
            Irreversible = ($impact.DataLoss -eq 'irreversible'); RequiresAdmin = $impact.RequiresAdmin; Impact = $impact
            EntryKeys = @($members | ForEach-Object { $_.EntryKey } | Sort-Object -Unique) }
    })
    $id = 0
    foreach ($item in @($items | Sort-Object @{ Expression = { $_.Irreversible } },
        @{ Expression = { $null -eq $_.EstimatedReclaimableBytes } },
        @{ Expression = { $_.EstimatedReclaimableBytes }; Descending = $true }, Title)) {
        $id++; $item.Id = $id; $item
    }
}

function Get-ScanManualSize {
    param($Entry)
    if ((Get-ScanProperty $Entry @('Status') '') -in @('partial', 'unknown', 'skipped', 'reparse-point', 'not-found', 'cloud-excluded')) { return $null }
    return Get-ScanProperty $Entry @('ManualEstimatedBytes', 'AllocatedBytes', 'LogicalBytes')
}

function Get-ScanManualItems {
    param([object[]]$Entries)
    $id = 0
    foreach ($entry in @($Entries | Where-Object { $_.Disposition -eq 'manual' } | Sort-Object `
        @{ Expression = { $null -eq (Get-ScanManualSize $_) } },
        @{ Expression = { Get-ScanManualSize $_ }; Descending = $true }, Name, EntryKey)) {
        $id++
        [pscustomobject]@{ Id = 'M' + $id; Title = $entry.Name; Reason = $entry.ManualReason + $(if ($entry.Category -eq 'installed-software') { ' 大小为厂商报告；未声明位置时不能确认在 C:。' }); Steps = @($entry.ManualSteps)
            EstimatedBytes = Get-ScanManualSize $entry
            Paths = @(Get-ScanProperty $entry.Details @('Paths') @($entry.Path) | Where-Object { $_ }); Category = $entry.Category }
    }
}

function Get-ScanAdvisory {
    param($Baseline, $DiskLayout, $StorageSenseEnabled, $Evidence)
    $advice = New-Object 'System.Collections.Generic.List[object]'
    $free = Get-ScanProperty $Baseline @('FreeBytes'); $total = Get-ScanProperty $Baseline @('TotalBytes')
    if ($null -ne $free -and ($free -lt 20GB -or ($null -ne $total -and $total -gt 0 -and $free / $total -lt 0.10))) {
        $advice.Add([pscustomobject]@{ Id = 'low-space'; Severity = 'critical'; Title = 'C 盘空间告急'
            Detail = 'C: 可用空间低于 20 GB 或总容量的 10%，可能影响更新和应用运行。'; Steps = @('先确认 A 区影响明确的项目，完成后重新扫描比较空闲空间。', '将可迁移的个人数据安排到数据卷，给系统和更新预留空间。') })
    }
    $hasData = Get-ScanProperty $DiskLayout @('HasDataVolume')
    if ($null -ne $hasData -and -not $hasData) {
        $advice.Add([pscustomobject]@{ Id = 'no-data-volume'; Severity = 'warn'; Title = '为系统之外的数据准备数据卷'
            Detail = '已确认没有固定数据卷；C 盘只放系统和必须装在系统盘的程序，个人数据应放到数据卷。'
            Steps = @('优先增加第二块物理磁盘作为数据盘，避免长期只依赖一个分区或一块磁盘。', '如需在现有磁盘分区，先完成独立备份并验证可恢复，再由人工在磁盘管理中评估压缩 C: 和新建数据分区；本 skill 不执行分区操作。') })
    }
    if ($hasData -eq $true -and (Get-ScanProperty $DiskLayout @('DataVolumesOnSystemDisk')) -eq $true) {
        $advice.Add([pscustomobject]@{ Id = 'same-disk-backup'; Severity = 'warn'; Title = '同一磁盘的分区不能作为独立备份'
            Detail = '已确认数据卷都在系统磁盘上，分区便于整理，但物理磁盘故障会同时影响 C: 和数据卷。'
            Steps = @('日常数据可放 D:，备份另存第二块物理磁盘、外置磁盘或云端。', '定期抽查备份并进行恢复验证，不把同盘复制当成独立备份。') })
    }
    $rows = @(
        @('UserFolderBytes', 10GB, 'user-folders', '个人文件移出系统盘', '桌面、文档、下载、图片和视频在 C: 上的已知占用超过 10 GB。', @('先备份并核对数据卷容量，通过文件夹属性→位置→移动到 D:\UserData。', '在设置→系统→存储→更改新内容的保存位置中选择数据卷。')),
        @('DevelopmentBytes', 5GB, 'development', '开发数据和虚拟磁盘安排到数据卷', '开发缓存、WSL 或虚拟磁盘在 C: 上的已知占用超过 5 GB。', @('按 B 区的 migrate.ps1 -WhatIf 命令逐步演练并验证；WSL 使用导出/导入，Docker 使用官方磁盘位置设置。', '开发缓存可先用 migrate.ps1 -Item DevCache 只改未来缓存配置；配置变更不会搬走旧缓存。')),
        @('InstalledSoftwareBytes', 20GB, 'software-placement', '今后安装软件优先选择数据卷', 'C: 软件的厂商报告大小合计超过 20 GB，实际占用可能不同。', @('新装普通应用时选择 D:\Apps 的专用目录；驱动和系统工具保留官方默认位置。', '现有应用通过卸载重装或官方移动功能迁移，绝不复制移动 Program Files。')),
        @('HibernationBytes', 8GB, 'hibernate-reduced', '评估精简休眠文件', '休眠文件已知大小超过 8 GB，可评估 A 区的 Hibernate Reduced 选项。', @('如不使用完整休眠或混合睡眠，单独点名确认 Reduced；它保留快速启动。', '变更后验证快速启动和电源功能；如需要完整休眠，请保留原设置。'))
    )
    foreach ($row in $rows) {
        $bytes = Get-ScanProperty $Evidence @($row[0])
        if ($null -ne $bytes -and $bytes -gt $row[1]) {
            $advice.Add([pscustomobject]@{ Id = $row[2]; Severity = 'info'; Title = $row[3]; Detail = $row[4]; Steps = $row[5] })
        }
    }
    if ($null -ne $StorageSenseEnabled -and $StorageSenseEnabled -eq $false) {
        $advice.Add([pscustomobject]@{ Id = 'storage-sense'; Severity = 'info'; Title = '启用存储感知定期维护'
            Detail = '原用户存储感知已关闭；开启后可按配置清理临时文件和过期回收站内容，下载及云文件策略需要单独核对。'
            Steps = @('打开设置→系统→存储→存储感知并启用，设置运行频率。', '核对回收站保留天数；下载文件夹按需保留，云文件仅在确认可取回后设置仅在线策略。') })
    }
    return $advice.ToArray()
}

function Get-ScanRecommendation {
    param($Entry, $Context)
    # 选择器只用于已实现的清理范围。迁移仍需用户选择目标、工具和具体数据，
    # 不把泛化的 migrate.ps1 链接伪装成可以直接执行的命令。
    $result = [pscustomobject]@{
        Action = $Entry.Action; HandlerScript = ''; HandlerParameters = @{}
        ExecutionCommand = $null; Notes = $Entry.Notes; SafetyBlocked = $false
    }
    if ($Entry.Action -eq 'keep') { return $result }
    if ($Entry.Category -match 'summary$') { $result.Action = 'keep'; return $result }
    if ($Entry.Category -eq 'shadowstorage') {
        $details = $Entry.Details
        if (-not (Get-ScanProperty $details @('AssociationResolved') $false)) { $result.Action = 'manual'; return $result }
        $result.HandlerScript = 'scripts/clean-system.ps1'; $result.Action = 'system-tool'
        $result.HandlerParameters = @{ Action = 'ShadowStorage'; ForVolume = $details.ForVolume; OnVolume = $details.OnVolume
            MaxSize = $details.ProposedMaxSize; AcknowledgeIrreversible = $true }
        $result.ExecutionCommand = "scripts/clean-system.ps1 -Action ShadowStorage -ForVolume '" + $details.ForVolume + "' -OnVolume '" + $details.OnVolume + "' -MaxSize '" + $details.ProposedMaxSize + "' -AcknowledgeIrreversible"
        return $result
    }
    if ($Entry.Path -and $Entry.Category -notin @('installed-software', 'old-installers', 'reserved-storage') -and
        $Entry.Status -notin @('not-found', 'reparse-point', 'cloud-excluded')) {
        try {
            $chain = Test-CleanerPathChain -LiteralPath $Entry.Path
            if (-not $chain.IsSafe) { throw $chain.Reason }
        }
        catch { $result.Action = 'keep'; $result.SafetyBlocked = $true; $result.Notes += ' 路径链检查失败：' + $_.Exception.Message; return $result }
    }
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
    if ($Entry.Category -eq 'recycle-bin' -and (Get-ScanProperty $Entry @('OriginalUserOnly') $false)) {
        $sid = [string](Get-ScanProperty $Context @('OriginalUserSid') '')
        if ($sid -and $path -ieq ($systemDrive + '\$Recycle.Bin\' + $sid) -and
            (Get-ScanProperty $Context @('CurrentUserSid') '') -eq $sid) { $systemActions[$path] = 'RecycleBin' }
    }
    if ($Entry.HandlerScript -eq 'scripts/clean-system.ps1' -and $systemActions.ContainsKey($path)) {
        $action = $systemActions[$path]
        try {
            if ($action -in @('ComponentStore', 'Hibernate')) { $check = Test-CleanerPathChain -LiteralPath $path }
            else {
                $safeCategory = $action
                if ($action -eq 'UpdateCache') { $safeCategory = 'WindowsUpdate' }
                if ($action -eq 'CrashDumps') { $safeCategory = 'CrashDumpReports' }
                $check = Test-SafeTarget -LiteralPath $path -Category $safeCategory -Context $Context
            }
            if (-not $check.IsSafe) { throw $check.Reason }
        }
        catch { $result.Action = 'keep'; $result.SafetyBlocked = $true; $result.Notes += ' 安全检查失败：' + $_.Exception.Message; return $result }
        $result.Action = 'system-tool'; $result.HandlerScript = 'scripts/clean-system.ps1'
        $result.HandlerParameters['Action'] = $action
        $result.ExecutionCommand = 'scripts/clean-system.ps1 -Action ' + $action
        if ($action -eq 'Hibernate') {
            $result.HandlerParameters['Mode'] = 'Reduced'; $result.ExecutionCommand += ' -Mode Reduced'
        }
        if ($action -in @('RecycleBin', 'CrashDumps', 'WindowsOld', 'Hibernate')) {
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
                    $temp = [string](Get-ScanProperty $Context @('StandardTempPath', 'OriginalTempPath', 'UserTempPath', 'TempPath', 'Temp'))
                    if ($temp -and $path -ieq $temp.TrimEnd('\')) { $cacheCategory = 'UserTemp' }
                }
            }
            'thumbnail-cache' { $cacheCategory = 'ThumbnailCache' }
            'browser-cache' { $cacheCategory = 'BrowserCache' }
            'developer-cache' { $cacheCategory = 'DevCache' }
            'app-cache' { $cacheCategory = 'AppCache' }
            'shader-cache' { $cacheCategory = 'ShaderCache' }
            'inet-cache' { $cacheCategory = 'InetCache' }
            'system-logs' { $cacheCategory = 'SystemLogs' }
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
            $result.SafetyBlocked = $true; $result.Action = 'keep'
            $result.Notes += ' 未通过清理范围检查：' + [string](Get-ScanProperty $check @('Reason', 'Message') '无明确安全结论。')
        }
        catch { $result.SafetyBlocked = $true; $result.Action = 'keep'; $result.Notes += ' 无法核对清理范围：' + $_.Exception.Message }
    }
    $result.Notes += ' 此条目没有覆盖整项的脚本清理选择器；请按上述说明在系统/软件界面人工处理，勿直接递归删除。'
    if ($Entry.Category -eq 'recycle-bin') {
        $result.Notes += ' 只能在已核实的原用户会话处理该用户的回收站，不借用其他账户身份。'
    }
    return $result
}

# 上下文由共享库管理；本脚本不实现提权、白名单或日志系统。
$context = Get-CleanerContext
$script:ScanOriginalProfile = [string](Get-ScanProperty $context @('OriginalUserProfile', 'OriginalProfilePath', 'UserProfile', 'UserProfilePath') '')
if ([string]::IsNullOrWhiteSpace($script:ScanOriginalProfile)) { throw '共享上下文未提供原用户目录，已停止。' }
$originalSid = [string](Get-ScanProperty $context @('OriginalUserSid', 'OriginalUserSID', 'UserSid', 'UserSID', 'Sid') '')
try { $script:ScanKnownFolders = Get-CleanerKnownFolderMap -Context $context }
catch { Add-ScanIssue $script:ScanOriginalProfile 'KnownFolders' $_.Exception.Message }
foreach ($syncRoot in @(Get-ScanProperty $context @('SyncRoots') @())) { Add-ScanCloudRoot $syncRoot }

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
    @('页面文件', 'C:\pagefile.sys', 'pagefile', 'manual', 3, 'none', '默认保留系统管理；迁移影响提交上限、崩溃转储，并需重启验证。'),
    @('交换文件', 'C:\swapfile.sys', 'swapfile', 'keep', 3, 'none', '系统管理，不直接删除。'),
    @('Windows 临时目录', 'C:\Windows\Temp', 'temp', 'delete', 0, 'allocated-upper-bound', '实际清理跳过近期和被占用文件。'),
    @('Windows 更新目录汇总', 'C:\Windows\SoftwareDistribution', 'windows-update-summary', 'keep', 2, 'none', '由存储感知/磁盘清理处理；更新进行时跳过，不把整个目录大小当可释放量。'),
    @('Windows 更新下载缓存', 'C:\Windows\SoftwareDistribution\Download', 'windows-update', 'system-tool', 2, 'allocated-upper-bound', '仅通过受支持的系统清理流程；更新进行时跳过。'),
    @('旧系统 Windows.old', 'C:\Windows.old', 'upgrade-residue', 'system-tool', 3, 'allocated-upper-bound', '清理后无法回退旧系统，必须独立确认。'),
    @('升级残留 $WINDOWS.~BT', 'C:\$WINDOWS.~BT', 'upgrade-residue', 'system-tool', 3, 'allocated-upper-bound', '使用系统磁盘清理；可能失去升级回退能力。'),
    @('升级残留 $WINDOWS.~WS', 'C:\$WINDOWS.~WS', 'upgrade-residue', 'system-tool', 3, 'allocated-upper-bound', '使用系统工具，不直接删除。'),
    @('升级残留 $WinREAgent', 'C:\$WinREAgent', 'upgrade-residue', 'system-tool', 3, 'allocated-upper-bound', '更新/恢复相关残留，仅评估系统清理。'),
    @('升级日志/残留 Windows10Upgrade', 'C:\Windows10Upgrade', 'upgrade-residue', 'system-tool', 2, 'allocated-upper-bound', '确认升级完成后使用系统工具。'),
    @('传递优化缓存', 'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache', 'delivery-optimization', 'system-tool', 1, 'allocated-upper-bound', '使用存储感知/磁盘清理。'),
    @('传递优化服务缓存', 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache', 'delivery-optimization', 'system-tool', 1, 'allocated-upper-bound', '使用系统工具；不更改服务状态。'),
    @('Windows 搜索索引', 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows', 'search-index', 'system-tool', 2, 'none', '用索引选项调整范围、重建或官方位置设置；重建不能保证长期释放。'),
    @('回收站（所有用户）', 'C:\$Recycle.Bin', 'recycle-bin-summary', 'keep', 3, 'allocated-upper-bound', '永久清空不可恢复，须独立确认；权限不足会保留未知。'),
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
if ($originalSid) {
    $recyclePath = 'C:\$Recycle.Bin\' + $originalSid
    Add-ScanTarget -Name '原用户 C 盘回收站' -LiteralPath $recyclePath -Category 'recycle-bin' `
        -Action system-tool -Risk 3 -HandlerScript 'scripts/clean-system.ps1' -Estimate allocated-upper-bound
    $recycleKey = $recyclePath.ToLowerInvariant()
    if ($script:ScanTargets.ContainsKey($recycleKey)) {
        $script:ScanTargets[$recycleKey] | Add-Member -NotePropertyName OriginalUserOnly -NotePropertyValue $true
    }
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

Add-ScanRegisteredCaches $context
foreach ($folder in @($script:ScanKnownFolders.Keys | Sort-Object)) {
    Add-ScanTarget -Name ('原用户：' + $folder) -LiteralPath $script:ScanKnownFolders[$folder] -Category 'user-files' `
        -Action migrate -Risk 1 -HandlerScript 'scripts/migrate.ps1' -Estimate allocated-upper-bound -Priority 20 `
        -Notes '已解析 Known Folder；用属性→位置迁移，先复制校验并验证独立备份，保留旧源。'
}
Write-Host '正在只读发现原用户大文件、旧安装包、软件清单及磁盘布局…'
$diskLayout = Get-ScanDiskLayout
$storageSenseEnabled = $null
if (-not $Quick) {
    $storageKey = 'Registry::HKEY_USERS\' + $originalSid + '\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    $storageValue = Get-ScanRegistryValue $storageKey '01'
    if ($null -ne $storageValue -and [string]$storageValue -in @('0', '1')) { $storageSenseEnabled = [string]$storageValue -eq '1' }
    else { Add-ScanIssue $storageKey 'StorageSense' '状态缺失或不可读，存储感知状态未知。' }
}
$inventoryRoots = @($script:ScanKnownFolders.Keys | Where-Object { $_ -in @('Downloads', 'Desktop') } | ForEach-Object { $script:ScanKnownFolders[$_] })
$largeFileInventory = [pscustomobject]@{ Status = 'skipped'; EstimatedBytes = $null; Files = @(); Reason = '未启用大文件发现或原用户身份未核实。' }
$installerInventory = [pscustomobject]@{ Status = 'unknown'; EstimatedBytes = $null; Files = @(); Reason = '下载和桌面位置或原用户身份未核实。' }
if ((Get-ScanProperty $context @('OriginalUserVerified') $false) -and
    (Get-ScanProperty $context @('CurrentUserSid') '') -eq $originalSid) {
    if ($LargeFileCount -gt 0) { $largeFileInventory = Get-ScanFileInventory @($script:ScanOriginalProfile) }
    if ($inventoryRoots.Count -gt 0) { $installerInventory = Get-ScanFileInventory $inventoryRoots -Installers }
}
if ($Quick) {
    $installerInventory = [pscustomobject]@{ Status = 'skipped'; EstimatedBytes = $null; Files = @(); Reason = '-Quick 跳过旧安装包发现，大小未知。' }
}
foreach ($file in @($largeFileInventory.Files)) {
    # 同一路径已有更具体建议时保留两种发现证据，键可区分；无自动删除授权。
    $script:ScanExtraEntries.Add((New-ScanInventoryEntry ('large-file:' + $file.Path.ToLowerInvariant()) `
        ('大文件：' + $file.Path) 'large-file' $file.Path $file.LogicalBytes $file))
}
if (@($installerInventory.Files).Count -gt 0) {
    $topFiles = @($installerInventory.Files | Select-Object -First 20)
    $details = [pscustomobject]@{ Paths = $inventoryRoots; Files = $topFiles; FileCount = @($installerInventory.Files).Count
        SizeKind = 'logical'; KnownLowerBoundBytes = Get-ScanProperty $installerInventory @('KnownLowerBoundBytes') }
    $entry = New-ScanInventoryEntry 'inventory:old-installers' '旧安装包和归档（先逐个审阅）' 'old-installers' `
        $inventoryRoots[0] $installerInventory.EstimatedBytes $details
    $entry.Status = $installerInventory.Status
    if ($entry.Status -eq 'partial') { $entry.KnownLogicalBytes = $details.KnownLowerBoundBytes; $entry.KnownSizeKind = 'lower-bound' }
    $script:ScanExtraEntries.Add($entry)
}
$softwareInventory = Get-ScanInstalledSoftware $originalSid
foreach ($application in @($softwareInventory.Items | Where-Object { $null -ne $_.EstimatedBytes -and $_.EstimatedBytes -ge 500MB } | Select-Object -First 20)) {
    $entry = New-ScanInventoryEntry ('software:' + $application.RegistryKey) ('已安装软件：' + $application.Name) `
        'installed-software' $application.Path $application.EstimatedBytes $application
    $entry.LogicalBytes = $null; $entry.KnownLogicalBytes = $null
    $entry.Notes = '大小为厂商 EstimatedSize（KB）报告，非实测；位置未声明的项目不能确认在 C:。Program Files 绝不能靠复制移动。'
    $script:ScanExtraEntries.Add($entry)
}
$script:ScanExtraEntries.Add((New-ScanInventoryEntry 'system:reserved-storage' 'Windows 保留存储（默认保留）' `
    'reserved-storage' 'C:\' $null $null))

Write-Host '正在读取大小；完整扫描可能较慢，-Quick 可跳过目录递归统计。'
foreach ($entry in @($script:ScanTargets.psbase.Values | Sort-Object Path)) {
    Write-Verbose ('统计：' + $entry.Path)
    if ($entry.Category -eq 'component-store') { Set-ScanComponentStore $entry $isAdmin }
    elseif ($entry.Category -eq 'shadowstorage') { Set-ScanShadowStorage $entry $isAdmin }
    else { Measure-ScanEntry $entry }
}
# 各条目独立展示，明确标注父子重叠；不生成会重复计数的“总可释放量”。
$entries = @($script:ScanTargets.psbase.Values) + @($script:ScanExtraEntries.ToArray())
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
    if (-not (Get-ScanProperty $entry @('EntryKey'))) {
        $entry | Add-Member -NotePropertyName EntryKey -NotePropertyValue $entry.Path.TrimEnd('\').ToLowerInvariant()
    }
    if ($entry.Action -eq 'migrate') {
        $entry | Add-Member -NotePropertyName MigrationWhatIf -NotePropertyValue (Get-ScanMigrationWhatIf $entry $context) -Force
    }
    $recommendation = Get-ScanRecommendation $entry $context
    $entry.Action = $recommendation.Action; $entry.HandlerScript = $recommendation.HandlerScript
    $entry.HandlerParameters = $recommendation.HandlerParameters; $entry.ExecutionCommand = $recommendation.ExecutionCommand
    $entry.Notes = $recommendation.Notes
    $entry | Add-Member -NotePropertyName SafetyBlocked -NotePropertyValue $recommendation.SafetyBlocked -Force
    $classification = Get-ScanDisposition $entry
    foreach ($field in @('Disposition', 'Impact', 'ManualReason', 'ManualSteps', 'DefaultSelected', 'Irreversible')) {
        $entry | Add-Member -NotePropertyName $field -NotePropertyValue $classification.$field -Force
    }
    if ($entry.Disposition -ne 'ai') {
        $entry.HandlerScript = ''; $entry.HandlerParameters = @{}; $entry.ExecutionCommand = $null
    }
}
$confirmationItems = @(Get-ScanConfirmationItems $entries)
$manualItems = @(Get-ScanManualItems $entries)
$folderEvidence = @($entries | Where-Object { $_.Category -eq 'user-files' -and $_.Path -in @($script:ScanKnownFolders.Values) -and
    -not $_.ExcludedFromLocalTotals -and -not $_.SafetyBlocked -and $_.Status -ne 'reparse-point' })
$developmentEvidence = @($entries | Where-Object { $_.Category -match 'developer-cache|configured-development|^wsl|vhdx|vdisk|^docker-data$' -and
    -not $_.ExcludedFromLocalTotals -and -not $_.SafetyBlocked -and $_.Status -ne 'reparse-point' })
$folderAggregate = Get-ScanSizeAggregate $folderEvidence 'AllocatedBytes' 'KnownAllocatedBytes'
$developmentAggregate = Get-ScanSizeAggregate $developmentEvidence 'AllocatedBytes' 'KnownAllocatedBytes'
$verifiedSoftwareBytes = [long]0
foreach ($application in @($softwareInventory.Items | Where-Object { $_.LocationVerified -and $null -ne $_.EstimatedBytes })) {
    $verifiedSoftwareBytes += $application.EstimatedBytes
}
$hibernation = @($entries | Where-Object { $_.Category -eq 'hibernation' -and $_.Status -ne 'not-found' -and -not $_.SafetyBlocked })
$advisoryEvidence = [pscustomobject]@{
    UserFolderBytes = if ($null -ne $folderAggregate.TotalBytes -or $folderAggregate.KnownLowerBoundBytes -gt 0) { $folderAggregate.KnownLowerBoundBytes } else { $null }
    DevelopmentBytes = if ($null -ne $developmentAggregate.TotalBytes -or $developmentAggregate.KnownLowerBoundBytes -gt 0) { $developmentAggregate.KnownLowerBoundBytes } else { $null }
    InstalledSoftwareBytes = if ($softwareInventory.Status -eq 'ok' -or $verifiedSoftwareBytes -gt 0) { $verifiedSoftwareBytes } else { $null }
    HibernationBytes = if ($hibernation.Count -gt 0) { Get-ScanProperty $hibernation[0] @('AllocatedBytes', 'LogicalBytes') (Get-ScanProperty (Get-ScanProperty $hibernation[0] @('Metadata')) @('Length')) } else { $null } }
$advisory = @(Get-ScanAdvisory $baseline $diskLayout $storageSenseEnabled $advisoryEvidence)

$sortedEntries = @($entries | Sort-Object -Property @(
    @{ Expression = { if ($null -eq $_.EstimatedReclaimableBytes) { -1.0 } else { [double]$_.EstimatedReclaimableBytes } }; Descending = $true },
    @{ Expression = { $_.Path }; Descending = $false }
))
$publicEntries = @($sortedEntries | Select-Object EntryKey, Name, Path, Category, LogicalBytes, AllocatedBytes, KnownLogicalBytes, KnownAllocatedBytes, KnownSizeKind, EstimatedReclaimableBytes,
    EstimateKind, Action, Risk, HandlerScript, HandlerParameters, ExecutionCommand, Status, Notes, Skipped, ReparsePoints, ExcludedFromLocalTotals, OverlapsOtherEntries, Details, Disposition, Impact, ManualReason, ManualSteps, DefaultSelected, Irreversible)
$report = [ordered]@{
    SchemaVersion = 3; StartedAtUtc = $startedAt.ToString('o'); CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
    ComputerName = $env:COMPUTERNAME; Quick = [bool]$Quick; WhatIf = [bool]$WhatIfPreference
    Context = [ordered]@{ OriginalUserSid = $originalSid; OriginalUserProfile = $script:ScanOriginalProfile; IsAdmin = $isAdmin; PowerShellVersion = $PSVersionTable.PSVersion.ToString() }
    Baseline = $baseline; SizeUnit = 'bytes'; UnknownValue = $null
    AccountingNotes = @(
        '目录汇总、子目录、文件条目存在重叠；不能相加，不提供重复计数的总可释放量。',
        'upper-bound 是成功清理/迁移后可能释放的上限；近期、占用文件、备份、硬链接与系统策略会减少实际释放。',
        '拒绝访问/长路径/解析失败/Quick 跳过的值为 null；partial 的 KnownLogicalBytes/KnownAllocatedBytes 只是已知下限，KnownSizeKind 为 lower-bound，总量和可释放量仍为 null。',
        '按 EstimatedReclaimableBytes 降序排列，未知排在末尾；已知下限不当作可释放量参与排序。',
        'ExecutionCommand/HandlerParameters 只列出覆盖该路径的清理选择器；同一 Category/Action 可能处理多个条目，仍须满足身份、白名单、进程和更新状态检查。manual/migrate 条目按 Notes 人工操作。',
        'ConfirmationItems 仅在同一执行选择器内去除父子重复，组间仍可能重叠，不能把所有确认项总量相加；KnownLowerBoundBytes 仅为已知大小下限，不是保证收益。',
        'ManualItems/Inventories 的逻辑大小和厂商报告大小用于人工判断，不代表可释放量；Quick 跳过清单时总量仍为 null。',
        'DefaultSelected 仅用于展示；所有动作仍须演练后明确确认，不可逆项必须由用户明确点名编号。',
        'OneDrive 根目录不递归计量且不计本地清理量；云占位不等于本地大小，已下载数据可由客户端释放空间。',
        'WinSxS 使用 DISM 数据；DISM 通常只报告候选组件和包数，估算上限不代表精确可回收量。',
        '扫描只发现默认位置、可访问的注册表和已知配置；不加载其他用户 hive，未知自定义位置可能遗漏。'
    )
    ConfirmationItems = $confirmationItems; ManualItems = $manualItems; Advisory = $advisory
    DiskLayout = $diskLayout; StorageSenseEnabled = $storageSenseEnabled
    Inventories = [ordered]@{ LargeFiles = $largeFileInventory; OldInstallers = $installerInventory; InstalledSoftware = $softwareInventory }
    AdvisoryEvidence = $advisoryEvidence
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

Write-Host "`nA. 只需确认（AI 执行）"
$confirmationRows = @($confirmationItems | Select-Object -First $Top | ForEach-Object {
    [pscustomobject]@{ Id = $_.Id; '选择方式' = if ($_.DefaultSelected) { '默认选中' } else { '需单独点名' }
        '项目' = $_.Title; '预计释放' = Format-ScanBytes $_.EstimatedReclaimableBytes; '影响' = $_.Impact.Summary
        '风险' = @{ low = '低'; medium = '中'; high = '高' }[$_.Impact.RiskLevel]; '需关闭的程序' = ($_.Impact.RequiresClosedApps -join '、')
        '需管理员' = if ($_.RequiresAdmin) { '是' } else { '否' }; '需重启' = if ($_.Impact.RequiresRestart) { '是' } else { '否' } }
})
Write-Host ($confirmationRows | Format-Table -Wrap | Out-String -Width 300)
Write-Host '默认选中不代表已授权；先按编号展示完整作用范围并演练，明确确认后才能执行；需单独点名的项目必须逐项确认。'
Write-Host "`nB. 需要你一步步操作"
foreach ($item in @($manualItems | Select-Object -First $Top)) {
    Write-Host ('{0}. {1}；大小 {2}' -f $item.Id, $item.Title, (Format-ScanBytes $item.EstimatedBytes))
    Write-Host ('原因：' + $item.Reason)
    if ($item.Paths.Count -gt 0) { Write-Host ('路径：' + ($item.Paths -join '；')) }
    foreach ($step in $item.Steps) { Write-Host ('  ' + $step) }
}
Write-Host "`nC. 长期规划建议"
foreach ($item in @($advisory | Select-Object -First $Top)) {
    Write-Host ('[{0}] {1}：{2}' -f @{ info = '建议'; warn = '注意'; critical = '紧急' }[$item.Severity], $item.Title, $item.Detail)
    $stepNumber = 0
    foreach ($step in $item.Steps) { $stepNumber++; Write-Host ('  {0}. {1}' -f $stepNumber, $step) }
}
if ($confirmationItems.Count -gt $Top -or $manualItems.Count -gt $Top -or $advisory.Count -gt $Top) {
    Write-Host ('每区最多显示 {0} 项；JSON 保留全部项目。' -f $Top)
}

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

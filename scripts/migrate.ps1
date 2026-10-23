<#
.SYNOPSIS
安全地把用户数据、开发缓存或 WSL 迁移到本地 NTFS 数据盘。
.DESCRIPTION
顺序为目标盘检查、关闭相关程序、复制、校验、切换。源数据始终保留。
复制使用 robocopy /E /COPY:DAT /R:1 /W:1 /XJ；目标必须为空，不镜像删除。
目标权限继承其父目录，不复制源 ACL；复制聊天文件或个人工具配置前请核对访问权限。
复制和校验全程锁住源、目标根及祖先，防止根目录被替换；robocopy 仍按路径访问
子项，不能完全排除其他进程在复制期间替换子项的竞争，须关闭相关程序并限制目录写权限。
兼容 Windows PowerShell 5.1 和 PowerShell 7。
用户文件夹和聊天软件只提供官方界面的切换指引，不直接改注册表。
WSL 导出后以新名称导入；绝不执行 unregister。联接仅作为最后手段，
源目录改名保留，逐步记录 JSON 清单；回滚只移除联接并恢复保留目录的名称。
所有路径安全判断、白名单和审计均委托 common.ps1。共享库须支持迁移类别、
不存在的安全目标和非系统卷；不具备这些能力时本脚本拒绝执行，不绕过检查。
拒绝访问、重解析点、
文件变化、复制失败或校验不一致都会阻止切换。-WhatIf 不运行外部程序、
不探测写入、不写配置、日志或清单。请先在 Windows 虚拟机验证。
.PARAMETER Item
UserFolder、DevCache、AppData、WSL 或 Junction。与 -Rollback 互斥。
.PARAMETER Destination
迁移目标的完整路径，须在非系统盘的本地固定 NTFS 卷上。
普通迁移须为不存在或为空的目录；WSL 使用此目录存放归档和新发行版。
.PARAMETER Folder
UserFolder 的 Desktop、Documents、Downloads、Pictures 或 Videos。
.PARAMETER Cache
DevCache 的 npm、pip、gradle、maven 或 conda；Junction 也须指定缓存类型。
Gradle 的目标是 GRADLE_USER_HOME，Maven 的目标是本地 repository。
.PARAMETER App
AppData 的 WeChat 或 QQ，只复制共享白名单允许的文件数据目录。
.PARAMETER Source
旧数据的完整路径。AppData 和 Junction 必填；DevCache 复制旧缓存时必填，
应先从工具自身查询真实路径。UserFolder 使用 Known Folder，不接受此参数。
.PARAMETER CopyExisting
DevCache 在修改配置前复制、校验 -Source；不指定时只修改配置。
其他文件夹迁移始终复制旧数据。Gradle 建议复制旧用户目录以保留个人配置。
.PARAMETER Distro
WSL 旧发行版的准确名称。
.PARAMETER NewDistroName
WSL 新发行版名称，默认旧名称加 -Migrated，绝不能与旧名称相同。
.PARAMETER ManifestPath
联接 JSON 清单路径；默认与共享日志同目录的 junctions.json。
只接受共享白名单认可的清单路径。
.PARAMETER Rollback
按清单回滚联接。可用 -Source 选择其中一项，否则处理所有未回滚记录。
仅删除已核实的 NTFS 联接本身，不递归删除、不删除目标或保留的旧数据。
.PARAMETER VerifyHash
普通复制逐文件验证 SHA-256。WSL 额外校验导出前后稳定文件集合的摘要；
运行时目录不参与 WSL 文件集合比较，仍须人工确认业务数据及默认用户。
.NOTES
共享 Test-SafeTarget 所需类别：
UserFolder（当前 Known Folder）、DevCacheMigration（包括仅迁移用的 .gradle 用户目录及
.m2\repository）、AppData（具体应用文件目录）、WSL（注册的发行版数据目录）、
Junction（明确可再生的缓存根）、MigrationDestination（数据卷的明确目标）、
DevCacheConfig（原用户配置及其备份/临时文件和必要父目录）、
MigrationManifest（审计目录内的清单/临时文件/锁及必要父目录）、
JunctionBackup（Junction 根后缀 .cdrive-retained-<32位ID>）、
JunctionParent（对应缓存根的准确父目录）。
后两项须由共享缓存白名单派生，不能泛化为整个 AppData 的操作授权。
普通源必须存在；允许目标、配置、清单和备份的缺失叶节点，但每级已存在父路径
仍须通过共享检查。迁移类别只授权本脚本的用途，不授权 Remove-SafeItem 删除。
.EXAMPLE
.\migrate.ps1 -Item UserFolder -Folder Downloads -Destination 'D:\Users\Downloads' -WhatIf
演练下载目录复制；完成真实复制后按提示在“属性 → 位置”中切换。
.EXAMPLE
.\migrate.ps1 -Item DevCache -Cache npm -Source 'C:\Users\me\AppData\Local\npm-cache' -Destination 'D:\Caches\npm' -CopyExisting -VerifyHash
复制旧 npm 缓存并将用户级 cache 配置指向新目录。
.EXAMPLE
.\migrate.ps1 -Item AppData -App WeChat -Source 'C:\Users\me\Documents\WeChat Files' -Destination 'D:\Chat\WeChat'
复制白名单内的微信文件数据，再按软件设置指引切换路径。
.EXAMPLE
.\migrate.ps1 -Item WSL -Distro Ubuntu -NewDistroName Ubuntu-D -Destination 'D:\WSL'
保留旧发行版和导出归档，以新名称导入并验证。
.EXAMPLE
.\migrate.ps1 -Item Junction -Cache pip -Source 'C:\Users\me\AppData\Local\pip\Cache' -Destination 'D:\Caches\pip'
复制校验后把原缓存改名保留，再创建联接并登记清单。
.EXAMPLE
.\migrate.ps1 -Rollback -ManifestPath 'D:\CleanerLogs\junctions.json' -WhatIf
演练联接回滚；实际操作只移除联接，再恢复原目录名称。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Migrate')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Migrate')]
    [ValidateSet('UserFolder', 'DevCache', 'AppData', 'WSL', 'Junction')]
    [string]$Item,

    [Parameter(Mandatory = $true, ParameterSetName = 'Migrate')]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Migrate')]
    [ValidateSet('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos')]
    [string]$Folder,

    [Parameter(ParameterSetName = 'Migrate')]
    [ValidateSet('npm', 'pip', 'gradle', 'maven', 'conda')]
    [string]$Cache,

    [Parameter(ParameterSetName = 'Migrate')]
    [ValidateSet('WeChat', 'QQ')]
    [string]$App,

    [string]$Source,

    [Parameter(ParameterSetName = 'Migrate')]
    [switch]$CopyExisting,

    [Parameter(ParameterSetName = 'Migrate')]
    [string]$Distro,

    [Parameter(ParameterSetName = 'Migrate')]
    [string]$NewDistroName,

    [string]$ManifestPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch]$Rollback,

    [Parameter(ParameterSetName = 'Migrate')]
    [switch]$VerifyHash
)

Set-StrictMode -Version 2.0
if ($env:OS -ne 'Windows_NT') { throw '此脚本只能在 Windows 上运行。' }
. (Join-Path $PSScriptRoot "common.ps1")

$ErrorActionPreference = 'Stop'
$script:MigrationCmdlet = $PSCmdlet
$script:MigrationContext = Get-CleanerContext
$script:MigrationWroteState = $false

function Get-MigrationValue {
    param($Object, [string[]]$Names, $Default = $null)
    foreach ($name in $Names) {
        if ($null -eq $Object) { break }
        if ($Object -is [hashtable]) {
            if ($Object.ContainsKey($name)) { return $Object[$name] }
        }
        elseif ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($name)) { return $Object[$name] }
        }
        else {
            $property = $Object.PSObject.Properties[$name]
            if ($null -ne $property) { return $property.Value }
        }
    }
    return $Default
}

$script:MigrationProfile = [string](Get-MigrationValue $script:MigrationContext @('OriginalUserProfile', 'UserProfile', 'UserProfilePath', 'OriginalProfilePath'))
$script:MigrationSid = [string](Get-MigrationValue $script:MigrationContext @('OriginalUserSid', 'OriginalUserSID', 'UserSid', 'UserSID', 'Sid'))
$script:MigrationLog = [string](Get-MigrationValue $script:MigrationContext @('LogPath', 'LogFilePath'))
if ([string]::IsNullOrWhiteSpace($script:MigrationProfile) -or [string]::IsNullOrWhiteSpace($script:MigrationSid)) {
    throw '共享上下文必须提供原用户 SID 和目录，禁止推断管理员账户的用户目录。'
}
$currentMigrationIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if ($currentMigrationIdentity.User.Value -ne $script:MigrationSid) {
        throw '当前账户与原用户 SID 不一致；请回到原用户会话执行迁移。不要使用另一个管理员账户。'
    }
}
finally { $currentMigrationIdentity.Dispose() }

function Get-MigrationFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:\\') {
        throw ('必须使用本地盘符的完整路径：{0}' -f $Path)
    }
    if ($Path.Substring(2).Contains(':')) { throw '不允许 NTFS 备用数据流路径。' }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -match '^[A-Za-z]:$') { throw '不允许把磁盘根目录作为迁移路径。' }
    return $full
}

function Assert-MigrationTarget {
    param([string]$Path, [string]$Category)
    # 不在本脚本定义白名单，不自行遍历、放行重解析点。
    $result = Test-SafeTarget -LiteralPath $Path -Category $Category -ErrorAction Stop
    $allowed = $false
    if ($result -is [bool]) { $allowed = $result }
    else { $allowed = (Get-MigrationValue $result @('IsSafe', 'Safe', 'Allowed', 'Success', 'IsValid') $false) -eq $true }
    if (-not $allowed) {
        $reason = Get-MigrationValue $result @('Reason', 'Message') '共享白名单或重解析点校验未通过'
        throw ('拒绝 {0} [{1}]：{2}' -f $Path, $Category, $reason)
    }
}

function Write-MigrationAudit {
    param([string]$Action, [string]$Path, [string]$Result, [long]$Bytes = 0)
    if ($WhatIfPreference) { return }
    if ($script:MigrationCmdlet.ShouldProcess($script:MigrationLog, '写入迁移审计日志')) {
        Write-CleanerLog -Action $Action -Path $Path -Result $Result -Bytes $Bytes -Confirm:$false -ErrorAction Stop
    }
}

function Assert-MigrationProcesses {
    param([string[]]$Names)
    if ($null -eq $Names -or $Names.Count -eq 0) { return }
    $running = @(Get-Process -ErrorAction Stop | Where-Object { $Names -contains $_.ProcessName })
    if ($running.Count -gt 0) {
        $details = ($running | ForEach-Object { '{0}({1})' -f $_.ProcessName, $_.Id }) -join ', '
        throw ('请完全退出相关程序后重试；脚本不会强制终止进程：' + $details)
    }
}

function Get-MigrationProcessNames {
    param([string]$Kind, [string]$Name)
    if ($Kind -eq 'AppData') {
        if ($Name -eq 'WeChat') { return @('WeChat', 'Weixin', 'WeChatAppEx', 'WeChatPlayer') }
        return @('QQ', 'QQNT', 'QQProtect', 'TIM')
    }
    switch ($Name) {
        'npm' { return @('node', 'npm', 'npx') }
        'pip' { return @('python', 'pythonw', 'pip', 'pip3') }
        'gradle' { return @('java', 'javaw', 'gradle') }
        'maven' { return @('java', 'javaw', 'mvn', 'mvnw') }
        'conda' { return @('conda', '_conda', 'python', 'pythonw', 'mamba', 'micromamba') }
    }
    return @()
}

function Assert-MigrationSeparation {
    param([string]$OldPath, [string]$NewPath)
    $old = $OldPath.TrimEnd('\')
    $new = $NewPath.TrimEnd('\')
    if ($old.Equals($new, [System.StringComparison]::OrdinalIgnoreCase) -or
        $old.StartsWith($new + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        $new.StartsWith($old + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '源与目标必须分离，不能相同或互为父子目录。'
    }
    if ($old.Substring(0, 2) -ieq $new.Substring(0, 2)) {
        throw '迁移目标必须位于另一个本地数据卷。'
    }
}

function Get-MigrationInventory {
    param([string]$Path, [string]$Category, [switch]$Hash)
    Assert-MigrationTarget $Path $Category
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw ('目录不存在：' + $Path) }
    # 共享大小统计用于报告未知/跳过项；未知不当作零，不进行不完整迁移。
    $size = Get-DirectorySize -LiteralPath $Path -ErrorAction Stop
    if ((Get-MigrationValue $size @('IsComplete') $true) -eq $false -or
        [long](Get-MigrationValue $size @('SkippedCount') 0) -gt 0) {
        throw ('共享大小统计不完整，停止迁移：' + $Path)
    }
    foreach ($field in @('SkippedItems', 'Skipped', 'Errors', 'ReparsePoints', 'UnknownItems')) {
        $unknown = @(Get-MigrationValue $size @($field) @())
        if ($unknown.Count -gt 0 -and $null -ne $unknown[0]) {
            throw ('共享扫描报告跳过项或未知数据，停止迁移：{0}；字段 {1}' -f $Path, $field)
        }
    }
    $files = @{}
    $directories = @{}
    $queue = New-Object 'System.Collections.Generic.Stack[string]'
    $queue.Push($Path)
    [long]$bytes = 0
    while ($queue.Count -gt 0) {
        $directory = $queue.Pop()
        Assert-MigrationTarget $directory $Category
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            Assert-MigrationTarget $entry.FullName $Category
            $relative = $entry.FullName.Substring($Path.TrimEnd('\').Length + 1)
            if ($entry.PSIsContainer) {
                $directories[$relative] = $true
                $queue.Push($entry.FullName)
                continue
            }
            $digest = $null
            if ($Hash) { $digest = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
            $files[$relative] = [pscustomobject]@{
                Length = [long]$entry.Length
                WriteTicks = [long]$entry.LastWriteTimeUtc.Ticks
                Hash = $digest
            }
            $bytes += [long]$entry.Length
        }
    }
    $sharedCount = Get-MigrationValue $size @('FileCount')
    $sharedBytes = Get-MigrationValue $size @('LogicalBytes')
    if (($null -ne $sharedCount -and [long]$sharedCount -ne $files.psbase.Count) -or
        ($null -ne $sharedBytes -and [long]$sharedBytes -ne $bytes)) {
        throw ('枚举期间目录发生变化或统计不一致，停止迁移：' + $Path)
    }
    return [pscustomobject]@{ Path = $Path; FileCount = [long]$files.psbase.Count; Bytes = $bytes; Files = $files; Directories = $directories }
}

function Assert-MigrationInventoryMatch {
    param($Expected, $Actual, [switch]$CheckTime, [switch]$Hash)
    if ($Expected.FileCount -ne $Actual.FileCount -or $Expected.Bytes -ne $Actual.Bytes -or
        $Expected.Directories.psbase.Count -ne $Actual.Directories.psbase.Count) {
        throw ('校验失败：文件数/总大小/目录数不同。源 {0} 文件、{1} 字节；另一侧 {2} 文件、{3} 字节。' -f
            $Expected.FileCount, $Expected.Bytes, $Actual.FileCount, $Actual.Bytes)
    }
    foreach ($relative in $Expected.Directories.psbase.Keys) {
        if (-not $Actual.Directories.ContainsKey($relative)) { throw ('缺少目录：' + $relative) }
    }
    foreach ($relative in $Expected.Files.psbase.Keys) {
        if (-not $Actual.Files.ContainsKey($relative)) { throw ('缺少文件：' + $relative) }
        $left = $Expected.Files[$relative]
        $right = $Actual.Files[$relative]
        if ($left.Length -ne $right.Length) { throw ('文件长度不一致：' + $relative) }
        if ($CheckTime -and $left.WriteTicks -ne $right.WriteTicks) { throw ('复制期间源文件发生变化：' + $relative) }
        if ($Hash -and $left.Hash -ne $right.Hash) { throw ('SHA-256 不一致：' + $relative) }
    }
}

function Assert-MigrationVolume {
    param([string]$Path, [long]$RequiredBytes)
    Assert-MigrationTarget $Path 'MigrationDestination'
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ($root.TrimEnd('\') -ieq $env:SystemDrive) { throw '目标不能位于 Windows 系统盘。' }
    $drive = New-Object System.IO.DriveInfo -ArgumentList $root
    if (-not $drive.IsReady -or $drive.DriveType -ne [System.IO.DriveType]::Fixed -or $drive.DriveFormat -ine 'NTFS') {
        throw '目标必须是已就绪的本地固定 NTFS 卷；不接受网络盘、可移动盘或其他文件系统。'
    }
    [long]$margin = [Math]::Max(268435456, [Math]::Ceiling($RequiredBytes * 0.05))
    if ($drive.AvailableFreeSpace -lt ($RequiredBytes + $margin)) {
        throw ('目标空间不足：需 {0} 字节及 {1} 字节余量，可用 {2} 字节。' -f $RequiredBytes, $margin, $drive.AvailableFreeSpace)
    }
    Write-Host ('目标卷 {0}：NTFS，本地固定磁盘，可用 {1:N2} GiB；预计写入 {2:N2} GiB。' -f
        $root, ($drive.AvailableFreeSpace / 1GB), ($RequiredBytes / 1GB))
}

function Test-MigrationEmptyDestination {
    param([string]$Path)
    Assert-MigrationTarget $Path 'MigrationDestination'
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw ('目标不是目录：' + $Path) }
        if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop).Count -ne 0) {
            throw '目标目录非空；请使用新的空目录，避免覆盖任何现有文件。中断后的副本也保留供人工检查。'
        }
    }
}

function Test-MigrationWritable {
    param([string]$Path)
    $parent = $Path
    while (-not (Test-Path -LiteralPath $parent)) { $parent = [System.IO.Path]::GetDirectoryName($parent) }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw '目标父路径不是目录。' }
    $probe = Join-Path $parent ('.cdrive-write-test-' + [guid]::NewGuid().ToString('N'))
    Assert-MigrationTarget $probe 'MigrationDestination'
    if (-not $script:MigrationCmdlet.ShouldProcess($probe, '创建并移除临时文件，检查目标卷写权限')) { return $false }
    Assert-MigrationTarget $probe 'MigrationDestination'
    $script:MigrationWroteState = $true
    $stream = $null
    try {
        # .NET 路径参数均为字面值；CreateNew 不覆盖已有文件。
        $stream = New-Object System.IO.FileStream -ArgumentList @($probe, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.WriteByte(0)
        $stream.Flush()
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
            Assert-MigrationTarget $probe 'MigrationDestination'
            [System.IO.File]::Delete($probe)
        }
    }
    return $true
}

function New-MigrationDirectory {
    param([string]$Path, [string]$Category = 'MigrationDestination')
    Assert-MigrationTarget $Path $Category
    if (Test-Path -LiteralPath $Path -PathType Container) { return $true }
    if (-not $script:MigrationCmdlet.ShouldProcess($Path, '创建迁移目录')) { return $false }
    Assert-MigrationTarget $Path $Category
    $script:MigrationWroteState = $true
    $null = [System.IO.Directory]::CreateDirectory($Path)
    return $true
}

function Invoke-MigrationCopy {
    param([string]$OldPath, [string]$NewPath, [string]$Category, [string[]]$Processes)
    $before = Get-MigrationInventory $OldPath $Category -Hash:$VerifyHash
    Assert-MigrationVolume $NewPath $before.Bytes
    Test-MigrationEmptyDestination $NewPath
    Assert-MigrationProcesses $Processes
    Write-Host ('计划复制 {0} 个文件、{1:N0} 字节；源目录保留：{2}' -f $before.FileCount, $before.Bytes, $OldPath)
    if ($WhatIfPreference) {
        $null = $script:MigrationCmdlet.ShouldProcess($NewPath, '探测写权限并创建空目录')
        $null = $script:MigrationCmdlet.ShouldProcess($NewPath, 'robocopy 复制并校验文件数/大小；可选 SHA-256；任何失败均不切换')
        return [pscustomobject]@{ Status = 'WhatIf'; Inventory = $before }
    }
    $robocopyPath = Join-Path ([Environment]::SystemDirectory) 'robocopy.exe'
    if (-not (Test-Path -LiteralPath $robocopyPath -PathType Leaf)) { throw '找不到系统 robocopy.exe。' }
    if (-not (Test-MigrationWritable $NewPath)) { return [pscustomobject]@{ Status = 'Declined' } }
    if (-not (New-MigrationDirectory $NewPath)) { return [pscustomobject]@{ Status = 'Declined' } }
    if (-not $script:MigrationCmdlet.ShouldProcess($NewPath, ('从 {0} 复制，禁止镜像/移动/清除目标' -f $OldPath))) {
        return [pscustomobject]@{ Status = 'Declined' }
    }
    $sourceGuards = $null
    $destinationGuards = $null
    try {
        # 共享函数只打开父级。使用从不创建的虚拟子路径，把根本身也纳入
        # OPEN_REPARSE_POINT 且不共享 DELETE 的句柄链；任一级获取失败即停止复制。
        $sourceGuards = Open-CleanerParentGuards -LiteralPath ([System.IO.Path]::Combine($OldPath, '.cdrive-copy-guard'))
        $destinationGuards = Open-CleanerParentGuards -LiteralPath ([System.IO.Path]::Combine($NewPath, '.cdrive-copy-guard'))
        Assert-MigrationTarget $OldPath $Category
        Assert-MigrationTarget $NewPath 'MigrationDestination'
        Test-MigrationEmptyDestination $NewPath
        Assert-MigrationProcesses $Processes
        $script:MigrationWroteState = $true
        # robocopy 的 0..7 是成功/差异状态；仍须后续校验，不能只凭退出码切换。
        # /XJ 不锁定子项；根及祖先的句柄不能消除子项被并发替换的残余风险。
        $arguments = @($OldPath, $NewPath, '/E', '/COPY:DAT', '/R:1', '/W:1', '/XJ')
        $copyResult = Invoke-External -FilePath $robocopyPath -ArgumentList $arguments -Description '复制迁移数据，保留源和目标额外数据' -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -Confirm:$false -ErrorAction Stop
        $copyExit = Get-MigrationValue $copyResult @('ExitCode')
        Write-Host (Get-MigrationExternalText $copyResult)
        if ($null -eq $copyExit -or $copyExit -lt 0 -or $copyExit -ge 8) {
            throw ('robocopy 失败，退出码 {0}；保留两侧数据，不切换路径。' -f $copyExit)
        }
        # 复制后仍持有全部句柄，重新由共享库核对目标根及每级祖先的重解析点。
        Assert-MigrationTarget $NewPath 'MigrationDestination'
        Assert-MigrationProcesses $Processes
        $after = Get-MigrationInventory $OldPath $Category -Hash:$VerifyHash
        $target = Get-MigrationInventory $NewPath 'MigrationDestination' -Hash:$VerifyHash
        Assert-MigrationInventoryMatch $before $after -CheckTime -Hash:$VerifyHash
        Assert-MigrationInventoryMatch $after $target -Hash:$VerifyHash
        Assert-MigrationTarget $NewPath 'MigrationDestination'
        Write-MigrationAudit 'MigrationCopyVerified' $NewPath ('成功；源保留；文件数 ' + $target.FileCount) 0
        return [pscustomobject]@{ Status = 'Verified'; Inventory = $after }
    }
    finally {
        if ($null -ne $destinationGuards) { foreach ($guard in $destinationGuards.Handles) { $guard.Dispose() } }
        if ($null -ne $sourceGuards) { foreach ($guard in $sourceGuards.Handles) { $guard.Dispose() } }
    }
}

function Get-MigrationKnownFolderNativeType {
    $native = 'CDriveCleaner.MigrationShellV1' -as [type]
    if ($null -ne $native) { return $native }
    # Reflection.Emit 只在内存声明官方 Shell API；5.1 下也不生成编译临时文件。
    $assemblyName = New-Object System.Reflection.AssemblyName -ArgumentList 'CDriveCleaner.MigrationShellV1'
    if ($null -ne [Reflection.Emit.AssemblyBuilder].GetMethod('DefineDynamicAssembly', [type[]]@([Reflection.AssemblyName], [Reflection.Emit.AssemblyBuilderAccess]))) {
        $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($assemblyName, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    }
    else { $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly($assemblyName, [Reflection.Emit.AssemblyBuilderAccess]::Run) }
    $module = $assembly.DefineDynamicModule('Shell')
    $builder = $module.DefineType('CDriveCleaner.MigrationShellV1', [Reflection.TypeAttributes]'Public, Abstract, Sealed')
    $parameters = [type[]]@([guid].MakeByRefType(), [uint32], [IntPtr], [IntPtr].MakeByRefType())
    $method = $builder.DefineMethod('SHGetKnownFolderPath', [Reflection.MethodAttributes]'Public, Static, PinvokeImpl', [int], $parameters)
    $attributeType = [Runtime.InteropServices.DllImportAttribute]
    $constructor = $attributeType.GetConstructor([type[]]@([string]))
    $fields = [Reflection.FieldInfo[]]@($attributeType.GetField('EntryPoint'), $attributeType.GetField('ExactSpelling'))
    $values = [object[]]@('SHGetKnownFolderPath', $true)
    $attribute = [Reflection.Emit.CustomAttributeBuilder]::new($constructor, [object[]]@('shell32.dll'), $fields, $values)
    $method.SetCustomAttribute($attribute)
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    return $builder.CreateType()
}

function Get-MigrationKnownFolder {
    param([string]$Name)
    # GUID 是 Windows 官方 Known Folder 标识，不使用用户目录的固定名称推测位置。
    $id = [guid]::Empty
    switch ($Name) {
        'Desktop' { $id = [guid]'B4BFCC3A-DB2C-424C-B029-7FE99A87C641' }
        'Documents' { $id = [guid]'FDD39AD0-238F-46AF-ADB4-6C85480369C7' }
        'Downloads' { $id = [guid]'374DE290-123F-4565-9164-39C4925E467B' }
        'Pictures' { $id = [guid]'33E28130-4E1E-4676-835A-98395C3BC3BB' }
        'Videos' { $id = [guid]'18989B1D-99B5-455B-841C-AB7C74E4DDFC' }
        default { throw '未指定用户文件夹。' }
    }
    $native = Get-MigrationKnownFolderNativeType
    $pointer = [IntPtr]::Zero
    try {
        # flags=0 不请求创建文件夹；token=0 仅当前已核实的原用户。
        $result = $native::SHGetKnownFolderPath([ref]$id, [uint32]0, [IntPtr]::Zero, [ref]$pointer)
        if ($result -lt 0) { [Runtime.InteropServices.Marshal]::ThrowExceptionForHR($result) }
        if ($pointer -eq [IntPtr]::Zero) { throw 'Known Folder API 没有返回路径。' }
        return [Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer) }
    }
}

function Show-MigrationRetention {
    param([string]$OldPath)
    Write-Host ('源数据仍保留在：{0}。当前未释放源占用。' -f $OldPath)
    Write-Host '请先试用新路径、重启相关软件并确认可靠备份。只有用户再次确认后，才考虑通过资源管理器删除明确的旧副本；本脚本不提供自动删除。'
}

function Get-MigrationTool {
    param([string[]]$Name)
    # npm.cmd/conda.bat 在 Windows 上属于 Application，交由共享包装器安全调用。
    foreach ($candidate in $Name) {
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { return $command.Source }
    }
    throw ('找不到工具：' + ($Name -join ', '))
}

function Invoke-MigrationExternal {
    param([string]$FilePath, [string[]]$Arguments, [string]$Description, [System.Text.Encoding]$OutputEncoding)
    # 调用者已进行 ShouldProcess；外部命令本身不会自动遵守 WhatIf。
    if ($WhatIfPreference) { throw '内部错误：WhatIf 不应调用外部程序。' }
    $invokeParameters = @{
        FilePath = $FilePath; ArgumentList = $Arguments; Description = $Description
        Confirm = $false; ErrorAction = 'Stop'
    }
    if ($null -ne $OutputEncoding) { $invokeParameters['OutputEncoding'] = $OutputEncoding }
    $result = Invoke-External @invokeParameters
    $exit = Get-MigrationValue $result @('ExitCode', 'Code')
    if ($null -eq $exit -or [int]$exit -ne 0) { throw ('外部命令没有报告成功退出码：' + $Description) }
    return $result
}

function Backup-MigrationConfiguration {
    param([string]$Path)
    Assert-MigrationTarget $Path 'DevCacheConfig'
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $backup = $Path + '.cdrive-backup-' + [guid]::NewGuid().ToString('N')
    Assert-MigrationTarget $backup 'DevCacheConfig'
    [System.IO.File]::Copy($Path, $backup, $false)
    Write-Host ('原配置备份：' + $backup)
    return $backup
}

function Set-MigrationDevConfiguration {
    param([string]$Name, [string]$Path, [string[]]$Processes, [string]$OldPath, $Expected)
    $profilePath = $script:MigrationProfile
    $config = $null
    $tool = $null
    switch ($Name) {
        'npm' {
            $config = Join-Path $profilePath '.npmrc'
            if (-not $WhatIfPreference) { $tool = Get-MigrationTool 'npm.cmd' }
        }
        'pip' { $config = 'HKCU:\Environment' }
        'gradle' { $config = 'HKCU:\Environment' }
        'maven' { $config = Join-Path $profilePath '.m2\settings.xml' }
        'conda' {
            $config = Join-Path $profilePath '.condarc'
            if (-not $WhatIfPreference) { $tool = Get-MigrationTool @('conda.exe', 'conda.bat', '_conda.exe') }
        }
    }
    if ($Name -eq 'npm' -or $Name -eq 'maven' -or $Name -eq 'conda') {
        Assert-MigrationTarget $config 'DevCacheConfig'
    }
    if ($WhatIfPreference) {
        $null = $script:MigrationCmdlet.ShouldProcess($config, ('备份并修改 {0} 用户配置，指向 {1}' -f $Name, $Path))
        return $false
    }
    Assert-MigrationTarget $Path 'MigrationDestination'
    Assert-MigrationProcesses $Processes
    if (-not $script:MigrationCmdlet.ShouldProcess($config, ('备份原值并将 {0} 指向 {1}' -f $Name, $Path))) { return $false }
    Assert-MigrationTarget $Path 'MigrationDestination'
    Assert-MigrationProcesses $Processes
    if ($null -ne $Expected) {
        $sourceNow = Get-MigrationInventory $OldPath 'DevCacheMigration' -Hash:$VerifyHash
        $destinationNow = Get-MigrationInventory $Path 'MigrationDestination' -Hash:$VerifyHash
        Assert-MigrationInventoryMatch $Expected $sourceNow -CheckTime -Hash:$VerifyHash
        Assert-MigrationInventoryMatch $sourceNow $destinationNow -Hash:$VerifyHash
    }
    $script:MigrationWroteState = $true
    $backup = $null
    if ($Name -eq 'npm' -or $Name -eq 'maven' -or $Name -eq 'conda') {
        # 写配置与备份属于同一个已确认操作；备份创建失败时不会修改配置。
        $configParent = [System.IO.Path]::GetDirectoryName($config)
        Assert-MigrationTarget $configParent 'DevCacheConfig'
        $null = [System.IO.Directory]::CreateDirectory($configParent)
        $backup = Backup-MigrationConfiguration $config
    }
    try {
        switch ($Name) {
            'npm' {
                $null = Invoke-MigrationExternal $tool @('config', 'set', 'cache', $Path, '--userconfig', $config, '--location=user') '设置 npm 用户 cache'
            }
            'pip' {
                $previous = [Environment]::GetEnvironmentVariable('PIP_CACHE_DIR', 'User')
                # 先把旧值写入共享审计，审计失败则不修改用户环境。
                Write-CleanerLog -Action 'DevCacheEnvironmentBackup/PIP_CACHE_DIR' -Path $config -Result (ConvertTo-Json -Compress -InputObject @{ OldValue = $previous; NewValue = $Path }) -Bytes 0 -Confirm:$false -ErrorAction Stop
                [Environment]::SetEnvironmentVariable('PIP_CACHE_DIR', $Path, 'User')
                [Environment]::SetEnvironmentVariable('PIP_CACHE_DIR', $Path, 'Process')
            }
            'gradle' {
                $previous = [Environment]::GetEnvironmentVariable('GRADLE_USER_HOME', 'User')
                Write-CleanerLog -Action 'DevCacheEnvironmentBackup/GRADLE_USER_HOME' -Path $config -Result (ConvertTo-Json -Compress -InputObject @{ OldValue = $previous; NewValue = $Path }) -Bytes 0 -Confirm:$false -ErrorAction Stop
                [Environment]::SetEnvironmentVariable('GRADLE_USER_HOME', $Path, 'User')
                [Environment]::SetEnvironmentVariable('GRADLE_USER_HOME', $Path, 'Process')
            }
            'maven' {
                $document = New-Object System.Xml.XmlDocument
                $document.PreserveWhitespace = $true
                $document.XmlResolver = $null
                if (Test-Path -LiteralPath $config) {
                    $settings = New-Object System.Xml.XmlReaderSettings
                    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
                    $settings.XmlResolver = $null
                    $reader = [System.Xml.XmlReader]::Create($config, $settings)
                    try { $document.Load($reader) } finally { $reader.Dispose() }
                }
                else {
                    $document.LoadXml('<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"></settings>')
                }
                if ($null -eq $document.DocumentElement -or $document.DocumentElement.LocalName -ne 'settings') { throw 'Maven 配置根节点不是 settings。' }
                $nodes = @($document.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'localRepository' })
                if ($nodes.Count -gt 1) { throw 'Maven 配置有重复 localRepository，请先人工整理。' }
                if ($nodes.Count -eq 0) {
                    $node = $document.CreateElement('localRepository', $document.DocumentElement.NamespaceURI)
                    $null = $document.DocumentElement.AppendChild($node)
                }
                else { $node = $nodes[0] }
                $node.InnerText = $Path
                Assert-MigrationTarget $config 'DevCacheConfig'
                $writerSettings = New-Object System.Xml.XmlWriterSettings
                $writerSettings.Encoding = New-Object System.Text.UTF8Encoding -ArgumentList $true
                $writerSettings.Indent = $true
                $temporary = $config + '.tmp-' + [guid]::NewGuid().ToString('N')
                Assert-MigrationTarget $temporary 'DevCacheConfig'
                $writer = [System.Xml.XmlWriter]::Create($temporary, $writerSettings)
                try { $document.Save($writer) } finally { $writer.Dispose() }
                Assert-MigrationTarget $config 'DevCacheConfig'
                Assert-MigrationTarget $temporary 'DevCacheConfig'
                if (Test-Path -LiteralPath $config) { [System.IO.File]::Replace($temporary, $config, $null) }
                else { [System.IO.File]::Move($temporary, $config) }
            }
            'conda' {
                $null = Invoke-MigrationExternal $tool @('config', '--file', $config, '--prepend', 'pkgs_dirs', $Path) '设置 conda 首选包缓存目录'
                Write-Host 'conda 保留原 pkgs_dirs 作为后备；请用 conda config --show pkgs_dirs 核对，不会移动已有环境。'
            }
        }
    }
    catch {
        Write-Warning ('配置修改失败，源数据未删除；备份路径：{0}。请先检查当前配置，勿直接删除新副本。' -f $backup)
        throw
    }
    Write-MigrationAudit ('DevCacheSwitch/' + $Name) $Path '成功；源数据未删除；新终端生效' 0
    Write-Host '配置已写入。请打开新终端，检查工具实际缓存路径；项目参数、其他环境变量或命令行选项仍可能覆盖用户配置。'
    return $true
}

function Get-MigrationExternalText {
    param($Result)
    $output = Get-MigrationValue $Result @('Output', 'StdOut', 'StandardOutput', 'OutputLines')
    if ($null -eq $output) { throw '共享外部命令接口没有提供标准输出，无法验证。' }
    return ((@($output) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Replace([string][char]0, '').Trim()
}

function Get-MigrationWSLRecord {
    param([string]$Name)
    $registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $registry)) { throw '当前用户没有 WSL 发行版注册记录。' }
    $records = @()
    foreach ($key in @(Get-ChildItem -LiteralPath $registry -ErrorAction Stop)) {
        $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
        if ((Get-MigrationValue $record @('DistributionName')) -ceq $Name) { $records += $record }
    }
    if ($records.Count -ne 1) { throw '无法唯一识别旧 WSL 发行版，请核对 -Distro 的名称及大小写。' }
    return $records[0]
}

function Get-MigrationWSLInventory {
    param([string]$Wsl, [string]$Name, [switch]$Hash)
    # 排除虚拟挂载和启动时变化的文件；其余本地常规文件用 find -xdev 统计。
    # 使用参数数组传递整个固定 shell 程序；发行版名和 Windows 路径不插入 shell。
    $program = @'
set -eu
export LC_ALL=C
sizes=$(find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /mnt -o -path /tmp -o -path /var/log -o -path /var/tmp -o -path /etc/hosts -o -path /etc/hostname -o -path /etc/resolv.conf -o -path /etc/machine-id -o -path /var/lib/systemd/random-seed \) -prune -o -type f -printf '%s\n') || exit 71
printf '%s\n' "$sizes" | awk 'NF {n++; b+=$1} END {printf "MCOUNT|%.0f|%.0f\n", n, b}'
'@
    if ($Hash) {
        $program += [Environment]::NewLine + @'
hashes=$(find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /mnt -o -path /tmp -o -path /var/log -o -path /var/tmp -o -path /etc/hosts -o -path /etc/hostname -o -path /etc/resolv.conf -o -path /etc/machine-id -o -path /var/lib/systemd/random-seed \) -prune -o -type f -exec sha256sum -- '{}' +) || exit 72
sorted=$(printf '%s\n' "$hashes" | sort) || exit 73
digest=$(printf '%s\n' "$sorted" | sha256sum) || exit 74
printf '%s\n' "$digest" | awk '{print "MHASH|" $1}'
'@
    }
    # 共享外部接口拒绝带换行的参数；固定程序折成单行，保留 shell 中的转义序列。
    $program = ($program.Trim() -replace '[\r\n]+', '; ')
    $result = Invoke-MigrationExternal $Wsl @('--distribution', $Name, '--user', 'root', '--exec', '/bin/sh', '-c', $program) '统计 WSL 稳定文件集合'
    $output = Get-MigrationExternalText $result
    $countMatch = [regex]::Match($output, '(?m)^MCOUNT\|([0-9]+)\|([0-9]+)\s*$')
    if (-not $countMatch.Success) { throw 'WSL 文件数/大小统计未返回可验证结果。' }
    $digest = $null
    if ($Hash) {
        $hashMatch = [regex]::Match($output, '(?m)^MHASH\|([0-9a-fA-F]{64})\s*$')
        if (-not $hashMatch.Success) { throw 'WSL SHA-256 统计未返回可验证结果。' }
        $digest = $hashMatch.Groups[1].Value
    }
    return [pscustomobject]@{
        FileCount = [long]$countMatch.Groups[1].Value
        Bytes = [long]$countMatch.Groups[2].Value
        Hash = $digest
    }
}

function Invoke-MigrationWSL {
    param([string]$Name, [string]$NewName, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'WSL 必须指定 -Distro。' }
    if (@('docker-desktop', 'docker-desktop-data') -contains $Name) {
        throw 'Docker 管理的内部发行版须使用 Docker Desktop 的官方存储设置迁移。'
    }
    if ([string]::IsNullOrWhiteSpace($NewName)) { $NewName = $Name + '-Migrated' }
    if ($Name.StartsWith('-') -or $Name.Contains([string][char]0) -or $Name -match '[\r\n]') {
        throw '旧发行版名称无效。'
    }
    if ($NewName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or $Name -ieq $NewName) {
        throw '新名称须为不同名称，只使用字母、数字、点、下划线或连字符（最长 80 字符）。'
    }
    $record = Get-MigrationWSLRecord $Name
    $registeredPath = [string](Get-MigrationValue $record @('BasePath'))
    if ([string]::IsNullOrWhiteSpace($registeredPath)) { throw 'WSL 注册记录缺少 BasePath，停止迁移。' }
    $registeredPath = [Environment]::ExpandEnvironmentVariables($registeredPath)
    if ($registeredPath -match '^\\\\\?\\[A-Za-z]:\\') { $registeredPath = $registeredPath.Substring(4) }
    $basePath = Get-MigrationFullPath $registeredPath
    Assert-MigrationTarget $basePath 'WSL'
    Assert-MigrationSeparation $basePath $Path
    # 只读取 VHDX 的目录大小元数据，不复制、挂载或删除虚拟磁盘。
    $size = Get-DirectorySize -LiteralPath $basePath -ErrorAction Stop
    $logicalBytes = Get-MigrationValue $size @('LogicalBytes')
    if ((Get-MigrationValue $size @('IsComplete') $false) -ne $true -or
        [long](Get-MigrationValue $size @('SkippedCount') 0) -gt 0 -or
        $null -eq $logicalBytes -or [long]$logicalBytes -lt 0) { throw 'WSL 源目录大小未知，无法可靠检查备份空间。' }
    [long]$estimated = [Math]::Max(1GB, [long]$logicalBytes) * 2
    Assert-MigrationVolume $Path $estimated
    Test-MigrationEmptyDestination $Path
    $archive = Join-Path $Path ($NewName + '-export.tar')
    $install = Join-Path $Path $NewName
    Assert-MigrationTarget $archive 'MigrationDestination'
    Assert-MigrationTarget $install 'MigrationDestination'
    $version = [int](Get-MigrationValue $record @('Version') 0)
    if ($version -ne 1 -and $version -ne 2) { throw '无法确定旧发行版的 WSL 版本，停止导入。' }
    Assert-MigrationProcesses @('Docker Desktop', 'com.docker.backend', 'wsl')
    Write-Host ('保留旧发行版 {0}；导出到 {1}；新发行版 {2}（WSL {3}）。' -f $Name, $archive, $NewName, $version)
    Write-Host '需关闭该发行版内的任务和 Docker。验证会启动发行版；统计排除虚拟挂载、临时目录、日志及 WSL 自动生成的主机配置。'
    if ($WhatIfPreference) {
        $null = $script:MigrationCmdlet.ShouldProcess($Path, '检查写权限并创建 WSL 迁移目录')
        $null = $script:MigrationCmdlet.ShouldProcess($Name, '验证发行版列表、读取默认用户及文件集合、终止旧发行版后导出')
        $null = $script:MigrationCmdlet.ShouldProcess($NewName, '以新名称导入，启动验证文件数/大小及默认用户；保留旧发行版')
        return [pscustomobject]@{ Item = 'WSL'; Status = 'WhatIf'; Source = $Name; Destination = $Path; NewDistroName = $NewName }
    }
    $wsl = Get-MigrationTool 'wsl.exe'
    if (-not (Test-MigrationWritable $Path)) { return }
    if (-not (New-MigrationDirectory $Path)) { return }
    if (-not $script:MigrationCmdlet.ShouldProcess($Name, '启动旧发行版读取默认用户与内容统计；随后需要停止它')) { return }
    $script:MigrationWroteState = $true
    # WSL 管理命令通常输出 UTF-16LE；--exec 的 Linux 标准输出保持默认解码。
    # Get-MigrationExternalText 继续去除 NUL，兼容已含 NUL 的历史输出形式。
    $list = Get-MigrationExternalText (Invoke-MigrationExternal $wsl @('--list', '--quiet') '列出 WSL 发行版' -OutputEncoding ([System.Text.Encoding]::Unicode))
    $names = @($list -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names -notcontains $Name -or $names -contains $NewName) { throw '旧发行版不存在或新名称已被占用。' }
    $oldUser = Get-MigrationExternalText (Invoke-MigrationExternal $wsl @('--distribution', $Name, '--exec', 'id', '-un') '读取旧发行版默认 Linux 用户')
    if ($oldUser -notmatch '^[A-Za-z_][A-Za-z0-9_.-]*[$]?$') { throw '无法可靠识别旧发行版的默认 Linux 用户。' }
    $before = Get-MigrationWSLInventory $wsl $Name -Hash:$VerifyHash
    if (-not $script:MigrationCmdlet.ShouldProcess($Name, '终止此发行版并导出 tar；旧发行版继续保留')) { return }
    Assert-MigrationTarget $basePath 'WSL'
    Assert-MigrationTarget $archive 'MigrationDestination'
    if (Test-Path -LiteralPath $archive) { throw '导出归档已存在，不覆盖。' }
    $null = Invoke-MigrationExternal $wsl @('--terminate', $Name) '停止旧 WSL 发行版' -OutputEncoding ([System.Text.Encoding]::Unicode)
    $null = Invoke-MigrationExternal $wsl @('--export', $Name, $archive) '导出旧 WSL 发行版' -OutputEncoding ([System.Text.Encoding]::Unicode)
    Assert-MigrationTarget $archive 'MigrationDestination'
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or (Get-Item -LiteralPath $archive).Length -le 0) {
        throw '导出归档不存在或为空，不进行导入。'
    }
    if ($VerifyHash) {
        $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        Write-MigrationAudit 'WSLExportHash' $archive ('SHA256=' + $archiveHash) 0
    }
    if (-not $script:MigrationCmdlet.ShouldProcess($NewName, ('从归档导入到 {0} 并启动验证' -f $install))) { return }
    Assert-MigrationTarget $install 'MigrationDestination'
    if (Test-Path -LiteralPath $install) { throw '新发行版目录已存在，不覆盖。' }
    Assert-MigrationVolume $Path ([long]($estimated / 2))
    $currentNames = (Get-MigrationExternalText (Invoke-MigrationExternal $wsl @('--list', '--quiet') '重新检查新发行版名称' -OutputEncoding ([System.Text.Encoding]::Unicode))) -split '\r?\n'
    if (@($currentNames | ForEach-Object { $_.Trim() }) -contains $NewName) { throw '新发行版名称已被占用。' }
    $null = Invoke-MigrationExternal $wsl @('--import', $NewName, $install, $archive, '--version', [string]$version) '以新名称导入 WSL' -OutputEncoding ([System.Text.Encoding]::Unicode)
    $after = Get-MigrationWSLInventory $wsl $NewName -Hash:$VerifyHash
    if ($before.FileCount -ne $after.FileCount -or $before.Bytes -ne $after.Bytes -or
        ($VerifyHash -and $before.Hash -ne $after.Hash)) {
        throw 'WSL 稳定文件集合校验不一致。保留旧发行版、新发行版和归档；不要注销旧发行版，请人工核查。'
    }
    $newUser = Get-MigrationExternalText (Invoke-MigrationExternal $wsl @('--distribution', $NewName, '--exec', 'id', '-un') '检查新发行版默认 Linux 用户')
    $null = Invoke-MigrationExternal $wsl @('--distribution', $NewName, '--user', $oldUser, '--exec', 'id') '验证原 Linux 用户仍可登录'
    $userVerified = $newUser -ceq $oldUser
    if (-not $userVerified) {
        Write-Warning ('默认 Linux 用户不同：旧 {0}，新 {1}。请在新发行版 /etc/wsl.conf 的 [user] 中设置 default={0}，终止并重新启动后验证。' -f $oldUser, $newUser)
    }
    Write-Host ('WSL 文件数/大小校验通过：{0} 文件，{1} 字节。仍须进入新发行版检查项目、服务、挂载及业务数据。' -f $after.FileCount, $after.Bytes)
    Write-Host ('导出归档保留：{0}。默认发行版未改变；旧发行版保留，占用尚未释放。' -f $archive)
    Write-Host '只有默认用户和业务数据验证完成、归档及可靠备份确认可用且用户另行明确确认后，才可手动执行下面的命令。注销会永久删除旧发行版：'
    Write-Host ("wsl.exe --unregister '" + $Name.Replace("'", "''") + "'")
    Write-MigrationAudit 'WSLImported' $install ('内容集合校验成功；默认用户一致=' + $userVerified + '；旧发行版保留') 0
    return [pscustomobject]@{
        Item = 'WSL'; Status = 'ImportedNeedsUserValidation'; Source = $Name; NewDistroName = $NewName
        Destination = $install; Archive = $archive; DefaultUserVerified = $userVerified; SourceRetained = $true
    }
}

function Get-MigrationManifestPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ([string]::IsNullOrWhiteSpace($script:MigrationLog)) { throw '无法确定默认联接清单路径，请指定 -ManifestPath。' }
        $Path = Join-Path ([System.IO.Path]::GetDirectoryName($script:MigrationLog)) 'junctions.json'
    }
    $Path = Get-MigrationFullPath $Path
    if ([System.IO.Path]::GetExtension($Path) -ine '.json') { throw '联接清单必须使用 .json 扩展名。' }
    Assert-MigrationTarget $Path 'MigrationManifest'
    return $Path
}

function Read-MigrationManifest {
    param([string]$Path, [switch]$Required)
    Assert-MigrationTarget $Path 'MigrationManifest'
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Required) { throw '联接清单不存在。' }
        return [pscustomobject]@{ Version = 1; UserSid = $script:MigrationSid; Entries = @() }
    }
    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ((Get-MigrationValue $document @('Version')) -ne 1 -or
        (Get-MigrationValue $document @('UserSid')) -ne $script:MigrationSid -or
        $null -eq $document.PSObject.Properties['Entries']) { throw '清单版本、所属用户或格式无效。' }
    $ids = @{}
    foreach ($entry in @($document.Entries)) {
        # JSON 记录来自文件；先验证后续必需字段，缺失时给出格式错误而非 StrictMode 异常。
        foreach ($field in @('Id', 'Cache', 'Source', 'Destination', 'RetainedSource', 'State')) {
            $value = Get-MigrationValue $entry @($field)
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                throw ('清单记录缺少有效字符串字段：' + $field)
            }
        }
        $entryId = [string]$entry.Id
        if ($entryId -notmatch '^[0-9a-f]{32}$' -or $ids.ContainsKey($entryId)) { throw '清单 ID 无效或重复。' }
        $ids[$entryId] = $true
    }
    return $document
}

function Write-MigrationManifest {
    param([string]$Path, $Document)
    # 只在已确认的联接事务中调用。先写临时文件，再原子替换，避免中断留下半份 JSON。
    if ($WhatIfPreference -or -not $script:MigrationWroteState) { throw '未授权的清单写入。' }
    Assert-MigrationTarget $Path 'MigrationManifest'
    $temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    Assert-MigrationTarget $temporary 'MigrationManifest'
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $true
    $json = ConvertTo-Json -InputObject $Document -Depth 8
    [System.IO.File]::WriteAllText($temporary, $json, $encoding)
    Assert-MigrationTarget $temporary 'MigrationManifest'
    Assert-MigrationTarget $Path 'MigrationManifest'
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($temporary, $Path, $null) }
    else { [System.IO.File]::Move($temporary, $Path) }
}

function Open-MigrationManifestLock {
    param([string]$Path, [switch]$Persistent)
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    Assert-MigrationTarget $parent 'MigrationManifest'
    $null = [System.IO.Directory]::CreateDirectory($parent)
    $lockPath = $Path + '.lock'
    Assert-MigrationTarget $lockPath 'MigrationManifest'
    $mode = [System.IO.FileMode]::CreateNew
    if ($Persistent) { $mode = [System.IO.FileMode]::OpenOrCreate }
    $stream = New-Object System.IO.FileStream -ArgumentList @($lockPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    return [pscustomobject]@{ Path = $lockPath; Stream = $stream; Persistent = [bool]$Persistent }
}

function Close-MigrationManifestLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try {
        $Lock.Stream.Dispose()
        Assert-MigrationTarget $Lock.Path 'MigrationManifest'
        if (-not (Get-MigrationValue $Lock @('Persistent') $false)) { [System.IO.File]::Delete($Lock.Path) }
    }
    catch {
        Write-Warning ('未能移除本次清单锁 {0}：{1}。确认没有迁移进程运行后才可人工移除锁文件。' -f $Lock.Path, $_.Exception.Message)
    }
}

function Get-MigrationExistingEntry {
    param([string]$Path)
    # Get-Item 可识别目标已丢失的联接，不能以 Test-Path 的 false 代替叶节点不存在。
    try { return Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { return $null }
        throw
    }
}

function Assert-MigrationJunctionRecord {
    param($Entry)
    if ([string]$Entry.Id -notmatch '^[0-9a-f]{32}$' -or
        @('npm', 'pip', 'gradle', 'maven', 'conda') -notcontains [string]$Entry.Cache) { throw '清单记录的 ID 或缓存类型无效。' }
    if (@('Prepared', 'SourceRetained', 'Active', 'LinkRemoved', 'RestoringSource', 'RolledBack', 'Cancelled') -notcontains [string]$Entry.State) {
        throw '清单记录状态无效。'
    }
    $sourcePath = Get-MigrationFullPath ([string]$Entry.Source)
    $targetPath = Get-MigrationFullPath ([string]$Entry.Destination)
    $retained = Get-MigrationFullPath ([string]$Entry.RetainedSource)
    if ($retained -cne ($sourcePath + '.cdrive-retained-' + $Entry.Id)) { throw '保留目录与记录 ID 不匹配。' }
    Assert-MigrationSeparation $sourcePath $targetPath
    # 叶节点是待移除的联接，父级和保留目录交给共享库校验，不沿联接检查目标。
    # JunctionBackup/JunctionParent 必须由共享白名单从同一组缓存根派生；未知类别拒绝执行。
    Assert-MigrationTarget ([System.IO.Path]::GetDirectoryName($sourcePath)) 'JunctionParent'
    Assert-MigrationTarget $retained 'JunctionBackup'
    Assert-MigrationTarget $targetPath 'MigrationDestination'
    return [pscustomobject]@{ Source = $sourcePath; Destination = $targetPath; RetainedSource = $retained }
}

function Get-MigrationVerifiedJunction {
    param([string]$Path, [string]$Target)
    $entry = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    # 这是回滚对叶节点的类型/目标确认，不代替父级的共享重解析点校验。
    if ((Get-MigrationValue $entry @('LinkType')) -ne 'Junction' -or -not $entry.PSIsContainer) { throw '待移除路径不是 NTFS 目录联接，拒绝删除。' }
    $targets = @(Get-MigrationValue $entry @('Target') @())
    if ($targets.Count -ne 1) { throw '联接目标不唯一。' }
    $actualTarget = [string]$targets[0]
    if ($actualTarget.StartsWith(('\' + [char]63 + [char]63 + '\'))) { $actualTarget = $actualTarget.Substring(4) }
    if ($actualTarget.TrimEnd('\') -ine $Target) { throw '联接原始目标与清单规范路径不一致，拒绝删除。' }
    $actualTarget = Get-MigrationFullPath $actualTarget
    if ($actualTarget -ine $Target) { throw '联接目标与清单不一致，拒绝删除。' }
    return $entry
}

function New-MigrationJunction {
    param([string]$OldPath, [string]$NewPath, [string]$CacheName, [string]$Manifest, $Inventory, [string[]]$Processes)
    Assert-MigrationTarget $OldPath 'Junction'
    Assert-MigrationTarget $NewPath 'MigrationDestination'
    $sourceDrive = New-Object System.IO.DriveInfo -ArgumentList ([System.IO.Path]::GetPathRoot($OldPath))
    if ($sourceDrive.DriveType -ne [System.IO.DriveType]::Fixed -or $sourceDrive.DriveFormat -ine 'NTFS') {
        throw '联接源也必须位于本地固定 NTFS 卷。'
    }
    if ($OldPath -match '[%!^&|<>()"\r\n]' -or $NewPath -match '[%!^&|<>()"\r\n]') {
        throw '联接路径含 cmd 元字符，请改用官方配置。'
    }
    $id = [guid]::NewGuid().ToString('N')
    $retained = $OldPath + '.cdrive-retained-' + $id
    Assert-MigrationTarget $retained 'JunctionBackup'
    Assert-MigrationTarget ([System.IO.Path]::GetDirectoryName($OldPath)) 'JunctionParent'
    foreach ($dataRoot in @($OldPath, $NewPath, $retained)) {
        if ($Manifest.Equals($dataRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $Manifest.StartsWith($dataRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw '联接清单不能放在源、目标或保留缓存目录内，以免被应用清理或随联接重定向。'
        }
    }
    if ($WhatIfPreference) {
        $null = $script:MigrationCmdlet.ShouldProcess($Manifest, '写入联接清单，逐阶段记录 Prepared/SourceRetained/Active')
        $null = $script:MigrationCmdlet.ShouldProcess($OldPath, ('把源改名保留为 {0}，再创建指向 {1} 的联接' -f $retained, $NewPath))
        return [pscustomobject]@{ Item = 'Junction'; Status = 'WhatIf'; Source = $OldPath; Destination = $NewPath }
    }
    if (-not $script:MigrationCmdlet.ShouldProcess($OldPath, ('保存清单、把源改名保留为 {0} 并创建联接到 {1}' -f $retained, $NewPath))) { return }
    $script:MigrationWroteState = $true
    $lock = $null
    try {
        $lock = Open-MigrationManifestLock $Manifest
        $document = Read-MigrationManifest $Manifest
        foreach ($previous in @($document.Entries)) {
            if ($previous.Source -ieq $OldPath -and @('RolledBack', 'Cancelled') -notcontains $previous.State) {
                throw '清单已有该源目录的未完成记录，请先检查或回滚。'
            }
        }
        Assert-MigrationProcesses $Processes
        Assert-MigrationTarget $OldPath 'Junction'
        Assert-MigrationTarget $retained 'JunctionBackup'
        if (Test-Path -LiteralPath $retained) { throw '保留目录已存在，拒绝覆盖。' }
        $current = Get-MigrationInventory $OldPath 'Junction' -Hash:$VerifyHash
        Assert-MigrationInventoryMatch $Inventory $current -CheckTime -Hash:$VerifyHash
        $newInventory = Get-MigrationInventory $NewPath 'MigrationDestination' -Hash:$VerifyHash
        Assert-MigrationInventoryMatch $current $newInventory -Hash:$VerifyHash
        $record = [pscustomobject]@{
            Id = $id; Cache = $CacheName; Source = $OldPath; Destination = $NewPath; RetainedSource = $retained
            State = 'Prepared'; CreatedUtc = [DateTime]::UtcNow.ToString('o')
            FileCount = $Inventory.FileCount; Bytes = $Inventory.Bytes; HashVerified = [bool]$VerifyHash
        }
        $document.Entries = @($document.Entries) + @($record)
        Write-MigrationManifest $Manifest $document
        Assert-MigrationProcesses $Processes
        Assert-MigrationTarget $OldPath 'Junction'
        Assert-MigrationTarget $retained 'JunctionBackup'
        [System.IO.Directory]::Move($OldPath, $retained)
        $record.State = 'SourceRetained'
        Write-MigrationManifest $Manifest $document
        Assert-MigrationTarget $OldPath 'Junction'
        Assert-MigrationTarget $NewPath 'MigrationDestination'
        Assert-MigrationProcesses $Processes
        # mklink 是 cmd 内建命令。每个参数独立传入共享包装器；
        # cmd 会展开部分引号内字符，因此额外拒绝所有 shell 元字符。
        if ($OldPath -match '[%!^&|<>()"\r\n]' -or $NewPath -match '[%!^&|<>()"\r\n]') {
            throw '联接路径含 cmd 元字符，拒绝创建。请改用 DevCache 的官方设置。'
        }
        $null = Invoke-MigrationExternal 'cmd.exe' @('/d', '/v:off', '/c', 'mklink', '/J', $OldPath, $NewPath) '创建 NTFS 目录联接'
        $null = Get-MigrationVerifiedJunction $OldPath $NewPath
        $record.State = 'Active'
        Write-MigrationManifest $Manifest $document
        Write-MigrationAudit 'JunctionCreated' $OldPath ('成功；源保留在 ' + $retained + '；清单 ' + $Manifest) 0
        Show-MigrationRetention $retained
        return [pscustomobject]@{
            Item = 'Junction'; Status = 'Active'; Source = $OldPath; Destination = $NewPath
            RetainedSource = $retained; ManifestPath = $Manifest; SourceRetained = $true
        }
    }
    catch {
        Write-Warning ('联接事务未完成。未删除任何数据；检查清单 {0} 并运行 -Rollback。保留目录：{1}' -f $Manifest, $retained)
        throw
    }
    finally { Close-MigrationManifestLock $lock }
}

function Invoke-MigrationRollback {
    param([string]$Manifest, [string]$OnlySource)
    $document = Read-MigrationManifest $Manifest -Required
    $selected = @($document.Entries | Where-Object {
        @('RolledBack', 'Cancelled') -notcontains $_.State -and
        ([string]::IsNullOrWhiteSpace($OnlySource) -or $_.Source -ieq $OnlySource)
    })
    if ($selected.Count -eq 0) { throw '没有匹配的待回滚联接记录。' }
    $reviewed = @{}
    foreach ($record in $selected) {
        $reviewed[[string]$record.Id] = [pscustomobject]@{
            Source = [string]$record.Source; Destination = [string]$record.Destination
            RetainedSource = [string]$record.RetainedSource; Cache = [string]$record.Cache; State = [string]$record.State
        }
    }
    foreach ($record in $selected) {
        $paths = Assert-MigrationJunctionRecord $record
        $sourceItem = Get-MigrationExistingEntry $paths.Source
        if ($null -ne $sourceItem) {
            if ((Get-MigrationValue $sourceItem @('LinkType')) -eq 'Junction') { $null = Get-MigrationVerifiedJunction $paths.Source $paths.Destination }
            elseif (@('Prepared', 'RestoringSource') -notcontains $record.State -or (Test-Path -LiteralPath $paths.RetainedSource)) {
                throw '源路径已变成普通目录或文件，拒绝覆盖；请人工处理清单。'
            }
        }
        Assert-MigrationProcesses @('node', 'npm', 'npx', 'python', 'pythonw', 'pip', 'pip3', 'java', 'javaw', 'gradle', 'mvn', 'mvnw', 'conda', '_conda', 'mamba', 'micromamba')
        Write-Host ('回滚 {0}：只移除联接，保留目标 {1}；若原副本仍在则恢复目录名称。' -f $paths.Source, $paths.Destination)
    }
    if (-not $script:MigrationCmdlet.ShouldProcess($Manifest, '锁定并更新清单；逐项仅移除联接并恢复保留的源目录名称')) { return }
    $script:MigrationWroteState = $true
    $lock = $null
    try {
        $lock = Open-MigrationManifestLock $Manifest
        $document = Read-MigrationManifest $Manifest -Required
        foreach ($record in @($document.Entries)) {
            if (-not $reviewed.ContainsKey([string]$record.Id)) { continue }
            $approved = $reviewed[[string]$record.Id]
            foreach ($field in @('Source', 'Destination', 'RetainedSource', 'Cache', 'State')) {
                if ([string]$record.$field -cne [string]$approved.$field) {
                    throw '清单在用户确认期间发生变化，请重新演练并确认回滚。'
                }
            }
            $paths = Assert-MigrationJunctionRecord $record
            Assert-MigrationProcesses @('node', 'npm', 'npx', 'python', 'pythonw', 'pip', 'pip3', 'java', 'javaw', 'gradle', 'mvn', 'mvnw', 'conda', '_conda', 'mamba', 'micromamba')
            $hasRetained = Test-Path -LiteralPath $paths.RetainedSource -PathType Container
            $sourceItem = Get-MigrationExistingEntry $paths.Source
            if ($null -ne $sourceItem) {
                if ((Get-MigrationValue $sourceItem @('LinkType')) -eq 'Junction') {
                    $null = Get-MigrationVerifiedJunction $paths.Source $paths.Destination
                    # false 表示不递归，只移除联接本身，绝不触及目标目录。
                    [System.IO.Directory]::Delete($paths.Source, $false)
                    $record.State = 'LinkRemoved'
                    Write-MigrationManifest $Manifest $document
                }
                elseif (@('Prepared', 'RestoringSource') -contains $record.State -and -not $hasRetained) {
                    Assert-MigrationTarget $paths.Source 'Junction'
                    if ($record.State -eq 'RestoringSource') { $record.State = 'RolledBack' }
                    else { $record.State = 'Cancelled' }
                    Write-MigrationManifest $Manifest $document
                    continue
                }
                else { throw '源路径不是预期联接；停止回滚，未覆盖源路径。' }
            }
            if ($hasRetained) {
                Assert-MigrationTarget $paths.RetainedSource 'JunctionBackup'
                Assert-MigrationTarget $paths.Source 'Junction'
                $record.State = 'RestoringSource'
                Write-MigrationManifest $Manifest $document
                Assert-MigrationTarget $paths.RetainedSource 'JunctionBackup'
                Assert-MigrationTarget $paths.Source 'Junction'
                [System.IO.Directory]::Move($paths.RetainedSource, $paths.Source)
            }
            else { Write-Warning '保留的原目录不存在；联接已移除，目标数据仍保留，请人工决定新的访问路径。' }
            $record.State = 'RolledBack'
            Write-MigrationManifest $Manifest $document
            Write-MigrationAudit 'JunctionRollback' $paths.Source '成功；未删除目标数据' 0
            [pscustomobject]@{ Item = 'Junction'; Status = 'RolledBack'; Source = $paths.Source; DestinationRetained = $paths.Destination }
        }
    }
    finally { Close-MigrationManifestLock $lock }
}

try {
    if ($Rollback) {
        $manifest = Get-MigrationManifestPath $ManifestPath
        $selectedSource = $null
        if (-not [string]::IsNullOrWhiteSpace($Source)) { $selectedSource = Get-MigrationFullPath $Source }
        Invoke-MigrationRollback $manifest $selectedSource
        return
    }
    if (($Item -ne 'UserFolder' -and $PSBoundParameters.ContainsKey('Folder')) -or
        (@('DevCache', 'Junction') -notcontains $Item -and $PSBoundParameters.ContainsKey('Cache')) -or
        ($Item -ne 'AppData' -and $PSBoundParameters.ContainsKey('App')) -or
        ($Item -ne 'WSL' -and ($PSBoundParameters.ContainsKey('Distro') -or $PSBoundParameters.ContainsKey('NewDistroName'))) -or
        ($Item -ne 'DevCache' -and $CopyExisting) -or
        ($Item -ne 'Junction' -and $PSBoundParameters.ContainsKey('ManifestPath'))) {
        throw '参数与 -Item 不匹配，请查看 Get-Help .\migrate.ps1 -Full。'
    }
    $Destination = Get-MigrationFullPath $Destination
    if ($Item -eq 'WSL') {
        if ($PSBoundParameters.ContainsKey('Source')) { throw 'WSL 源由发行版注册信息解析，不接受 -Source。' }
        Invoke-MigrationWSL $Distro $NewDistroName $Destination
        return
    }
    $sourceCategory = $Item
    if ($Item -eq 'DevCache') { $sourceCategory = 'DevCacheMigration' }
    $processes = @()
    $copyRequired = $true
    switch ($Item) {
        'UserFolder' {
            if (-not $Folder -or $PSBoundParameters.ContainsKey('Source')) { throw 'UserFolder 必须指定 -Folder，不能指定 -Source。' }
            $Source = Get-MigrationFullPath (Get-MigrationKnownFolder $Folder)
            # 同步根等被共享库禁止的 Known Folder 不输出迁移切换指引。
            Assert-MigrationTarget $Source 'UserFolder'
            Assert-MigrationTarget $Destination 'MigrationDestination'
            Write-Host ('用户文件夹 {0} 的官方切换方法：资源管理器打开原文件夹 {1} 的“属性 → 位置 → 移动”，选择 {2}。' -f $Folder, $Source, $Destination)
            Write-Host '先等待本脚本复制校验成功。切换位置时若询问是否移动原文件，选择“否”，保留旧副本；最后验证新位置与应用行为。请关闭编辑器、下载任务及同步程序。'
            $processes = @('OneDrive', 'Dropbox', 'GoogleDriveFS')
        }
        'DevCache' {
            if (-not $Cache) { throw 'DevCache 必须指定 -Cache。' }
            $copyRequired = [bool]$CopyExisting
            if ($copyRequired -and [string]::IsNullOrWhiteSpace($Source)) {
                throw '复制旧开发缓存必须显式指定 -Source，请先用工具自身查询真实缓存路径。'
            }
            if (-not $copyRequired -and -not [string]::IsNullOrWhiteSpace($Source)) { throw '指定了 -Source 时请同时指定 -CopyExisting，避免误以为旧缓存已复制。' }
            $processes = @(Get-MigrationProcessNames 'DevCache' $Cache)
            if ($Cache -eq 'gradle' -and -not $copyRequired) {
                Write-Warning '新的 GRADLE_USER_HOME 为空，个人 gradle.properties、init.d、wrapper 等不会自动继承；需要保留时请指定旧用户目录并加 -CopyExisting。'
            }
        }
        'AppData' {
            if (-not $App -or [string]::IsNullOrWhiteSpace($Source)) { throw 'AppData 必须指定 -App 和白名单内的 -Source；不能整体搬迁 AppData。' }
            $Source = Get-MigrationFullPath $Source
            Assert-MigrationTarget $Source 'AppData'
            Assert-MigrationTarget $Destination 'MigrationDestination'
            # 两类软件都检测，避免用户把另一应用的白名单文件目录误配给 -App。
            $processes = @((Get-MigrationProcessNames 'AppData' 'WeChat') + (Get-MigrationProcessNames 'AppData' 'QQ'))
            if ($App -eq 'WeChat') {
                Write-Host ('微信/Weixin：设置 → 文件管理/存储位置 → 修改，选择 {0}；菜单随版本变化。' -f $Destination)
            }
            else { Write-Host ('QQ：设置 → 文件管理/存储管理 → 文件保存位置，选择 {0}；菜单随版本变化。' -f $Destination) }
            Write-Host '这是完成复制校验后的切换步骤。现在请退出软件再复制；不要勾选会删除旧文件的移动选项。不同版本的聊天数据库、附件和缓存位置可能不同，只复制共享白名单认可的文件目录。'
            Write-Host '软件可能自动追加目录名称：务必核对设置显示的最终完整路径与 -Destination 完全一致。若软件强制移动并删除旧数据，先取消切换，保留本次副本供人工核查。'
        }
        'Junction' {
            if (-not $Cache -or [string]::IsNullOrWhiteSpace($Source)) { throw 'Junction 必须指定 -Cache 和白名单缓存 -Source。' }
            $processes = @('node', 'npm', 'npx', 'python', 'pythonw', 'pip', 'pip3', 'java', 'javaw', 'gradle', 'mvn', 'mvnw', 'conda', '_conda', 'mamba', 'micromamba')
            $manifest = Get-MigrationManifestPath $ManifestPath
            Write-Host '联接是最后手段，优先使用 DevCache 的官方配置。原目录会改名保留，清单用于仅移除联接的回滚。'
        }
    }
    Assert-MigrationTarget $Destination 'MigrationDestination'
    Assert-MigrationProcesses $processes
    $copied = $null
    if ($copyRequired) {
        $Source = Get-MigrationFullPath $Source
        Assert-MigrationTarget $Source $sourceCategory
        Assert-MigrationSeparation $Source $Destination
        $copied = Invoke-MigrationCopy $Source $Destination $sourceCategory $processes
        if (@('Verified', 'WhatIf') -notcontains $copied.Status) { return }
    }
    else {
        Assert-MigrationVolume $Destination 0
        Test-MigrationEmptyDestination $Destination
        if ($WhatIfPreference) { $null = $script:MigrationCmdlet.ShouldProcess($Destination, '检查写权限并创建新缓存目录') }
        else {
            if (-not (Test-MigrationWritable $Destination)) { return }
            if (-not (New-MigrationDirectory $Destination)) { return }
        }
    }
    switch ($Item) {
        'DevCache' {
            $expected = $null
            if ($null -ne $copied) { $expected = $copied.Inventory }
            $switched = Set-MigrationDevConfiguration $Cache $Destination $processes $Source $expected
            if ($copyRequired) { Show-MigrationRetention $Source }
            else { Write-Host '未复制、移动或删除任何旧缓存，源占用仍保留。请在新终端核对实际生效路径。' }
            [pscustomobject]@{
                Item = $Item; Cache = $Cache; Status = $(if ($WhatIfPreference) { 'WhatIf' } elseif ($switched) { 'ConfigurationChangedNeedsUserValidation' } else { 'SwitchDeclined' })
                Source = $Source; Destination = $Destination; SourceRetained = $true; ActualFreedBytes = [long]0
            }
        }
        'Junction' { New-MigrationJunction $Source $Destination $Cache $manifest $copied.Inventory $processes }
        default {
            if (-not $WhatIfPreference) {
                Write-Host '复制和校验已通过。现在按前述官方设置界面切换路径，随后验证软件实际使用新路径。'
                Write-MigrationAudit ($Item + 'AwaitingOfficialSwitch') $Destination '复制验证成功；官方界面切换待用户操作；源保留' 0
            }
            Show-MigrationRetention $Source
            [pscustomobject]@{
                Item = $Item; Status = $(if ($WhatIfPreference) { 'WhatIf' } else { 'CopiedNeedsOfficialSwitch' })
                Source = $Source; Destination = $Destination; SourceRetained = $true; ActualFreedBytes = [long]0
            }
        }
    }
}
catch {
    $migrationError = $_
    if (-not $WhatIfPreference) {
        $failurePath = $Destination
        $failureAction = 'MigrationFailed/' + $Item
        if ($Rollback) { $failurePath = $manifest; $failureAction = 'JunctionRollbackFailed' }
        try { Write-MigrationAudit $failureAction $failurePath ('失败；保留源和已生成的副本：' + $migrationError.Exception.Message) 0 }
        catch { Write-Warning '共享日志写入失败；请保存当前错误输出。' }
    }
    throw $migrationError
}

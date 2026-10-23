<#
.SYNOPSIS
只读体检 C 盘并给出搬家和备份提醒，除新建报告及其父目录外不写入任何内容。
.DESCRIPTION
仅统计已知位置。父子路径合并为一次遍历，文件归入最具体的类别，避免重复相加。
大小是文件长度之和，不保证等于清理后实际腾出的空间。云端文件和链接不展开。
默认每个根目录最多统计 15 秒，总预算 45 秒；最大预算 60 秒，其中预留 5 秒收尾。
查询也在受限的运行空间中执行。到时保留已统计下限，不同步等待阻塞的系统查询。
.PARAMETER ReportPath
可选的新报告路径，已有文件绝不覆盖。默认在共享日志目录使用唯一文件名。
.PARAMETER LocationTimeoutSeconds
每个合并后的根目录的统计时限，包括其所有子类别。
.PARAMETER TotalTimeoutSeconds
总体预算，最大 60 秒。报告写入与系统调用的实际耗时仍须在 Windows 虚拟机验证。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$ReportPath,
    [ValidateRange(1, 60)][int]$LocationTimeoutSeconds = 15,
    [ValidateRange(1, 60)][int]$TotalTimeoutSeconds = 45
)

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此脚本只能在 Windows 上运行。' }
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-CheckupValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function ConvertTo-CheckupPath {
    param([string]$Path)
    $value = $Path.Replace('/', '\').TrimEnd([char]'\')
    if ($value -notmatch '^[A-Za-z]:\\[^\\]' -or $value.Substring(2) -match '[:*?"<>|\x00-\x1f]' -or
        $value -match '\\(\.|\.\.)(\\|$)' -or $value.Contains('\\')) { throw '只能检查本地盘中的具体文件夹或文件。' }
    return $value.Substring(0, 1).ToUpperInvariant() + $value.Substring(1)
}

function Test-CheckupPathWithin {
    param([string]$Path, [string]$Parent)
    return ($Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Parent.TrimEnd([char]'\') + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-CheckupLevel {
    param([long]$TotalBytes, [long]$FreeBytes)
    if ($TotalBytes -le 0) { return 'ok' } # 未知大小另在 Issues 说明，不虚构空间告急。
    $ratio = [double]$FreeBytes / $TotalBytes
    if ($ratio -lt 0.05) { return 'severe' }
    if ($ratio -lt 0.10) { return 'tight' }
    return 'ok'
}

function Get-CheckupNeedsReminder {
    param($PhysicalDiskCount, $FileHistoryEnabled, $OneDriveSyncing)
    return ($null -ne $PhysicalDiskCount -and $PhysicalDiskCount -eq 1 -and
        $FileHistoryEnabled -ne $true -and $OneDriveSyncing -ne $true)
}

function Get-CheckupNextStep {
    param([object[]]$Items, [object[]]$DataVolumes)
    $move = @($Items | Where-Object { $_.Group -eq 'move' -and $_.Bytes -gt 0 })
    if ($move.Count -gt 0) {
        [long]$required = 0
        foreach ($item in $move) { $required += [long]$item.Bytes }
        foreach ($volume in $DataVolumes) {
            if ($volume.Letter -ine 'C:' -and $volume.IsFixed -eq $true -and $volume.FileSystem -ieq 'NTFS' -and
                [long]$volume.FreeBytes -ge $required) { return 'move' }
        }
        return 'partition'
    }
    if (@($Items | Where-Object { $_.Group -eq 'safe' -and $_.Bytes -gt 0 }).Count -gt 0) { return 'clean' }
    return 'none'
}

function Merge-CheckupLocations {
    param([object[]]$Locations)
    # 先按路径前缀去重扫描根。保留子选择器：父目录只计不属于子选择器的文件。
    # 同路径以 Priority 决定归属；同 id 的重复路径不产生重复工作。
    $unique = @{}
    foreach ($location in $Locations) {
        $path = ConvertTo-CheckupPath $location.Path
        $key = $path.ToLowerInvariant() + '|' + $location.Id
        if (-not $unique.ContainsKey($key)) {
            $unique[$key] = [pscustomobject]@{
                Path = $path; Id = $location.Id; Priority = [int](Get-CheckupValue $location 'Priority' 50)
                Scope = [string](Get-CheckupValue $location 'Scope' 'Contents')
                FilePatterns = @(Get-CheckupValue $location 'FilePatterns' @())
                ExcludeChildren = @(Get-CheckupValue $location 'ExcludeChildren' @())
                Recursive = [bool](Get-CheckupValue $location 'Recursive' $true)
            }
        }
    }
    $roots = [Collections.Generic.List[object]]::new()
    foreach ($selector in @($unique.Values | Sort-Object @{ Expression = { $_.Path.Length } }, Path, Priority, Id)) {
        $parent = $null
        foreach ($root in $roots) {
            if (Test-CheckupPathWithin $selector.Path $root.Path) { $parent = $root; break }
        }
        if ($null -eq $parent) {
            $parent = [pscustomobject]@{ Path = $selector.Path; Selectors = [Collections.Generic.List[object]]::new() }
            $roots.Add($parent)
        }
        $parent.Selectors.Add($selector)
    }
    foreach ($root in $roots) {
        [pscustomobject]@{ Path = $root.Path; Selectors = @($root.Selectors.ToArray() | Sort-Object @{ Expression = { $_.Path.Length }; Descending = $true }, Priority, Id) }
    }
}

function Get-CheckupSelection {
    param([string]$Path, [bool]$IsDirectory, [object[]]$Selectors)
    foreach ($selector in $Selectors) {
        if (-not (Test-CheckupPathWithin $Path $selector.Path)) { continue }
        $relative = $Path.Substring($selector.Path.Length).TrimStart([char]'\')
        if ($relative.Length -gt 0) {
            $first = $relative.Split([char]'\')[0]
            if ($first -in $selector.ExcludeChildren) { return $null }
        }
        if ($selector.Scope -eq 'File' -and ($IsDirectory -or $relative.Length -gt 0)) { return $null }
        if ($selector.Scope -eq 'SelectedFiles') {
            if ($IsDirectory) {
                if ($relative.Length -gt 0 -and -not $selector.Recursive) { return $null }
            }
            else {
                $matches = $false
                foreach ($pattern in $selector.FilePatterns) {
                    if ($Path.Substring($Path.LastIndexOf('\') + 1) -like $pattern) { $matches = $true; break }
                }
                if (-not $matches) { return $null }
            }
        }
        return $selector
    }
    return $null
}

function Get-CheckupRootEntry {
    param([string]$Path)
    # 只在每个扫描根检查父路径，不在每个文件上打开安全句柄。
    $current = $Path.Substring(0, 3)
    foreach ($part in $Path.Substring(3).Split([char]'\')) {
        $current = [IO.Path]::Combine($current, $part)
        $attributes = [IO.File]::GetAttributes($current)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ FullName = $Path; Attributes = $attributes; Length = 0 }
        }
    }
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { return [IO.DirectoryInfo]::new($Path) }
    return [IO.FileInfo]::new($Path)
}

function Get-CheckupEnumerator {
    param([string]$Path)
    # 不使用 EnumerationOptions，兼容 .NET Framework；返回迭代器，绝不物化整个目录。
    return ,([IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos().GetEnumerator())
}

function Measure-CheckupTree {
    param($Plan, [datetime]$DeadlineUtc,
        [scriptblock]$GetEntry = { param($path) Get-CheckupRootEntry $path },
        [scriptblock]$Enumerate = { param($path) Get-CheckupEnumerator $path },
        [scriptblock]$UtcNow = { [datetime]::UtcNow },
        [ValidateRange(1, 4096)][int]$CheckEvery = 128, $State = $null)
    $bytes = @{}
    foreach ($selector in $Plan.Selectors) { $bytes[$selector.Id] = [long]0 }
    $lower = $false; $exists = $null; $reason = ''; $entries = 0
    $simple = ($Plan.Selectors.Count -eq 1 -and $Plan.Selectors[0].Scope -eq 'Contents' -and $Plan.Selectors[0].ExcludeChildren.Count -eq 0)
    $stack = [Collections.Generic.Stack[object]]::new()
    try { $stack.Push((& $GetEntry $Plan.Path)); $exists = $true }
    catch [IO.FileNotFoundException] { $exists = $false }
    catch [IO.DirectoryNotFoundException] { $exists = $false }
    catch { $lower = $true; $reason = '部分文件夹无法读取，大小仅为已检查部分。' }
    while ($stack.Count -gt 0) {
        if ((& $UtcNow) -ge $DeadlineUtc) { $lower = $true; $reason = '检查时间已到，大小仅为已检查部分。'; break }
        $entry = $stack.Pop()
        try {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $lower = $true; continue }
            if (([int]$entry.Attributes -band 0x441000) -ne 0) { $lower = $true; continue }
            $directory = (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0)
            $selection = $Plan.Selectors[0]
            if (-not $simple) { $selection = Get-CheckupSelection $entry.FullName $directory $Plan.Selectors }
            if ($null -eq $selection) { continue }
            if (-not $directory) { $bytes[$selection.Id] += [long]$entry.Length; continue }
            $iterator = $null
            try {
                $iterator = & $Enumerate $entry.FullName
                while ($iterator.MoveNext()) {
                    $child = $iterator.Current
                    $entries++
                    if (($entries % $CheckEvery) -eq 0) {
                        if ($null -ne $State) { $State.Snapshot = @{ Bytes = $bytes.Clone(); IsLowerBound = $true; Exists = $exists; Issue = '' } }
                        if ((& $UtcNow) -ge $DeadlineUtc) { $lower = $true; $reason = '检查时间已到，大小仅为已检查部分。'; break }
                    }
                    try {
                        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $lower = $true; continue }
                        # 云端占位和按需读取项只看属性，不触发下载，不计其逻辑长度。
                        if (([int]$child.Attributes -band 0x441000) -ne 0) { $lower = $true; continue }
                        $isDirectory = (($child.Attributes -band [IO.FileAttributes]::Directory) -ne 0)
                        $selected = $Plan.Selectors[0]
                        if (-not $simple) { $selected = Get-CheckupSelection $child.FullName $isDirectory $Plan.Selectors }
                        if ($null -eq $selected) { continue }
                        if ($isDirectory) { $stack.Push($child) }
                        else { $bytes[$selected.Id] += [long]$child.Length }
                    }
                    catch { $lower = $true }
                }
            }
            catch { $lower = $true; $reason = '部分文件夹无法读取，大小仅为已检查部分。' }
            finally { if ($null -ne $iterator -and $iterator -is [IDisposable]) { $iterator.Dispose() } }
            if ($reason -eq '检查时间已到，大小仅为已检查部分。') { break }
        }
        catch { $lower = $true; $reason = '部分文件夹无法读取，大小仅为已检查部分。' }
    }
    if ($lower -and $reason.Length -eq 0) { $reason = '部分文件已跳过，大小仅为已检查部分。' }
    $result = @{ Bytes = $bytes; IsLowerBound = $lower; Exists = $exists; Issue = $reason }
    if ($null -ne $State) { $State.Snapshot = $result }
    return $result
}

function ConvertFrom-CheckupConfig {
    param([string]$Text, [string]$Format, [string[]]$PathKeys)
    if ($Format -eq 'Text') {
        foreach ($line in ($Text -split '[\r\n\x00]+')) {
            $value = $line.Trim().Trim([char]'"')
            if ($value -match '^[A-Za-z]:[\\/]') { $value }
        }
        return
    }
    $document = ConvertFrom-Json -InputObject $Text -ErrorAction Stop
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Value = $document; Depth = 0 })
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node.Value -or $node.Depth -gt 6) { continue }
        foreach ($property in $node.Value.PSObject.Properties) {
            if ($property.Name -in $PathKeys -and $property.Value -is [string]) { $property.Value }
            elseif ($property.Value -is [pscustomobject]) { $stack.Push(@{ Value = $property.Value; Depth = $node.Depth + 1 }) }
        }
    }
}

function Read-CheckupSmallFile {
    param([string]$Path)
    $entry = Get-CheckupRootEntry $Path
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ([int]$entry.Attributes -band 0x441000) -ne 0 -or $entry.Length -gt 65536) { throw '配置文件无法快速读取。' }
    # 有界读取，避免文件检查后增大。UTF-8 严格解码失败时回退当前系统的 ANSI 编码。
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $buffer = [byte[]]::new(65537); $length = 0
        while ($length -lt $buffer.Length) {
            $read = $stream.Read($buffer, $length, $buffer.Length - $length)
            if ($read -eq 0) { break }
            $length += $read
        }
        if ($length -gt 65536) { throw '配置文件过大，已跳过。' }
        return ConvertFrom-CheckupConfigBytes $buffer $length
    }
    finally { $stream.Dispose() }
}

function ConvertFrom-CheckupConfigBytes {
    param([byte[]]$Bytes, [int]$Length)
    if ($Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) { return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Length - 2) }
    if ($Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) { return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Length - 2) }
    if ($Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) { return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Length - 3) }
    try { return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, 0, $Length) }
    catch {
        $encoding = [Text.Encoding]::Default
        try { $encoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { }
        return $encoding.GetString($Bytes, 0, $Length)
    }
}

function Resolve-CheckupChatPaths {
    param([string]$Value, [string[]]$FolderNames, [bool]$IsParent)
    $base = ConvertTo-CheckupPath $Value
    if (-not $IsParent -or $base.Substring($base.LastIndexOf('\') + 1) -in $FolderNames) { return $base }
    foreach ($name in $FolderNames) { $base + '\' + $name }
}

function Expand-CheckupPattern {
    param([string]$Pattern, $Context, [datetime]$DeadlineUtc)
    $expanded = Expand-CleanerPath -Pattern $Pattern -Context $Context
    if ($expanded -notmatch '[*?]') { ConvertTo-CheckupPath $expanded; return }
    # 通配符只展开一个目录层；绝不递归查找配置或浏览器用户目录。
    $parts = $expanded.Substring(3).Split([char]'\')
    $paths = @($expanded.Substring(0, 3))
    foreach ($part in $parts) {
        $next = [Collections.Generic.List[string]]::new()
        foreach ($path in $paths) {
            if ([datetime]::UtcNow -ge $DeadlineUtc) { throw '检查时间已到，部分位置尚未找到。' }
            if ($part -notmatch '[*?]') { $next.Add([IO.Path]::Combine($path, $part)); continue }
            $root = Get-CheckupRootEntry ($path.TrimEnd([char]'\'))
            if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $iterator = Get-CheckupEnumerator $path
            try {
                while ($iterator.MoveNext()) {
                    if ([datetime]::UtcNow -ge $DeadlineUtc) { throw '检查时间已到，部分位置尚未找到。' }
                    $entry = $iterator.Current
                    if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -and
                        ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $entry.Name -like $part) { $next.Add($entry.FullName) }
                }
            }
            finally { if ($iterator -is [IDisposable]) { $iterator.Dispose() } }
        }
        $paths = $next.ToArray()
    }
    $paths
}

function Get-CheckupLocations {
    param($Data, $Context, $KnownFolders, [datetime]$DeadlineUtc, $State)
    $targets = Get-CleanerTargets
    $locations = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[string]]::new()
    $unknown = [Collections.Generic.List[string]]::new()
    foreach ($item in $Data.Items) {
        $specifications = @()
        try {
            if ($item.ContainsKey('Category')) { $specifications = @($targets.Categories[$item.Category].Targets) }
            elseif ($item.ContainsKey('Path')) { $specifications = @(@{ Path = $item.Path; Scope = 'File' }) }
            elseif ($item.ContainsKey('KnownFolder')) {
                if (-not $KnownFolders.ContainsKey($item.KnownFolder)) { throw '这个用户文件夹的位置暂时无法读取。' }
                $specifications = @(@{ Path = $KnownFolders[$item.KnownFolder] })
            }
            elseif ($item.ContainsKey('Chat')) {
                $chat = $Data.Chats[$item.Chat]
                $chatPaths = [Collections.Generic.List[string]]::new()
                if ($KnownFolders.ContainsKey('Documents')) {
                    $names = @('Tencent Files')
                    if ($item.Chat -eq 'WeChat') { $names = @('WeChat Files', 'xwechat_files') }
                    foreach ($name in $names) { $chatPaths.Add([IO.Path]::Combine($KnownFolders.Documents, $name)) }
                }
                else { $unknown.Add($item.Id) }
                $custom = [Collections.Generic.List[object]]::new()
                foreach ($registry in $chat.Registry) {
                    $value = Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::Users) -SubKey ($Context.OriginalUserSid + '\' + $registry.Key) -Name $registry.Name
                    if ($value -is [string] -and $value.Length -gt 0) { $custom.Add(@{ Value = $value; IsParent = ($item.Chat -eq 'WeChat') }) }
                }
                foreach ($config in $chat.Configs) {
                    $configPath = Expand-CleanerPath -Pattern $config.Path -Context $Context
                    try {
                        $text = Read-CheckupSmallFile $configPath
                        foreach ($value in @(ConvertFrom-CheckupConfig $text $config.Format $Data.ConfigPathKeys)) { $custom.Add(@{ Value = $value; IsParent = ($config.Format -eq 'Text') }) }
                    }
                    catch [IO.FileNotFoundException] { }
                    catch [IO.DirectoryNotFoundException] { }
                    catch { $unknown.Add($item.Id); $issues.Add($item.Title + '：自定义位置暂时无法读取，已检查能找到的位置。') }
                }
                foreach ($value in $custom) {
                    try {
                        $expanded = Expand-CleanerPath -Pattern $value.Value -Context $Context
                        foreach ($candidate in @(Resolve-CheckupChatPaths $expanded $chat.FolderNames $value.IsParent)) {
                            # 自定义数据根可改名，但不能扩大为整盘、用户根或系统区域。
                            $reason = Get-CleanerForbiddenReason -LiteralPath $candidate -Context $Context
                            if ($reason) { throw '自定义文件夹范围无法确认。' }
                            $chatPaths.Add($candidate)
                        }
                    }
                    catch { $unknown.Add($item.Id); $issues.Add($item.Title + '：自定义位置无法确认，已跳过。') }
                }
                foreach ($path in $chatPaths) { $specifications += @{ Path = $path } }
            }
            foreach ($specification in $specifications) {
                try {
                    foreach ($path in @(Expand-CheckupPattern $specification.Path $Context $DeadlineUtc)) {
                        if (-not $path.StartsWith('C:\', [StringComparison]::OrdinalIgnoreCase)) { continue }
                        $priority = 50
                        if ($item.ContainsKey('Chat')) { $priority = 10 }
                        $locations.Add([pscustomobject]@{ Id = $item.Id; Path = $path; Priority = $priority
                            Scope = Get-CheckupValue $specification 'Scope' 'Contents'
                            FilePatterns = @(Get-CheckupValue $specification 'FilePatterns' @())
                            ExcludeChildren = @(Get-CheckupValue $specification 'ExcludeChildren' @())
                            Recursive = Get-CheckupValue $specification 'Recursive' $true })
                    }
                }
                catch [IO.FileNotFoundException] { }
                catch [IO.DirectoryNotFoundException] { }
                catch { $unknown.Add($item.Id); $issues.Add($item.Title + '：部分位置无法读取，大小可能不完整。') }
            }
        }
        catch { $unknown.Add($item.Id); $issues.Add($item.Title + '：位置暂时无法读取。') }
        # 按项发布快照，发现超时仍可检查已找到的位置。
        $State.Locations = $locations.ToArray(); $State.Issues = $issues.ToArray(); $State.Unknown = $unknown.ToArray()
    }
}

function Get-CheckupStorage {
    param($State)
    $system = @{ Letter = 'C:'; TotalBytes = [long]0; FreeBytes = [long]0 }
    $volumes = @(); $issues = @(); $count = $null
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.DriveType -ne [IO.DriveType]::Fixed) { continue }
            $letter = $drive.Name.Substring(0, 2)
            if ($letter -ieq 'C:') { $system.TotalBytes = [long]$drive.TotalSize; $system.FreeBytes = [long]$drive.AvailableFreeSpace }
            else { $volumes += [pscustomobject]@{ Letter = $letter; Label = $drive.VolumeLabel; FileSystem = $drive.DriveFormat
                TotalBytes = [long]$drive.TotalSize; FreeBytes = [long]$drive.AvailableFreeSpace; IsFixed = $true; OnSystemDisk = $null } }
        }
        catch { $issues += '部分磁盘的容量暂时无法读取。' }
        $State.Result = @{ SystemDrive = $system.Clone(); DataVolumes = @($volumes); PhysicalDiskCount = $count; Issues = @($issues) }
    }
    $diskMap = @{}
    try {
        foreach ($partition in @(Get-Partition -ErrorAction Stop)) {
            if ($partition.DriveLetter) { $diskMap[[string]$partition.DriveLetter + ':'] = $partition.DiskNumber }
        }
    }
    catch {
        try {
            foreach ($relation in @(Get-CimInstance -ClassName Win32_LogicalDiskToPartition -OperationTimeoutSec 3 -ErrorAction Stop)) {
                if ([string]$relation.Antecedent -match 'Disk #(\d+),' -and [string]$relation.Dependent -match 'DeviceID="([A-Za-z]:)"') {
                    $diskMap[$Matches[1]] = [int]([regex]::Match([string]$relation.Antecedent, 'Disk #(\d+),').Groups[1].Value)
                }
            }
        }
        catch { $issues += '暂时无法判断各分区是否位于同一块硬盘。' }
    }
    foreach ($volume in $volumes) {
        if ($diskMap.ContainsKey('C:') -and $diskMap.ContainsKey($volume.Letter)) { $volume.OnSystemDisk = ($diskMap['C:'] -eq $diskMap[$volume.Letter]) }
    }
    if (@($volumes | Where-Object { $null -eq $_.OnSystemDisk }).Count -gt 0) { $issues += '部分分区是否位于系统硬盘暂时未知。' }
    $State.Result = @{ SystemDrive = $system; DataVolumes = @($volumes); PhysicalDiskCount = $count; Issues = @($issues) }
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop); if ($disks.Count -gt 0) { $count = $disks.Count } }
    catch { }
    if ($null -eq $count) {
        try { $disks = @(Get-CimInstance -ClassName Win32_DiskDrive -OperationTimeoutSec 3 -ErrorAction Stop); if ($disks.Count -gt 0) { $count = $disks.Count } }
        catch { }
    }
    if ($null -eq $count) { $issues += '物理硬盘数量暂时未知。' }
    if ($system.TotalBytes -eq 0) { $issues += 'C 盘容量暂时未知，无法判断空间紧张程度。' }
    $State.Result = @{ SystemDrive = $system; DataVolumes = @($volumes); PhysicalDiskCount = $count; Issues = @($issues) }
}

function Get-CheckupBackup {
    param($Context, $KnownFolders, $State)
    $history = $null; $oneDrive = $null; $issues = @()
    try {
        $path = [IO.Path]::Combine($Context.LocalAppData, 'Microsoft\Windows\FileHistory\Configuration\Config1.xml')
        $text = Read-CheckupSmallFile $path
        $xml = [xml]::new(); $xml.XmlResolver = $null; $xml.LoadXml($text)
        $status = $xml.SelectSingleNode('//Config/Status')
        if ($null -eq $status) { $status = $xml.SelectSingleNode('//Status') }
        if ($null -ne $status) {
            if ($status.InnerText -ieq 'ENABLED') { $history = $true }
            elseif ($status.InnerText -ieq 'DISABLED') { $history = $false }
        }
    }
    catch { }
    $State.Result = @{ FileHistoryEnabled = $history; OneDriveSyncing = $oneDrive; Issues = @($issues) }
    $accounts = $null
    try {
        $accounts = [Microsoft.Win32.Registry]::Users.OpenSubKey($Context.OriginalUserSid + '\Software\Microsoft\OneDrive\Accounts', $false)
        if ($null -ne $accounts) {
            $foundRoot = $false; $matched = $false
            foreach ($account in $accounts.GetSubKeyNames()) {
                $root = Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::Users) -SubKey ($Context.OriginalUserSid + '\Software\Microsoft\OneDrive\Accounts\' + $account) -Name 'UserFolder'
                if (-not $root) { continue }
                $root = ConvertTo-CheckupPath $root; $foundRoot = $true
                foreach ($folder in $KnownFolders.Values) { if (Test-CheckupPathWithin $folder $root) { $matched = $true } }
            }
            if ($foundRoot -and $matched) {
                # 文件夹重定向 + 有 OneDrive 运行是尽力检测；不声称云端已有完整备份。
                if (@(Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId }).Count -gt 0) { $oneDrive = $true }
            }
            elseif ($foundRoot -and $KnownFolders.Count -eq 5) { $oneDrive = $false }
        }
    }
    catch { }
    finally { if ($null -ne $accounts) { $accounts.Dispose() } }
    if ($null -eq $history) { $issues += '文件历史记录是否开启暂时未知。' }
    if ($null -eq $oneDrive) { $issues += 'OneDrive 是否正在同步用户文件夹暂时未知。' }
    if ($oneDrive -eq $true) { $issues += '检测到 OneDrive 正在运行并接管用户文件夹；是否同步完成仍需在 OneDrive 中核实。' }
    $State.Result = @{ FileHistoryEnabled = $history; OneDriveSyncing = $oneDrive; Issues = @($issues) }
}

function Select-CheckupLargeApps {
    param([object[]]$Entries)
    $seen = @{}
    foreach ($entry in $Entries) {
        [long]$kb = 0
        if (-not [long]::TryParse([string](Get-CheckupValue $entry 'EstimatedSize'), [ref]$kb) -or $kb -le (1GB / 1KB) -or $kb -gt ([long]::MaxValue / 1KB)) { continue }
        $path = [string](Get-CheckupValue $entry 'InstallLocation' '')
        $name = [string](Get-CheckupValue $entry 'DisplayName' '')
        if ($path -notmatch '^(?i:C):[\\/]' -or [string]::IsNullOrWhiteSpace($name)) { continue }
        $version = [string](Get-CheckupValue $entry 'DisplayVersion' '')
        $key = ($name + '|' + $version + '|' + $path.TrimEnd([char]'\')).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [pscustomobject]@{ Name = $name; Version = $version; InstallLocation = $path; Bytes = [long]($kb * 1KB) }
    }
}

function Get-CheckupLargeApps {
    param($Data, $Context, $State)
    $apps = @(); $issues = @()
    foreach ($specification in $Data.UninstallKeys) {
        $base = $null; $root = $null
        try {
            # 显式 64 位视图：即使宿主为 32 位，也读取原生和 WOW6432Node 两处。
            $hive = [Microsoft.Win32.RegistryHive]::LocalMachine
            $keyPath = $specification.Key
            if ($specification.Hive -eq 'User') { $hive = [Microsoft.Win32.RegistryHive]::Users; $keyPath = $Context.OriginalUserSid + '\' + $keyPath }
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
            $root = $base.OpenSubKey($keyPath, $false)
            if ($null -eq $root) { continue }
            foreach ($name in $root.GetSubKeyNames()) {
                $key = $null
                try {
                    $key = $root.OpenSubKey($name, $false)
                    if ($null -eq $key) { continue }
                    $apps += @(Select-CheckupLargeApps @(@{ DisplayName = $key.GetValue('DisplayName', '')
                        DisplayVersion = $key.GetValue('DisplayVersion', ''); InstallLocation = $key.GetValue('InstallLocation', '')
                        EstimatedSize = $key.GetValue('EstimatedSize', $null) }))
                }
                catch { $issues += '部分软件的大小或安装位置暂时无法读取。' }
                finally { if ($null -ne $key) { $key.Dispose() } }
                $State.Result = @{ Apps = @($apps); Issues = @($issues) }
            }
        }
        catch { $issues += '部分软件清单暂时无法读取。' }
        finally { if ($null -ne $root) { $root.Dispose() }; if ($null -ne $base) { $base.Dispose() } }
    }
    # 不同注册表视图的同一软件只提示一次。
    $deduplicated = @($apps | Sort-Object Name, Version, InstallLocation -Unique)
    $State.Result = @{ Apps = $deduplicated; Issues = @($issues) }
}

function New-CheckupReport {
    param($Data, $Context, $SystemDrive, [object[]]$Measurements, [object[]]$DataVolumes,
        $Backup, [object[]]$Apps = @(), $Timings, [string[]]$Issues = @(), [datetimeoffset]$GeneratedAt = [datetimeoffset]::Now)
    $items = [Collections.Generic.List[object]]::new()
    [long]$safe = 0; [long]$confirm = 0; [long]$move = 0; $safeLower = $false
    foreach ($definition in $Data.Items) {
        $parts = @($Measurements | Where-Object { $_.Id -eq $definition.Id })
        [long]$bytes = 0; $lower = $false
        foreach ($part in $parts) { $bytes += [long]$part.Bytes; $lower = $lower -or $part.IsLowerBound }
        $paths = @($parts | ForEach-Object { $_.Paths } | Sort-Object -Unique)
        $detail = @{}
        if ($definition.ContainsKey('Name')) { $detail.Name = $definition.Name }
        if ($definition.Id -eq 'info:LargeApps') {
            $paths = @($Apps | ForEach-Object { $_.InstallLocation } | Sort-Object -Unique)
            foreach ($app in $Apps) { $bytes += [long]$app.Bytes }
            $detail = @{ Apps = @($Apps); SizeSource = 'EstimatedSizeKB' }
        }
        # 未知且为零的安全项不发条目，但仍传播到安全总量的下限标记。
        if ($definition.Group -eq 'safe') { $safeLower = $safeLower -or $lower }
        if ($bytes -le 0 -or ($definition.Group -eq 'move' -and $bytes -le 100MB)) { continue }
        $excluded = @($parts | ForEach-Object { @(Get-CheckupValue $_ 'ExcludedPaths' @()) } | Sort-Object -Unique)
        if ($excluded.Count -gt 0) { $detail.ExcludedPaths = $excluded }
        $items.Add([pscustomobject]@{ Id = $definition.Id; Group = $definition.Group; Title = $definition.Title
            Bytes = [long]$bytes; IsLowerBound = [bool]$lower; NeedsAdmin = [bool]$definition.NeedsAdmin
            Loss = $definition.Loss; Paths = @($paths); Detail = $detail })
        switch ($definition.Group) { 'safe' { $safe += $bytes }; 'confirm' { $confirm += $bytes }; 'move' { $move += $bytes } }
    }
    $backupResult = @{ PhysicalDiskCount = $Backup.PhysicalDiskCount; FileHistoryEnabled = $Backup.FileHistoryEnabled
        OneDriveSyncing = $Backup.OneDriveSyncing
        NeedsReminder = Get-CheckupNeedsReminder $Backup.PhysicalDiskCount $Backup.FileHistoryEnabled $Backup.OneDriveSyncing }
    $notes = @($Issues)
    if ($backupResult.NeedsReminder) {
        $notes += '电脑只检测到一块硬盘，尚未确认有备份。建议在“设置”中搜索“文件历史记录”，接入移动硬盘后开启；也可打开 OneDrive 的“同步和备份”来备份重要文件。'
    }
    return [pscustomobject]@{
        Schema = 'pc-care/checkup/1'; GeneratedAt = $GeneratedAt.ToString('yyyy-MM-ddTHH:mm:sszzz')
        User = @{ Sid = $Context.OriginalUserSid; Profile = $Context.OriginalUserProfile; IsElevated = [bool]$Context.IsAdmin }
        SystemDrive = @{ Letter = 'C:'; TotalBytes = [long]$SystemDrive.TotalBytes; FreeBytes = [long]$SystemDrive.FreeBytes
            Level = Get-CheckupLevel $SystemDrive.TotalBytes $SystemDrive.FreeBytes }
        Items = @($items.ToArray()); Totals = @{ SafeBytes = $safe; SafeIsLowerBound = [bool]$safeLower; ConfirmBytes = $confirm; MoveBytes = $move }
        DataVolumes = @($DataVolumes); Backup = $backupResult; NextStep = Get-CheckupNextStep $items.ToArray() $DataVolumes
        Timings = $Timings; Issues = @($notes | Sort-Object -Unique)
    }
}

function ConvertTo-CheckupMeasurements {
    param($Plan, $Snapshot, [bool]$Completed)
    foreach ($id in @($Plan.Selectors.Id | Sort-Object -Unique)) {
        [long]$bytes = 0; $lower = $true
        if ($null -ne $Snapshot) { $bytes = [long]$Snapshot.Bytes[$id]; $lower = $Snapshot.IsLowerBound -or -not $Completed }
        $selectors = @($Plan.Selectors | Where-Object { $_.Id -eq $id })
        $excluded = @($Plan.Selectors | Where-Object {
            $other = $_
            $other.Id -ne $id -and @($selectors | Where-Object { $_.Path -ine $other.Path -and (Test-CheckupPathWithin $other.Path $_.Path) }).Count -gt 0
        } | ForEach-Object { $_.Path } | Sort-Object -Unique)
        [pscustomobject]@{ Id = $id; Bytes = $bytes; IsLowerBound = [bool]$lower; Paths = @($selectors.Path); ExcludedPaths = $excluded }
    }
}

function Invoke-CheckupWorker {
    param([string]$Kind, $State, $Argument, $Data, [datetime]$DeadlineUtc, [int]$LocationSeconds)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        switch ($Kind) {
            'Discovery' {
                $context = Get-CleanerContext
                $State.Context = $context
                $folders = @{}
                try { $folders = Get-CleanerKnownFolderMap -Context $context }
                catch { $State.Issues = @('用户文件夹的位置暂时无法读取。') }
                $State.KnownFolders = $folders
                Get-CheckupLocations $Data $context $folders $DeadlineUtc $State
            }
            'Storage' { Get-CheckupStorage $State }
            'Backup' { Get-CheckupBackup $Argument.Context $Argument.KnownFolders $State }
            'Apps' { Get-CheckupLargeApps $Data $Argument.Context $State }
            'Measure' {
                $deadline = [datetime]::UtcNow.AddSeconds($LocationSeconds)
                if ($deadline -gt $DeadlineUtc) { $deadline = $DeadlineUtc }
                $null = Measure-CheckupTree -Plan $Argument -DeadlineUtc $deadline -State $State
            }
        }
    }
    catch { $State.Error = '部分检查未能完成，相关结果可能不完整。' }
    finally { $State.ElapsedMs = $timer.ElapsedMilliseconds }
}

function Start-CheckupWork {
    param($Pool, [string]$WorkerCode, [string]$Kind, $Argument, $Data, [datetime]$DeadlineUtc, [int]$LocationSeconds, [string]$Root)
    $state = [hashtable]::Synchronized(@{ Context = $null; KnownFolders = $null; Locations = @(); Unknown = @(); Issues = @()
        Result = $null; Snapshot = $null; Error = ''; ElapsedMs = [long]0 })
    $powershell = [PowerShell]::Create(); $powershell.RunspacePool = $Pool
    $null = $powershell.AddScript($WorkerCode).AddArgument($Root).AddArgument($Kind).AddArgument($state).AddArgument($Argument).AddArgument($Data).AddArgument($DeadlineUtc).AddArgument($LocationSeconds)
    $handle = $powershell.BeginInvoke()
    return [pscustomobject]@{ Kind = $Kind; State = $state; PowerShell = $powershell; Handle = $handle; Argument = $Argument; Done = $false; StartedUtc = [datetime]::UtcNow }
}

function Write-CheckupReport {
    param($Report, [string]$Path, $Context)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Context.LogPath),
            ('checkup-' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '-' + [guid]::NewGuid().ToString('N') + '.json'))
    }
    $Path = [IO.Path]::GetFullPath($Path)
    $check = Test-CleanerPathChain -LiteralPath $Path -AllowMissing
    if (-not $check.IsSafe) { throw '报告保存位置无法安全使用，请选择普通的本地文件夹。' }
    if ($check.Exists) { throw '报告文件已存在，请换一个新文件名。' }
    $json = ConvertTo-Json -InputObject $Report -Depth 8
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $stream = $null; $writer = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false)); $writer.Write($json)
    }
    catch { throw '无法新建体检报告，请检查文件夹权限和剩余空间。' }
    finally { if ($null -ne $writer) { $writer.Dispose() }; if ($null -ne $stream) { $stream.Dispose() } }
    return $Path
}

function Invoke-Checkup {
    param([string]$Root, [string]$Path, [int]$LocationSeconds, [int]$TotalSeconds)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [datetime]::UtcNow.AddSeconds([math]::Min($TotalSeconds, 55))
    $data = Import-PowerShellDataFile -LiteralPath (Join-Path $Root 'checkup-locations.psd1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'checkup.ps1'), [ref]$tokens, [ref]$errors)
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
    $worker = 'param($Root, $Kind, $State, $Argument, $Data, $DeadlineUtc, $LocationSeconds)' + "`n" +
        'Set-StrictMode -Version 2.0; $ErrorActionPreference = ''Stop''; . (Join-Path $Root ''common.ps1'')' + "`n" + $definitions + "`n" +
        'Invoke-CheckupWorker $Kind $State $Argument $Data $DeadlineUtc $LocationSeconds'
    $pool = [RunspaceFactory]::CreateRunspacePool(1, [math]::Max(1, [math]::Min(8, [Environment]::ProcessorCount)))
    $pool.Open()
    $jobs = [Collections.Generic.List[object]]::new()
    $plans = @(); $measurementStarted = $false; $metadataStarted = $false
    $issues = [Collections.Generic.List[string]]::new(); $steps = @{}
    Write-Host '正在检查：C 盘空间和已知文件夹'
    $discovery = Start-CheckupWork $pool $worker 'Discovery' $null $data $deadline $LocationSeconds $Root
    $jobs.Add($discovery)
    $jobs.Add((Start-CheckupWork $pool $worker 'Storage' $null $data $deadline $LocationSeconds $Root))
    try {
        while ([datetime]::UtcNow -lt $deadline) {
            foreach ($job in $jobs) {
                if (-not $job.Done -and $job.Handle.IsCompleted) {
                    try { $null = $job.PowerShell.EndInvoke($job.Handle) }
                    catch { $job.State.Error = '部分检查未能完成，相关结果可能不完整。' }
                    $job.Done = $true; $job.PowerShell.Dispose()
                }
            }
            if (-not $metadataStarted -and $null -ne $discovery.State.KnownFolders) {
                $argument = @{ Context = $discovery.State.Context; KnownFolders = $discovery.State.KnownFolders }
                $jobs.Add((Start-CheckupWork $pool $worker 'Backup' $argument $data $deadline $LocationSeconds $Root))
                $jobs.Add((Start-CheckupWork $pool $worker 'Apps' $argument $data $deadline $LocationSeconds $Root))
                $metadataStarted = $true
                Write-Host '正在检查：备份状态和大软件'
            }
            if (-not $measurementStarted -and $discovery.Done) {
                $plans = @(Merge-CheckupLocations $discovery.State.Locations)
                foreach ($plan in $plans) {
                    $display = @($data.Items | Where-Object { $_.Id -eq $plan.Selectors[0].Id })[0]
                    $title = Get-CheckupValue $display 'Name' $display.Title
                    Write-Host ('正在检查：' + $title)
                    $jobs.Add((Start-CheckupWork $pool $worker 'Measure' $plan $data $deadline $LocationSeconds $Root))
                }
                $measurementStarted = $true
            }
            if ($measurementStarted -and @($jobs | Where-Object { -not $_.Done }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 25
        }
    }
    finally {
        $pending = @($jobs | Where-Object { -not $_.Done })
        if ($pending.Count -gt 0) {
            foreach ($job in $pending) { try { $null = $job.PowerShell.BeginStop($null, $null) } catch { } }
            # Dispose/Stop/Close 会等待阻塞的系统调用；到时只能异步请求停止，不能在此同步等待。
            try { $pool.CloseAsync() } catch { }
        }
        else { $pool.Close(); $pool.Dispose() }
    }
    $context = $discovery.State.Context
    if ($null -eq $context) { throw '未能在时限内读取当前用户信息，无法确定报告保存位置。' }
    $measurements = [Collections.Generic.List[object]]::new()
    $storage = @{ SystemDrive = @{ TotalBytes = 0; FreeBytes = 0 }; DataVolumes = @(); PhysicalDiskCount = $null }
    $backup = @{ PhysicalDiskCount = $null; FileHistoryEnabled = $null; OneDriveSyncing = $null }
    $apps = @()
    foreach ($job in $jobs) {
        $stepName = $job.Kind
        if ($job.Kind -eq 'Measure') { $stepName = 'Location:' + $job.Argument.Path }
        $steps[$stepName] = [long]$job.State.ElapsedMs
        if (-not $job.Done) { $steps[$stepName] = [long]([datetime]::UtcNow - $job.StartedUtc).TotalMilliseconds }
        if (-not $job.Done) { $issues.Add('检查时间已到，部分结果仅为已检查部分；没有结果的项目仍为未知。') }
        if ($job.State.Error) { $issues.Add($job.State.Error) }
        switch ($job.Kind) {
            'Discovery' { foreach ($note in $job.State.Issues) { $issues.Add($note) } }
            'Storage' { if ($null -ne $job.State.Result) { $storage = $job.State.Result } }
            'Backup' { if ($null -ne $job.State.Result) { $backup = $job.State.Result } }
            'Apps' {
                if ($null -ne $job.State.Result) { $apps = @($job.State.Result.Apps) }
                if (-not $job.Done -or $job.State.Error -or ($null -ne $job.State.Result -and $job.State.Result.Issues.Count -gt 0)) {
                    $measurements.Add([pscustomobject]@{ Id = 'info:LargeApps'; Bytes = [long]0; IsLowerBound = $true; Paths = @() })
                }
            }
            'Measure' {
                $snapshot = $job.State.Snapshot
                foreach ($measurement in @(ConvertTo-CheckupMeasurements $job.Argument $snapshot $job.Done)) { $measurements.Add($measurement) }
                if ($null -ne $snapshot -and $snapshot.Issue) {
                    $titles = @($data.Items | Where-Object { $_.Id -in $job.Argument.Selectors.Id } | ForEach-Object { $_.Title } | Sort-Object -Unique)
                    $issues.Add(($titles -join '、') + '：' + $snapshot.Issue)
                }
            }
        }
        if ($null -ne $job.State.Result) { foreach ($note in @(Get-CheckupValue $job.State.Result 'Issues' @())) { $issues.Add($note) } }
    }
    foreach ($definition in $data.Items) {
        if ($definition.Id -in $discovery.State.Unknown -or ((-not $discovery.Done -or $discovery.State.Error) -and $definition.Group -eq 'safe')) {
            $measurements.Add([pscustomobject]@{ Id = $definition.Id; Bytes = [long]0; IsLowerBound = $true; Paths = @() })
        }
    }
    $backup.PhysicalDiskCount = $storage.PhysicalDiskCount
    if ($storage.SystemDrive.TotalBytes -le 0) { $issues.Add('C 盘容量暂时未知，无法判断空间紧张程度。') }
    foreach ($field in @('PhysicalDiskCount', 'FileHistoryEnabled', 'OneDriveSyncing')) {
        if ($null -eq $backup[$field]) { $issues.Add('部分磁盘或备份信息暂时未知，请在系统设置中核实。') }
    }
    $report = New-CheckupReport $data $context $storage.SystemDrive $measurements.ToArray() $storage.DataVolumes $backup $apps @{
        TotalMs = [long]$timer.ElapsedMilliseconds; Steps = $steps
    } $issues.ToArray()
    $resultPath = Write-CheckupReport $report $Path $context
    Write-Output ('RESULT: ' + $resultPath)
}

if ($PSCmdlet.ShouldProcess('C:', '只读体检并新建报告')) {
    Invoke-Checkup -Root $PSScriptRoot -Path $ReportPath -LocationSeconds $LocationTimeoutSeconds -TotalSeconds $TotalTimeoutSeconds
}

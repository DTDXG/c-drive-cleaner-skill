Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/checkup.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ($errors.Message -join '; ') }
foreach ($name in @('Get-CheckupValue', 'ConvertTo-CheckupPath', 'Test-CheckupPathWithin', 'Get-CheckupLevel',
    'Get-CheckupNeedsReminder', 'Get-CheckupNextStep', 'Merge-CheckupLocations', 'Get-CheckupSelection',
    'Measure-CheckupTree', 'ConvertFrom-CheckupConfig', 'ConvertFrom-CheckupConfigBytes', 'Resolve-CheckupChatPaths',
    'ConvertTo-CheckupMeasurements', 'Select-CheckupLargeApps', 'New-CheckupReport')) {
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($definitions.Count -ne 1) { throw "函数缺失或重复：$name" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$data = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'scripts/checkup-locations.psd1')
$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw "失败：$Message" }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:assertions++
    if ($null -eq $Expected) { if ($null -ne $Actual) { throw "失败：$Message；预期 null，实际 $Actual" } }
    elseif ($Actual -ne $Expected) { throw "失败：$Message；预期 $Expected，实际 $Actual" }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $caught = $false
    try { & $Action } catch { $caught = $true }
    Assert-True $caught $Message
}
function New-Measurement {
    param([string]$Id, [long]$Bytes, [bool]$Lower = $false, [string[]]$Paths = @('C:\test'))
    return [pscustomobject]@{ Id = $Id; Bytes = $Bytes; IsLowerBound = $Lower; Paths = @($Paths) }
}
function New-FakeEntry {
    param([string]$Path, [long]$Length = 0, [int]$Attributes = 0)
    return [pscustomobject]@{ FullName = $Path; Name = $Path.Substring($Path.LastIndexOf('\') + 1); Length = $Length; Attributes = $Attributes }
}
$context = @{ OriginalUserSid = 'S-1-5-21-test'; OriginalUserProfile = 'C:\Users\测试'; IsAdmin = $false }
$drive = @{ TotalBytes = 200GB; FreeBytes = 15GB }
$backup = @{ PhysicalDiskCount = 1; FileHistoryEnabled = $null; OneDriveSyncing = $null }
$timings = @{ TotalMs = 25; Steps = @{ Discovery = 5; Storage = 10; Measurement = 10 } }
$generated = [datetimeoffset]::Parse('2026-10-23T15:04:05+08:00')

# 分类和显示名来自纯数据，所有契约 id 都有稳定映射。
$safeIds = @('cache:UserTemp', 'cache:WindowsTemp', 'cache:ThumbnailCache', 'cache:BrowserCache', 'cache:InetCache',
    'cache:AppCache', 'cache:ShaderCache', 'system:UpdateCache', 'system:DeliveryOptimization', 'system:CrashDumps')
$confirmIds = @('system:RecycleBin', 'system:Hibernate', 'system:WindowsOld')
$moveIds = @('move:KnownFolder:Desktop', 'move:KnownFolder:Documents', 'move:KnownFolder:Downloads',
    'move:KnownFolder:Pictures', 'move:KnownFolder:Videos', 'move:WeChat', 'move:QQ')
Assert-Equal $data.Items.Count 21 '仅有 21 个契约 id'
$fake = @()
foreach ($id in @($safeIds + $confirmIds + $moveIds)) { $fake += New-Measurement $id 200MB }
$fakeApps = @(@{ Name = '示例软件'; Version = '1'; InstallLocation = 'C:\Apps\Example'; Bytes = [long]2GB })
$report = New-CheckupReport $data $context $drive $fake @() $backup $fakeApps $timings @() $generated
foreach ($id in $safeIds) {
    $item = @($report.Items | Where-Object { $_.Id -eq $id })[0]
    Assert-Equal $item.Group 'safe' "$id 放心清"
    Assert-Equal $item.Loss '' "$id 没有损失提示"
}
foreach ($id in $confirmIds) {
    $item = @($report.Items | Where-Object { $_.Id -eq $id })[0]
    Assert-Equal $item.Group 'confirm' "$id 单独确认"
    Assert-True ($item.Loss.Length -gt 5) "$id 说明后果"
}
foreach ($id in $moveIds) { Assert-Equal @($report.Items | Where-Object { $_.Id -eq $id })[0].Group 'move' "$id 搬家" }
$byId = @{}; foreach ($item in $report.Items) { $byId[$item.Id] = $item }
Assert-Equal $byId['cache:UserTemp'].Title '系统临时文件' '用户临时目录标题'
Assert-Equal $byId['cache:WindowsTemp'].Title $byId['cache:UserTemp'].Title '同标题保留不同 id'
Assert-Equal $byId['cache:BrowserCache'].Title $byId['cache:InetCache'].Title '浏览器缓存标题归并'
Assert-Equal $byId['system:CrashDumps'].Title '常见软件缓存' '崩溃报告标题归并'
Assert-Equal $byId['system:Hibernate'].Title '系统大文件' '系统大文件标题'
Assert-Equal $byId['system:WindowsOld'].Title $byId['system:Hibernate'].Title '两种系统大文件同标题'
Assert-Equal $byId['move:WeChat'].Title '聊天软件文件' '聊天数据标题'
Assert-Equal $byId['move:QQ'].Title $byId['move:WeChat'].Title '两种聊天数据同标题'
Assert-Equal $byId['move:KnownFolder:Downloads'].Title '用户文件夹' '用户文件夹标题'
Assert-Equal $byId['move:KnownFolder:Desktop'].Title $byId['move:KnownFolder:Downloads'].Title '用户文件夹同标题'
Assert-Equal $byId['move:KnownFolder:Downloads'].Detail.Name '下载文件夹' '明细保留具体文件夹名'
foreach ($id in @('cache:WindowsTemp', 'system:UpdateCache', 'system:DeliveryOptimization', 'system:Hibernate', 'system:WindowsOld')) {
    Assert-True $byId[$id].NeedsAdmin "$id 需要管理员"
}
Assert-True (-not $byId['system:RecycleBin'].NeedsAdmin) '原用户回收站无需管理员'
Assert-True ($byId['system:RecycleBin'].Loss -match '无法.*恢复') '回收站后果'
Assert-True ($byId['system:Hibernate'].Loss -match '休眠和快速启动') '休眠后果'
Assert-True ($byId['system:WindowsOld'].Loss -match '无法回退') '旧版系统后果'
Assert-Equal $report.Totals.SafeBytes (200MB * 10) '安全总量'
Assert-Equal $report.Totals.ConfirmBytes (200MB * 3) '确认总量'
Assert-Equal $report.Totals.MoveBytes (200MB * 7) '搬家总量'
Assert-True (-not $report.Totals.SafeIsLowerBound) '完整安全总量'

# 零和未知项目不冒充已知可清理空间，搬家严格大于 100 MB。
$parts = @((New-Measurement 'cache:UserTemp' 11), (New-Measurement 'cache:UserTemp' 7 $true),
    (New-Measurement 'cache:WindowsTemp' 0 $true), (New-Measurement 'system:Hibernate' 9 $true),
    (New-Measurement 'move:KnownFolder:Downloads' 100MB), (New-Measurement 'move:QQ' (100MB + 1)),
    (New-Measurement 'future:Unknown' 10GB))
$partial = New-CheckupReport $data $context $drive $parts @() $backup @() $timings
Assert-Equal $partial.Totals.SafeBytes 18 '下限仍累加已知值'
Assert-True $partial.Totals.SafeIsLowerBound '部分不可读传播到安全总量'
Assert-Equal @($partial.Items | Where-Object { $_.Group -eq 'safe' }).Count 1 '零大小未知项不发出'
Assert-True @($partial.Items | Where-Object { $_.Id -eq 'cache:UserTemp' })[0].IsLowerBound '单项下限传播'
Assert-True @($partial.Items | Where-Object { $_.Id -eq 'system:Hibernate' })[0].IsLowerBound '确认项下限传播'
Assert-Equal @($partial.Items | Where-Object { $_.Group -eq 'move' }).Count 1 '100 MB 边界不发出'
Assert-Equal $partial.Totals.MoveBytes (100MB + 1) '搬家总量只包含发出的项目'
$zero = New-CheckupReport $data $context $drive @((New-Measurement 'cache:UserTemp' 0 $true)) @() $backup @() $timings
Assert-Equal $zero.Items.Count 0 '未知零值没有条目'
Assert-True $zero.Totals.SafeIsLowerBound '只有未知安全项时也必须标下限'
Assert-Equal $zero.NextStep 'none' '未知不当作正收益'

foreach ($case in @(@(1000, 100, 'ok'), @(1000, 99, 'tight'), @(1000, 50, 'tight'), @(1000, 49, 'severe'), @(0, 0, 'ok'))) {
    Assert-Equal (Get-CheckupLevel $case[0] $case[1]) $case[2] '10% / 5% 严格边界'
}
$safeItems = @(@{ Group = 'safe'; Bytes = [long]1GB })
$moveItems = @(@{ Group = 'move'; Bytes = [long]2GB }, @{ Group = 'move'; Bytes = [long]3GB })
$dataVolume = @{ Letter = 'D:'; IsFixed = $true; FileSystem = 'NTFS'; FreeBytes = [long]5GB }
Assert-Equal (Get-CheckupNextStep $safeItems @()) 'clean' '只有安全项先清理'
Assert-Equal (Get-CheckupNextStep @() @($dataVolume)) 'none' '没有项目无需操作'
Assert-Equal (Get-CheckupNextStep ($safeItems + $moveItems) @($dataVolume)) 'move' '搬家优先且空间相等可用'
Assert-Equal (Get-CheckupNextStep $moveItems @()) 'partition' '没有数据盘建议规划'
foreach ($override in @(@{ Letter = 'C:' }, @{ IsFixed = $false }, @{ FileSystem = 'exFAT' }, @{ FreeBytes = (5GB - 1) })) {
    $volume = $dataVolume.Clone(); foreach ($key in $override.Keys) { $volume[$key] = $override[$key] }
    Assert-Equal (Get-CheckupNextStep $moveItems @($volume)) 'partition' '不合适的数据盘不推荐搬家'
}
foreach ($disks in @($null, 0, 1, 2)) {
    foreach ($history in @($null, $false, $true)) {
        foreach ($sync in @($null, $false, $true)) {
            $expected = ($null -ne $disks -and $disks -eq 1 -and $history -ne $true -and $sync -ne $true)
            Assert-Equal (Get-CheckupNeedsReminder $disks $history $sync) $expected '备份提醒三态组合'
        }
    }
}
Assert-Equal $zero.Backup.FileHistoryEnabled $null '文件历史记录未知保留 null'
Assert-Equal $zero.Backup.OneDriveSyncing $null '云同步未知保留 null'
Assert-True $zero.Backup.NeedsReminder '单盘且没有已知开启备份就提醒'
Assert-True (($zero.Issues -join ' ') -match '设置.*文件历史记录.*OneDrive') '提醒包含开启方法'

# 前缀去重忽略大小写、末尾分隔符，但不吞掉相似前缀的兄弟目录。
$locations = @(@{ Id = 'move:KnownFolder:Documents'; Path = 'C:\Users\me\Documents' },
    @{ Id = 'move:KnownFolder:Documents'; Path = 'c:/users/me/Documents/' },
    @{ Id = 'move:WeChat'; Path = 'C:\Users\me\Documents\WeChat Files'; Priority = 10 },
    @{ Id = 'move:QQ'; Path = 'C:\Users\me\Documents\Tencent Files'; Priority = 10 },
    @{ Id = 'move:KnownFolder:Downloads'; Path = 'C:\Users\me\Documents-other' })
$plans = @(Merge-CheckupLocations $locations)
Assert-Equal $plans.Count 2 '嵌套路径只启动一个扫描根'
Assert-Equal $plans[0].Selectors.Count 3 '重复选择器去除，保留聊天归属'
Assert-True (-not (Test-CheckupPathWithin 'C:\cache-other' 'C:\cache')) '路径段边界'
Assert-True (Test-CheckupPathWithin 'c:\CACHE\child' 'C:\cache') '忽略大小写'
foreach ($path in @('C:\', 'C:', '\\server\share', 'C:\Users\..\Windows', 'C:\x:stream', 'C:\Users\\me')) {
    Assert-Throws { ConvertTo-CheckupPath $path } '拒绝全盘和模糊路径'
}

# 目录统计仅使用内存目录和注入时钟；没有任何真实文件枚举和 Windows 调用。
$script:tree = @{}; $script:enumerated = @(); $script:failPaths = @(); $script:lazyFailure = $false
$enumerate = {
    param($path)
    $script:enumerated += $path
    if ($path -in $script:failPaths) { throw [UnauthorizedAccessException]::new('fake denied') }
    $entries = @($script:tree[$path])
    if ($script:lazyFailure) {
        $fakeIterator = [pscustomobject]@{ Entries = $entries; Index = -1; Current = $null }
        $fakeIterator | Add-Member ScriptMethod MoveNext {
            $this.Index++
            if ($this.Index -eq 1) { throw [IO.IOException]::new('fake lazy failure') }
            if ($this.Index -ge $this.Entries.Count) { return $false }
            $this.Current = $this.Entries[$this.Index]; return $true
        }
        return ,$fakeIterator
    }
    return ,$entries.GetEnumerator()
}
$getRoot = { param($path) New-FakeEntry $path 0 ([int][IO.FileAttributes]::Directory) }
$now = [datetime]::Parse('2026-10-23T00:00:00Z').ToUniversalTime()
$clock = { $now }.GetNewClosure()
$deadline = $now.AddSeconds(10)
$base = $plans[0].Path
$script:tree[$base] = @((New-FakeEntry ($base + '\document.txt') 4),
    (New-FakeEntry ($base + '\WeChat Files') 0 16), (New-FakeEntry ($base + '\Tencent Files') 0 16),
    (New-FakeEntry ($base + '\link') 999 1040))
$script:tree[$base + '\WeChat Files'] = @((New-FakeEntry ($base + '\WeChat Files\chat.db') 6))
$script:tree[$base + '\Tencent Files'] = @((New-FakeEntry ($base + '\Tencent Files\chat.db') 8))
$size = Measure-CheckupTree $plans[0] $deadline $getRoot $enumerate $clock
Assert-Equal $size.Bytes['move:KnownFolder:Documents'] 4 '父目录只计剩余文档'
Assert-Equal $size.Bytes['move:WeChat'] 6 '子目录微信单独归属'
Assert-Equal $size.Bytes['move:QQ'] 8 '子目录 QQ 单独归属'
Assert-Equal $script:enumerated.Count 3 '每个真实目录恰好遍历一次'
Assert-True (-not (($base + '\link') -in $script:enumerated)) '链接绝不进入'
Assert-True $size.IsLowerBound '跳过链接保守标下限'
Assert-True $size.Exists '找到根目录'
$partitioned = @(ConvertTo-CheckupMeasurements $plans[0] $size $true)
Assert-Equal $partitioned.Count 3 '一次遍历产生三个互斥测量'
$parentMeasurement = @($partitioned | Where-Object { $_.Id -eq 'move:KnownFolder:Documents' })[0]
Assert-Equal $parentMeasurement.ExcludedPaths.Count 2 '父项注明另列的两个聊天目录'
Assert-Equal @($partitioned | Where-Object { $_.Id -eq 'move:WeChat' })[0].ExcludedPaths.Count 0 '子项没有误排除父目录'
$cutoff = @(ConvertTo-CheckupMeasurements $plans[0] @{ Bytes = $size.Bytes; IsLowerBound = $false } $false)
Assert-Equal @($cutoff | Where-Object { -not $_.IsLowerBound }).Count 0 '总体超时强制每个子测量为下限'
$notStarted = @(ConvertTo-CheckupMeasurements $plans[0] $null $false)
Assert-Equal @($notStarted | Where-Object { $_.Bytes -ne 0 -or -not $_.IsLowerBound }).Count 0 '排队中未启动的位置仍未知'

$single = @(Merge-CheckupLocations @(@{ Id = 'cache:UserTemp'; Path = 'C:\Temp' }))[0]
$script:tree = @{ 'C:\Temp' = @((New-FakeEntry 'C:\Temp\one' 11), (New-FakeEntry 'C:\Temp\two' 13), (New-FakeEntry 'C:\Temp\bad' 0 16)) }
$script:failPaths = @('C:\Temp\bad')
$size = Measure-CheckupTree $single $deadline $getRoot $enumerate $clock
Assert-Equal $size.Bytes['cache:UserTemp'] 24 '一个目录拒绝访问仍保留其他文件长度'
Assert-True $size.IsLowerBound '拒绝访问为下限'
Assert-True ($size.Issue -match '无法读取') '拒绝访问有中文说明'
$script:failPaths = @(); $script:lazyFailure = $true
$size = Measure-CheckupTree $single $deadline $getRoot $enumerate $clock
Assert-Equal $size.Bytes['cache:UserTemp'] 11 '延迟枚举异常保留前面的文件'
Assert-True $size.IsLowerBound '迭代期间 IO 异常也是下限'
$script:lazyFailure = $false; $script:clockCalls = 0
$expiringClock = { $script:clockCalls++; if ($script:clockCalls -ge 2) { $now.AddSeconds(11) } else { $now } }
$state = @{}
$size = Measure-CheckupTree $single $deadline $getRoot $enumerate $expiringClock 2 $state
Assert-Equal $size.Bytes['cache:UserTemp'] 11 '每 N 项检查时限并停止'
Assert-True $size.IsLowerBound '超时为下限'
Assert-True ($size.Issue -match '时间已到') '超时说明'
Assert-Equal $state.Snapshot.Bytes['cache:UserTemp'] 11 '共享快照保留已完成的统计'
$size = Measure-CheckupTree $single $now $getRoot $enumerate $clock
Assert-Equal $size.Bytes['cache:UserTemp'] 0 '开始前到期不扫描'
Assert-True $size.IsLowerBound '开始前到期也为下限'
$size = Measure-CheckupTree $single $deadline { throw [IO.DirectoryNotFoundException]::new('missing') } $enumerate $clock
Assert-True (-not $size.Exists -and -not $size.IsLowerBound) '不存在目录不是未知大小'
$size = Measure-CheckupTree $single $deadline { throw [UnauthorizedAccessException]::new('denied') } $enumerate $clock
Assert-True ($null -eq $size.Exists -and $size.IsLowerBound) '根目录拒绝访问为未知下限'
$script:enumerated = @()
$size = Measure-CheckupTree $single $deadline { param($path) New-FakeEntry $path 0 1040 } $enumerate $clock
Assert-Equal $script:enumerated.Count 0 '根目录为链接也不枚举'
Assert-Equal $size.Bytes['cache:UserTemp'] 0 '链接不计长度'

$selected = @(Merge-CheckupLocations @(@{ Id = 'cache:ThumbnailCache'; Path = 'C:\Explorer'; Scope = 'SelectedFiles'; Recursive = $false; FilePatterns = @('thumbcache_*.db') }))[0]
$script:tree = @{ 'C:\Explorer' = @((New-FakeEntry 'C:\Explorer\thumbcache_1.db' 10), (New-FakeEntry 'C:\Explorer\other.db' 100), (New-FakeEntry 'C:\Explorer\child' 0 16)) }
$size = Measure-CheckupTree $selected $deadline $getRoot $enumerate $clock
Assert-Equal $size.Bytes['cache:ThumbnailCache'] 10 '缩略图只统计白名单文件'
Assert-True (-not $size.IsLowerBound) '有意排除的文件不导致下限'
$excluded = @(Merge-CheckupLocations @(@{ Id = 'cache:InetCache'; Path = 'C:\InetCache'; ExcludeChildren = @('Content.Outlook') }))[0]
$script:tree = @{ 'C:\InetCache' = @((New-FakeEntry 'C:\InetCache\cache' 12), (New-FakeEntry 'C:\InetCache\Content.Outlook' 0 16), (New-FakeEntry 'C:\InetCache\cloud' 100 4096)) }
$size = Measure-CheckupTree $excluded $deadline $getRoot $enumerate $clock
Assert-Equal $size.Bytes['cache:InetCache'] 12 '保留附件目录和云端占位文件都不计量'
Assert-True $size.IsLowerBound '未知云端本地占用为下限'
$filePlan = @(Merge-CheckupLocations @(@{ Id = 'system:Hibernate'; Path = 'C:\hiberfil.sys'; Scope = 'File' }))[0]
$size = Measure-CheckupTree $filePlan $deadline { param($path) New-FakeEntry $path 8GB } $enumerate $clock
Assert-Equal $size.Bytes['system:Hibernate'] 8GB '单文件只读取长度'

$paths = @(ConvertFrom-CheckupConfig '{"nested":{"file_save_path":"C:\\Chat"},"unrelated":"C:\\Windows"}' Json $data.ConfigPathKeys)
Assert-Equal $paths.Count 1 '配置只读已知路径字段'
Assert-Equal $paths[0] 'C:\Chat' '读取嵌套配置路径'
$paths = @(ConvertFrom-CheckupConfig "MyDocument:`nC:\Chat`n" Text $data.ConfigPathKeys)
Assert-Equal $paths.Count 1 '忽略旧微信默认目录标记'
$paths = @(Resolve-CheckupChatPaths 'C:\Chat' @('WeChat Files', 'xwechat_files') $true)
Assert-Equal ($paths -join '|') 'C:\Chat\WeChat Files|C:\Chat\xwechat_files' '旧微信配置是父目录'
$paths = @(Resolve-CheckupChatPaths 'C:\Chat\xwechat_files' @('WeChat Files', 'xwechat_files') $true)
Assert-Equal $paths[0] 'C:\Chat\xwechat_files' '完整微信数据目录不再追加目录名'
$paths = @(Resolve-CheckupChatPaths 'C:\我的聊天资料' @('Tencent Files', 'QQNT') $false)
Assert-Equal $paths[0] 'C:\我的聊天资料' 'QQ NT 自定义数据目录可以改名'
Assert-Throws { Resolve-CheckupChatPaths 'C:\' @('QQNT') $false } '配置也不能触发全盘遍历'
$text = 'C:\聊天资料'
$utf8 = [Text.Encoding]::UTF8.GetBytes($text)
Assert-Equal (ConvertFrom-CheckupConfigBytes $utf8 $utf8.Length) $text '无 BOM 的 UTF-8 中文路径'
$utf16 = [byte[]](@(255, 254) + @([Text.Encoding]::Unicode.GetBytes($text)))
Assert-Equal (ConvertFrom-CheckupConfigBytes $utf16 $utf16.Length) $text '带 BOM 的 UTF-16 中文路径'
$utf8Bom = [byte[]](@(239, 187, 191) + @($utf8))
Assert-Equal (ConvertFrom-CheckupConfigBytes $utf8Bom $utf8Bom.Length) $text 'UTF-8 BOM 不混入路径'
$apps = @(Select-CheckupLargeApps @(@{ DisplayName = '软件'; InstallLocation = 'C:\Apps'; EstimatedSize = 2097152 },
    @{ DisplayName = '软件'; InstallLocation = 'C:\Apps'; EstimatedSize = 2097152 },
    @{ DisplayName = '边界'; InstallLocation = 'C:\Apps'; EstimatedSize = 1048576 },
    @{ DisplayName = '其他盘'; InstallLocation = 'D:\Apps'; EstimatedSize = 2097152 },
    @{ DisplayName = '未知位置'; EstimatedSize = 2097152 },
    @{ DisplayName = '坏数据'; InstallLocation = 'C:\Apps'; EstimatedSize = 'oops' }))
Assert-Equal $apps.Count 1 '大软件筛选位置、大小并去重'
Assert-Equal $apps[0].Bytes 2GB '卸载信息 KB 转字节'

# 实际 JSON 往返验证空数组、null、数值和深度，报告由假测量构建。
$json = ConvertTo-Json -InputObject $report -Depth 8
$roundtrip = ConvertFrom-Json -InputObject $json
Assert-Equal $roundtrip.Schema 'pc-care/checkup/1' '报告模式'
Assert-Equal $roundtrip.GeneratedAt '2026-10-23T15:04:05+08:00' '带偏移的时间'
Assert-Equal (($roundtrip.PSObject.Properties.Name | Sort-Object) -join ',') 'Backup,DataVolumes,GeneratedAt,Issues,Items,NextStep,Schema,SystemDrive,Timings,Totals,User' '顶层字段严格契约'
Assert-Equal $roundtrip.User.Sid 'S-1-5-21-test' '用户身份'
Assert-Equal $roundtrip.SystemDrive.Level 'tight' '报告空间等级'
Assert-Equal $roundtrip.Timings.TotalMs 25 '阶段计时形状'
Assert-Equal $roundtrip.Items.Count 21 '报告全部已知项目'
foreach ($item in $report.Items) {
    Assert-True ($item.Bytes -is [long]) 'Bytes 为 int64'
    Assert-True ($item.IsLowerBound -is [bool] -and $item.NeedsAdmin -is [bool]) '布尔字段'
    Assert-True ($item.Paths -is [array]) '路径始终为数组'
    Assert-True ($null -ne $item.Detail) '明细对象'
}
$emptyJson = ConvertTo-Json -InputObject $zero -Depth 8
Assert-True ($emptyJson -match '"Items":\s*\[\s*\]') '空条目编码为数组'
Assert-True ($emptyJson -match '"DataVolumes":\s*\[\s*\]') '空卷编码为数组'
Assert-True ($emptyJson -match '"FileHistoryEnabled":\s*null') '未知编码为 null'
Assert-Equal $roundtrip.Items[20].Detail.Apps[0].Name '示例软件' '大软件明细未被序列化深度截断'
$withVolume = New-CheckupReport $data $context $drive $fake @(@{ Letter = 'D:'; Label = '资料'; FileSystem = 'NTFS'; TotalBytes = 500GB; FreeBytes = 400GB; IsFixed = $true; OnSystemDisk = $true }) $backup @() $timings
$volumeJson = ConvertFrom-Json (ConvertTo-Json -InputObject $withVolume -Depth 8)
Assert-Equal $volumeJson.DataVolumes.Count 1 '单个数据卷仍为数组'
Assert-Equal $volumeJson.DataVolumes[0].OnSystemDisk $true '同盘信息保留'
Assert-Equal $volumeJson.NextStep 'move' '完整报告从假卷决定搬家'
Write-Host ("PASS t4-checkup: {0} assertions; AST-only loading; in-memory fakes; no script body executed." -f $script:assertions)

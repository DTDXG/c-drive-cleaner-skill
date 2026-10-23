Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/partition.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ($errors.Message -join '; ') }
# 只载入函数，绝不执行脚本体或 Windows API；适配器在下面用内存假实现替换。
foreach ($definition in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
    . ([scriptblock]::Create($definition.Extent.Text))
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
    if ($Actual -ne $Expected) { throw "失败：$Message；预期 $Expected，实际 $Actual" }
}
function Copy-TestObject { param($Object); return (ConvertTo-Json -InputObject $Object -Depth 8 | ConvertFrom-Json) }
function New-TestPartition {
    param([int]$Number = 1, [long]$Offset = 1MB, [long]$Size = 500GB, [string]$Letter = 'C',
        [int]$DiskNumber = 0, [string]$Type = 'Basic', [string]$FileSystem = 'NTFS')
    return [pscustomobject]@{ DiskNumber = $DiskNumber; PartitionNumber = $Number; Offset = $Offset; Size = $Size
        DriveLetter = $Letter; Type = $Type; GptType = 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'; MbrType = 0
        FileSystem = $FileSystem; HasVolume = ($FileSystem -ne ''); IsSystem = $false; IsBoot = ($Letter -eq 'C'); IsHidden = $false
        VolumeSize = $Size; FreeBytes = ($Size - 100GB); Label = '' }
}
function New-TestDisk {
    param([int]$Number = 0, [object[]]$Partitions = @(), [long]$Size = (500GB + 2MB), [string]$BusType = 'NVMe')
    return [pscustomobject]@{ Number = $Number; UniqueId = ('disk-' + $Number); SerialNumber = ('serial-' + $Number)
        Size = $Size; PartitionStyle = 'GPT'; BusType = $BusType; IsOffline = $false; IsReadOnly = $false; IsRemovable = $false
        IsDynamic = $false; IsStorageSpaces = $false; InspectionComplete = $true; Partitions = @($Partitions) }
}
function New-TestState {
    $c = New-TestPartition
    return [pscustomobject]@{ Disks = @((New-TestDisk -Partitions @($c))); SystemDiskNumber = 0
        CUsedBytes = [long]100GB; MaxShrinkBytes = [long]340GB; BitLocker = 'Off'; UsedLetters = @('C'); UserSid = 'test-sid' }
}
function Assert-Refused {
    param($PlanObject, $State, [string]$Message)
    Assert-True (-not (Test-PcFrozenPlan $PlanObject $State).Valid) $Message
}

# PRD 四行情况；已有数据盘只映射用途。
$s = New-TestState; $p = New-PcPartitionPlan $s
Assert-True (Test-PcFrozenPlan (Copy-TestObject $p) $s).Valid '方案 JSON 往返及新版自动日期转换兼容'
Assert-Equal $p.Situation 'ShrinkC' '仅 C 且足够 -> 压缩'
Assert-True $p.Feasible '普通方案可行'
Assert-Equal $p.CAfterBytes 160GB '冻结 C 保留值'
Assert-Equal @($p.NewVolumes).Count 2 '340 GB 默认两个盘'
Assert-Equal $p.NewVolumes[0].DriveLetter 'D' '默认 D'
Assert-Equal $p.NewVolumes[1].DriveLetter 'E' '默认 E'
Assert-True ($p.Summary -match 'C 盘从 500 GB 变成 160 GB') '一句话前后变化'
Assert-Equal @($p.NewVolumes[0].Folders).Count 4 '资料默认目录'
Assert-True ($p.Warnings -match '不算备份').Count '同盘不算备份'
$s.Disks[0].Partitions += New-TestPartition 2 (501GB) 200GB 'D'
$s.Disks[0].Size = 702GB
$p = New-PcPartitionPlan $s
Assert-Equal $p.Situation 'ExistingData' '已有数据分区 -> 不分区'
Assert-Equal $p.Mode 'None' '不生成写入模式'
Assert-Equal @($p.NewVolumes).Count 0 '不改现有数据盘'
Assert-Equal $p.PurposeMappings[0].DriveLetter 'D' '按现有盘符映射用途'
Assert-Equal @(Get-PcPartitionSteps $p).Count 0 '不分区的方案无写步骤'
$s = New-TestState; $s.Disks[0].Size += 100GB
$p = New-PcPartitionPlan $s
Assert-Equal $p.Situation 'UnallocatedSpace' '未分配空间优先'
Assert-Equal $p.CAfterBytes 500GB '空闲空间方案保留 C'
Assert-True (Test-PcFrozenPlan $p $s).Valid '未分配方案可执行'
$s = New-TestState; $s.Disks += New-TestDisk 1 @() 1TB 'SATA'
$p = New-PcPartitionPlan $s
Assert-Equal $p.Situation 'EmptyDisk' '空内部硬盘优先于压缩 C'
Assert-Equal $p.Disk.Number 1 '明确空盘编号'
Assert-True ($p.Summary -match '硬盘 1') '摘要明确空盘'
Assert-True (Test-PcFrozenPlan $p $s).Valid '空盘冻结方案可执行'
$s.Disks[1].PartitionStyle = 'RAW'; $p = New-PcPartitionPlan $s
Assert-Equal @(Get-PcPartitionSteps $p)[0].Id 'InitializeDisk' '全新空白盘先建立分区表'
Assert-Equal $p.NewVolumes[0].Offset 17MB '为 Windows 自动保留分区让出位置'
$s = New-TestState; $s.CUsedBytes = 430GB; $p = New-PcPartitionPlan $s
Assert-Equal $p.Situation 'InsufficientSpace' '空间不足不分区'
Assert-Equal @($p.NewVolumes).Count 0 '不足不创建小分区'
Assert-True ($p.Summary -match '清理.*移动硬盘') '不足时建议清理和外部磁盘'

# 保留量、Windows 可压缩量、推荐边界及布局校验。
Assert-Equal (Get-PcReserve 10GB) 120GB '最低保留 120 GB'
Assert-Equal (Get-PcReserve 100GB) 160GB '已用加 60 GB'
Assert-Equal (Get-PcUsable 500GB 100GB 50GB) 50GB 'Windows 限制优先'
Assert-Equal (Get-PcUsable 500GB 100GB $null) 340GB '未知限制只估算'
Assert-Equal (Get-PcUsable 120GB 110GB 10GB) 0 '保留量不能为负'
foreach ($case in @(@(199GB, 1), @(200GB, 2), @(1TB, 2), @((1TB + 1MB), 3))) {
    Assert-Equal @(Get-PcDefaultLayout $case[0]).Count $case[1] ('推荐边界 ' + $case[0])
}
$r = Resolve-PcLayout @(@{ Label = '资料'; SizeGB = 40 }, @{ Label = '游戏'; SizeGB = 'rest' }) 100GB @('C', 'D')
Assert-True $r.Valid '合法 rest 布局'
Assert-Equal $r.Volumes[0].DriveLetter 'E' '跳过已用 D'
Assert-Equal $r.Volumes[1].Size 60GB 'rest 在规划时求值'
foreach ($case in @(
    @{ Volumes = @(@{ Label = '大'; SizeGB = 101 }); Name = '超出空间' },
    @{ Volumes = @(@{ Label = '小'; SizeGB = 19 }); Name = '小于 20 GB' },
    @{ Volumes = @(@{ Label = '无效'; SizeGB = 'bad' }); Name = '无效大小' },
    @{ Volumes = @(@{ Label = '无效'; SizeGB = -20 }); Name = '负大小' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 20; Letter = 'C' }); Name = '不能用 C' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 20; Letter = 'D' }); Name = '盘符被占用' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 20; Letter = 'DD' }); Name = '盘符格式' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 20; Letter = 'E' }, @{ Label = '游戏'; SizeGB = 20; Letter = 'E' }); Name = '重复盘符' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 'rest' }, @{ Label = '游戏'; SizeGB = 20 }); Name = 'rest 必须最后' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 'rest' }, @{ Label = '游戏'; SizeGB = 'rest' }); Name = '不能重复 rest' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 90 }, @{ Label = '游戏'; SizeGB = 'rest' }); Name = 'rest 不得太小' },
    @{ Volumes = @(@{ Label = 'bad/name'; SizeGB = 40 }); Name = '卷名字符' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 40; Folders = @('..\逃逸') }); Name = '目录逃逸' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 40; Folders = @('NUL') }); Name = '保留目录名' },
    @{ Volumes = @(@{ Label = '资料'; SizeGB = 40; Folders = @('下载', '下载') }); Name = '重复目录' }
)) { Assert-True (-not (Resolve-PcLayout $case.Volumes 100GB @('C', 'D')).Valid) $case.Name }
$s = New-TestState
foreach ($json in @('bad', '[]', 'null', '{"Count":0}', '{"Count":1.5}', '{"Count":24}', '{"Count":2,"Volumes":[{"Label":"资料","SizeGB":30}]}', '{"Volumes":[{"Label":"资料","SizeGB":900}]}', '{"Volumes":[{"Label":"资料","SizeGB":8589934592}]}')) {
    Assert-True (-not (New-PcPartitionPlan $s $json).Feasible) ('错误布局返回不可行计划 ' + $json)
}
$p = New-PcPartitionPlan $s '{"Count":1,"Volumes":[{"Label":"项目","SizeGB":40,"Letter":"G","Folders":["代码","资料"]}]}'
Assert-True $p.Feasible '自定义布局可行'
Assert-Equal $p.CAfterBytes 460GB '只压出固定布局的空间'
Assert-Equal $p.NewVolumes[0].DriveLetter 'G' '自定义盘符'
Assert-Equal $p.NewVolumes[0].Folders[0] '代码' '自定义目录'
Assert-True (Test-PcFrozenPlan $p $s).Valid '固定大小布局可执行'
$d = $s.Disks[0]; $d.PartitionStyle = 'MBR'
$d.Partitions += @(New-TestPartition 2 (501GB) 1GB '' 0 'Recovery' ''; New-TestPartition 3 (502GB) 1GB '' 0 'Reserved' '')
Assert-Equal @(Get-PcMbrReasons $d 1).Count 0 '三主分区可再加一个'
Assert-Equal @(Get-PcMbrReasons $d 2).Count 1 '超过四主分区拒绝'
$d.Partitions[2].MbrType = 15
Assert-True (@(Get-PcMbrReasons $d 1)[0] -match '扩展分区') '扩展分区不误算空闲主分区'

# P1：指纹只含稳定事实；执行核对冻结字节数，不重新规划 rest。
$s = New-TestState; $s.MaxShrinkBytes = 300GB; $p = New-PcPartitionPlan $s; $old = Copy-TestObject $p
$s.CUsedBytes = 101GB; $s.MaxShrinkBytes = 301GB
Assert-Equal (Get-PcFingerprint $s 0) $p.Fingerprint 'P1 已用和 max shrink 改变不影响指纹'
Assert-True (Test-PcFrozenPlan $p $s).Valid 'P1 保留量仍够时允许执行原方案'
Assert-Equal $p.NewVolumes[1].Size $old.NewVolumes[1].Size 'P1 rest 未重新计算'
$s.CUsedBytes = 150GB
Assert-Refused $p $s 'P1 实时保留空间不足拒绝'
$s.CUsedBytes = 100GB; $s.MaxShrinkBytes = 299GB
Assert-Refused $p $s 'P1 Windows 新限制不足拒绝'
$s = New-TestState; $p = New-PcPartitionPlan $s
foreach ($field in @('Size', 'Offset', 'DriveLetter', 'Type', 'GptType', 'PartitionNumber')) {
    $changed = Copy-TestObject $s
    switch ($field) {
        'Size' { $changed.Disks[0].Partitions[0].Size += 1MB }
        'Offset' { $changed.Disks[0].Partitions[0].Offset += 1MB }
        'DriveLetter' { $changed.Disks[0].Partitions[0].DriveLetter = 'X' }
        'Type' { $changed.Disks[0].Partitions[0].Type = 'Changed' }
        'GptType' { $changed.Disks[0].Partitions[0].GptType = 'different' }
        'PartitionNumber' { $changed.Disks[0].Partitions[0].PartitionNumber = 7 }
    }
    Assert-True ((Get-PcFingerprint $changed 0) -ne $p.Fingerprint) ('P1 指纹覆盖分区 ' + $field)
    Assert-Refused $p $changed ('P1 ' + $field + ' 变化拒绝')
}
foreach ($field in @('UniqueId', 'SerialNumber', 'Size', 'PartitionStyle')) {
    $changed = Copy-TestObject $s
    if ($field -eq 'Size') { $changed.Disks[0].Size += 1GB } else { $changed.Disks[0].$field = 'changed' }
    Assert-Refused $p $changed ('P1 硬盘身份 ' + $field)
}
$changed = Copy-TestObject $s; $changed.UsedLetters += 'D'; Assert-Refused $p $changed 'P1 盘符后来被占用拒绝'
$future = Copy-TestObject $p; $future.GeneratedAt = [datetimeoffset]::Now.AddHours(1).ToString('o'); Assert-Refused $future $s '未来时间的方案拒绝'
$expired = Copy-TestObject $p; $expired.GeneratedAt = [datetimeoffset]::Now.AddHours(-2).ToString('o'); Assert-Refused $expired $s '方案一小时过期'
$at = [datetimeoffset]::Now; $boundary = Copy-TestObject $p; $boundary.GeneratedAt = $at.AddHours(-1).ToString('o')
Assert-True (Test-PcFrozenPlan $boundary $s $at).Valid '恰好一小时仍有效'
$bad = Copy-TestObject $p; $bad.NewVolumes[0].Offset -= 1GB; Assert-Refused $bad $s '冻结偏移越界拒绝'
$bad = Copy-TestObject $p; $bad.NewVolumes[0].Size = 999GB; Assert-Refused $bad $s '冻结大小越界拒绝'
$bad = Copy-TestObject $p; $bad.Feasible = $false; Assert-Refused $bad $s '不可行方案不能执行'
$s = New-TestState; $s.Disks[0].Size += 100GB; $p = New-PcPartitionPlan $s
$s.MaxShrinkBytes = 0; $s.CUsedBytes = 490GB
Assert-True (Test-PcFrozenPlan $p $s).Valid 'P1 未分配方案不因 C 使用量变化而拒绝'
$bad = Copy-TestObject $p; $bad.NewVolumes[0].Offset = 1MB; Assert-Refused $bad $s 'P1 冻结空闲位置被占用拒绝'

# P2：普通权限下未知只进入待确认；提权后必须得出肯定结论。
$s = New-TestState; $s.BitLocker = 'Unknown'; $s.MaxShrinkBytes = $null
$s.Disks[0].IsDynamic = $null; $s.Disks[0].IsStorageSpaces = $null
$p = New-PcPartitionPlan $s
Assert-True $p.Feasible 'P2 未知检查不使规划不可行'
Assert-True ($p.PendingChecks.Count -ge 3) 'P2 未读到的事实记为待确认'
Assert-Equal $p.UsableBytes 340GB 'P2 未知 max shrink 用保留线估算'
Assert-True (($p.Warnings -join '') -match 'Windows 确认') 'P2 标明执行时 Windows 决定'
Assert-Refused $p $s 'P2 提权后仍未知拒绝'
$s.BitLocker = 'Off'; $s.MaxShrinkBytes = 340GB; $s.Disks[0].IsDynamic = $false; $s.Disks[0].IsStorageSpaces = $false
Assert-True (Test-PcFrozenPlan $p $s).Valid 'P2 所有待确认现在通过即允许'
foreach ($state in @('Protected', 'Unknown')) {
    $s.BitLocker = $state; Assert-Refused $p $s ('P2 默认加密策略 ' + $state)
}
$s.BitLocker = 'Protected'
Assert-True (Test-PcFrozenPlan $p $s -BlockEncrypted:$false).Valid '单行策略开关可以改变加密限制'
foreach ($field in @('IsDynamic', 'IsStorageSpaces')) {
    $s = New-TestState; $p = New-PcPartitionPlan $s; $s.Disks[0].$field = $true
    Assert-Refused $p $s ($field + ' 执行硬阻断')
    Assert-True (-not (New-PcPartitionPlan $s).Feasible) ($field + ' 规划硬阻断')
    Assert-True (-not (Test-PcFrozenPlan $p $s -BlockEncrypted:$false).Valid) ($field + ' 不受加密策略影响')
}
$s = New-TestState; $s.Disks[0].BusType = 'RAID'
Assert-True (-not (New-PcPartitionPlan $s).Feasible) 'RAID 规划拒绝'
$s = New-TestState; $s.Disks[0].Partitions += New-TestPartition 2 (500GB + 1MB) 500MB '' 0 'Recovery' ''
$s.Disks[0].Size += 500MB; $p = New-PcPartitionPlan $s
Assert-True (($p.Warnings -join '') -match '以后不能直接扩大 C 盘') '恢复分区紧接 C 的警告'
Assert-Equal (ConvertFrom-PcBitLockerStatus "Conversion Status: Fully Decrypted`nProtection Status: Protection Off") 'Off' '英文加密状态解析'
Assert-Equal (ConvertFrom-PcBitLockerStatus "转换状态：完全解密`n保护状态：保护关闭") 'Off' '中文加密状态解析'
Assert-Equal (ConvertFrom-PcBitLockerStatus "Conversion Status: Fully Encrypted`nProtection Status: Protection Off") 'Protected' '暂停保护仍加密'
Assert-Equal (ConvertFrom-PcBitLockerStatus 'Access is denied') 'Unknown' '读取失败不当未加密'

# P3：数据盘需要内部设备、盘符和真实文件卷；未知 OEM 分区永不成为空闲空间。
foreach ($bus in @('NVMe', 'SATA', 'SAS', 'ATA', 'SCSI', 'RAID', 'Virtual', 'File Backed Virtual')) {
    Assert-True (Test-PcInternalDisk (New-TestDisk -BusType $bus)) ('P3 内部总线 ' + $bus)
}
foreach ($bus in @('USB', 'SD', 'MMC', 'Unknown', 'iSCSI')) {
    $s = New-TestState; $external = New-TestDisk 1 @((New-TestPartition 1 1MB 100GB 'D' 1)) 200GB $bus; $s.Disks += $external
    Assert-Equal (New-PcPartitionPlan $s).Situation 'ShrinkC' ('P3 忽略外部数据盘 ' + $bus)
    Assert-True (-not (New-PcPartitionPlan $s '{"DiskNumber":1}').Feasible) ('P3 明确指定外部盘也拒绝 ' + $bus)
    $external.Partitions = @()
    Assert-Equal (New-PcPartitionPlan $s).Disk.Number 0 ('P3 外部空盘不自动选择 ' + $bus)
}
$s = New-TestState; $s.Disks[0].IsRemovable = $true
Assert-True (-not (New-PcPartitionPlan $s).Feasible) 'P3 removable 即使内部总线也拒绝'
foreach ($fs in @('NTFS', 'ReFS', 'exFAT', 'FAT32')) {
    $d = New-TestDisk 1 @() 200GB 'SATA'; $part = New-TestPartition 1 1MB 100GB 'D' 1 'Basic' $fs
    Assert-True (Test-PcDataPartition $d $part) ('P3 支持真实文件系统 ' + $fs)
    $part.DriveLetter = ''; Assert-True (-not (Test-PcDataPartition $d $part)) 'P3 无盘符不是数据分区'
    $part.DriveLetter = 'D'; $part.HasVolume = $false; Assert-True (-not (Test-PcDataPartition $d $part)) 'P3 无挂载卷不是数据分区'
}
$d = New-TestDisk 1 @() 200GB 'SATA'; $part = New-TestPartition 1 1MB 100GB 'D' 1 'Basic' 'RAW'
Assert-True (-not (Test-PcDataPartition $d $part)) 'P3 RAW 不是数据分区'
$s = New-TestState; $oem = New-TestPartition 2 (500GB + 1MB) 30GB '' 0 'OEM' ''
$s.Disks[0].Partitions += $oem; $s.Disks[0].Size += 30GB
$p = New-PcPartitionPlan $s
Assert-Equal $p.Situation 'ShrinkC' 'P3 OEM 不是数据分区也不是未分配空间'
foreach ($v in $p.NewVolumes) { Assert-True (-not (Test-PcOverlap $v $oem)) 'P3 新卷不覆盖 OEM' }
$d = New-TestDisk 1 @((New-TestPartition 1 1MB 100GB '' 1 'Basic' 'NTFS')) 200GB 'SATA'
Assert-True (-not (Test-PcEmptyDisk $d $true)) 'P3 明确指定也不触碰无盘符文件卷'
$d = New-TestDisk 1 @((New-TestPartition 1 1MB 1GB '' 1 'Reserved' '')) 200GB 'SATA'
Assert-True (-not (Test-PcEmptyDisk $d $false)) '有保留分区时不自动当空盘'
Assert-True (Test-PcEmptyDisk $d $true) '明确指定且只含保留分区可用空闲空间'
$s = New-TestState; $rawData = New-TestPartition 2 (500GB + 1MB) 30GB 'G' 0 'Basic' 'RAW'
$s.Disks[0].Partitions += $rawData; $s.Disks[0].Size += 30GB; $s.UsedLetters += 'G'; $p = New-PcPartitionPlan $s
$rawData.FileSystem = 'NTFS'
Assert-Equal (Get-PcFingerprint $s 0) $p.Fingerprint '文件系统变化不是分区表指纹的一部分'
Assert-Refused $p $s '实时已出现数据盘时保留布局，不重新分区'

# P4：C 盘 64 MB / 新分区 1 MB、16 MB 容差；只减最后卷，绝不扩大任一卷。
$s = New-TestState; $p = New-PcPartitionPlan $s; $c = $s.Disks[0].Partitions[0]
$actual = Copy-TestObject $c; $actual.Size = $p.CAfterBytes + 32MB
$r = Resolve-PcAfterShrink $c $actual $p.CAfterBytes $p.NewVolumes 120GB
Assert-True $r.Valid 'P4 C 盘向上取整 32 MB 可继续'
Assert-Equal $r.NewVolumes[0].Offset ($p.NewVolumes[0].Offset + 32MB) 'P4 起点采用实际 C 结尾'
Assert-Equal $r.NewVolumes[0].Size $p.NewVolumes[0].Size 'P4 不减少前面的卷'
Assert-Equal $r.NewVolumes[1].Size ($p.NewVolumes[1].Size - 32MB) 'P4 仅减少最后卷'
Assert-Equal $r.NewVolumes[1].Offset ($p.NewVolumes[1].Offset + 32MB) 'P4 每个偏移重新计算'
$actual.Size = $p.CAfterBytes - 32MB; $r = Resolve-PcAfterShrink $c $actual $p.CAfterBytes $p.NewVolumes 120GB
Assert-True $r.Valid 'P4 C 盘向下取整可继续'
Assert-Equal $r.NewVolumes[1].Size $p.NewVolumes[1].Size 'P4 多出空间也不扩大最后卷'
$actual.Size = $p.CAfterBytes + 64MB
Assert-True (Resolve-PcAfterShrink $c $actual $p.CAfterBytes $p.NewVolumes 120GB).Valid 'P4 64 MB 边界'
$actual.Size += 1
Assert-True (-not (Resolve-PcAfterShrink $c $actual $p.CAfterBytes $p.NewVolumes 120GB).Valid) 'P4 超过 64 MB 停止'
$small = New-PcPartitionPlan $s '{"Count":1,"Volumes":[{"Label":"资料","SizeGB":20}]}'
$actual.Size = $small.CAfterBytes + 1MB
Assert-True (-not (Resolve-PcAfterShrink $c $actual $small.CAfterBytes $small.NewVolumes 120GB).Valid) 'P4 最后卷减至不足 20 GB 停止'
$actual.Size = $p.CAfterBytes - 1MB
Assert-True (-not (Resolve-PcAfterShrink $c $actual $p.CAfterBytes $p.NewVolumes $p.CAfterBytes).Valid) 'P4 实际 C 不能小于实时保留量'
$v = $p.NewVolumes[0]; $createdPart = New-TestPartition 2 ($v.Offset + 1MB) ($v.Size - 16MB) ''
Assert-True (Test-PcCreatedSize $v $createdPart) 'P4 新分区对齐容差边界'
$createdPart.Offset += 1
Assert-True (-not (Test-PcCreatedSize $v $createdPart)) 'P4 超过 1 MB 偏移拒绝'
$createdPart.Offset = $v.Offset; $createdPart.Size = $v.Size - 16MB - 1
Assert-True (-not (Test-PcCreatedSize $v $createdPart)) 'P4 超过 16 MB 变小拒绝'
$createdPart.Size = $v.Size + 1
Assert-True (-not (Test-PcCreatedSize $v $createdPart)) 'P4 不允许新分区变大'

# 格式化守卫必须用本次创建记录、实际分区和调整后的旧 C；不能格式化旧盘或重试。
$target = New-TestPartition 2 $v.Offset ($v.Size - 8MB) '' 0 'Basic' ''
$shrunk = Copy-TestObject $c; $shrunk.Size = $p.CAfterBytes
$records = @([pscustomobject]@{ RunId = 'this-run'; Partition = (Copy-TestObject $target) })
$current = @($shrunk, $target)
Assert-True (Test-PcFormatTarget $target $records @($shrunk) $current 'this-run') 'P4 实际创建记录通过格式化守卫'
Assert-True (-not (Test-PcFormatTarget $target @() @($shrunk) $current 'this-run')) '没有创建记录拒绝'
Assert-True (-not (Test-PcFormatTarget $target $records @($shrunk) $current 'other-run')) '其他运行创建记录拒绝'
Assert-True (-not (Test-PcFormatTarget $target $records @($c) $current 'this-run')) '与旧分区重叠拒绝'
Assert-True (-not (Test-PcFormatTarget $shrunk $records @($shrunk) $current 'this-run')) '永不格式化原 C'
$wrong = Copy-TestObject $target; $wrong.Size -= 1MB
Assert-True (-not (Test-PcFormatTarget $wrong $records @($shrunk) @($shrunk, $wrong) 'this-run')) '记录必须精确匹配实际字节数'
$wrong = Copy-TestObject $target; $wrong.FileSystem = 'NTFS'
Assert-True (-not (Test-PcFormatTarget $wrong $records @($shrunk) @($shrunk, $wrong) 'this-run')) '不能再次格式化已有文件卷'
$changedLive = Copy-TestObject $target; $changedLive.Offset += 1MB
Assert-True (-not (Test-PcFormatTarget $target $records @($shrunk) @($shrunk, $changedLive) 'this-run')) '读取后实时目标又变更时拒绝格式化'
$steps = @(Get-PcPartitionSteps $p)
Assert-Equal (($steps.Id) -join ',') 'ShrinkC,NewPartition,FormatVolume,AssignLetter,CreateFolders,NewPartition,FormatVolume,AssignLetter,CreateFolders' 'R2 执行步骤顺序：无盘符新建、格式化、分配盘符、目录'

# R2：有盘符的原始分区也不能进入格式化，精确身份必须仍来自本次无盘符创建记录。
$lettered = Copy-TestObject $target; $lettered.DriveLetter = 'D'
Assert-True (-not (Test-PcCreatedSize $v $lettered)) 'R2 新建回读必须无盘符'
$letteredRecords = @(@{ RunId = 'this-run'; Partition = $lettered })
Assert-True (-not (Test-PcFormatTarget $lettered $letteredRecords @($shrunk) @($shrunk, $lettered) 'this-run')) 'R2 即使记录匹配也拒绝带盘符的原始分区'
foreach ($field in @('DiskNumber', 'PartitionNumber', 'Offset', 'Size')) {
    $wrong = Copy-TestObject $target; $wrong.$field += 1
    Assert-True (-not (Test-PcFormatTarget $wrong $records @($shrunk) @($shrunk, $wrong) 'this-run')) ('R2 创建身份不匹配拒绝 ' + $field)
}
Assert-True (-not (Test-PcFormatTarget $target $records @($shrunk, $target) $current 'this-run')) 'R2 旧分区即使伪装成本次记录也拒绝'
$overlap = Copy-TestObject $target; $overlap.PartitionNumber = 9
Assert-True (-not (Test-PcFormatTarget $target $records @($shrunk) @($shrunk, $target, $overlap) 'this-run')) 'R2 实时其他分区重叠拒绝'
$formatted = Copy-TestObject $target; $formatted.FileSystem = 'NTFS'
Assert-True (Test-PcAssignLetter $formatted $records @($shrunk) @($shrunk, $formatted) 'this-run' 'D' @('C')).Valid 'R2 本次无盘符 NTFS 可分配盘符'
Assert-True (-not (Test-PcAssignLetter $target $records @($shrunk) $current 'this-run' 'D' @('C')).Valid) 'R2 未格式化不可分配盘符'
Assert-True (-not (Test-PcAssignLetter $formatted $records @($shrunk) @($shrunk, $formatted) 'other-run' 'D' @('C')).Valid) 'R2 分配盘符仍核对本次创建证据'
Assert-True (-not (Test-PcAssignLetter $formatted $records @($shrunk) @($shrunk, $formatted) 'this-run' 'D' @('C', 'D')).Valid) 'R2 分配时盘符占用拒绝'

# 适配器假实现：覆盖整个执行器，不运行任何 Windows / 外部进程 / 日志写入。
$script:sideEffects = @(); $script:fakeParts = @(); $script:shrinkDelta = 0; $script:newDelta = 0; $script:failAt = ''; $script:newOffsetDelta = 0
function Write-PcPartitionLog { param($Step, $Status, $Message, $Context); $script:sideEffects += ('Log:' + $Status) }
function Read-PcDiskPartitions { param($DiskNumber); return @($script:fakeParts) }
function Read-PcUsedLetters { return @($script:fakeParts | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter }) }
function Read-PcPartition {
    param($DiskNumber, $PartitionNumber)
    if ($script:failAt -eq 'ReadNew' -and $PartitionNumber -gt 1) { throw '模拟创建后回读失败' }
    return @($script:fakeParts | Where-Object { $_.PartitionNumber -eq $PartitionNumber })[0]
}
function Resize-PcC {
    param($DiskNumber, $PartitionNumber, $Size)
    $script:sideEffects += 'Resize'
    if ($script:failAt -eq 'ShrinkC') { throw '模拟缩小失败' }
    $script:fakeParts[0].Size = $Size + $script:shrinkDelta
}
function New-PcDataPartition {
    param($Volume)
    $script:sideEffects += 'New'
    if ($script:failAt -eq 'NewPartition') { throw '模拟创建失败' }
    $new = New-TestPartition ($script:fakeParts.Count + 1) ($Volume.Offset + $script:newOffsetDelta) ($Volume.Size + $script:newDelta) '' $Volume.DiskNumber 'Basic' ''
    $script:fakeParts += $new
    return Copy-TestObject $new
}
function Format-PcNewVolume {
    param($Partition, $Label)
    $script:sideEffects += 'Format'
    Assert-Equal $Partition.DriveLetter '' 'R2 格式化入口没有盘符'
    if ($script:failAt -eq 'FormatVolume') { throw '模拟格式化失败' }
    $found = Read-PcPartition $Partition.DiskNumber $Partition.PartitionNumber; $found.FileSystem = 'NTFS'; $found.Label = $Label
}
function Set-PcPartitionLetter {
    param($Partition, $Letter)
    $script:sideEffects += 'Assign'
    if ($script:failAt -eq 'AssignLetter') { throw '模拟分配盘符失败' }
    $found = Read-PcPartition $Partition.DiskNumber $Partition.PartitionNumber
    Assert-Equal $found.FileSystem 'NTFS' 'R2 分配入口已经格式化'
    Assert-Equal $found.DriveLetter '' 'R2 分配前保持无盘符'
    $found.DriveLetter = $Letter
}
function New-PcVolumeFolder { param($Letter, $Name); $script:sideEffects += 'Folder'; if ($script:failAt -eq 'CreateFolders') { throw '模拟建目录失败' } }
function Reset-TestExecution {
    param($State)
    $script:sideEffects = @(); $script:fakeParts = @((Copy-TestObject $State.Disks[0].Partitions[0]))
    $script:shrinkDelta = 0; $script:newDelta = 0; $script:failAt = ''; $script:newOffsetDelta = 0
}
$context = @{ IsAdmin = $true; CurrentUserSid = 'test-sid' }
$s = New-TestState; $p = New-PcPartitionPlan $s; Reset-TestExecution $s
$r = Invoke-PcPartitionExecution $p $s $context -WhatIf
Assert-Equal $r.Status 'WhatIf' 'WhatIf 状态'
Assert-Equal $script:sideEffects.Count 0 'WhatIf 无任何副作用调用'
Assert-Equal $r.Steps.Count 9 'WhatIf 打印完整步骤'
Assert-Equal $script:fakeParts[0].Size 500GB 'WhatIf C 未变'
Reset-TestExecution $s; $script:shrinkDelta = 32MB; $script:newDelta = -8MB; $script:newOffsetDelta = 1MB
$r = Invoke-PcPartitionExecution $p $s $context -Confirm:$false
Assert-Equal $r.Status 'Done' ('P4 对齐差异整个执行成功：' + $r.Reason)
Assert-Equal $r.CAfterBytes ($p.CAfterBytes + 32MB) 'P4 结果报告 C 实际值'
Assert-Equal $r.CreatedPartitions[0].Partition.Size ($p.NewVolumes[0].Size - 8MB) 'P4 记录新卷实际值'
Assert-Equal $r.CreatedPartitions[0].Partition.Offset ($p.NewVolumes[0].Offset + 33MB) 'P4 记录新卷实际对齐偏移'
Assert-Equal $r.FinalLayout[2].Size ($p.NewVolumes[1].Size - 32MB - 8MB) 'P4 最后卷实际值'
Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'Format' }).Count 2 '只格式化两个本次新卷'
foreach ($failure in @('ShrinkC', 'NewPartition', 'FormatVolume', 'AssignLetter', 'CreateFolders')) {
    Reset-TestExecution $s; $script:failAt = $failure
    $r = Invoke-PcPartitionExecution $p $s $context -Confirm:$false
    Assert-Equal $r.Status 'Failed' ('首次失败即停 ' + $failure)
    Assert-Equal $r.StoppedAt ($failure + ':' + $(if ($failure -eq 'ShrinkC') { -1 } else { 0 })) '准确记录停止步骤'
    Assert-Equal $r.Steps[-1].Status 'Failed' '步骤记录失败'
    $operation = @{ ShrinkC = 'Resize'; NewPartition = 'New'; FormatVolume = 'Format'; AssignLetter = 'Assign'; CreateFolders = 'Folder' }[$failure]
    Assert-Equal @($script:sideEffects | Where-Object { $_ -eq $operation }).Count 1 '失败操作绝不重试'
    Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'New' }).Count $(if ($failure -eq 'ShrinkC') { 0 } else { 1 }) '失败不创建后续卷'
}
Reset-TestExecution $s; $script:shrinkDelta = 65MB
$r = Invoke-PcPartitionExecution $p $s $context -Confirm:$false
Assert-Equal $r.Status 'Failed' 'P4 C 超容差停止执行'
Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'New' }).Count 0 'P4 C 超容差不继续创建'
Reset-TestExecution $s; $script:newDelta = -17MB
$r = Invoke-PcPartitionExecution $p $s $context -Confirm:$false
Assert-Equal $r.Status 'Failed' 'P4 新卷超容差停止'
Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'Format' }).Count 0 'P4 新卷超容差不格式化'
Reset-TestExecution $s; $script:failAt = 'ReadNew'
$r = Invoke-PcPartitionExecution $p $s $context -Confirm:$false
Assert-Equal $r.Status 'Failed' '创建后回读失败即停'
Assert-Equal $r.CreatedPartitions.Count 1 '回读失败仍保留已创建记录'
Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'Format' }).Count 0 '回读失败绝不格式化'
Reset-TestExecution $s; $s.MaxShrinkBytes = 300GB; $frozen = New-PcPartitionPlan $s
$s.CUsedBytes = 101GB; $s.MaxShrinkBytes = 301GB
$r = Invoke-PcPartitionExecution $frozen $s $context -Confirm:$false
Assert-Equal $r.Status 'Done' 'P1 日常波动仍按冻结方案完整执行'
Assert-Equal $r.CAfterBytes $frozen.CAfterBytes 'P1 完整执行不重新计算 C 大小'
Assert-Equal $r.CreatedPartitions[1].Partition.Size $frozen.NewVolumes[1].Size 'P1 完整执行不重新计算 rest'
Reset-TestExecution $s; $s = New-TestState; $p = New-PcPartitionPlan $s
Reset-TestExecution $s; $s.BitLocker = 'Unknown'
$r = Invoke-PcPartitionExecution $p $s $context -Confirm:$false
Assert-Equal $r.Status 'Refused' 'P2 执行前未完成检查拒绝'
Assert-Equal $script:sideEffects.Count 0 'P2 拒绝没有日志或写入操作'
$s.BitLocker = 'Off'; Reset-TestExecution $s
$r = Invoke-PcPartitionExecution $p $s @{ IsAdmin = $true; CurrentUserSid = 'other-user' } -Confirm:$false
Assert-Equal $r.Status 'Skipped' '其他账户跳过'
Assert-Equal $script:sideEffects.Count 0 '其他账户不改磁盘'

# 空白内部盘的完整假执行：允许 Windows 建保留分区，完全不压缩系统盘。
& {
    $state = New-TestState; $blank = New-TestDisk 1 @() 1TB 'SATA'; $blank.PartitionStyle = 'RAW'; $state.Disks += $blank
    $planObject = New-PcPartitionPlan $state
    Reset-TestExecution $state
    function Initialize-PcDisk {
        param($DiskNumber)
        $script:sideEffects += 'Initialize'
        $blank.PartitionStyle = 'GPT'
        $script:fakeParts += New-TestPartition 1 1MB 16MB '' $DiskNumber 'Reserved' ''
    }
    function Read-PcDisk { param($DiskNumber); return $blank }
    function Read-PcDiskPartitions { param($DiskNumber); return @($script:fakeParts | Where-Object { $_.DiskNumber -eq $DiskNumber }) }
    function Read-PcPartition { param($DiskNumber, $PartitionNumber); return @($script:fakeParts | Where-Object { $_.DiskNumber -eq $DiskNumber -and $_.PartitionNumber -eq $PartitionNumber })[0] }
    $r = Invoke-PcPartitionExecution $planObject $state $context -Confirm:$false
    Assert-Equal $r.Status 'Done' ('空内部盘完整执行 ' + $r.Reason)
    Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'Initialize' }).Count 1 '只初始化一次'
    Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'Resize' }).Count 0 '空盘方案不缩 C'
    Assert-Equal $script:fakeParts[0].Size 500GB '空盘方案保持 C 大小'
    Assert-Equal $r.FinalLayout.Count 3 '空盘最终布局包含保留分区和两数据盘'
    Assert-Equal $r.CreatedPartitions[0].Partition.DiskNumber 1 '只在选定空盘新建'
}

# UAC 参数按字面量编码，路径中的中文、空格、引号不会变为命令。
$command = New-PcElevationCommand "C:\脚本's\partition.ps1" 'C:\方案 空格.json' 'C:\结果.json' 'test-sid'
Assert-True ($command.Contains("'C:\脚本''s\partition.ps1'")) '提权脚本路径正确转义'
Assert-True ($command -match '-Apply -ElevatedChild' -and $command -match '-PlanPath' -and $command -match '-ResultPath' -and $command -match '-OriginalUserSid') '提权传递完整参数'
Assert-Equal @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process' }, $true)).Count 1 '只有一个提权入口'

# 主入口 WhatIf 也必须完全跳过上下文、外部程序、提权、报告及日志写入。
function Read-PcJson { param($Path); return $p }
function Get-CleanerContext { throw 'WhatIf 不得查询真实用户上下文' }
function Read-PcPartitionState { throw 'WhatIf 不得运行存储和加密查询' }
function Start-PcElevatedApply { throw 'WhatIf 不得提权' }
function Write-PcJson { throw 'WhatIf 不得写文件' }
$script:sideEffects = @()
$output = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $false -InputPath 'fake-plan.json' -DryRun $true -BlockEncrypted $true)
Assert-Equal $script:sideEffects.Count 0 '主入口 WhatIf 零副作用'
Assert-True (($output -join '') -match 'RESULT: .*fake-plan.json') '演练只引用已有输入方案'

# 读取适配器：模拟标准 Windows 存储对象及普通权限拒绝，仍只在内存运行。
& {
    foreach ($name in @('Read-PcPartitionState', 'Read-PcDiskPartitions', 'Read-PcPartition', 'Read-PcUsedLetters')) {
        $definition = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true))[0]
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:nativeAllowed = $false; $script:nativeDynamic = $false; $script:nativeDeny = ''
    $script:nativeState = New-TestState
    $script:nativeState.Disks[0] | Add-Member -NotePropertyName NumberOfPartitions -NotePropertyValue 1
    function Get-Disk {
        [CmdletBinding()]param($Number)
        if ($script:nativeDeny -eq 'Disk') { throw 'Access is denied' }
        if ($PSBoundParameters.ContainsKey('Number')) { return @($script:nativeState.Disks | Where-Object { $_.Number -eq $Number }) }
        return $script:nativeState.Disks
    }
    function Get-Partition {
        [CmdletBinding()]param($DiskNumber, $PartitionNumber)
        if ($script:nativeDeny -eq 'Partitions' -or ($script:nativeDeny -eq 'SecondPartitions' -and $DiskNumber -eq 1)) { throw 'Access is denied' }
        return @($script:nativeState.Disks | Where-Object { $_.Number -eq $DiskNumber })[0].Partitions
    }
    function Get-Volume {
        [CmdletBinding()]param($Partition)
        return [pscustomobject]@{ DriveLetter = 'C'; FileSystem = 'NTFS'; Size = 500GB; SizeRemaining = 400GB; FileSystemLabel = '系统' }
    }
    function Get-PSDrive {
        [CmdletBinding()]param($PSProvider)
        if ($script:nativeDeny -eq 'Letters') { throw 'Access is denied' }
        return @([pscustomobject]@{ Name = 'C' }, [pscustomobject]@{ Name = 'Q' })
    }
    function Get-CimInstance {
        [CmdletBinding()]param($ClassName)
        if (-not $script:nativeAllowed) { throw '模拟普通权限无法查询' }
        if ($script:nativeDynamic) { return [pscustomobject]@{ DiskIndex = 0; Type = 'Logical Disk Manager' } }
        return @()
    }
    function Get-VirtualDisk {
        [CmdletBinding()]param()
        if (-not $script:nativeAllowed) { throw '模拟普通权限无法查询' }
        return @()
    }
    function Get-PartitionSupportedSize {
        [CmdletBinding()]param($DiskNumber, $PartitionNumber)
        if (-not $script:nativeAllowed) { throw '模拟普通权限无法查询' }
        return @{ SizeMin = 160GB; SizeMax = 500GB }
    }
    function Read-PcBitLocker { param($Context); if ($script:nativeAllowed) { return 'Off' }; return 'Unknown' }
    $context = @{ SystemDrive = 'C:'; CurrentUserSid = 'test-sid'; IsAdmin = $false }
    $state = Read-PcPartitionState $context
    $planObject = New-PcPartitionPlan $state
    Assert-True $planObject.Feasible 'P2 普通权限读取适配器能生成可行方案'
    Assert-Equal $state.CUsedBytes 100GB '存储适配器读取容量和可用空间'
    Assert-Equal $state.MaxShrinkBytes $null 'P2 不把未知可压缩量当成零'
    Assert-True ('Q' -in $state.UsedLetters) '网络映射盘符也属于已用盘符'
    Assert-True ($planObject.PendingChecks.Count -ge 3) 'P2 适配器权限拒绝转待确认'
    $script:nativeAllowed = $true
    $live = Read-PcPartitionState $context
    Assert-True (Test-PcFrozenPlan $planObject $live).Valid 'P2 后续完整读取通过原方案'
    $script:nativeDynamic = $true
    Assert-True (-not (New-PcPartitionPlan (Read-PcPartitionState $context)).Feasible) '读取适配器检测动态磁盘'
    $script:nativeState.Disks[0].NumberOfPartitions = 2; $failed = $false
    try { $null = @(Read-PcDiskPartitions 0) } catch { $failed = $true }
    Assert-True $failed '分区清单数不完整立即拒绝'
    # R3a/b：使用实际读取适配器，拒绝 Get-Disk、Get-Partition 和盘符读取。
    $script:nativeState.Disks[0].NumberOfPartitions = 1; $script:nativeDynamic = $false
    $second = New-TestDisk 1 @((New-TestPartition 1 1MB 30GB '' 1 'OEM' '')) 200GB 'SATA'
    $second | Add-Member -NotePropertyName NumberOfPartitions -NotePropertyValue 1
    $script:nativeState.Disks += $second
    $readContext = @{ SystemDrive = 'C:'; CurrentUserSid = 'test-sid'; IsAdmin = $true }
    $planForReadFailure = New-PcPartitionPlan (New-TestState)
    function Get-CleanerContext { return $readContext }
    function Read-PcJson { param($Path); return $planForReadFailure }
    function Get-PcOutputPath { param($Path, $Kind, $Context); return 'memory-read-result.json' }
    function Write-PcJson { param($Value, $Path); $script:readFailureWrites += $Value }
    foreach ($denied in @('Disk', 'Partitions', 'Letters', 'SecondPartitions')) {
        $script:nativeDeny = $denied; $script:readFailureWrites = @()
        $output = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $true -InputPath 'plan.json' -BlockEncrypted $true)
        $unavailable = $script:readFailureWrites[0]
        Assert-Equal $unavailable.Situation 'Unknown' ('R3a 实际读取失败 -> Unknown ' + $denied)
        Assert-True (-not $unavailable.Feasible -and $unavailable.NeedsElevatedRead) ('R3a 实际权限失败标记 ' + $denied)
        Assert-True (($output -join '') -match 'RESULT: memory-read-result.json') ('R3a 实际读取失败仍输出 RESULT ' + $denied)
        $script:readFailureWrites = @()
        $output = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $false -InputPath 'plan.json' -Child $true -BlockEncrypted $true)
        Assert-Equal $script:readFailureWrites[0].Status 'Refused' ('R3b 实际读取失败仍写子结果 ' + $denied)
        Assert-Equal $script:readFailureWrites[0].StoppedAt 'Preflight' ('R3b 实际读取失败无磁盘步骤 ' + $denied)
    }
}

# UAC 和主入口：完全用内存结果替代磁盘文件，确认每次 Apply 最多请求一次权限。
& {
    $script:launches = 0; $script:mainWrites = @(); $script:launchMode = 'Cancel'; $script:mainState = New-TestState
    function Get-CleanerContext { return @{ IsAdmin = $false; CurrentUserSid = 'test-sid'; LogPath = 'fake-log' } }
    function Get-PcOutputPath { param($Path, $Kind, $Context); return 'memory-result.json' }
    function Write-PcJson { param($Value, $Path); $script:mainWrites += $Value }
    function Read-PcPartitionState { param($Context); return $script:mainState }
    function Start-PcElevatedApply {
        param($Command)
        $script:launches++
        if ($script:launchMode -eq 'Cancel') { throw '模拟用户取消 UAC' }
        return 13
    }
    $null = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $true -InputPath 'plan.json' -BlockEncrypted $true)
    Assert-Equal $script:launches 0 'Plan 普通权限不请求 UAC'
    Assert-True $script:mainWrites[0].Feasible '普通权限主入口保存可行方案'
    $script:mainWrites = @()
    $null = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $false -InputPath 'plan.json' -BlockEncrypted $true)
    Assert-Equal $script:launches 1 '取消 UAC 不重试'
    Assert-Equal $script:mainWrites[0].Status 'Skipped' '取消 UAC 报跳过'
    Assert-True ($script:mainWrites[0].Reason -match '没有获得管理员权限') '取消 UAC 中文原因'
    $script:launches = 0; $script:mainWrites = @(); $script:launchMode = 'OtherAccount'
    $null = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $false -InputPath 'plan.json' -BlockEncrypted $true)
    Assert-Equal $script:launches 1 '更换账户只请求一次 UAC'
    Assert-Equal $script:mainWrites[0].Status 'Skipped' '更换账户报跳过'
    Assert-True ($script:mainWrites[0].Reason -match '另一个账户') '即使子进程不能写原目录仍报告账户变化'
}
# R1：纯主机参数、实际启动入口及退出码协议；从不更改用户/机器策略。
& {
    $command = New-PcElevationCommand 'Invoke-TestChild' '方案 空格.json' '结果.json' 'test-sid'
    $arguments = @(Get-PcElevationArguments $command)
    Assert-Equal ($arguments[0..5] -join ' ') '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand' 'R1 完整主机参数包含进程级 Bypass'
    Assert-Equal $arguments.Count 7 'R1 编码命令独立参数'
    Assert-Equal ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($arguments[6]))) $command 'R1 UTF-16 编码无损往返'
    Assert-Equal @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-ExecutionPolicy' }, $true)).Count 0 'R1 从不写入执行策略'
    $definition = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-PcElevatedApply' }, $true))[0]
    . ([scriptblock]::Create($definition.Extent.Text))
    function Test-Path { param($LiteralPath); return $true }
    function Start-Process {
        [CmdletBinding()]param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru)
        Assert-Equal ($ArgumentList -join '|') ($arguments -join '|') 'R1 启动器实际使用纯函数参数'
        Assert-Equal $Verb 'RunAs' 'R1 保留 UAC'
        Assert-True ($Wait -and $PassThru) 'R1 等待退出码'
        $process = [pscustomobject]@{ ExitCode = 12 }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $process
    }
    Assert-Equal (Start-PcElevatedApply $command) 12 'R1 返回子进程退出码'
    # 用假身份/假入口运行生成的包装器；exit 改为 return，避免结束测试宿主。
    $testCommand = $command.Replace('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value', "'test-sid'") -replace '\bexit (0|12|13|21)\b', 'return $1'
    $mode = 'Before'
    function Invoke-TestChild {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param([switch]$Apply, [switch]$ElevatedChild, $PlanPath, $ResultPath, $OriginalUserSid, $ChildState)
        if ($mode -eq 'Before') { throw 'Access denied before script execution' }
        if ($mode -eq 'After') { $ChildState.StepMayHaveRun = $true; throw 'Result write failed after step' }
    }
    Assert-Equal (& ([scriptblock]::Create($testCommand))) 12 'R1 启动异常且无步骤 -> 12'
    $mode = 'After'
    Assert-Equal (& ([scriptblock]::Create($testCommand))) 21 'R1 步骤后结果丢失 -> 21'
    $mode = 'Success'
    Assert-Equal (& ([scriptblock]::Create($testCommand))) 0 'R1 正常入口 -> 0'
    Assert-Equal (& ([scriptblock]::Create($testCommand.Replace("'test-sid' -cne", "'other-sid' -cne")))) 13 'R1 换账户在脚本前退出 -> 13'
}

# R2：格式化后才占用盘符时，保留无盘符 NTFS，停止且不建目录/后续分区。
& {
    $s = New-TestState; $p = New-PcPartitionPlan $s; Reset-TestExecution $s
    function Read-PcUsedLetters {
        if (@($script:fakeParts | Where-Object { $_.DriveLetter -eq '' -and $_.FileSystem -eq 'NTFS' }).Count -gt 0) { return @('C', 'D') }
        return @('C')
    }
    $phase = @{ StepMayHaveRun = $false }
    $r = Invoke-PcPartitionExecution $p $s $context -ChildState $phase -Confirm:$false
    Assert-Equal $r.Status 'Failed' 'R2 分配时占用正常返回失败结果'
    Assert-Equal $r.StoppedAt 'AssignLetter:0' 'R2 停在分配盘符'
    Assert-True ($r.Reason -match '盘符已被占用.*仍没有盘符') 'R2 中文说明保留无盘符文件盘'
    Assert-Equal $r.UnassignedFormattedPartitions.Count 1 'R2 结果列出无盘符 NTFS'
    Assert-Equal $r.FinalLayout[1].DriveLetter '' 'R2 最终布局没有提前暴露盘符'
    Assert-Equal $r.FinalLayout[1].FileSystem 'NTFS' 'R2 保留已格式化状态'
    Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'Format' }).Count 1 'R2 不重复格式化'
    Assert-Equal @($script:sideEffects | Where-Object { $_ -in @('Assign', 'Folder') }).Count 0 'R2 占用后不分配也不建目录'
    Assert-Equal $r.CreatedPartitions.Count 1 'R2 不创建后续分区'
    Assert-True $phase.StepMayHaveRun 'R1 开始磁盘步骤后标记可能已修改'
    $phase.StepMayHaveRun = $false; $s.BitLocker = 'Unknown'
    $r = Invoke-PcPartitionExecution $p $s $context -ChildState $phase -Confirm:$false
    Assert-True (-not $phase.StepMayHaveRun) 'R1 前置拒绝不标记已进入步骤'
}
& {
    foreach ($field in @('DriveLetter', 'FileSystem', 'Offset', 'Size')) {
        $s = New-TestState; $p = New-PcPartitionPlan $s; Reset-TestExecution $s
        function Set-PcPartitionLetter {
            param($Partition, $Letter)
            $found = Read-PcPartition $Partition.DiskNumber $Partition.PartitionNumber
            $found.DriveLetter = $Letter
            switch ($field) {
                'DriveLetter' { $found.DriveLetter = 'X' }
                'FileSystem' { $found.FileSystem = 'RAW' }
                'Offset' { $found.Offset += 1MB }
                'Size' { $found.Size -= 1MB }
            }
        }
        $r = Invoke-PcPartitionExecution $p $s $context -Confirm:$false
        Assert-Equal $r.StoppedAt 'AssignLetter:0' ('R2 分配后精确校验 ' + $field)
        Assert-Equal @($script:sideEffects | Where-Object { $_ -eq 'Folder' }).Count 0 ('R2 校验失败不建目录 ' + $field)
    }
}

# R2：真实写入适配器仅绑定内存假命令，检查 Windows 参数及分配前最后一次盘符竞争。
& {
    foreach ($name in @('New-PcDataPartition', 'Format-PcNewVolume', 'Set-PcPartitionLetter')) {
        $definition = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true))[0]
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $s = New-TestState; $p = New-PcPartitionPlan $s; $v = $p.NewVolumes[0]
    $native = New-TestPartition 2 $v.Offset $v.Size '' 0 'Basic' 'RAW'
    $native.DriveLetter = [string][char]0
    $volume = @{ FileSystem = 'RAW' }; $taken = $false
    function New-Partition {
        [CmdletBinding(SupportsShouldProcess = $true)]param($DiskNumber, $Offset, $Size, $DriveLetter, [switch]$AssignDriveLetter)
        Assert-True (-not $PSBoundParameters.ContainsKey('DriveLetter') -and -not $PSBoundParameters.ContainsKey('AssignDriveLetter')) 'R2 New-Partition 不传任何盘符参数'
        return $native
    }
    function Get-Partition { [CmdletBinding()]param($DiskNumber, $PartitionNumber); return $native }
    function Get-Volume { [CmdletBinding()]param($Partition); return $volume }
    function Format-Volume {
        [CmdletBinding(SupportsShouldProcess = $true)]param($Partition, $FileSystem, $NewFileSystemLabel)
        Assert-True ([object]::ReferenceEquals($Partition, $native)) 'R2 Format-Volume 使用精确分区对象'
        Assert-Equal $FileSystem 'NTFS' 'R2 格式化为 NTFS'
        $volume.FileSystem = 'NTFS'; $script:adapterFormatCalls++
    }
    function Read-PcUsedLetters { if ($taken) { return @('C', 'D') }; return @('C') }
    function Set-Partition {
        [CmdletBinding(SupportsShouldProcess = $true)]param($DiskNumber, $PartitionNumber, $NewDriveLetter)
        Assert-Equal $DiskNumber $native.DiskNumber 'R2 精确硬盘分配盘符'
        Assert-Equal $PartitionNumber $native.PartitionNumber 'R2 精确分区分配盘符'
        Assert-Equal $NewDriveLetter 'D' 'R2 只分配规划盘符'
        $script:adapterAssignCalls++; $native.DriveLetter = $NewDriveLetter
    }
    $script:adapterFormatCalls = 0; $script:adapterAssignCalls = 0
    $created = New-PcDataPartition $v
    Assert-Equal $created.DriveLetter '' 'R2 Windows 空字符盘符规范化'
    Format-PcNewVolume $created '资料'
    Assert-Equal $script:adapterFormatCalls 1 'R2 无盘符格式化成功'
    $formatted = ConvertTo-PcPartitionRecord $native $volume
    $taken = $true; $reason = ''
    try { Set-PcPartitionLetter $formatted 'D' } catch { $reason = $_.Exception.Message }
    Assert-True ($reason -match '盘符已被占用.*仍没有盘符') 'R2 最后一次竞争也返回中文无盘符原因'
    Assert-Equal $script:adapterAssignCalls 0 'R2 最后一次检查发现占用不调用 Set-Partition'
    $taken = $false; Set-PcPartitionLetter $formatted 'D'
    Assert-Equal $script:adapterAssignCalls 1 'R2 确认空闲后才分配'
    $reason = ''; try { Format-PcNewVolume $created '资料' } catch { $reason = $_.Exception.Message }
    Assert-True ([bool]$reason) 'R2 适配器也拒绝重复格式化'
    Assert-Equal $script:adapterFormatCalls 1 'R2 重复格式化没有调用 Windows 命令'
}

# R3a / P2：决定“布局致命、辅助安全检查待确认”的纯逻辑。
foreach ($read in @('Layout', 'UsedLetters', 'UnrecognizedRead')) {
    Assert-True (Get-PcReadFailure $read).Fatal ('R3a 规划依据缺失即停止 ' + $read)
}
foreach ($read in @('DiskKind', 'BitLocker', 'MaxShrink')) {
    Assert-True (-not (Get-PcReadFailure $read).Fatal) ('R3a 辅助读取待确认 ' + $read)
    Assert-True (Get-PcReadFailure $read $true).Fatal ('R3a 提权后仍未知致命 ' + $read)
}

# R1/R3：所有文件读写都是内存假实现，覆盖主入口和提权子入口的失败结果输出。
& {
    $mode = ''; $admin = $true; $exitCode = 0; $state = New-TestState; $planObject = New-PcPartitionPlan $state
    function Get-CleanerContext {
        if ($mode -eq 'Context') { throw 'Access is denied' }
        return @{ IsAdmin = $admin; CurrentUserSid = 'test-sid'; LogPath = 'memory-log' }
    }
    function Get-PcOutputPath { param($Path, $Kind, $Context); return 'memory-result.json' }
    function Write-PcJson { param($Value, $Path); $script:failureWrites += (Copy-TestObject $Value) }
    function Read-PcJson {
        param($Path)
        $script:failureReads++
        switch ($mode) {
            'Missing' { throw 'File not found' }
            'Unreadable' { throw 'Access is denied' }
            'Malformed' { throw 'Invalid JSON' }
            'Incomplete' { return @{ Schema = 'pc-care/partition-plan/1' } }
        }
        return $planObject
    }
    function Read-PcPartitionState { param($Context); if ($mode -eq 'Live') { throw 'Access is denied' }; return $state }
    function Invoke-PcPartitionExecution {
        [CmdletBinding(SupportsShouldProcess = $true)]param($PlanObject, $State, $Context, $BlockEncrypted, $ChildState)
        $script:failureExecCalls++
        if ($mode -eq 'Incomplete') { throw 'Missing property' }
        if ($mode -eq 'AfterStep') { $ChildState.StepMayHaveRun = $true; throw 'Unexpected error after step' }
        return @{ Schema = 'pc-care/partition/1'; Status = 'Done'; Reason = '' }
    }
    function Start-PcElevatedApply { param($Command); return $exitCode }
    function Test-Path { param($LiteralPath, $PathType); return $false }
    foreach ($child in @($false, $true)) {
        foreach ($failure in @('Missing', 'Unreadable', 'Malformed', 'Incomplete', 'Live', 'Context')) {
            $mode = $failure; $script:failureWrites = @(); $script:failureExecCalls = 0; $script:failureReads = 0
            $output = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $false -InputPath 'plan.json' -OutputPath 'child-result.json' -Child $child -BlockEncrypted $true)
            Assert-Equal $script:failureWrites.Count 1 ('R3b 每次失败保存唯一结果 ' + $child + '/' + $failure)
            $r = $script:failureWrites[0]
            Assert-Equal $r.Schema 'pc-care/partition/1' 'R3b 结果契约'
            Assert-Equal $r.Status 'Refused' 'R3b 读取失败拒绝'
            Assert-Equal $r.StoppedAt 'Preflight' 'R3b 停于前置检查'
            Assert-True ($r.Reason -match '未修改任何分区' -and $r.Reason -notmatch 'Access|JSON|property|重复执行') 'R3b 中文说明无磁盘修改'
            Assert-True (($output -join '') -match 'RESULT: memory-result.json') 'R3b 总是输出 RESULT'
            if ($failure -ne 'Incomplete') { Assert-Equal $script:failureExecCalls 0 'R3b 读取失败不进入执行器' }
        }
    }
    $mode = 'Live'; $script:failureWrites = @()
    $output = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $true -InputPath 'plan.json' -BlockEncrypted $true)
    $r = $script:failureWrites[0]
    Assert-Equal $r.Schema 'pc-care/partition-plan/1' 'R3a 布局读取失败仍保存方案'
    Assert-Equal $r.Situation 'Unknown' 'R3a 不把未知布局误报为空闲'
    Assert-Equal $r.Feasible $false 'R3a 布局读取失败不可行'
    Assert-True $r.NeedsElevatedRead 'R3a 标明需要提权读取'
    Assert-True ($r.Blockers[0] -match '管理员权限' -and $r.Blockers[0] -notmatch 'Access') 'R3a 明确中文阻碍'
    Assert-Equal @($r.NewVolumes).Count 0 'R3a 不虚构新分区'
    Assert-True (($output -join '') -match 'RESULT: memory-result.json') 'R3a 失败方案照常输出 RESULT'
    $mode = 'AfterStep'; $script:failureWrites = @()
    $null = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $false -InputPath 'plan.json' -BlockEncrypted $true)
    Assert-Equal $script:failureWrites[0].Status 'Failed' 'R1 步骤后意外异常不能误报前置拒绝'
    Assert-True ($script:failureWrites[0].Reason -notmatch '未修改任何分区' -and $script:failureWrites[0].Reason -match '不要重复执行') 'R1 步骤后异常保留布局检查提示'
    $admin = $false; $mode = ''
    foreach ($code in @(0, 1, 12, 13, 21)) {
        $exitCode = $code; $script:failureWrites = @()
        $output = @(Invoke-PcPartitionMain -ScriptPath 'fake.ps1' -Planning $false -InputPath 'plan.json' -BlockEncrypted $true)
        $r = $script:failureWrites[0]
        Assert-True (($output -join '') -match 'RESULT: memory-result.json') ('R1 缺失结果仍输出 RESULT ' + $code)
        if ($code -notin @(0, 13)) { Assert-True ($r.Reason -match '管理员窗口没有正常运行') ('R1 非零退出中文解释 ' + $code) }
        if ($code -eq 13) {
            Assert-Equal $r.Status 'Skipped' 'R1 换账户保持跳过'
            Assert-True ($r.Reason -match '未修改任何分区' -and $r.Reason -notmatch '不要重复执行') 'R1 换账户退出也明确没有修改'
        }
        elseif ($code -eq 12) {
            Assert-Equal $r.Status 'Refused' 'R1 已证明无步骤时拒绝'
            Assert-Equal $r.StoppedAt 'Preflight' 'R1 无步骤停在前置检查'
            Assert-True ($r.Reason -match '未修改任何分区' -and $r.Reason -notmatch '不要重复执行') 'R1 已证明无修改不误报警告'
        }
        else { Assert-True ($r.Reason -match '先检查磁盘状态.*不要重复执行' -and $r.Reason -notmatch '未修改任何分区') 'R1 可能修改时保留检查布局提示' }
    }
}
Write-Host ("PASS t7-partition: {0} assertions; P1/P2/P3/P4; R1/R2/R3a/R3b; AST-only loading; fake storage; no script body executed." -f $script:assertions)

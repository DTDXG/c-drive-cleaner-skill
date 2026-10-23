Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$script:definitions=@{};$script:assertions=0
function Import-T6Functions {
    param([string]$Path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors.Message -join ';')}
    foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
        $script:definitions[$node.Name]=$node.Extent.Text
        . ([scriptblock]::Create($node.Extent.Text))
        Set-Item ('Function:script:'+$node.Name) (Get-Item ('Function:'+$node.Name)).ScriptBlock
    }
}
foreach($file in @('common.ps1','migrate.ps1','move.ps1')){Import-T6Functions (Join-Path $repo ('scripts/'+$file))}
function Restore-T6 {param([string[]]$Names) foreach($name in $Names){. ([scriptblock]::Create($script:definitions[$name]));Set-Item ('Function:script:'+$name) (Get-Item ('Function:'+$name)).ScriptBlock}}
function Assert-T6 {param([bool]$Condition,[string]$Message) $script:assertions++;if(-not $Condition){throw ('FAIL: '+$Message)}}
function Assert-ThrowsT6 {param([scriptblock]$Action,[string]$Message) $thrown=$false;try{$null=& $Action}catch{$thrown=$true};Assert-T6 $thrown $Message}
$script:CleanerTargets=Import-PowerShellDataFile (Join-Path $repo 'scripts/targets.psd1')
$script:MigrationSid='S-test';$script:MigrationProfile='C:\Users\me';$script:MoveDocument=[pscustomobject]@{Entries=@()}
$script:MigrationContext=[pscustomobject]@{
    OriginalUserSid='S-test';CurrentUserSid='S-test';OriginalUserProfile='C:\Users\me';OriginalUserVerified=$true
    SystemDrive='C:';SystemRoot='C:\Windows';SyncRoots=@();ProtectedMachineRoots=@('C:\Program Files');LogPath='C:\Users\me\AppData\Local\pc-care\logs\audit.jsonl'
    Variables=@{USERPROFILE='C:\Users\me';APPDATA='C:\Users\me\AppData\Roaming';LOCALAPPDATA='C:\Users\me\AppData\Local';ProgramData='C:\ProgramData';SystemRoot='C:\Windows';SystemDrive='C:';ProgramFiles='C:\Program Files';'ProgramFiles(x86)'='C:\Program Files (x86)';ProgramW6432='C:\Program Files'}
}
function New-T6Facts {return @{AlreadyMoved=$false;OneDrive=$false;RunningApps=@();IsFixed=$true;IsLocal=$true;FileSystem='NTFS';SystemVolume=$false;Forbidden=$false;NonEmpty=$false;Resume=$false;Bytes=[long]1000;FreeBytes=[long]1100}}
function New-T6Inventory {
    param([int]$Count=1)
    $files=@{};for($i=0;$i -lt $Count;$i++){$files[('文件'+$i+'.db')]=[pscustomobject]@{Length=[long]10;WriteTicks=[long]100;Hash='';FileId=('id'+$i)}}
    return [pscustomobject]@{Files=$files;Directories=@{};Links=@{};Excluded=@();FileCount=[long]$Count;Bytes=[long]($Count*10)}
}
function New-T6Record {param([string]$Kind='KnownFolder') $r=New-MoveRecord $Kind 'Documents' 'C:\Users\me\Documents' 'D:\资料\文档' @('WeChat') $false 'root';$r.InventorySha256=('A'*64);return $r}
function Open-CleanerParentGuards {param([string]$LiteralPath) [pscustomobject]@{Handles=@()}}
function Test-CleanerPathChain {param([string]$LiteralPath,[switch]$AllowMissing) [pscustomobject]@{IsSafe=$true;Path=$LiteralPath;Exists=$true;Attributes=[IO.FileAttributes]::Directory;ExistingParent='C:\Users\me'}}

# Preflight: every condition has a failing case and the exact 10% boundary.
$f=New-T6Facts;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Done') '10% exact boundary accepted'
foreach($key in @('IsFixed','IsLocal')){$f=New-T6Facts;$f[$key]=$false;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Failed') $key}
foreach($key in @('SystemVolume','Forbidden','NonEmpty','OneDrive')){$f=New-T6Facts;$f[$key]=$true;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Failed') $key}
$f=New-T6Facts;$f.FileSystem='exFAT';Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Failed') 'non NTFS rejected'
$f=New-T6Facts;$f.FreeBytes=1099;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'NotEnoughSpace') '10% margin enforced'
$f=New-T6Facts;$f.AlreadyMoved=$true;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'AlreadyMoved') 'already moved'
$f=New-T6Facts;$f.NonEmpty=$true;$f.Resume=$true;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Done') 'P3 resume accepts nonempty only via resume'
$f=New-T6Facts;$f.RunningApps=@('微信');$decision=Get-MovePreflightDecision $f;Assert-T6 ($decision.Status -eq 'NeedsAppExit' -and $decision.Reason.Contains('微信')) 'running app in Chinese'
foreach($name in @('WeChat.exe','Weixin','WeChatAppEx.exe','QQ.exe','QQNT')){$apps=@(Get-MoveRunningApps @('WeChat','QQ') @($name));Assert-T6 ($apps.Count -eq 1) ('process '+$name)}
Assert-T6 (@(Get-MoveRunningApps @('WeChat') @('notepad')).Count -eq 0) 'unrelated process allowed'

# Detection is the same bounded configuration convention as v1/checkup, with a fake FS.
$folders=@{Documents='C:\Users\me\Documents'}
$fakeRoots=@('C:\Users\me\Documents\WeChat Files','C:\Users\me\Documents\xwechat_files','C:\Users\me\Documents\Tencent Files','C:\Chat\WeChat Files','C:\Chat\xwechat_files','C:\CustomQQ')
$exists={param($p) $p -in $fakeRoots}
$reg={param($k,$n) if($n -eq 'FileSavePath'){'C:\Chat'};if($n -eq 'DataPath'){'C:\CustomQQ'}}
$roots=@(Get-CleanerChatRoots $script:MigrationContext $folders $reg {param($p) ''} $exists)
Assert-T6 ($roots.Count -eq 6) 'detect old/new WeChat, QQ and configured roots'
foreach($path in $fakeRoots){Assert-T6 ($path -in $roots.Path) ('detected '+$path)}
$roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) ''} {param($p) if($p -like '*xwechat*'){'{"settings":{"data_dir":"C:\\Custom微信"}}'}} {param($p) $p -eq 'C:\Custom微信'})
Assert-T6 ($roots.Count -eq 1 -and $roots[0].Path -eq 'C:\Custom微信') 'JSON exact custom root, arbitrary directory name'
Assert-T6 (@(Resolve-CleanerChatPaths 'C:\Chat\xwechat_files' @('WeChat Files','xwechat_files') $true).Count -eq 1) 'no double suffix'
Assert-T6 (@(ConvertFrom-CleanerChatConfig "C:\Chat`r`nMyDocument:" Text).Count -eq 1) 'text configuration rejects marker'
$roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) 'C:\Users\me\Documents'} {param($p) ''} {param($p) $true})
Assert-T6 (@($roots | Where-Object {$_.Path -eq $folders.Documents}).Count -eq 0) 'custom setting cannot authorize all Documents'
$roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) 'C:\Windows'} {param($p) ''} {param($p) $true})
Assert-T6 (@($roots | Where-Object {$_.Path -like 'C:\Windows*'}).Count -eq 0) 'forbidden custom config rejected'

# Exact new whitelist roots; old cache-only Junction category still derives only DevCache.
function Get-CleanerKnownFolderMap {param($Context) return @{Documents='C:\Users\me\Documents';Desktop='C:\Users\me\Desktop'}}
function Get-CleanerChatRoots {param($Context,[switch]$IncludeMissing) @([pscustomobject]@{App='WeChat';Path='C:\Users\me\Documents\WeChat Files'},[pscustomobject]@{App='WeChat';Path='C:\Users\me\Documents\xwechat_files'},[pscustomobject]@{App='QQ';Path='C:\Users\me\Documents\Tencent Files'})}
foreach($category in @('MoveChat','MoveChatBackup','MoveChatParent')) {
    $def=$script:CleanerTargets.Categories[$category]
    Assert-T6 ($def.ExternalOnly -and $def.MigrationOnly) ($category+' cannot delete')
    $targets=@(Get-CleanerMigrationTarget $def $script:MigrationContext)
    Assert-T6 ($targets.Count -eq 3) ($category+' exact derived roots')
    Assert-ThrowsT6 {Assert-CleanerDeletionCategory $category} ($category+' deletion guard')
}
$chatTargets=@(Get-CleanerMigrationTarget $script:CleanerTargets.Categories.MoveChat $script:MigrationContext)
Assert-T6 (@($chatTargets | Where-Object {$_.Path -in @('C:\Users\me\Documents','C:\Users\me\AppData')}).Count -eq 0) 'no broad data root'
$cacheTargets=@(Get-CleanerMigrationTarget $script:CleanerTargets.Categories.Junction $script:MigrationContext)
Assert-T6 (@($cacheTargets | Where-Object {$_.Path -like '*WeChat*' -or $_.Path -like '*Tencent Files*'}).Count -eq 0) 'cache junction whitelist unchanged'
$auditTargets=@(Get-CleanerMigrationTarget $script:CleanerTargets.Categories.MigrationManifest $script:MigrationContext)
Assert-T6 (@($auditTargets | Where-Object {$_.Path -like '*move-inventory-*.tsv' -and $_.Scope -eq 'File'}).Count -eq 1) 'P2 inventory sidecar whitelist exact audit directory'

# P4a: chat root containment; require exit before copy and before switch.
$chats=@([pscustomobject]@{App='WeChat';Path='C:\Users\me\Documents\WeChat Files'},[pscustomobject]@{App='QQ';Path='C:\Users\me\Documents\Tencent Files'},[pscustomobject]@{App='QQ';Path='C:\Users\me\DocumentsOther\Tencent Files'})
$included=@(Get-MoveIncludedChats 'C:\Users\me\Documents' $chats)
Assert-T6 ($included.Count -eq 2 -and 'WeChat' -in $included -and 'QQ' -in $included) 'P4a included chat data with path boundary'
$script:runningNames=@('WeChatAppEx')
function Get-Process {param($ErrorAction) foreach($p in $script:runningNames){[pscustomobject]@{ProcessName=$p}}}
$r=New-T6Record;Assert-ThrowsT6 {Assert-MoveAppsClosed $r} 'P4a Documents refuses running included chat'
$script:mutations=0
function Set-MoveKnownFolder {$script:mutations++}
function Set-MoveState {$script:mutations++}
Assert-ThrowsT6 {Invoke-MoveSwitch $r (New-T6Inventory) 'fake' @{}} 'P4a second process gate before switching'
Assert-T6 ($script:mutations -eq 0) 'P4a running process gate has no side effects'
$script:runningNames=@()

# P4b: old chat root is retained inside active Documents; orchestration returns AlreadyMoved.
$r.State='Active';$old=Find-MoveContainingRecord 'C:\Users\me\Documents\WeChat Files' @($r)
Assert-T6 ($old.Id -eq $r.Id) 'P4b retained chat is part of Documents move'
Assert-T6 ($null -eq (Find-MoveContainingRecord 'C:\Users\me\Documents2\WeChat Files' @($r))) 'P4b sibling not covered'
function Assert-MoveRecord {param($Record,[switch]$ForRollback)}
function Read-MoveInventory {param($Manifest,$Record) New-T6Inventory}
function Assert-MoveActive {param($Record,$Baseline,[switch]$Inventory,[switch]$AllowRunning)}
$doc=[pscustomobject]@{Entries=@($r)}
$oldResult=Invoke-MoveNew WeChat '' 'D:\Chat' 'fake' $doc $false
Assert-T6 ($oldResult.Status -eq 'AlreadyMoved' -and $oldResult.Id -eq $r.Id) 'P4b no separate chat move from retained Documents'

# P4c: /XJ agrees with inventory. No traversal or identity access through links; unknown links fail closed.
$script:visited=[Collections.Generic.List[string]]::new();$script:identities=0;$script:verifiedLinks=0
function Get-MigrationVerifiedJunction {param($Path,$Target) $script:verifiedLinks++;return $true}
$enumerate={param($p)
    $script:visited.Add($p)
    if($p -eq 'C:\src') {
        [pscustomobject]@{FullName='C:\src\WeChat Files';Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)}
        [pscustomobject]@{FullName='C:\src\normal.db';Attributes=[IO.FileAttributes]::Normal}
        [pscustomobject]@{FullName='C:\src\WeChat Files.cdrive-retained-a';Attributes=[IO.FileAttributes]::Directory}
    }else{throw 'must not enumerate link or excluded retained chat'}
}
$identity={param($p) $script:identities++;[pscustomobject]@{IsDirectory=$false;FileId='file';LogicalBytes=[long]10;LastWriteTimeUtc=[datetime]::new(100)}}
$tree=Get-MoveInventory 'C:\src' -AllowedLinks @{'WeChat Files'='D:\Chat'} -Excluded @('WeChat Files.cdrive-retained-a') -Enumerate $enumerate -Identity $identity -Guard {param($p) [pscustomobject]@{Handles=@()}}
Assert-T6 ($script:visited.Count -eq 1 -and $script:identities -eq 1 -and $tree.FileCount -eq 1) 'P4c no link/retained data traversal'
Assert-T6 ($tree.Links['WeChat Files'] -eq 'D:\Chat' -and $script:verifiedLinks -eq 1) 'P4c verified skipped link recorded'
Assert-ThrowsT6 {Get-MoveInventory 'C:\src' -Enumerate $enumerate -Identity $identity -Guard {param($p) [pscustomobject]@{Handles=@()}}} 'P4c unknown link refuses'
$target=New-T6Inventory 0;$target.Files=$tree.Files;$target.FileCount=1;$target.Bytes=10
Assert-MoveInventoryMatch $tree $target -AllowMissingLinks
Assert-ThrowsT6 {Assert-MoveInventoryMatch $tree $target} 'P4c active target must have restored link'

# P2: immutable, authenticated, non-JSON sidecar round trip including Chinese names, dirs, links.
Restore-T6 @('Read-MoveInventory','Assert-MoveRecord','Set-MoveState')
$baseline=New-T6Inventory 5000;$baseline.Directories['空目录']='dir-id';$baseline.Links['聊天']='D:\Chat';$baseline.Excluded=@('旧聊天副本')
$lines=@(ConvertTo-MoveInventoryLines $baseline)
$converted=ConvertFrom-MoveInventoryLines $lines
Assert-T6 ($converted.FileCount -eq 5000 -and $converted.Bytes -eq 50000 -and $converted.Directories['空目录'] -eq 'dir-id' -and $converted.Links['聊天'] -eq 'D:\Chat') 'P2 line-based round trip'
Assert-ThrowsT6 {ConvertFrom-MoveInventoryLines @("F`tLi5cZXNjYXBl`t1`t2`t`tid")} 'P2 sidecar refuses path escape'
Assert-ThrowsT6 {ConvertFrom-MoveInventoryLines @($lines[0],$lines[0])} 'P2 duplicate inventory record rejected'
function Assert-MigrationTarget {param([string]$Path,[string]$Category)}
$testDir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testDir)
try {
    $r=New-T6Record;$manifest=Join-Path $testDir 'moves.json'
    Write-MoveInventory $manifest $r $baseline
    $path=Join-Path $testDir $r.InventoryFile
    Assert-T6 ([IO.File]::Exists($path) -and $r.EntryCount -eq 5003) 'P2 metadata covers every inventory row'
    $read=Read-MoveInventory $manifest $r
    Assert-T6 ($read.FileCount -eq 5000 -and $read.Bytes -eq 50000) 'P2 SHA-verified read'
    Assert-ThrowsT6 {Write-MoveInventory $manifest $r $baseline} 'P2 sidecar never overwritten'
    $json=ConvertTo-Json -InputObject $r -Depth 8
    $r.EntryCount=1;$r.TotalBytes=10;$small=ConvertTo-Json -InputObject $r -Depth 8
    Assert-T6 ([math]::Abs($json.Length-$small.Length) -lt 30 -and $json.Length -lt 2000 -and $json -notmatch '文件4999') 'P2 manifest size independent of inventory count'
    [IO.File]::AppendAllText($path,"tampered`n")
    Assert-ThrowsT6 {Read-MoveInventory $manifest $r} 'P2 modified sidecar digest rejected before conversion'
}
finally {foreach($p in [IO.Directory]::EnumerateFiles($testDir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($testDir)}

# P3: only recorded entries may exist in resumed target; changed/missing files can be recopied.
$b=New-T6Inventory 3;$partial=New-T6Inventory 1;$partial.Files['文件0.db'].Length=2
Assert-MoveDestinationSubset $b $partial
Assert-T6 $true 'P3 partial changed file accepted for recopy'
$partial.Files['foreign.db']=$partial.Files['文件0.db'];Assert-ThrowsT6 {Assert-MoveDestinationSubset $b $partial} 'P3 foreign file blocks resume'
$partial=New-T6Inventory 0;$partial.Directories['foreign']=$true;Assert-ThrowsT6 {Assert-MoveDestinationSubset $b $partial} 'P3 foreign directory blocks resume'
$partial=New-T6Inventory 0;$partial.Links['foreign']='D:\other';Assert-ThrowsT6 {Assert-MoveDestinationSubset $b $partial} 'P3 foreign link blocks resume'

# Stage journal, rollback plan, active guard. Cache field retains migrate manifest compatibility.
$script:journal=[Collections.Generic.List[string]]::new()
function Write-MigrationManifest {param($Path,$Document) $script:journal.Add($Document.Entries[0].State)}
$r=New-T6Record;$document=[pscustomobject]@{Entries=@($r)}
foreach($state in @('Copying','Copied','Verified','Switching','Active')){Set-MoveState $r $state 'fake' $document}
Assert-T6 (($script:journal -join ',') -eq 'Copying,Copied,Verified,Switching,Active' -and $r.Steps.Count -eq 5) 'each transition recorded in order'
Assert-T6 ((Get-MoveRollbackPlan $r) -contains 'RestoreKnownFolder') 'known-folder rollback plan'
$app=New-T6Record WeChat
Assert-T6 ((Get-MoveRollbackPlan $app) -contains 'RemoveVerifiedJunction' -and (Get-MoveRollbackPlan $app) -contains 'KeepDestination') 'app rollback removes only link and keeps destination'
$r.State='Releasing';Assert-ThrowsT6 {Get-MoveRollbackPlan $r} 'partial release cannot claim full rollback'
$r.State='Copying';Assert-ThrowsT6 {Invoke-MoveRelease $r (New-T6Inventory) 'fake' $document} 'release refuses before verified active'
Restore-T6 @('Assert-MoveActive')
$r.State='Active'
Assert-ThrowsT6 {Assert-MoveActive $r (New-T6Inventory)} 'release refuses inactive known folder path'

# A Windows-native fake lets the performance test run the real per-file deletion helper.
class T6MoveNative {
    static [string] $Path
    static [int] $Deletes
    static [Microsoft.Win32.SafeHandles.SafeFileHandle] CreateFileW([string]$path,[uint32]$access,[uint32]$share,[IntPtr]$security,[uint32]$mode,[uint32]$flags,[IntPtr]$template) {
        [T6MoveNative]::Path=$path
        return [Microsoft.Win32.SafeHandles.SafeFileHandle]::new([IntPtr]4242,$false)
    }
    static [bool] SetFileInformationByHandle([Microsoft.Win32.SafeHandles.SafeFileHandle]$handle,[int]$kind,[IntPtr]$memory,[uint32]$size) {
        [T6MoveNative]::Deletes++
        return $true
    }
}
function Get-CleanerNativeType {return [T6MoveNative]}
function Get-CleanerFinalHandlePath {param($Handle) return [T6MoveNative]::Path}
function Get-CleanerHandleMetadata {
    param($Handle)
    $path=[T6MoveNative]::Path;$id='root';$directory=$true
    if($path -match '文件(\d+)\.db$'){$id='id'+$matches[1];$directory=$false}
    return [pscustomobject]@{FileId=$id;IsDirectory=$directory;LogicalBytes=[long]10;LastWriteTimeUtc=[datetime]::new(100)}
}
Restore-T6 @('Remove-MoveRetainedLeaf')

function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;$f.FreeBytes=100000;return $f}

# P1: full release orchestration, 5000 files. Record validation/conversion each exactly once.
$script:counts=@{Validate=0;Convert=0;Read=0;Active=0;Delete=0;Inventory=0}
$script:large=New-T6Inventory 5000;$script:largeLines=@(ConvertTo-MoveInventoryLines $script:large)
$script:convertDefinition=$script:definitions['ConvertFrom-MoveInventoryLines']
function Assert-MoveRecord {param($Record,[switch]$ForRollback) $script:counts.Validate++}
function Read-MoveInventory {
    param($Manifest,$Record)
    $script:counts.Read++
    . ([scriptblock]::Create($script:convertDefinition))
    $script:counts.Convert++;ConvertFrom-MoveInventoryLines $script:largeLines
}
function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded) $script:counts.Inventory++;return $script:large}
function Assert-MoveActive {param($Record,$Baseline,[switch]$Inventory,[switch]$AllowRunning) $script:counts.Active++}
function Get-MoveEntryIdentity {param($Path) [pscustomobject]@{FileId='root'}}
function Get-MigrationExistingEntry {param($Path) [pscustomobject]@{FullName=$Path;Attributes=[IO.FileAttributes]::Normal}}
$r=New-T6Record;$r.State='Active';$document=[pscustomobject]@{Entries=@($r)}
$result=Invoke-MoveRecord $r 'fake' $document Release
Assert-T6 ($result.Status -eq 'Done' -and $r.State -eq 'Released') 'release completes fake operation'
Assert-T6 ($script:counts.Validate -eq 1 -and $script:counts.Convert -eq 1 -and $script:counts.Read -eq 1) 'P1 record/inventory work constant for 5000 files'
Assert-T6 ($script:counts.Active -ge 8 -and $script:counts.Active -le 12 -and $script:counts.Inventory -eq 1) 'P1 active checks batched; no whole-inventory revalidation per file'
Assert-T6 ([T6MoveNative]::Deletes -eq 5001) 'P1 each file plus root handled once'
# The same real helper refuses a substituted identity, length/time change or wrong final path.
$beforeDeletes=[T6MoveNative]::Deletes
Assert-ThrowsT6 {Remove-MoveRetainedLeaf 'C:\Users\me\Documents\文件0.db' @{FileId='different';Length=10;WriteTicks=100} $false $false} 'per-file identity substitution refuses delete'
Assert-ThrowsT6 {Remove-MoveRetainedLeaf 'C:\Users\me\Documents\文件0.db' @{FileId='id0';Length=11;WriteTicks=100} $false $false} 'per-file size change refuses delete'
Assert-ThrowsT6 {Remove-MoveRetainedLeaf 'C:\Users\me\Documents\文件0.db' @{FileId='id0';Length=10;WriteTicks=101} $false $false} 'per-file timestamp change refuses delete'
Assert-T6 ([T6MoveNative]::Deletes -eq $beforeDeletes) 'failed per-file guard never marks deletion'
function Remove-MoveRetainedLeaf {param($Path,$Expected,$Directory,$Hash,$Checkpoint) $script:counts.Delete++}
# P1 wall-clock safety check even when fewer than 1000 entries processed.
$script:now=[datetime]::new(2026,1,1);$script:activeCalls=0
Invoke-MoveReleaseLoop $r (New-T6Inventory 3) {param($r,$b) $script:activeCalls++} {} { $script:now=$script:now.AddSeconds(31);$script:now }
Assert-T6 ($script:activeCalls -eq 5) 'P1 30-second active guard and final check'

# P3 actual Copying orchestration with fake Windows boundaries, including a killed copy.
$script:copyCalls=0;$script:switchCalls=0;$script:crash=$true
function Invoke-MoveCopy {param($Record,$Baseline) $script:copyCalls++;if($script:crash){throw '模拟中断'}}
function New-MigrationDirectory {param($Path) $script:mutations++;return $true}
function Invoke-MoveSwitch {param($Record,$Baseline,$Manifest,$Document) $script:switchCalls++;Set-MoveState $Record Active $Manifest $Document}
$r=New-T6Record;$r.State='Copying';$document=[pscustomobject]@{Entries=@($r)}
Assert-ThrowsT6 {Invoke-MoveRecord $r fake $document Move} 'P3 interrupted copy returns without switch'
Assert-T6 ($r.State -eq 'Copying' -and $script:switchCalls -eq 0) 'P3 Copying persists after interruption'
$script:crash=$false;$result=Invoke-MoveRecord $r fake $document Move
Assert-T6 ($result.Status -eq 'Done' -and $script:copyCalls -eq 2 -and $script:switchCalls -eq 1) 'P3 resume reaches switch after verify'
Assert-T6 ($result.ResumeHint -match 'ResumeId' -and $result.Schema -eq 'pc-care/move/1') 'P3 result gives safe resume guidance'
$r.State='Copied';$script:copyCalls=0;$null=Invoke-MoveRecord $r fake $document Move
Assert-T6 ($script:copyCalls -eq 0) 'P3 interrupted verification resumes without repeating copy'

# WhatIf through actual orchestration: zero write, external-tool, log or delete calls.
$script:mutations=0
function Read-MoveInventory {throw 'WhatIf must not read/conversion inventory for release'}
function Write-MigrationManifest {$script:mutations++}
function Invoke-External {$script:mutations++}
function Invoke-MoveCopy {$script:mutations++}
function New-MigrationDirectory {$script:mutations++}
function Invoke-MoveRelease {$script:mutations++}
function Invoke-MoveRollback {$script:mutations++}
$WhatIfPreference=$true
foreach($operation in @('Move','Release','Rollback')){
    $r=New-T6Record;$result=Invoke-MoveRecord $r fake @{Entries=@($r)} $operation
    Assert-T6 ($result.StoppedAt -eq 'WhatIf') ('WhatIf '+$operation)
}
Assert-T6 ($script:mutations -eq 0) 'WhatIf no writes, external tools, release or rollback'
$WhatIfPreference=$false

# Actual copy adapter: verify resumable robocopy arguments, progress callbacks and foreign-file refusal.
Restore-T6 @('Invoke-MoveCopy','Assert-MoveAppsClosed','Get-MigrationExistingEntry','Set-MoveState')
$script:copyBaseline=New-T6Inventory 4;$script:copyActual=New-T6Inventory 1;$script:copyArgs=@();$script:externalCalls=0
function Get-CimInstance {param($ClassName,$Filter) return @()}
function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded) if($Path -eq 'C:\Users\me\Documents'){$script:copyBaseline}else{$script:copyActual}}
function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;$f.FreeBytes=100000;$f.NonEmpty=$NonEmpty;$f.Resume=$Resume;return $f}
function Invoke-External {
    param($FilePath,$ArgumentList,$Description,$SuccessExitCodes,$OutputEncoding,$OutputLine,$ProgressCallback,$Confirm)
    $script:externalCalls++;$script:copyArgs=$ArgumentList
    if($OutputLine){$null=& $OutputLine '  新文件 10 C:\Users\me\Documents\文件1.db'}
    if($ProgressCallback){$null=& $ProgressCallback}
    [pscustomobject]@{ExitCode=1}
}
$r=New-T6Record
Invoke-MoveCopy $r $script:copyBaseline
Assert-T6 ($script:externalCalls -eq 1 -and '/XJ' -in $script:copyArgs -and '/E' -in $script:copyArgs) 'copy adapter runs resumable copy with /XJ'
Assert-T6 (@($script:copyArgs | Where-Object {$_ -in @('/MIR','/PURGE','/MOVE','/MOV')}).Count -eq 0) 'copy adapter never removes source/destination files'
$script:copyActual.Files['foreign.db']=$script:copyActual.Files['文件0.db']
Assert-ThrowsT6 {Invoke-MoveCopy $r $script:copyBaseline} 'P3 real copy adapter refuses foreign file before external tool'
Assert-T6 ($script:externalCalls -eq 1) 'P3 foreign file has no copy side effects'

# P4c actual known-folder switch recreates skipped link at destination and leaves old link intact.
Restore-T6 @('Invoke-MoveSwitch','Assert-MoveInventoryMatch')
$script:copyActual=New-T6Inventory 0
$script:created=[Collections.Generic.List[string]]::new();$script:activated=''
function Get-CleanerKnownFolderMap {param($Context) return @{Documents='C:\Users\me\Documents'}}
function Set-MoveKnownFolder {param($Name,$Path) $script:activated=$Path}
function New-MovePreservedJunction {param($Path,$Target) $script:created.Add($Path+' => '+$Target)}
function Get-MigrationExistingEntry {param($Path) return $null}
function Assert-MoveActive {param($Record,$Baseline,[switch]$Inventory,[switch]$AllowRunning)}
function Write-MigrationManifest {param($Path,$Document)}
$r=New-T6Record;$r.State='Verified';$inventory=New-T6Inventory 0;$inventory.Links['WeChat Files']='D:\Chat'
Invoke-MoveSwitch $r $inventory fake @{Entries=@($r)}
Assert-T6 ($script:activated -eq $r.Destination -and $script:created.Count -eq 1 -and $script:created[0].StartsWith('D:\资料\文档\WeChat Files')) 'P4c restored link uses new Documents path'
Assert-T6 ($r.State -eq 'Active') 'P4c switch only active after link restoration'

# Actual rollback adapters use exact retained name; no destination deletion callback is reached.
Restore-T6 @('Invoke-MoveRollback')
$script:renames=[Collections.Generic.List[string]]::new();$script:removedLinks=[Collections.Generic.List[string]]::new();$script:linkPresent=$true
function Get-MigrationExistingEntry {
    param($Path)
    if($Path -like '*.cdrive-retained-*'){return [pscustomobject]@{Attributes=[IO.FileAttributes]::Directory}}
    if($script:linkPresent){return [pscustomobject]@{Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)}}
    return $null
}
function Remove-MoveVerifiedJunction {param($Path,$Target) $script:removedLinks.Add($Path+' => '+$Target);$script:linkPresent=$false}
function Move-MoveDirectory {param($Source,$Target) $script:renames.Add($Source+' => '+$Target)}
$app=New-T6Record WeChat;$app.State='Active';$app.Source='C:\Users\me\Documents\WeChat Files';$app.RetainedSource=$app.Source+'.cdrive-retained-'+$app.Id
Invoke-MoveRollback $app (New-T6Inventory) fake @{Entries=@($app)}
Assert-T6 ($script:removedLinks.Count -eq 1 -and $script:removedLinks[0].StartsWith($app.Source)) 'app rollback only removes verified source junction'
Assert-T6 ($script:renames.Count -eq 1 -and $script:renames[0] -eq ($app.RetainedSource+' => '+$app.Source) -and $app.State -eq 'RolledBack') 'app rollback restores exact retained name'
$r=New-T6Record;$r.State='Active'
Invoke-MoveRollback $r (New-T6Inventory) fake @{Entries=@($r)}
Assert-T6 ($script:activated -eq $r.Source -and $r.State -eq 'RolledBack') 'known-folder rollback restores original API location'

# Install detection is read-only and does not invent data roots from installation paths.
$installs=@(Get-MoveAppInstallations $script:MigrationContext {param($h,$k,$n) if($k -match 'WeChat' -and $n -eq 'InstallPath'){'C:\Program Files\Tencent\WeChat'}})
Assert-T6 ($installs.Count -eq 2 -and $installs[0].Installed -eq $true -and $installs[0].InstallPaths.Count -eq 1 -and $null -eq $installs[1].Installed) 'installation detection reports unknown without false absence'
$plan=@(Get-MoveChatPlan @(@{Path='C:\a\WeChat Files'},@{Path='C:\b\xwechat_files'},@{Path='C:\a\WeChat Files'}) 'D:\Chat')
Assert-T6 ($plan.Count -eq 2 -and $plan[0].Destination -eq 'D:\Chat\WeChat Files' -and $plan[1].Destination -eq 'D:\Chat\xwechat_files') 'multi-layout plan covers both versions exactly once'
$plan=@(Get-MoveChatPlan @(@{Path='C:\a\data'},@{Path='C:\b\data'}) 'D:\Chat')
Assert-T6 ($plan[0].Destination -ne $plan[1].Destination) 'custom roots with same leaf have different targets'

# WhatIf new move goes through discovery/preflight, with every mutation faked and counted.
Restore-T6 @('Invoke-MoveNew')
$script:mutations=0
function Get-MigrationExistingEntry {param($Path) if($Path.StartsWith('C:')){[pscustomobject]@{Attributes=[IO.FileAttributes]::Directory;PSIsContainer=$true}}}
function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded) New-T6Inventory}
function Write-MoveInventory {$script:mutations++}
function Set-MoveState {$script:mutations++}
function Invoke-MoveRecord {$script:mutations++}
function Get-MoveAppInstallations {param($Context) @()}
function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) New-T6Facts}
$WhatIfPreference=$true
$result=Invoke-MoveNew KnownFolder Documents 'D:\new' fake @{Entries=@()} $false
Assert-T6 ($result.StoppedAt -eq 'WhatIf' -and $result.Preview -and $script:mutations -eq 0) 'WhatIf new move has no writes or external tools'
$WhatIfPreference=$false

# P3 rerunning the identical command selects its previous Copying record before discovering new paths.
$WhatIfPreference=$false;$script:resumed=''
function Invoke-MoveRecord {param($Record,$Manifest,$Document,$Operation) $script:resumed=$Record.Id;New-MoveResult Done Copying '' $Record}
$r=New-T6Record;$r.Folder='Documents';$r.State='Copying'
$null=Invoke-MoveNew KnownFolder Documents $r.Destination fake @{Entries=@($r)} $false
Assert-T6 ($script:resumed -eq $r.Id) 'P3 identical command resumes existing record'

# Real shared whitelist matching with fake handles; sidecar scope must not leak outside log directory.
Restore-T6 @('Assert-MoveRecord','Assert-MigrationTarget','Test-CleanerRetainedChat')
function Get-CleanerEntryMetadata {param($LiteralPath) [pscustomobject]@{IsDirectory=($LiteralPath -notmatch '\.(tsv|json)(?:\.|$)');LinkCount=1}}
foreach($path in @('C:\Users\me\AppData\Local\pc-care\logs\move-inventory-'+('a'*32)+'.tsv')) {
    Assert-T6 ((Test-SafeTarget $path MigrationManifest $script:MigrationContext).IsSafe) 'P2 sidecar accepted by actual MigrationManifest matching'
}
foreach($path in @('C:\Users\me\AppData\Local\pc-care\move-inventory-a.tsv','C:\Users\me\AppData\Local\pc-care\logs\other.tsv','C:\Users\me\Documents')) {
    Assert-T6 (-not (Test-SafeTarget $path MigrationManifest $script:MigrationContext).IsSafe) 'P2 non-sidecar/outside log rejected'
}
foreach($path in @('C:\Users\me\Documents','C:\Users\me\AppData','C:\Users\me\Documents\OtherApp')) {
    Assert-T6 (-not (Test-SafeTarget $path MoveChat $script:MigrationContext).IsSafe) 'exact chat whitelist refuses broad and unrelated root'
}
function Test-CleanerPathChain {param($LiteralPath,[switch]$AllowMissing) [pscustomobject]@{IsSafe=$true;Path=$LiteralPath;Exists=($LiteralPath -notlike '*WeChat Files');Attributes=[IO.FileAttributes]::Directory;ExistingParent='C:\Users\me\Documents'}}
function Get-CleanerChildren {param($LiteralPath) @()}
Assert-T6 (-not (Test-SafeTarget 'C:\Users\me\Documents\WeChat Files' MoveChat $script:MigrationContext).IsSafe) 'missing chat root requires retained-copy proof'
function Get-CleanerChildren {param($LiteralPath) [pscustomobject]@{FullName=('C:\Users\me\Documents\WeChat Files.cdrive-retained-'+('a'*32))}}
Assert-T6 ((Test-SafeTarget 'C:\Users\me\Documents\WeChat Files' MoveChat $script:MigrationContext).IsSafe) 'exact retained chat sibling proves interrupted switch'

# Persistent lock is released by the OS on interruption and can reopen without unlink races.
function Assert-MigrationTarget {param($Path,$Category)}
$testDir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($testDir)
try {
    $lockPath=Join-Path $testDir 'moves.json';$lock=Open-MigrationManifestLock $lockPath -Persistent
    Assert-ThrowsT6 {Open-MigrationManifestLock $lockPath -Persistent} 'P3 concurrent move cannot acquire same lock'
    Close-MigrationManifestLock $lock
    Assert-T6 ([IO.File]::Exists($lockPath+'.lock')) 'P3 persistent lock file is not unlinked'
    $lock=Open-MigrationManifestLock $lockPath -Persistent;Close-MigrationManifestLock $lock
    Assert-T6 $true 'P3 stale lock file allows resume after handle is released'
}
finally {if($null -ne $lock){$lock.Stream.Dispose()};foreach($p in [IO.Directory]::EnumerateFiles($testDir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($testDir)}

# Rollback can restore the original even when the destination disk is disconnected.
function Assert-MigrationTarget {param($Path,$Category) if($Path.StartsWith('D:')){throw '模拟数据盘不在线'}}
$r=New-T6Record
Assert-MoveRecord $r -ForRollback
Assert-T6 $true 'rollback validates recorded path without accessing offline data volume'
Assert-ThrowsT6 {Assert-MoveRecord $r} 'move/release still require a reachable safe destination'
function Assert-MigrationTarget {param($Path,$Category)}

# Streaming hash agrees with SHA256 and works without Windows APIs.
$bytes=[Text.Encoding]::UTF8.GetBytes('聊天内容');$stream=[IO.MemoryStream]::new($bytes);$sha=[Security.Cryptography.SHA256]::Create()
try {Assert-T6 ((Get-MoveStreamHash $stream) -eq [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')) 'streaming hash correct'} finally {$stream.Dispose();$sha.Dispose()}

# P3 tiny hashed files must not each print progress; the enclosing inventory reports the phase.
& {
    $script:hashLines=0
    function Write-Host {param($Object) $script:hashLines++}
    for($i=0;$i -lt 10;$i++) {
        $stream=[IO.MemoryStream]::new([byte[]]@(1,2,3))
        try {$null=Get-MoveStreamHash $stream} finally {$stream.Dispose()}
    }
    Assert-T6 ($script:hashLines -eq 0) 'P3 hash progress does not flood one line per small file'
}

# Self-elevation passes original identity, continuation data and an explicit result path; cancellation is a result.
$script:elevationArgs='';$script:elevationCalls=0
function Get-Process {param($Id,$ErrorAction) [pscustomobject]@{Path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';ProcessName='notepad'}}
function Start-Process {param($FilePath,$ArgumentList,$Verb,[switch]$Wait,[switch]$PassThru,$ErrorAction) $script:elevationCalls++;$script:elevationArgs=$ArgumentList;throw '模拟取消'}
$output=Join-Path $PSScriptRoot ('not-created-'+[guid]::NewGuid().ToString('N')+'.json')
$result=Invoke-MoveElevatedChild @{ResumeId=('a'*32)} 'C:\pc-care\move.ps1' $output
Assert-T6 ($result.Status -eq 'Failed' -and $result.StoppedAt -eq 'Elevation' -and $result.Reason.Contains('取消') -and $script:elevationCalls -eq 1) 'UAC cancellation skips without attempting a move'
Assert-T6 ($script:elevationArgs.Contains('-OriginalUserSid') -and $script:elevationArgs.Contains('S-test') -and $script:elevationArgs.Contains('-OriginalUserProfile') -and $script:elevationArgs.Contains('-ResumeId') -and $script:elevationArgs.Contains('-ResultPath')) 'elevation preserves identity and resume command'
Restore-T6 @('Set-MoveKnownFolder')
$script:MigrationContext.CurrentUserSid='other'
Assert-ThrowsT6 {Set-MoveKnownFolder Documents 'D:\docs'} 'another account cannot change original known folder'
$script:MigrationContext.CurrentUserSid='S-test'

# Result writer creates a fresh JSON, emits a final RESULT line and does nothing in preview.
$testDir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($testDir)
try {
    $path=Join-Path $testDir 'result.json';$result=New-MoveResult Done Active '' (New-T6Record)
    $text=@(Write-MoveResult $result $path)
    $json=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-T6 ($json.Schema -eq 'pc-care/move/1' -and $text[-1] -eq ('RESULT: '+$path)) 'result schema and final locator line'
    Assert-ThrowsT6 {Write-MoveResult $result $path} 'result JSON never overwritten'
    $preview=Join-Path $testDir 'preview.json';$WhatIfPreference=$true;$text=@(Write-MoveResult $result $preview)
    Assert-T6 (-not [IO.File]::Exists($preview) -and $text[-1] -eq ('RESULT: '+$preview)) 'WhatIf result printed without writing reserved path'
    $WhatIfPreference=$false
}
finally {$WhatIfPreference=$false;foreach($p in [IO.Directory]::EnumerateFiles($testDir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($testDir)}
Assert-ThrowsT6 {Assert-MigrationSeparation 'C:\src' 'C:\dest'} 'same volume rejected by pure separation logic'
Assert-ThrowsT6 {Assert-MigrationSeparation 'C:\src' 'C:\src\child'} 'nested destination rejected by pure separation logic'

# Exercise loader used in production; it must not execute migrate body on Linux.
Import-MoveMigrationFunctions (Join-Path $repo 'scripts/migrate.ps1')
Assert-T6 ((Get-MigrationValue @{a=42} @('a')) -eq 42) 'AST migration reuse loader works'
Write-Output ('PASS t6-move: '+$script:assertions+' assertions')

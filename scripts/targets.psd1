<#
.SYNOPSIS
    C 盘清理白名单和永久禁止区（纯数据，不执行代码）。
.DESCRIPTION
    占位符由 common.ps1 使用原用户身份展开，绝不使用提权账户的用户目录。
    Contents 只允许清空目录内容；File 只允许指定文件；SelectedFiles 仅允许列出的文件名。
    ExternalOnly 类别只能交给官方工具处理，Remove-SafeItem 拒绝直接删除。
    MigrationOnly 类别仅授权迁移；Container 仅核实准确目录，不授权其内容。
    App / ProcessNames 仅为显示名及须退出的进程名称；ExcludeChildren 保留准确子项及其后代。
.PARAMETER Categories
    类别及其路径、范围、原用户身份要求和处理方式。
.PARAMETER ForbiddenPaths
    永久禁止路径及其所有子路径；通配符只匹配一个路径段。
.EXAMPLE
    Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'targets.psd1')
#>
@{
    SchemaVersion = 1
    CleanupDrive = 'C:'
    # 保持其他脚本使用的类别拼写兼容；别名不改变删除权限。
    CategoryAliases = @{ UpdateCache = 'WindowsUpdate'; CrashDumps = 'CrashDumpReports' }
    UserScopedExecutables = @(
        'npm', 'npm.cmd', 'npm.exe', 'pip', 'pip.exe', 'pip3', 'pip3.exe'
        'conda', 'conda.exe', 'conda.bat', 'dotnet', 'dotnet.exe'
        'yarn', 'yarn.cmd', 'pnpm', 'pnpm.cmd', 'pnpm.exe', 'go', 'go.exe'
    )

    # Known Folder 使用 Shell API 读取原用户当前路径，不猜测固定目录名。
    MigrationKnownFolders = @{
        Desktop = 'B4BFCC3A-DB2C-424C-B029-7FE99A87C641'
        Documents = 'FDD39AD0-238F-46AF-ADB4-6C85480369C7'
        Downloads = '374DE290-123F-4565-9164-39C4925E467B'
        Pictures = '33E28130-4E1E-4676-835A-98395C3BC3BB'
        Videos = '18989B1D-99B5-455B-841C-AB7C74E4DDFC'
    }
    # 数据卷上的同名系统区域也不作为迁移目标；%VOLUME% 只取已校验的盘符。
    MigrationForbiddenPaths = @(
        '%VOLUME%\Windows', '%VOLUME%\Program Files', '%VOLUME%\Program Files (x86)'
        '%VOLUME%\ProgramData', '%VOLUME%\WindowsApps', '%VOLUME%\WpSystem'
        '%VOLUME%\Recovery', '%VOLUME%\System Volume Information', '%VOLUME%\Boot'
        '%VOLUME%\EFI', '%VOLUME%\$Recycle.Bin', '%VOLUME%\$WINDOWS.~BT', '%VOLUME%\$WINDOWS.~WS'
    )

    Categories = @{
        UserFolder = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $false; TargetSource = 'KnownFolders'; Targets = @()
        }
        DevCacheMigration = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $false; TargetSource = 'DevCache'
            Targets = @(
                # 仅复制保留配置，绝不能通过此类别删除整个 .gradle 或 .m2。
                @{ Path = '%USERPROFILE%\.gradle'; Scope = 'Contents'; AllowProtectedRoot = $true }
                @{ Path = '%USERPROFILE%\.m2\repository'; Scope = 'Contents' }
            )
        }
        AppData = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $false; TargetSource = 'ApplicationFiles'
            # 不授权整个 Tencent/AppData，也不推测其他版本的聊天数据库位置。
            Targets = @(
                @{ RelativePath = 'WeChat Files'; Scope = 'Contents' }
                @{ RelativePath = 'Tencent Files'; Scope = 'Contents' }
                @{ RelativePath = 'xwechat_files'; Scope = 'Contents' }
            )
        }
        WSL = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $false; TargetSource = 'RegisteredWSL'; Targets = @()
        }
        Junction = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            # 改名后仅当安全的同根保留副本存在时，允许缓存根暂时缺失。
            AllowMissing = $false; TargetSource = 'DevCache'; Targets = @()
        }
        MigrationDestination = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $true; TargetSource = 'DataVolume'; Targets = @()
        }
        DevCacheConfig = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $true; TargetSource = 'Configuration'
            Targets = @(
                @{ Path = '%USERPROFILE%\.npmrc'; Scope = 'File' }
                @{ Path = '%USERPROFILE%\.condarc'; Scope = 'File' }
                @{ Path = '%USERPROFILE%\.m2\settings.xml'; Scope = 'File' }
            )
        }
        MigrationManifest = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $true; TargetSource = 'AuditDirectory'; Targets = @()
        }
        JunctionBackup = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $true; TargetSource = 'RetainedDevCache'; Targets = @()
        }
        JunctionParent = @{
            RequiresOriginalUser = $true; ExternalOnly = $true; MigrationOnly = $true
            AllowMissing = $false; TargetSource = 'DevCacheParent'; Targets = @()
        }
        UserTemp = @{
            RequiresOriginalUser = $true
            ExternalOnly = $false
            Targets = @(
                # 自定义 TEMP 不构成用途证明；仅允许已解析的标准临时目录。
                @{ Path = '%LOCALAPPDATA%\Temp'; Scope = 'Contents' }
            )
        }
        WindowsTemp = @{
            RequiresOriginalUser = $false
            ExternalOnly = $false
            Targets = @(@{ Path = '%SystemRoot%\Temp'; Scope = 'Contents' })
        }
        ThumbnailCache = @{
            RequiresOriginalUser = $true
            ExternalOnly = $false
            Targets = @(
                @{
                    Path = '%LOCALAPPDATA%\Microsoft\Windows\Explorer'
                    Scope = 'SelectedFiles'
                    FilePatterns = @('thumbcache_*.db')
                    Recursive = $false
                }
            )
        }
        BrowserCache = @{
            RequiresOriginalUser = $true
            ExternalOnly = $false
            Targets = @(
                @{ Path = '%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache'; Scope = 'Contents'; App = 'Chrome'; ProcessNames = @('chrome') }
                @{ Path = '%LOCALAPPDATA%\Google\Chrome\User Data\*\Network\Cache'; Scope = 'Contents'; App = 'Chrome'; ProcessNames = @('chrome') }
                @{ Path = '%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache'; Scope = 'Contents'; App = 'Chrome'; ProcessNames = @('chrome') }
                @{ Path = '%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache'; Scope = 'Contents'; App = 'Chrome'; ProcessNames = @('chrome') }
                @{ Path = '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache'; Scope = 'Contents'; App = 'Edge'; ProcessNames = @('msedge') }
                @{ Path = '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Network\Cache'; Scope = 'Contents'; App = 'Edge'; ProcessNames = @('msedge') }
                @{ Path = '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache'; Scope = 'Contents'; App = 'Edge'; ProcessNames = @('msedge') }
                @{ Path = '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache'; Scope = 'Contents'; App = 'Edge'; ProcessNames = @('msedge') }
                @{ Path = '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Cache'; Scope = 'Contents'; App = 'Brave'; ProcessNames = @('brave') }
                @{ Path = '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Code Cache'; Scope = 'Contents'; App = 'Brave'; ProcessNames = @('brave') }
                @{ Path = '%LOCALAPPDATA%\Chromium\User Data\*\Cache'; Scope = 'Contents'; App = 'Chromium'; ProcessNames = @('chrome') }
                @{ Path = '%LOCALAPPDATA%\Chromium\User Data\*\Code Cache'; Scope = 'Contents'; App = 'Chromium'; ProcessNames = @('chrome') }
                @{ Path = '%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2'; Scope = 'Contents'; App = 'Firefox'; ProcessNames = @('firefox') }
                @{ Path = '%LOCALAPPDATA%\Opera Software\Opera Stable\Cache'; Scope = 'Contents'; App = 'Opera'; ProcessNames = @('opera') }
                @{ Path = '%LOCALAPPDATA%\Opera Software\Opera Stable\Code Cache'; Scope = 'Contents'; App = 'Opera'; ProcessNames = @('opera') }
            )
        }
        AppCache = @{
            RequiresOriginalUser = $true
            ExternalOnly = $false
            Targets = @(
                @{ Path = '%APPDATA%\Code\Cache'; Scope = 'Contents'; App = 'VS Code'; ProcessNames = @('Code') }
                @{ Path = '%APPDATA%\Code\CachedData'; Scope = 'Contents'; App = 'VS Code'; ProcessNames = @('Code') }
                @{ Path = '%APPDATA%\Code\Code Cache'; Scope = 'Contents'; App = 'VS Code'; ProcessNames = @('Code') }
                @{ Path = '%APPDATA%\Code\GPUCache'; Scope = 'Contents'; App = 'VS Code'; ProcessNames = @('Code') }
                @{ Path = '%APPDATA%\Code\CachedExtensionVSIXs'; Scope = 'Contents'; App = 'VS Code'; ProcessNames = @('Code') }
                @{ Path = '%APPDATA%\Code\logs'; Scope = 'Contents'; App = 'VS Code'; ProcessNames = @('Code') }
                @{ Path = '%APPDATA%\Microsoft\Teams\Cache'; Scope = 'Contents'; App = 'Teams 经典版'; ProcessNames = @('Teams') }
                @{ Path = '%APPDATA%\Microsoft\Teams\Code Cache'; Scope = 'Contents'; App = 'Teams 经典版'; ProcessNames = @('Teams') }
                @{ Path = '%APPDATA%\Microsoft\Teams\GPUCache'; Scope = 'Contents'; App = 'Teams 经典版'; ProcessNames = @('Teams') }
                @{ Path = '%APPDATA%\Microsoft\Teams\tmp'; Scope = 'Contents'; App = 'Teams 经典版'; ProcessNames = @('Teams') }
                @{ Path = '%APPDATA%\discord\Cache'; Scope = 'Contents'; App = 'Discord'; ProcessNames = @('Discord') }
                @{ Path = '%APPDATA%\discord\Code Cache'; Scope = 'Contents'; App = 'Discord'; ProcessNames = @('Discord') }
                @{ Path = '%APPDATA%\discord\GPUCache'; Scope = 'Contents'; App = 'Discord'; ProcessNames = @('Discord') }
                @{ Path = '%APPDATA%\Slack\Cache'; Scope = 'Contents'; App = 'Slack'; ProcessNames = @('slack') }
                @{ Path = '%APPDATA%\Slack\Code Cache'; Scope = 'Contents'; App = 'Slack'; ProcessNames = @('slack') }
                @{ Path = '%APPDATA%\Slack\GPUCache'; Scope = 'Contents'; App = 'Slack'; ProcessNames = @('slack') }
                @{
                    Path = '%LOCALAPPDATA%\JetBrains\*\caches'; Scope = 'Contents'; App = 'JetBrains IDE'
                    ProcessNames = @('idea64', 'pycharm64', 'webstorm64', 'goland64', 'clion64', 'rider64', 'datagrip64', 'phpstorm64', 'rubymine64', 'rustrover64')
                }
                @{
                    Path = '%LOCALAPPDATA%\JetBrains\*\log'; Scope = 'Contents'; App = 'JetBrains IDE'
                    ProcessNames = @('idea64', 'pycharm64', 'webstorm64', 'goland64', 'clion64', 'rider64', 'datagrip64', 'phpstorm64', 'rubymine64', 'rustrover64')
                }
                # 微信、QQ 和新版 Teams 的目录布局须按版本核实，暂不授权自动清理。
            )
        }
        ShaderCache = @{
            RequiresOriginalUser = $true
            ExternalOnly = $false
            Targets = @(
                @{ Path = '%LOCALAPPDATA%\D3DSCache'; Scope = 'Contents'; App = 'Direct3D' }
                @{ Path = '%LOCALAPPDATA%\NVIDIA\DXCache'; Scope = 'Contents'; App = 'NVIDIA' }
                @{ Path = '%LOCALAPPDATA%\NVIDIA\GLCache'; Scope = 'Contents'; App = 'NVIDIA' }
                @{ Path = '%LOCALAPPDATA%\AMD\DxCache'; Scope = 'Contents'; App = 'AMD' }
                @{ Path = '%LOCALAPPDATA%\AMD\DxcCache'; Scope = 'Contents'; App = 'AMD' }
                @{ Path = '%LOCALAPPDATA%\AMD\GLCache'; Scope = 'Contents'; App = 'AMD' }
                @{ Path = '%LOCALAPPDATA%\AMD\VkCache'; Scope = 'Contents'; App = 'AMD' }
                @{ Path = '%LOCALAPPDATA%\Intel\ShaderCache'; Scope = 'Contents'; App = 'Intel' }
            )
        }
        InetCache = @{
            RequiresOriginalUser = $true
            ExternalOnly = $false
            Targets = @(
                # Outlook 的已打开附件副本可能包含未保存修改，连同所有子项一起保留。
                @{ Path = '%LOCALAPPDATA%\Microsoft\Windows\INetCache'; Scope = 'Contents'; ExcludeChildren = @('Content.Outlook') }
            )
        }
        SystemLogs = @{
            RequiresOriginalUser = $false
            ExternalOnly = $false
            Targets = @(
                @{ Path = '%SystemRoot%\Logs\CBS'; Scope = 'SelectedFiles'; FilePatterns = @('CbsPersist_*.log', 'CbsPersist_*.cab'); Recursive = $false }
                @{ Path = '%SystemRoot%\Logs\WindowsUpdate'; Scope = 'SelectedFiles'; FilePatterns = @('*.etl'); Recursive = $false }
            )
        }
        DevCache = @{
            RequiresOriginalUser = $true
            ExternalOnly = $true
            Targets = @(
                @{ Path = '%USERPROFILE%\.npm'; Scope = 'Contents' }
                @{ Path = '%USERPROFILE%\.npm-cache'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\npm-cache'; Scope = 'Contents' }
                @{ Path = '%APPDATA%\npm-cache'; Scope = 'Contents' }
                @{ Path = '%USERPROFILE%\.cache\pip'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\pip\Cache'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\NuGet\Cache'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\NuGet\v3-cache'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\NuGet\plugins-cache'; Scope = 'Contents' }
                @{ Path = '%USERPROFILE%\.nuget\packages'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\Temp\NuGetScratch'; Scope = 'Contents' }
                @{ Path = '%USERPROFILE%\.conda\pkgs'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\conda\conda\pkgs'; Scope = 'Contents' }
                @{ Path = '%USERPROFILE%\miniconda3\pkgs'; Scope = 'Contents' }
                @{ Path = '%USERPROFILE%\anaconda3\pkgs'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\miniconda3\pkgs'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\anaconda3\pkgs'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\Programs\miniconda3\pkgs'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\Programs\anaconda3\pkgs'; Scope = 'Contents' }
                @{ Path = '%USERPROFILE%\.gradle\caches\modules-2\files-2.1'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\Yarn\Cache'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\Yarn\Berry\cache'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\pnpm\store'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\pnpm-store'; Scope = 'Contents' }
                @{ Path = '%LOCALAPPDATA%\go-build'; Scope = 'Contents' }
                @{ Path = '%USERPROFILE%\go\pkg\mod'; Scope = 'Contents' }
            )
        }
        WER = @{
            RequiresOriginalUser = $false
            ExternalOnly = $false
            Targets = @(@{ Path = '%ProgramData%\Microsoft\Windows\WER'; Scope = 'Contents' })
        }
        CrashDump = @{
            RequiresOriginalUser = $false
            ExternalOnly = $false
            Targets = @(
                @{ Path = '%SystemRoot%\Minidump'; Scope = 'Contents' }
                @{ Path = '%SystemRoot%\LiveKernelReports'; Scope = 'Contents' }
                @{ Path = '%SystemRoot%\MEMORY.DMP'; Scope = 'File' }
            )
        }
        UserCrashDump = @{
            RequiresOriginalUser = $true
            ExternalOnly = $false
            Targets = @(@{ Path = '%LOCALAPPDATA%\CrashDumps'; Scope = 'Contents' })
        }
        CrashDumpReports = @{
            RequiresOriginalUser = $false
            ExternalOnly = $false
            Targets = @(
                @{ Path = '%ProgramData%\Microsoft\Windows\WER'; Scope = 'Contents' }
                @{ Path = '%SystemRoot%\Minidump'; Scope = 'Contents' }
                @{ Path = '%SystemRoot%\LiveKernelReports'; Scope = 'Contents' }
                @{ Path = '%SystemRoot%\MEMORY.DMP'; Scope = 'File' }
            )
        }
        RecycleBin = @{
            RequiresOriginalUser = $true
            ExternalOnly = $true
            Targets = @(@{ Path = '%SystemDrive%\$Recycle.Bin\%ORIGINALUSERSID%'; Scope = 'Contents' })
        }
        WindowsUpdate = @{
            RequiresOriginalUser = $false
            # 只授权下列精确 Download 目录的内容，根目录始终保留。
            ExternalOnly = $false
            Targets = @(@{ Path = '%SystemRoot%\SoftwareDistribution\Download'; Scope = 'Contents' })
        }
        DeliveryOptimization = @{
            RequiresOriginalUser = $false
            ExternalOnly = $true
            Targets = @(@{ Path = '%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache'; Scope = 'Contents' })
        }
        WindowsOld = @{
            RequiresOriginalUser = $false
            ExternalOnly = $true
            Targets = @(@{ Path = '%SystemDrive%\Windows.old'; Scope = 'Contents' })
        }
        UpgradeFiles = @{
            RequiresOriginalUser = $false
            ExternalOnly = $true
            Targets = @(
                @{ Path = '%SystemDrive%\$WINDOWS.~BT'; Scope = 'Contents' }
                @{ Path = '%SystemDrive%\$WINDOWS.~WS'; Scope = 'Contents' }
            )
        }
    }

    # 下列规则优先于一切白名单；从不允许以子目录例外覆盖禁止区。
    ForbiddenPaths = @(
        '%SystemRoot%\WinSxS'
        '%SystemRoot%\System32'
        '%SystemRoot%\SysWOW64'
        '%SystemRoot%\Sysnative'
        '%SystemRoot%\Installer'
        '%SystemRoot%\DriverStore'
        '%SystemRoot%\servicing'
        '%SystemRoot%\Recovery'
        '%SystemDrive%\Recovery'
        '%SystemDrive%\System Volume Information'
        '%SystemDrive%\Boot'
        '%SystemDrive%\EFI'
        '%ProgramFiles%'
        '%ProgramFiles(x86)%'
        '%ProgramW6432%'
        '%ProgramData%\Package Cache'
        '%ProgramData%\Microsoft\Windows\AppRepository'
        '%LOCALAPPDATA%\Microsoft\WindowsApps'
        '%USERPROFILE%\OneDrive*'
        '%USERPROFILE%\Dropbox'
        '%USERPROFILE%\Google Drive'
        '%USERPROFILE%\GoogleDrive'
        '%USERPROFILE%\iCloudDrive'
        '%USERPROFILE%\Box'
        '%USERPROFILE%\Box Sync'
    )

    # 只保护目录本身，避免将 AppData/ProgramData/用户目录作为整棵树处理。
    ProtectedRoots = @(
        '%SystemRoot%'
        '%SystemDrive%\Users'
        '%USERPROFILE%'
        '%USERPROFILE%\AppData'
        '%LOCALAPPDATA%'
        '%APPDATA%'
        '%ProgramData%'
        '%LOCALAPPDATA%\Google\Chrome\User Data'
        '%LOCALAPPDATA%\Microsoft\Edge\User Data'
        '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data'
        '%LOCALAPPDATA%\Chromium\User Data'
        '%USERPROFILE%\.m2'
        '%USERPROFILE%\.gradle'
    )

    # 即使临时目录中出现这些文件，也不直接删除虚拟磁盘、注册表配置单元或系统文件。
    ForbiddenFilePatterns = @(
        '*.vhd', '*.vhdx', '*.avhd', '*.avhdx', '*.vmdk', '*.vdi'
        'NTUSER.DAT*', 'UsrClass.dat*', 'pagefile.sys', 'swapfile.sys', 'hiberfil.sys'
        'Bookmarks*', 'Login Data*', 'Cookies*', 'Web Data*', 'History*'
        'key3.db', 'key4.db', 'logins.json', 'places.sqlite*', 'cookies.sqlite*'
    )

    # 同步根还会从原用户的 OneDrive 账户/环境、Dropbox 配置中读取。
    SyncDirectoryNames = @('OneDrive', 'OneDrive - *', 'Dropbox', 'Google Drive', 'GoogleDrive', 'iCloudDrive', 'Box Sync')
}

@{
    SchemaVersion = 1
    # 这里只声明体检的显示信息；清理路径、筛选和排除规则来自 targets.psd1。
    Items = @(
        @{ Id = 'cache:UserTemp'; Group = 'safe'; Title = '系统临时文件'; Category = 'UserTemp'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'cache:WindowsTemp'; Group = 'safe'; Title = '系统临时文件'; Category = 'WindowsTemp'; NeedsAdmin = $true; Loss = '' }
        @{ Id = 'cache:ThumbnailCache'; Group = 'safe'; Title = '常见软件缓存'; Category = 'ThumbnailCache'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'cache:BrowserCache'; Group = 'safe'; Title = '浏览器缓存'; Category = 'BrowserCache'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'cache:InetCache'; Group = 'safe'; Title = '浏览器缓存'; Category = 'InetCache'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'cache:AppCache'; Group = 'safe'; Title = '常见软件缓存'; Category = 'AppCache'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'cache:ShaderCache'; Group = 'safe'; Title = '常见软件缓存'; Category = 'ShaderCache'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'system:UpdateCache'; Group = 'safe'; Title = '更新缓存'; Category = 'WindowsUpdate'; NeedsAdmin = $true; Loss = '' }
        @{ Id = 'system:DeliveryOptimization'; Group = 'safe'; Title = '更新缓存'; Category = 'DeliveryOptimization'; NeedsAdmin = $true; Loss = '' }
        @{ Id = 'system:CrashDumps'; Group = 'safe'; Title = '常见软件缓存'; Category = 'CrashDumpReports'; NeedsAdmin = $true; Loss = '' }
        @{ Id = 'system:RecycleBin'; Group = 'confirm'; Title = '回收站'; Category = 'RecycleBin'; NeedsAdmin = $false; Loss = '清空后，里面已删除的文件将无法再从回收站恢复。' }
        @{ Id = 'system:Hibernate'; Group = 'confirm'; Title = '系统大文件'; Name = '休眠文件'; Path = '%SystemDrive%\hiberfil.sys'; NeedsAdmin = $true; Loss = '关闭后将不能使用休眠和快速启动；以后可以重新开启。' }
        @{ Id = 'system:WindowsOld'; Group = 'confirm'; Title = '系统大文件'; Name = '旧版系统文件'; Category = 'WindowsOld'; NeedsAdmin = $true; Loss = '删除后，将无法回退到之前的 Windows 版本。' }
        @{ Id = 'move:KnownFolder:Desktop'; Group = 'move'; Title = '用户文件夹'; Name = '桌面文件夹'; KnownFolder = 'Desktop'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'move:KnownFolder:Documents'; Group = 'move'; Title = '用户文件夹'; Name = '文档文件夹'; KnownFolder = 'Documents'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'move:KnownFolder:Downloads'; Group = 'move'; Title = '用户文件夹'; Name = '下载文件夹'; KnownFolder = 'Downloads'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'move:KnownFolder:Pictures'; Group = 'move'; Title = '用户文件夹'; Name = '图片文件夹'; KnownFolder = 'Pictures'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'move:KnownFolder:Videos'; Group = 'move'; Title = '用户文件夹'; Name = '视频文件夹'; KnownFolder = 'Videos'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'move:WeChat'; Group = 'move'; Title = '聊天软件文件'; Name = '微信聊天文件'; Chat = 'WeChat'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'move:QQ'; Group = 'move'; Title = '聊天软件文件'; Name = 'QQ 聊天文件'; Chat = 'QQ'; NeedsAdmin = $false; Loss = '' }
        @{ Id = 'info:LargeApps'; Group = 'info'; Title = '大软件和游戏'; NeedsAdmin = $false; Loss = '' }
    )
    Chats = @{
        WeChat = @{
            FolderNames = @('WeChat Files', 'xwechat_files')
            Configs = @(
                @{ Path = '%APPDATA%\Tencent\WeChat\All Users\config\3ebffe94.ini'; Format = 'Text' }
                @{ Path = '%APPDATA%\Tencent\xwechat\config.json'; Format = 'Json' }
            )
            Registry = @(@{ Key = 'Software\Tencent\WeChat'; Name = 'FileSavePath' })
        }
        QQ = @{
            FolderNames = @('Tencent Files', 'QQNT', 'qq_nt')
            Configs = @(
                @{ Path = '%APPDATA%\Tencent\QQ\nt_data\global\nt_qq\nt_qq_config.json'; Format = 'Json' }
                @{ Path = '%APPDATA%\Tencent\QQ\nt_data\global\nt_qq\config.json'; Format = 'Json' }
            )
            Registry = @(@{ Key = 'Software\Tencent\QQNT'; Name = 'DataPath' })
        }
    }
    ConfigPathKeys = @('fileSavePath', 'file_save_path', 'savePath', 'dataPath', 'data_dir', 'userDataPath', 'filePath')
    UninstallKeys = @(
        @{ Hive = 'Machine'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
        @{ Hive = 'Machine'; Key = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
        @{ Hive = 'User'; Key = 'Software\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
}

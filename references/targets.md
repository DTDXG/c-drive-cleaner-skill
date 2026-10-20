# 清理目标、风险与禁止区

面向 Windows 10 / 11 的磁盘规划参考。LTSC、企业策略、应用版本与布局差异须实机核实；尚未在真实 Windows 验证。顾问给出明确建议并解释使用影响，尽量覆盖大块占用，始终优先官方工具与数据安全。主流程和三段答复模板见 [SKILL.md](../SKILL.md)。

## 分类与授权：只有 A / B 或保留

`SchemaVersion=3` 的 `Disposition` 与默认状态决定展示位置；以报告的真实结果为准，不按路径名字猜类别：

| 报告分类 | 项目 | 对用户的表达与授权 |
| --- | --- | --- |
| `ai`，`DefaultSelected=true` | UserTemp、WindowsTemp、ThumbnailCache、BrowserCache、AppCache、ShaderCache、InetCache、SystemLogs、DevCache、ComponentStore、UpdateCache、DeliveryOptimization | A「只需确认（AI 执行）」；推荐编号，一次确认整个清单。默认推荐不是自动许可。 |
| `ai`，`DefaultSelected=false`、`Irreversible=true` | RecycleBin、CrashDumps、WindowsOld、Hibernate（仅 Reduced）、已核实关联的 ShadowStorage | 同一 A 表最后，默认不选；逐项解释后果，用户必须明确点名各编号，可与其他编号在一次回复中确认。 |
| `manual` | 个人数据 / 开发缓存 / 聊天 / 游戏 / VM / WSL / Docker 迁移，同步客户端释放空间，大文件、旧安装包、已安装软件，PageFile、ReservedStorage、VSS 关联不明或其他无覆盖整项选择器的项目 | B「需要你一步步操作」，使用 M 编号，写明原因与具体界面 / 命令、验证、停止条件；不进入 apply-plan。 |
| `keep` | 系统 / 用户目录汇总、所有用户回收站汇总、保护区、未知且无授权的内容、路径安全检查失败、缺失目标、根重解析点等 | 只报告或保留；不能为了覆盖更多占用而临时放宽白名单。同步项有明确客户端步骤时可归 B。 |

每个 Entries 条目含 `Disposition`、`Impact`、`ManualReason`、`ManualSteps`。Impact 的 `Summary`、`DataLoss`、`Reversible`、`RequiresClosedApps`、`RequiresAdmin`、`RequiresRestart`、`RiskLevel`、`SideEffects` 用于解释使用影响；“可再生”只表示可能生成同类缓存，绝不保证原文件、版本或历史日志可恢复，删除不可撤销，日志不是备份。

A 直接采用 `ConfirmationItems.Id`，相同处理器和参数归组，含完整 `Paths`、`EntryKeys`。编号不能重编或改作单个路径授权；一个 BrowserCache / DevCache 选择器可能覆盖多个应用 / 工具，要展示全范围。用户回复“确认 1-6,9”后，AI 自行运行 `apply-plan.ps1 -ReportPath ... -Items ... [-AcknowledgeIrreversible ...] -WhatIf`，展示短差异，再给一条同账户管理员终端命令（已提权且确认则直接执行）。不可逆确认在计划入口是编号数组，在 clean-system 底层是开关；没有额外逐项确认轮次。仅范围变化、新增项目或报告过旧需重扫时重新确认。迁移和旧源删除仍走独立 B 流程。

## 路径、身份与计量规则

- 路径只是定位线索，不能扩大 [targets.psd1](../scripts/targets.psd1) 白名单；脚本参数以实际 `param` 和帮助为准。删除前重新检查目标及每级父目录，不跟随联接、符号链接，不接管所有权、不杀进程、不绕过 UAC。
- `%USERPROFILE%`、`%LOCALAPPDATA%`、`%APPDATA%` 都指被诊断的原用户，使用共享上下文解析值，提权后不得换成另一管理员目录。文档 / 下载等使用 Known Folder 实际位置，不能假定仍在 C:。
- 正常流程在原用户普通会话扫描，同账户提权执行计划。apply-plan 要求同机、同原 SID / 目录、当前 SID 与原 SID 一致及身份已核实；它没有身份覆盖入口参数。报告默认自扫描开始最多 24 小时，过期就重扫核对清单，不放宽年龄绕过。
- 底层仅 clean-system 提供成对的 `-OriginalUserSid` / `-OriginalUserProfile`；跨账户须显式传入、匹配 ProfileList，且共享库用 CIM 核实 Explorer 所有者 SID 为原 SID、SessionId 与当前进程相同且大于 0；失败就不验证通过。环境变量 `CLEANER_ORIGINAL_USER_SID` / `CLEANER_ORIGINAL_USER_PROFILE` 只能成对传递同账户身份，不能单独证明跨账户来源或与一个显式参数拼身份。开发工具清理、迁移与回收站仍要求当前 SID 等于原 SID。
- UserTemp 仅授权原用户已解析的 LocalAppData\Temp；ProfileList 边界拒绝 TEMP / LocalAppData 重定向到其他账户或非原用户的 Users 子目录。其他自定义 TEMP 即使在 C: 也只报告、跳过，不因确认而扩白名单。
- 缓存文件默认保留最近 24 小时修改的文件，`clean-cache.ps1 -MinAgeHours` 范围 0–876000；不擅自降低。SystemLogs 至少保留 168 小时，官方开发缓存命令不按年龄筛选。占用、只读、拒绝访问等按脚本跳过。
- `null`、拒绝访问、Quick 跳过不是零。`Status=partial` 的 `KnownLogicalBytes` / `KnownAllocatedBytes` 仅为下限，完整 `LogicalBytes` / `AllocatedBytes` / `EstimatedReclaimableBytes` 仍未知；`KnownSizeKind=lower-bound`。组内去父子重复，组间仍可能重叠；`KnownLowerBoundBytes` 不能冒充保证收益，所有 A / B 项不可相加。
- 普通权限系统查询可为未知；WinSxS 依 DISM 数据，不递归累加硬链接。同步云占位不计本地收益，不读取内容触发下载。清理结果以 `FreeBytesBefore` / `FreeBytesAfter` 为准，后台活动可能使差值为负；系统工具结束、界面完成和重启后仍需验证。

## 缓存类别：具体路径、损失与门控

统一由 `clean-cache.ps1 -Category` 处理；所有类别须显式选择，省略会处理全部。清目录内容保留白名单根；SelectedFiles 仅授权指定直接文件，不自动授权整目录。下表“关闭”是执行前要求；只有注明的进程名有脚本门控，不能把建议退出当作已实现的检测。

| 类别 | 精确范围 / 路径线索 | 会失去什么、使用影响 | 进程 / 状态门控；管理员 |
| --- | --- | --- | --- |
| UserTemp | `%LOCALAPPDATA%\Temp`；自定义 TEMP 不自动授权 | 闲置临时文件；近期 / 占用文件跳过，不保证所有内容都是垃圾 | 先关闭使用者，无专门进程名门控；普通权限 |
| WindowsTemp | `%SystemRoot%\Temp` 内容 | 系统临时文件，需要时会重新生成 | 安装 / 更新进程、待完成 / 待重启或查询失败时整类跳过；计划要求管理员 |
| ThumbnailCache | `%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db`，不递归 | 文件预览重新生成，首次打开文件夹较慢 | 建议退出相关资源管理器窗口；无强杀或专门退出门控，占用即跳过；普通权限 |
| BrowserCache | 见下表，仅 HTTP / 编译 / GPU 缓存 | 页面需重新下载，首次访问较慢且用流量；保留书签、密码、Cookie、会话、Local Storage、IndexedDB 和完整用户配置 | 按浏览器进程门控，运行或进程查询失败就跳过该浏览器；普通权限 |
| AppCache | 见下表，仅指定应用缓存 / 日志 | 缓存需重新生成或下载，首次启动较慢；旧日志排障历史丢失，不动项目、设置、扩展安装目录或聊天数据库 | 对应进程运行或查询失败，保留该应用全部余下目标；确认后再检查；普通权限 |
| ShaderCache | `%LOCALAPPDATA%\` 下 `D3DSCache`、`NVIDIA\DXCache` / `NVIDIA\GLCache`、`AMD\DxCache` / `AMD\DxcCache` / `AMD\GLCache` / `AMD\VkCache`、`Intel\ShaderCache` | Direct3D / 显卡着色器缓存；游戏与图形应用重新编译，首次启动可能卡顿，不卸载驱动 | 用户先退出游戏和图形应用；白名单无专门进程名检测，占用跳过；普通权限 |
| InetCache | `%LOCALAPPDATA%\Microsoft\Windows\INetCache` 内容，明确排除 `Content.Outlook` 及全部后代 | Internet 临时资源 / 离线页面可能需重新下载；Outlook 打开的附件副本可能有未保存修改，始终保留 | 先退出浏览器及使用 Internet 缓存的应用；无专门进程名门控，占用跳过；普通权限 |
| SystemLogs | `%SystemRoot%\Logs\CBS` 的直接 `CbsPersist_*.log` / `CbsPersist_*.cab`；`%SystemRoot%\Logs\WindowsUpdate` 的直接 `*.etl` | 永久失去这些旧日志的历史排障信息，新日志继续产生；不删 `CBS.log`、其他文件或嵌套日志 | 至少 168 小时未修改；无更新活动专项门控，占用仍跳过；必须管理员，处理器与共享删除层都检查 |
| DevCache | 见开发工具表，实际路径以官方查询和白名单双重核实 | 可下载缓存 / 包；下次恢复依赖可能需联网，离线构建或旧包不可取回时受影响 | 先停 IDE、构建和包管理任务；无统一进程门控；同原用户身份，普通权限或同账户提权 |

ShaderCache 中所有厂商路径直接位于 `%LOCALAPPDATA%` 下，并非位于 D3DSCache 内。所有缓存均不保证立即释放扫描上限；系统日志虽在报告中默认推荐，旧排障证据并不可再生，需要排障时建议取消该项。

### BrowserCache：白名单全部浏览器

`*` 只匹配一个目录段，发现时不进入重解析点；不是任意用户配置通配删除。

| 浏览器 | 原用户目录及清理子项 | 门控进程名（不带 .exe） |
| --- | --- | --- |
| Chrome | `%LOCALAPPDATA%\Google\Chrome\User Data\*\` 下 Cache、Network\Cache、Code Cache、GPUCache | chrome |
| Edge | `%LOCALAPPDATA%\Microsoft\Edge\User Data\*\` 下同上四类 | msedge |
| Brave | `%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\` 下 Cache、Code Cache | brave |
| Chromium | `%LOCALAPPDATA%\Chromium\User Data\*\` 下 Cache、Code Cache | chrome |
| Firefox | `%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2` | firefox |
| Opera Stable | `%LOCALAPPDATA%\Opera Software\Opera Stable\` 下 Cache、Code Cache | opera |

不支持的渠道、版本或自定义位置只报告；不能把 Chrome / Edge 的全部子项自动推广给其他浏览器，也不因此授权其他浏览器或整个 User Data。

### AppCache：应用缓存白名单

| 应用 | 清理位置 | 门控进程 |
| --- | --- | --- |
| VS Code | `%APPDATA%\Code\` 下 Cache、CachedData、Code Cache、GPUCache、CachedExtensionVSIXs、logs | Code |
| Teams 经典版 | `%APPDATA%\Microsoft\Teams\` 下 Cache、Code Cache、GPUCache、tmp | Teams |
| Discord | `%APPDATA%\discord\` 下 Cache、Code Cache、GPUCache | Discord |
| Slack | `%APPDATA%\Slack\` 下 Cache、Code Cache、GPUCache | slack |
| JetBrains IDE | `%LOCALAPPDATA%\JetBrains\*\caches`、`log`，单段版本目录 | idea64、pycharm64、webstorm64、goland64、clion64、rider64、datagrip64、phpstorm64、rubymine64、rustrover64 |

CachedExtensionVSIXs 是下载的扩展安装包缓存，离线重装可能需重新取得；JetBrains 索引重建可能较慢。新版 Teams、微信、QQ 等不在自动应用缓存白名单，走 B 类应用内存储管理，不凭相似目录名删除。

### DevCache：只用官方工具

下列路径列出白名单线索，查询到自定义、非 C:、同步、重解析点或其他未授权目录就跳过整个工具。任何一个目录失败都不能改成只清通过的部分。

| 工具 | 路径 / 查询 | 实际清理范围与影响 |
| --- | --- | --- |
| npm | `%USERPROFILE%\.npm` / `.npm-cache`，`%LOCALAPPDATA%\npm-cache`、`%APPDATA%\npm-cache`；`npm config get cache` 须返回唯一目录 | `npm --cache <已验证目录> cache clean --force`；仅固定缓存，不改全局包 prefix；force 不扩大本 skill 授权 |
| pip | `%LOCALAPPDATA%\pip\Cache`、`%USERPROFILE%\.cache\pip`；`pip cache dir` 唯一目录 | `pip --cache-dir <已验证目录> cache purge`；下载 / wheel 缓存，不动 site-packages / 虚拟环境；入口不遍历所有解释器 |
| conda | `%USERPROFILE%\.conda\pkgs`、`miniconda3\pkgs`、`anaconda3\pkgs`；LocalAppData 下 `conda\conda\pkgs`、`miniconda3\pkgs`、`anaconda3\pkgs`、`Programs\miniconda3\pkgs`、`Programs\anaconda3\pkgs`；`conda info --json` 完整 pkgs_dirs 数组 | `conda clean --tarballs --packages -y`；不清环境、不使用 force-pkgs-dirs；依赖包缓存符号链接或严格离线环境建议保留 |
| dotnet NuGet | `%LOCALAPPDATA%\NuGet\Cache` / `v3-cache` / `plugins-cache`、`%USERPROFILE%\.nuget\packages`、`%LOCALAPPDATA%\Temp\NuGetScratch`；`dotnet nuget locals all --list --force-english-output` 须完整解析四类 locals，并核对 NUGET_PACKAGES / NUGET_HTTP_CACHE_PATH / NUGET_PLUGINS_CACHE_PATH / NUGET_SCRATCH | `dotnet nuget locals all --clear`；含全局包，下一次 restore 需包源可用，不删配置、凭据或项目 |
| yarn | `%LOCALAPPDATA%\Yarn\Cache`、`Yarn\Berry\cache`；`yarn cache dir` 须返回唯一目录 | `yarn cache clean`；按工具版本能力核实，不支持该查询或项目位置不匹配则跳过，不能承诺所有 Berry / 项目缓存已处理 |
| pnpm | `%LOCALAPPDATA%\pnpm\store`、`pnpm-store` 及允许内容；`pnpm store path` 唯一目录 | `pnpm store prune`；只由工具移除未引用内容，不保证清空整个 store，后续安装可能重下载 |
| go | `%LOCALAPPDATA%\go-build`、`%USERPROFILE%\go\pkg\mod`；分别 `go env GOCACHE`、`go env GOMODCACHE` | 依次 `go clean -cache`、`go clean -modcache`；构建缓存和模块缓存均可能处理，第二条失败仍保留第一条完成结果 |
| Maven / Gradle | `.m2\repository`、`.gradle` 等仅诊断 / 迁移；共享 DevCache 有 Gradle 子项规则也不等于此入口有清理命令 | 无对应官方清理分支；仓库可能含唯一 install 工件、凭据和初始化配置，不整体清空，优先 B 类迁移 |

实际执行先解析、校验所有路径，持有每条路径祖先的防替换句柄，取得后、运行前及结束后复查；祖先缺失或句柄失败跳过整个工具，finally 释放。npm / pip 命令显式固定已验证目录；conda、dotnet、yarn、pnpm、go 在确认后重查配置，变化即停止。为允许工具删除缓存根，不锁根本身，根及子项仍有并发替换风险，不是原子快照。

官方清理命令不支持统一年龄筛选，可能清理近期内容；释放量按系统卷空闲变化估算，受其他进程影响。DevCache 演练不启动任何工具查询 / 清理、不写审计，工具可用性和实际目录均待解析；未安装工具安静跳过。清理支持 yarn / pnpm / go 不表示 migrate 的 Cache 枚举有这些值。

## 系统 A 项：官方接口与不可逆后果

下表是 `clean-system.ps1 -Action` 的处理范围。除只报告 PageFile 外，所有底层动作都需要管理员；计划中不可逆项必须最后、默认不选、明确点名编号。系统工具可能有界面或后台工作，启动工具不等于释放已完成。

| 动作 | 范围 / 工具 | 使用影响、门控和风险 |
| --- | --- | --- |
| ComponentStore | `%SystemRoot%\WinSxS`；DISM AnalyzeComponentStore，再仅在明确有可回收包且建议清理时 StartComponentCleanup | 中风险；移除被替代组件，无直接撤销；不承诺所有旧更新都可卸载，不手删、不用 ResetBase；分析未明确建议则跳过 |
| UpdateCache | 仅 `%SystemRoot%\SoftwareDistribution\Download` 内容，保留根，不碰 DataStore / 整棵 SoftwareDistribution | 中风险；以后可能重新下载更新。快照 BITS / wuauserv 启动类型和运行状态，Running + Disabled 或过渡状态拒绝；授权事务内 COM / BITS 核实空闲，临时禁用启动后停止服务，删除前复查更新 / 待重启，逐项前后检查服务仍停止，finally 还原启动类型与运行状态；查询失败 / 更新活动停止，恢复失败人工检查 |
| DeliveryOptimization | 官方 Delete-DeliveryOptimizationCache；路径可能为 `%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache` 或 NetworkService 下系统缓存 | 低风险；重新下载可能用流量。更新活动 / 待重启 / 状态未知跳过，查询启动的服务恢复原状态；缺接口只给系统设置 / 磁盘清理指引，不手删目录；PowerShell 7 模块可用性须验证 |
| RecycleBin（不可逆） | 仅 C: `$Recycle.Bin\<原用户SID>`，Clear-RecycleBin | 高风险；永久失去回收站恢复机会；原身份核实且当前 SID 等于原 SID，不用所有用户汇总冒充收益；不清其他账户 |
| CrashDumps（不可逆） | `%ProgramData%\Microsoft\Windows\WER`、`%SystemRoot%\Minidump`、`LiveKernelReports` 内容保留根，另处理 `MEMORY.DMP` | 高风险；永久丢失故障现场，需要排障 / 报修时先备份；底层按年龄 0 清理，占用等仍跳过。不含 `%LOCALAPPDATA%\CrashDumps`，共享库有规则也不表示该入口会处理 |
| WindowsOld（不可逆） | `C:\Windows.old`；系统 cleanmgr /AUTOCLEAN 也可能覆盖升级相关残留 | 高风险；失去对应版本回退能力及未备份旧用户数据。先检查备份，解释完整工具范围；缺 cleanmgr 只给设置→系统→存储→临时文件→以前的 Windows 安装指引，不夺权强删；不能保证扫描目录大小都释放 |
| Hibernate（不可逆分组） | `C:\hiberfil.sys`；报告只推荐 `-Mode Reduced` | 中风险；保留快速启动，失去完整休眠 / 混合睡眠，已有休眠状态不可恢复；可恢复配置不等于恢复会话。整个文件大小不是 Reduced 的释放量，实际收益未知；先核实电源状态，变更后验证 |
| ShadowStorage（不可逆） | `-ForVolume` 默认 C:，`-OnVolume` 为实际关联的存储卷，`-MaxSize` 为报告提出的上限 | 高风险；缩小可能立即永久丢失旧快照 / 还原点，调回上限不能恢复。只接受可靠解析的现有关联；不猜同盘，不把配额当收益；存于其他卷时 C: 收益为 0 |

UpdateCache 状态检查与删除不是原子事务，其他管理员重启服务仍可能造成竞争，Windows / NTFS 行为待实测。普通权限下 apply-plan 的管理员项会连演练一起跳过，必须说明未运行其处理器；实际管理员执行还会重新校验状态，不擅自取消门控。

底层 `-Mode Off` 虽存在，会禁用休眠、快速启动、混合睡眠，不属于报告自动推荐计划；如另有需求归 B 单独评估。`powercfg /a` 核实支持状态，恢复可用 `powercfg /h on` 并依原配置恢复 full / reduced，不能找回旧会话。VSS 无唯一可靠关联归 B；省略 MaxSize 时底层只报告，接受的大小为正整数 MB / GB / TB 或 1%–100%，未给 OnVolume 必须唯一匹配。扫描仅在容量 / 分配量可靠且至少 320 MiB 时提出保守上限（不超过相关卷较小容量的 10%，必要时按现有分配量向下取整 MiB）；不为凑收益改配额。

## B 类只读发现与人工步骤

| 项目 | 发现范围与大小依据 | 原因与具体步骤 |
| --- | --- | --- |
| 大文件 | 原用户 C: 目录，默认逻辑大小至少 500 MiB、取前 30；排除 AppData、同步和重解析点；受时间 / 条目 / 深度上限限制 | 可能是唯一副本。资源管理器定位并核对用途 → 需保留就复制至数据卷专用目录并打开 / 摘要校验 → 独立备份可恢复后再人工决定旧副本，无用文件由用户自行删除；不传入 apply-plan |
| 旧安装包 / 归档 | Known Folder 下载 / 桌面，默认至少 30 天；EXE、MSI、MSIX、MSIXBUNDLE、APPX、ISO、IMG、ZIP、7Z、RAR；B 步骤最多列最大 20 个，Inventories 保留发现清单 | 年龄不证明无用。打开详细信息按大小 / 日期核对 → 保留唯一安装介质、授权及重要归档，需留的复制至 D:\Installers 并验证 → 可重下 / 已备份且明确无用的由用户自行删除，不批量清空下载 |
| 已安装软件 | 机器及原用户 32 / 64 位卸载信息；排除部分运行时 / SDK / 驱动，已声明非 C: 位置排除；B 取厂商报告至少 500 MiB 的前 20 项 | EstimatedSize 是厂商估计，不等于实际占用；位置未声明不确认在 C:。设置→应用→已安装的应用（Win10：应用和功能）找到准确软件 → 备份数据 / 许可证后官方卸载或支持的“移动” → 需继续用则安装至允许的数据卷位置并验证；不执行注册表卸载字符串，不手删安装目录 |
| PageFile | 页面文件及提交 / 崩溃转储配置；底层只报告 | 默认保持系统管理。SystemPropertiesAdvanced.exe→性能设置→高级→虚拟内存记录现状 → 管理员按内存峰值和转储需求评估 → 如变更需重启并验证提交上限 / 事件，异常恢复原配置；不删 pagefile.sys / swapfile.sys |
| ReservedStorage | 系统保留存储；底层查询 / 切换限 Win10 2004+ / Win11，依版本 / 策略 | 默认启用，为更新留余量，不保证禁用立即释放。管理员查询 DISM /Online /Get-ReservedStorageState → 存储界面核对系统和保留 → 优先清其他项；底层只有 `-DisableReservedStorage` 才请求禁用，状态不明 / 更新 / 待重启不执行，不列入 A |
| 同步数据 | OneDrive / 其他同步目录；不以云占位逻辑大小算本地收益 | 客户端确认同步无错误、网页抽查可下载 → 客户端“释放空间 / 仅在线” → 抽查可取回，需离线的保持本地；禁止直接删除，退出客户端不阻止未来同步删除 |
| 迁移及未知应用数据 | 个人文件、开发目录、聊天附件、模型、手机备份、VM / WSL / Docker、游戏等 | 官方查询归属及路径 → 数据卷容量、独立备份、正常停写 → 复制校验 → 官方切换并试用 → 保留旧源，备份验证后另行处理；详见 [迁移参考](migration.md) |

Quick 跳过上述新清单和磁盘布局，状态 / 总量未知；无法访问或达到发现上限不能宣称“已找全”。三种新清单只读，无自动删除或卸载授权。无自动选择器的独立升级残留、搜索索引等也归 B 或保留，不能用一个子项选择器处理整个目录。

Docker 容器清理不是现有系统 Action，卷中可能是业务数据；任何额外卷清理必须另行解释和确认，不能自动附加删除卷选项。所有 `.vhdx` 禁止直接删除。

## Advisory：长期磁盘规划规则

C 段依据报告 `Advisory` 的实际证据，给出“建议做什么、为什么、下一步怎么验证”，不虚构诊断。容量阈值在脚本中按二进制 GB 计算；相等时不触发“大于”规则。

| 规则 / Id | 触发证据 | 推荐行动 |
| --- | --- | --- |
| low-space | C: 空闲少于 20 GiB，或少于总容量 10% | 优先确认影响明确的 A 项并复扫，安排 B 类迁移，预留系统更新空间，不靠删保护区救急 |
| no-data-volume | `HasDataVolume=false`，明确无其他固定数据卷 | 优先增加第二物理磁盘；不要长期只依赖一个分区或一块盘。如需分区，先完成独立备份并验证恢复，再由人工在磁盘管理评估压缩 / 新建；skill 不做分区 |
| same-disk-backup | 有数据卷且 `DataVolumesOnSystemDisk=true`，全部数据卷与 C: 同物理磁盘 | D: 可整理日常数据；备份另存第二物理盘、外置盘或云端，定期恢复验证，同盘分区副本不是独立备份 |
| user-folders | C: 已知个人文件夹占用超过 10 GiB | B 类迁至 D:\UserData，设置新内容保存位置并验证新写入；只改默认位置不搬旧文件 |
| development | C: 开发缓存 / WSL / 虚拟磁盘已知占用超过 5 GiB | B 类逐步迁移至数据卷，开发缓存改官方配置、WSL 导出 / 新名导入、Docker 官方位置设置；只改配置不释放旧缓存 |
| software-placement | C: 位置已声明的软件厂商报告合计超过 20 GiB | 今后普通应用优先 D:\Apps；驱动 / 系统工具留官方默认位置，现有程序官方移动或卸载重装，绝不复制移动 Program Files |
| hibernate-reduced | 已知休眠文件超过 8 GiB | 仅不需完整休眠 / 混合睡眠时，明确点名 A 的 Reduced 项；否则建议保留；验证快速启动和电源功能，不推荐默认 Off |
| storage-sense | 原用户存储感知状态明确为关闭 | 设置→系统→存储→存储感知，核对频率和回收站保留天数；下载按需保留、云文件须确认可取回后再设策略，不自动开启有损规则 |

DiskLayout 记录 Disks、Volumes、SystemDiskNumber、HasDataVolume、DataVolumesOnSystemDisk、SystemDiskPartitionCount；分区数含系统辅助分区，不代表有可用数据卷。数据缺失 / Quick 跳过时不触发无证据的磁盘或开关结论。无论本次是否触发规则，长期原则都是系统 / 必须的程序留 C:，个人数据、开发缓存、VM / WSL、游戏放数据卷，独立备份不放同一物理磁盘；宁可少释放，也不牺牲安全。

## 迁移选择器与风险

| `migrate.ps1 -Item` | 适用路径 / 版本 | 风险与再生性 | 可逆性与处理方式 |
| --- | --- | --- | --- |
| `UserFolder` | 仅桌面、文档、下载、图片、视频五类已知文件夹；Win10 / Win11 | 中；个人文件通常不可再生；OneDrive / 企业重定向需先核实 | 必须给 `-Folder`，不接受 `-Source`；复制校验后用“属性 → 位置”切换，询问移动原文件时选“否”以保留副本。 |
| `DevCache` | `-Cache` 仅 npm / pip / gradle / maven / conda；源须匹配迁移白名单 | 中；部分内容可重下，凭据、本地工件、环境配置不可视为缓存 | 复制旧数据须成对给 `-Source` / `-CopyExisting`；仅改配置时不传源。备份配置后切换，不能整棵删除 `.m2` / `.gradle`。 |
| `AppData` | `-App` 仅 WeChat / QQ；当前 Documents Known Folder 下 WeChat Files / Tencent Files / xwechat_files 及允许子项 | 中至高；数据库、聊天记录、登录状态不可再生 | 必须给白名单 `-Source`；只复制校验，应用内人工切换。名称不表示允许整体搬迁 AppData 或其他自定义数据根。 |
| `WSL` | 已安装发行版的注册与虚拟磁盘；Win10 / Win11，`wsl.exe` 功能依系统 / Store WSL 版本核实 | 高；Linux 数据不可再生；注销会删除发行版数据 | export 后新名字 import 到 D 盘；原发行版保留至验证和备份完成。注销不可撤销，只能从备份重建。 |
| `Junction` | 白名单明确许可的具体缓存目录；本地 NTFS 目标 | 高；联接使旧路径的删除可能实际作用于 D 盘 | 最后手段；记录旧源、新目标与联接，回滚只移除联接本身，不递归、不删除目标。常规清理应跳过它。 |

普通迁移的实际复制及后续校验期间，脚本持有源、目标根及祖先的保护句柄，复制后与校验后复查目标路径；异常阻止切换，`finally` 释放句柄。robocopy 仍按路径访问子项，根目录保护未完全消除子项并发替换风险，必须关闭相关程序并限制目录写权限。参数、校验、WSL 编码及回滚细节见 [迁移参考](migration.md)。

## 国内常见软件：定位数据与可清理部分

下面都是**示例线索**，不是通配删除规则。先在软件“存储管理 / 文件管理 / 下载设置”查看当前账户真实位置，再区分历史记录、附件原件、下载、缓存。用户可自定义路径，多账户、绿色版、商店版和大版本升级尤其需要核实。未明确匹配清理白名单的软件，仅提供软件内清理或 `migrate.ps1 -Item AppData` 的受支持迁移指引。

| 软件 | 常见位置与版本差异 | 可清理部分 / 优先处理方式 | 必须保留或先验证的内容 |
| --- | --- | --- | --- |
| 微信 | 旧版常见“文档\WeChat Files\<账户>”；4.x 常见“文档\xwechat_files\<账户>”；设置 / 账户信息也可能在 `%APPDATA%\Tencent` 下。实际路径、加密数据库和附件布局需按版本核实 | 优先内置“存储空间管理”明确标注的缓存；在设置中改文件存储路径，确认是否迁移旧文件 | 聊天数据库、附件原件、接收文件及备份；`FileStorage` 等目录含业务数据，不能整体当缓存。缩略图可再生不代表原图仍可从服务端取回。 |
| QQ / NTQQ | 旧版常见“文档\Tencent Files\<QQ号>”；NTQQ 常见 `%APPDATA%\Tencent\QQ` 下用户数据；部分版本仍使用文档路径 | 用软件存储管理清缓存、修改文件保存目录，退出后按官方流程迁移 | 聊天库、图片、视频、接收文件及迁移备份；不按旧版路径套用到 NTQQ，不清整个 Tencent 目录。 |
| 企业微信 | 常见“文档\WXWork\<账户>”及 `%APPDATA%\Tencent\WXWork`；企业策略可改变位置 | 内置缓存 / 存储管理；文件保存路径按客户端支持情况修改 | 聊天记录、工作文件、本地数据库、离线与待上传数据；先满足企业保留要求。 |
| 钉钉 | 常见 `%APPDATA%\DingTalk`、`%LOCALAPPDATA%\DingTalk` 相关子项及自定义下载目录；各版差异大 | 使用客户端清缓存及下载目录设置，明确缓存列表后处理 | 本地消息、离线文档、待发送数据、录制文件；安装目录与用户数据不能混为一谈。 |
| 飞书 | 常见 `%APPDATA%\LarkShell` 等用户目录，下载另设；飞书 / Lark、渠道及版本需核实 | 客户端缓存清理与下载保存路径设置 | 离线文档、消息附件、未同步编辑、录制与下载；不要整体删 `LarkShell`。 |
| 百度 / 阿里 / 夸克网盘 | 安装目录、AppData 子目录及用户配置的下载 / 缓存 / 同步根目录均可能存在；不能假定固定盘符 | 只清客户端明确识别的缓存，退出后确认无下载任务；修改下载 / 缓存路径并检查旧数据 | 完整下载文件、未完成分片和任务状态、同步文件。删除同步目录会传播到云端；使用“仅在线 / 释放本地空间”等功能前核实客户端支持与上传状态。 |
| 迅雷 | 用户设置的下载目录、任务数据库、未完成下载分片；版本、极速版与产品形态有差异 | 软件内清任务缓存或明确放弃的下载；更改下载路径 | `.td` / `.td.cfg` 等可能是未完成任务及其恢复信息，不可一律视为垃圾；删除任务与删除已下载文件是不同动作。 |
| 搜狗 / 百度等输入法 | 常见 `%APPDATA%\SogouPY`、`SogouPY.users`、`%LOCALAPPDATA%\SogouPY`；百度可能使用 `Baidu\BaiduPinyin` 等，名称需实机确认 | 使用输入法内置缓存 / 安装包清理，确认云同步状态 | 自定义词库、用户词频、短语、皮肤与配置；不整体清用户目录。自动更新包也必须先确认已非当前安装所需。 |
| Steam | 软件设置列出的各游戏库，`steamapps` 下游戏、`workshop`、`shadercache`，`userdata` 中账户数据 | 设置“存储”添加 D 盘库并移动；下载缓存用客户端清理，可能需重新登录 | `userdata`、本地存档、模组、截图、创意工坊订阅内容。游戏能重下不代表存档可重建；不要把整个 `steamapps` 当缓存。 |
| WeGame / Epic / Xbox | 客户端管理的库目录；Xbox 可能为 `WindowsApps` 或 `XboxGames` 等，依安装与版本变化 | 用客户端 / Windows 提供的“移动”，不支持时备份存档后卸载重装到 D 盘 | 游戏存档常在文档、Saved Games、AppData 或云端；不得直接挪 WindowsApps、改所有权或删除安装文件夹。 |

其他大户：Apple 设备备份可能在 `%APPDATA%\Apple Computer\MobileSync\Backup` 或 `%USERPROFILE%\Apple\MobileSync\Backup`（产品与渠道需核实），只用设备管理软件识别旧备份；爱思备份位置在应用内查询。Android SDK / AVD 用 Android Studio / SDK Manager 管理，移路径后验证环境变量；Hugging Face、Ollama 模型先核实缓存与模型根配置，区分下载缓存、模型实体、硬链接及个人微调结果。这些都没有隐含的通用删除授权。

## 禁止区与原因

| 禁止的直接操作 | 原因 / 可接受的替代方式 |
| --- | --- |
| 手动删除 `%SystemRoot%\WinSxS`、`System32`、`Installer`、`System32\DriverStore`、`servicing` | 系统组件、更新、驱动与 MSI 修复 / 卸载依赖这些数据；通过 DISM、系统存储工具或正规的卸载流程管理。 |
| 手动删除 `Recovery`、`System Volume Information` | 可能破坏恢复环境、卷元数据、VSS 与还原点；只通过系统保护、VSS 等官方工具管理已确认项目。 |
| 手动删除 `WindowsApps`、`%ProgramData%\Package Cache` | 包部署及安装 / 修复依赖；使用应用设置、安装器或卸载器。不夺取权限。 |
| 直接删除 `Program Files` / `Program Files (x86)` 下的软件目录 | 会留下服务、组件注册、共享依赖；走卸载或厂商支持的移动方式。 |
| 整体搬迁 / 删除 `AppData`、`ProgramData`，批量修改所有用户配置 | 含系统与应用状态、数据库、凭据及权限关系；只接受已识别应用子项及官方设置。`-Item AppData` 不是例外。 |
| 注册表清理 | 缺少可靠、通用的“垃圾键”判定，收益小且可能破坏系统和软件；不提供该功能。 |
| 浏览器书签、密码、Cookie、`Login Data`、`Cookies`、`Bookmarks`、`Local Storage`、`IndexedDB`、会话与完整配置目录 | 这些是用户数据或站点状态，不能当 HTTP 缓存；网站离线存储也不默认清理。 |
| 同步根目录中直接删文件，包括 OneDrive 等 | 删除可能同步至云端及其他设备；已上传且验证可取回后，只用客户端“释放空间 / 仅在线”功能。 |
| 直接删除 `.vhdx`、整棵 `.m2` / `.gradle`、未知数据、重解析点及其目标 | 虚拟磁盘包含整个系统或容器数据；工具目录混有非缓存内容；链接可能越过盘符与边界。只报告或用受支持迁移流程。 |

禁止区是直接文件操作的边界，不妨碍在明确确认后调用系统支持的组件清理、VSS 配额管理或应用卸载。任何无法确认版本、用途、归属、真实路径或恢复能力的项目，一律保留并报告。

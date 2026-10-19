# 清理目标、风险与禁止区

本文用于 Windows 上的诊断、选项解释和执行前核对。按“预计实际释放量、风险、迁移成本”选择项目，不要求按下列层级顺序执行。默认覆盖 Windows 10 / Windows 11 桌面系统；LTSC、受企业策略管理的设备、不同应用版本可能存在差异，须按实际版本核实。旧版 Windows、Windows Server 不视为已验证环境。

## 阅读与执行规则

- 下列路径是定位线索，**不是新增白名单的授权**。最终以 `scripts/targets.psd1`、共享库校验以及当前脚本实际支持项为准；不匹配就只报告。
- `%USERPROFILE%`、`%LOCALAPPDATA%`、`%APPDATA%` 指被诊断的原用户，LocalAppData / AppData 使用共享上下文解析值，管理员提权后不得改成管理员账户。`%SystemRoot%` 通常是 `C:\Windows`；文档、桌面等应解析 Windows 已知文件夹位置，不能假定它们仍在 C 盘。`UserTemp` 只授权原用户已解析的 `LocalAppData\Temp`；上下文解析和 UserTemp 授权均按机器 ProfileList 检查账户边界，拒绝 TEMP / LocalAppData 重定向到其他账户目录或非原用户的 Users 子目录。其他非标准 TEMP 位置（即使仍在 C 盘）仍需人工确认，脚本不自动授权该路径。
- 同账户（含同账户提权）以当前令牌 SID 核对原身份；提供的 SID / 目录须成对且与 ProfileList 匹配，用户路径也须安全。跨账户必须显式成对传参，并由共享库核实 ProfileList，且 `explorer.exe` 的所有者 SID 须为原 SID、SessionId 与当前进程相同且大于 0；查询失败或无匹配会话则不验证通过。入口中仅 `clean-system.ps1` 提供 `-OriginalUserSid` / `-OriginalUserProfile`，其他入口在原用户会话运行；成对的 `CLEANER_ORIGINAL_USER_SID` / `CLEANER_ORIGINAL_USER_PROFILE` 环境变量不能单独作为跨账户可信来源。开发工具清理、迁移及回收站还要求原 SID 等于当前 SID。
- “可再生”表示系统或应用可能重新生成同类内容；“可逆”表示能恢复原状态。缓存能再下载，不等于离线可用、原版本仍可下载或删除操作可撤销。日志不是备份。
- 先关闭相关应用；按文件清理的缓存默认跳过近 24 小时内修改、占用、拒绝访问、长路径不受支持的文件。开发工具官方清理命令不保证按文件年龄筛选，可能清掉近期缓存，需另行说明。不得夺取所有权，不得跟随重解析点。操作前重新校验路径及各级父目录。
- 第 1 层可按清单批量确认；第 2 层逐项确认；第 3 层每项单独解释后果、单独确认。所有执行项先用 `-WhatIf` 演练，系统操作通常需要管理员。
- 本文只固定公开选择器：`clean-cache.ps1 -Category`、`clean-system.ps1 -Action`、`migrate.ps1 -Item`。具体目的路径、阶段、配额等附加参数，以当前脚本 `Get-Help ... -Full` 为准，不从本文推导未实现的参数。脚本若仅给出人工步骤，应完成相应人工步骤，不能当成已经执行。

## 第 0 层：只读诊断

入口为 `scripts/scan.ps1`。记录 C 盘总量、可用空间及扫描时间；同时区分逻辑大小、实际磁盘占用、预计可释放量。不能获取实际占用时标为未知或估算，不得把逻辑大小直接当成预计释放量。

| 对象与路径 | 适用版本 | 诊断方法与限制 |
| --- | --- | --- |
| 用户目录、`AppData\Local`、`AppData\Roaming`、`Program Files`、`Program Files (x86)`、`ProgramData` | Win10 / Win11 | 只读识别大目录；其他用户的访问失败记“未知”，不能记为 0；不以管理员身份自动授权清理其他账户。 |
| `%SystemRoot%\WinSxS` | Win10 / Win11 | 硬链接会重复计数；使用 `DISM /Online /Cleanup-Image /AnalyzeComponentStore` 的分析结果评估回收价值。不要把资源管理器统计值作为可释放量。分析结果不一定给出精确可回收字节数。 |
| `C:\hiberfil.sys`、`C:\pagefile.sys`、`C:\swapfile.sys` | Win10 / Win11 | 记录实际存在文件与配置；不直接删除。禁用功能的释放量以操作后卷可用空间为准。 |
| `%SystemRoot%\SoftwareDistribution`、`C:\Windows.old`、`C:\$WINDOWS.~BT`、`C:\$WINDOWS.~WS` | Win10 / Win11；升级残留依版本而异 | 识别更新、回退及安装文件；Download 仅按 UpdateCache 服务事务清内容，其他旧安装项走系统支持的清理入口，不能见到这些名字就删除。 |
| VSS / 系统保护、`System Volume Information` | Win10 / Win11，取决于卷与功能启用情况 | 用 `vssadmin list shadowstorage` 记录源卷、存储卷、已用量及上限；目录扫描结果不能代替 VSS 报告。 |
| 搜索索引，如 `%ProgramData%\Microsoft\Search\Data` | Win10 / Win11，索引文件名与布局依版本变化 | 报告大小；通过“索引选项”缩小索引范围或受支持的重建流程处理，重建期间搜索会受影响。没有专用清理选择器，不直接删除数据库。 |
| OneDrive 等云占位、联接、符号链接 | Win10 / Win11，取决于客户端与文件系统 | 云端逻辑大小不等于本地占用；离线/固定保留状态单独记录。重解析点单列，不递归跟随；不能靠遍历读取触发大批云文件下载。 |
| WSL / Docker `.vhdx`、手机备份、Android SDK / 模拟器、AI 模型 | 依所装软件与版本 | 报告真实位置及实际占用。虚拟磁盘内部空闲不等于宿主已释放空间；模型与备份可能是唯一副本，不归类为通用缓存。 |

扫描得到的“未知数据”只能提出检查或迁移建议。目录计量不完整时 `Status=partial`，JSON 的 `KnownLogicalBytes` / `KnownAllocatedBytes` 保留已知小计，`KnownSizeKind=lower-bound`；总量 `LogicalBytes` / `AllocatedBytes` 及 `EstimatedReclaimableBytes` 仍为 `null`，控制台显示 `unknown (partial >= …)`。报告按预计可释放量排序，未知在后，下限不当作收益；父子重叠项不能相加。实际释放量最终比较操作前后 C 盘可用空间，并注明后台下载、更新等并发活动可能造成偏差。

JSON `SchemaVersion=2` 中，`HandlerScript` 为脚本，`HandlerParameters` 为参数对象，`ExecutionCommand` 为清理选择器，控制台也显示后者。例如 Chrome / Edge 的 `Network\Cache` 对应 `clean-cache.ps1 -Category BrowserCache`，`LiveKernelReports` 对应 `clean-system.ps1 -Action CrashDumps -AcknowledgeIrreversible`。选择器可能同时处理同类其他路径，须先演练并确认完整范围；扫描不构成删除授权，执行器仍检查身份、权限、白名单、进程和更新状态。

没有覆盖整项的清理执行器时，候选项动作改为 `manual`；迁移项保留 `migrate` 指引，应保留项保持 `keep`，不生成可直接执行的命令。无选择器时 `HandlerScript` 为空、`HandlerParameters` 为 `{}`、`ExecutionCommand` 为 `null`，按 `Notes` 操作。特别是所有用户回收站汇总、SoftwareDistribution 汇总、搜索索引、独立升级残留等，不能把某个子项或单用户动作冒充整项清理。

## 第 1 层：低风险、通常可再生的缓存

入口形式：`scripts/clean-cache.ps1 -Category <类别> -WhatIf`。类别省略时选择全部，须显式指定已确认类别。文件清理可用 `-MinAgeHours` 调整最短未修改时间，默认 24 小时，范围 `0..876000`；它不适用于 `DevCache` 调用的工具官方命令。实际缓存路径须全部通过 C 盘 DevCache 白名单检查，非 C 盘或未知路径会使对应工具整项跳过。清理命令受 `ShouldProcess` 控制；`DevCache -WhatIf` 不启动 npm / pip / conda / dotnet，仅报告计划查询和清理的命令，路径标为“待解析”，不执行查询或清理、不写审计日志；扫描、系统清理和迁移的演练也不启动外部查询工具。

| 类别 | 路径 / 识别范围 | 适用版本 | 风险、可再生性 | 可逆性 | 处理方式 |
| --- | --- | --- | --- | --- | --- |
| `UserTemp` | 仅原用户已解析的 `%LOCALAPPDATA%\Temp` 内容 | Win10 / Win11 | 低；大多可再生，但安装器、未完成导出可能仍需临时文件 | 删除不可撤销，个别内容无法重建 | `clean-cache.ps1 -Category UserTemp`；只清符合年龄要求的内容，保留临时目录根。入口选用解析出的 TEMP；TEMP / LocalAppData 指向其他账户目录或非原用户的 Users 子目录时拒绝。其他非标准 TEMP 位置跳过并报告需人工确认，不自动改清标准目录，也没有放宽白名单的确认开关。 |
| `WindowsTemp` | `%SystemRoot%\Temp` | Win10 / Win11 | 低至中；大多可再生，更新、安装期间风险上升 | 删除不可撤销 | `clean-cache.ps1 -Category WindowsTemp`；受保护内容需要管理员。检测到安装 / 更新进程、待完成或待重启标志，或查询失败时整类跳过；空闲时仍跳过锁定项。 |
| `ThumbnailCache` | `%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db` | Win10 / Win11；文件名依版本核实 | 低；可再生，首次浏览会变慢 | 原缓存不可恢复 | `clean-cache.ps1 -Category ThumbnailCache`；仅识别出的缩略图数据库；占用时跳过或走系统“缩略图”清理入口。图标缓存不是本类别的自动扩大范围。 |
| `BrowserCache` | Chrome：`%LOCALAPPDATA%\Google\Chrome\User Data\<配置>`；Edge：`%LOCALAPPDATA%\Microsoft\Edge\User Data\<配置>`；各自仅 `Cache`、`Code Cache`、`GPUCache`、`Network\Cache` | Win10 / Win11；桌面 Chromium 版 Chrome / Edge，渠道及自定义配置路径另核实 | 低；大多可下载重建，可能失去离线资源，首次打开变慢 | 删除不可撤销；远端资源不保证仍可下载 | `clean-cache.ps1 -Category BrowserCache`；浏览器含后台进程仍运行或无法查询时跳过。使用上下文已解析的 LocalAppData，缺失时停止；不扩大到整个配置目录。白名单中其他浏览器没有此入口的执行分支。 |
| `DevCache` | npm 实际 `cache`；pip 实际缓存目录；conda 全部 `pkgs_dirs`；dotnet NuGet 四类 locals 与环境覆盖；Maven / Gradle 仅诊断或迁移 | Win10 / Win11；依工具版本和配置 | 低至中；下载内容通常可再生，本地安装包、离线依赖不一定可得 | 不保证可逆；需保留本地产物及备份 | `clean-cache.ps1 -Category DevCache`；实际执行时先查询实际路径，每条通过 `Test-SafeTarget -Category DevCache` 后才用官方命令。查询 / 解析失败或任一路径不通过则跳过整个工具，不只清理通过的部分。 |

开发缓存需额外区分：

- npm：入口选用可用的 `npm` 应用，`npm config get cache` 必须返回唯一目录；清理时用 `npm --cache <已验证目录> cache clean --force` 固定范围。`--force` 是 npm 对清缓存的要求，不代表允许扩大本 skill 的范围。
- pip：入口选用可用的 `pip` 应用，`pip cache dir` 必须返回唯一目录，再用 `pip --cache-dir <已验证目录> cache purge` 清下载 / wheel 缓存。人工可用 `python -m pip cache dir` 核实各解释器，但入口不遍历所有 Python。旧版无子命令则跳过，不直接删除安装目录。
- conda：先从 `conda info --json` 解析完整 `pkgs_dirs` 数组；全部校验通过后，用 `conda clean --tarballs --packages -y` 移除 tarball 和工具判断未使用的包。依赖包缓存符号链接的环境可能受影响，先检查链接方式；不使用 `--force-pkgs-dirs`、不清环境目录，严格依赖离线包时跳过。
- NuGet：用 `dotnet nuget locals all --list --force-english-output` 查询，须完整识别 `http-cache`、`global-packages`、`temp`、`plugins-cache`，并校验 `NUGET_PACKAGES`、`NUGET_HTTP_CACHE_PATH`、`NUGET_PLUGINS_CACHE_PATH`、`NUGET_SCRATCH` 的非空覆盖值。全部通过后才用 `dotnet nuget locals all --clear`；含非 C 盘 / 未授权目录时整工具跳过。下次 restore 需要包源可用，不删配置、凭据或项目。
- Maven：`%USERPROFILE%\.m2\repository` 也可能存放仅本地 `install` 的工件；`settings.xml` 可含认证配置。Gradle：`%USERPROFILE%\.gradle` 含 `gradle.properties`、初始化脚本、分发包及缓存。**都不允许整体清空**；不能确认可重下的子项则只报告，优先迁移。

conda / NuGet 无法在清理命令中逐一固定目录，确认后会再次查询并逐项校验，配置改变则停止；所有工具实际执行时逐路径持有祖先防替换句柄，获取后、启动清理前及工具结束后重新校验路径，异常明确报告，`finally` 统一释放句柄。缓存根尚未创建时仍校验路径；任一祖先缺失或句柄获取失败则跳过整个工具。为允许官方工具删除缓存根，不锁根本身，根及子项仍有并发替换窗口，不能视为整个目录树的原子保护；Windows / NTFS 实际行为仍待验证。官方命令不按年龄筛选，释放量只按系统卷空闲变化估算，可能受其他进程影响，不是工具精确释放量。

## 第 2 层：系统工具清理及官方迁移

| 选择器 | 路径 / 对象 | 适用版本 | 风险、可再生性 | 可逆性 | 处理方式 |
| --- | --- | --- | --- | --- | --- |
| `ComponentStore` | `%SystemRoot%\WinSxS` 中已被替代组件 | Win10 / Win11 | 中；旧组件并非一般缓存，不保证再生；影响旧组件保留状态 | 无直接撤销；不能承诺所有旧更新均可卸载 | `clean-system.ps1 -Action ComponentStore`；先 DISM 分析，确有清理价值再 `/StartComponentCleanup`。**禁止自动附加 `/ResetBase`**，禁止手删 WinSxS。 |
| `UpdateCache` | 仅精确的 `%SystemRoot%\SoftwareDistribution\Download` 内容，保留根目录 | Win10 / Win11 | 中；所需下载通常会再生；安装中处理可能破坏更新 | 清理不可撤销；只可重新下载仍受提供的更新 | `clean-system.ps1 -Action UpdateCache`；采用微软文档中的停服务清理方法，不使用系统清理界面。快照 BITS / wuauserv 状态及启动类型，原为 `Running` + `Disabled` 时拒绝执行；事务内检查 COM / BITS 活动，临时将两服务启动类型设为 `Disabled` 后停止，复查更新、待重启及服务停止状态，再由 `Remove-SafeItem -Category WindowsUpdate -MinAgeHours 0` 清理。逐项删除前后检查服务仍为停止状态，重启或查询失败即禁止后续删除；`finally` 还原原启动类型及运行状态。忙碌或查询失败则停止清理，恢复失败须人工检查。不处理 DataStore 或整棵 SoftwareDistribution，也不是更新重置。 |
| `DeliveryOptimization` | 传递优化服务管理的缓存，常见于 `%SystemRoot%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization`；实际布局依版本核实 | Win10 / Win11；功能、模块可用性依版本 | 低至中；可再下载，可能增加流量 | 原缓存不可恢复 | `clean-system.ps1 -Action DeliveryOptimization`；使用系统“传递优化文件”清理或可用的官方模块接口。PowerShell 7 能否加载该 Windows 模块须实机核实；不要据示例路径直接删。 |
| 官方迁移 | 用户已知文件夹、应用存储设置、游戏库、开发工具缓存配置 | Win10 / Win11；依应用版本 | 中；目的是保留数据，并非删除 | 保留源数据与配置备份时通常可回滚 | 见下一表及 [迁移参考](migration.md)。软件原生迁移优先于联接。 |

UpdateCache 的服务状态检查与单项删除并非原子操作，管理员强行重新启用服务仍可能造成竞争；真实 Windows 服务及 NTFS 行为尚待实测。系统设置可能需要人工交互。若脚本仅打开设置或给出命令，释放量记为待验证；不能把启动设置页面记为清理成功。

## 第 3 层：有损或高影响项目

入口形式：`scripts/clean-system.ps1 -Action <动作> -AcknowledgeIrreversible -WhatIf`。第 3 层即使只报告或演练也要求该开关，它不代替用户确认。每次仅选择已单独确认的一项；除只报告的 `PageFile` 外需要管理员，系统接口可达不等于允许自行调整策略。

| 动作 | 路径 / 对象 | 适用版本 | 风险、可再生性 | 可逆性 | 处理方式与后果 |
| --- | --- | --- | --- | --- | --- |
| `RecycleBin` | C 盘 `$Recycle.Bin\<原用户SID>` | Win10 / Win11 | 高；旧文件不可再生 | 清空不可撤销 | `-Action RecycleBin`；原身份须验证通过且当前令牌 SID 等于原 SID，使用 `Clear-RecycleBin` 仅清系统卷。不能跨账户清理，也不能递归清空其他账户的回收站。 |
| `CrashDumps` | `%ProgramData%\Microsoft\Windows\WER`、`%SystemRoot%\Minidump`、`%SystemRoot%\LiveKernelReports`、`%SystemRoot%\MEMORY.DMP` | Win10 / Win11；WER 位置、策略依版本核实 | 高；新故障可产生新报告，旧故障现场不可再生 | 原诊断证据不可恢复 | `-Action CrashDumps`；目录由 `Remove-SafeItem -MinAgeHours 0` 清内容并保留根，另处理 MEMORY.DMP。用户 `%LOCALAPPDATA%\CrashDumps` 虽有共享规则，但不在此入口执行列表内。尚需排障、报修或审计时先备份。 |
| `WindowsOld` | `C:\Windows.old`；`$WINDOWS.~BT` / `$WINDOWS.~WS` 等仅限系统识别的旧安装项目 | Win10 / Win11，升级后才存在 | 高；旧系统及其中遗漏用户数据不可再生 | 删除后失去对应系统回退途径 | `-Action WindowsOld`；先检查旧用户数据，通过系统“以前的 Windows 安装”清理。回退窗口常见为 10 天，但可随版本、配置变化，按实际状态核实。不能手工强删目录。 |
| `Hibernate` | `C:\hiberfil.sys` | Win10 / Win11；设备须支持相应电源状态 | 高影响；文件可重建，当前休眠状态不可恢复 | 设置可恢复，原休眠会话不可恢复 | `-Action Hibernate`；必须显式给 `-Mode Off` 或 `-Mode Reduced`；先测大小，人工用 `powercfg /a` 核实支持状态。Off 影响休眠、快速启动、混合睡眠；Reduced 只保留快速启动所需精简文件，按设备支持情况验证。 |
| `ShadowStorage` | `-ForVolume` 默认 `C:`；实际 VSS 存储卷未必是 C 盘 | Win10 / Win11；受 VSS、系统保护、备份软件配置影响 | 高；历史快照不可再生 | 调大配额无法恢复已删快照 | `-Action ShadowStorage`；查询并用 CIM 核实实际关联。省略 `-MaxSize` 只报告；调整可给 `-ForVolume`、`-OnVolume`、`-MaxSize 10GB`（也接受正整数 MB/GB/TB 或 1%–100%）。未给 OnVolume 时须唯一匹配，不能猜测。**缩小可能立即删除旧快照 / 还原点**。 |
| `ReservedStorage` | Windows 保留存储，无可手删目录 | DISM 查询 / 切换接口：Win10 2004+ / Win11；是否启用依安装方式、版本与策略 | 高影响；可能影响更新临时空间保障 | 支持时可恢复启用；不恢复过去的空间状态 | `-Action ReservedStorage` 默认只查询，额外给 `-DisableReservedStorage` 才请求禁用；状态不明、更新活动或待重启时不禁用。约 7 GB 只是常见量级，非固定收益，默认不建议且不保证立即释放。 |
| `PageFile` | `C:\pagefile.sys` 与其他卷分页文件配置 | Win10 / Win11 | 高影响；文件可再建，缩小降低提交上限，可能导致内存不足 | 配置可改回，需重启；发生的崩溃 / 数据丢失不可逆 | `-Action PageFile`；默认保持系统管理，只在明确容量、内存与转储需求后指导配置。移到 D 盘可能影响崩溃转储；不要给所有机器套固定最小值，不直接删除 `pagefile.sys` / `swapfile.sys`。 |

补充高风险对象：Docker 的 `docker system prune` 会删停止的容器、未使用网络、镜像 / 构建缓存等，具体范围随参数与版本变化；`--volumes` 必须另行确认，不能承诺只删“无用数据”。本表没有对应的系统清理 `-Action`，不把它伪装成已实现选项。WSL / Docker `.vhdx` 一律禁止直接删除，保留数据的操作见迁移文档。

休眠设置可用 `powercfg /h on` 恢复启用，再按原设置选择 full / reduced 类型；这不能找回旧休眠会话。reduced 类型受现有自定义休眠文件大小等条件影响，必要时按实际版本帮助恢复默认大小后再设置；不将某个固定百分比用于所有设备。变更后核实 `powercfg /a`、快速启动与实际睡眠 / 休眠行为。

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

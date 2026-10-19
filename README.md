# c-drive-cleaner-skill

面向 Windows 的 Claude Code skill：查明 C 盘空间被什么占用，解释可清理项目的收益与风险，在用户确认后清理已识别的缓存和系统项目，或将需要保留的数据迁移到 D 盘。可用“C 盘满了，先帮我检查”“清理 C 盘缓存”“把下载文件迁移到 D 盘”等请求触发。

**已在 Linux 做过静态检查及部分模拟逻辑验证，真实 Windows 行为仍须先在虚拟机验证。** 当前不把真实身份 / 会话、DISM、VSS、Windows 服务、OneDrive 占位文件、NTFS 句柄 / 联接及实际释放效果视为已验证。脚本面向 Windows 10 / 11、Windows PowerShell 5.1 / PowerShell 7；PowerShell 5.1 实际运行仍待验证，Linux 不能用于执行清理或迁移。

## 安全原则

- 先扫描、选择项目，再用 `-WhatIf` 演练，列出具体路径、动作、预计释放量和不可逆后果。**任何删除前都必须得到用户明确确认**；第 1 层可按清单批量确认，第 2、3 层逐项确认，高风险项另需确认开关。
- 只处理脚本支持的白名单具体项；未知数据只报告。操作前重新校验路径和各级父目录，不跟随联接、符号链接，不接管所有权；占用、拒绝访问、无法可靠处理的项跳过。
- 不手删 WinSxS、System32、Installer、DriverStore、servicing、Recovery、System Volume Information、WindowsApps、ProgramData\Package Cache；不直接删除软件安装目录，不整体搬迁 AppData / ProgramData，不做注册表清理。
- 不删除浏览器书签、密码、Cookie 等用户数据，不直接删除 `.vhdx`，不使用 DISM `/ResetBase`。OneDrive 等同步文件只通过客户端“释放空间 / 仅在线”处理，避免同步删除云端副本。
- 迁移先备份、停应用、复制、校验、切换并试用；复制不用 `robocopy /MIR`。脚本保留旧源，不自动删除源文件或注销旧 WSL；确认备份可恢复后才能另行讨论释放源空间。
- 日志用于审计，不能恢复已删数据。报告中的上限不等于实际收益，未知值不等于零，重叠目录不可相加。

各项目的路径线索、版本差异与风险见 [targets.md](references/targets.md)；迁移、验证与回滚见 [migration.md](references/migration.md)。参考文档不额外授予删除权限，实际白名单在 `scripts/targets.psd1`。

## 目录结构

```text
c-drive-cleaner/
├── SKILL.md                    Claude 的触发条件、操作流程和安全边界
├── README.md                   项目说明与示例
├── scripts/
│   ├── common.ps1              共享安全校验、计量、日志及外部命令包装
│   ├── targets.psd1            白名单和永久禁止区数据
│   ├── scan.ps1                扫描与 JSON 报告
│   ├── clean-cache.ps1         第 1 层可再生缓存清理
│   ├── clean-system.ps1        第 2、3 层系统项目
│   └── migrate.ps1             数据复制、校验、配置切换与联接回滚
└── references/
    ├── targets.md              清理项、风险和禁止区
    └── migration.md            迁移步骤、验证和回滚
```

## 安装与使用

把完整仓库放入下列目录，保留 `scripts/`、`references/` 与 `SKILL.md` 的相对位置，不要只复制入口文档：

- 使用 `~` 表示用户目录的环境：`~/.claude/skills/c-drive-cleaner`
- Windows：`%USERPROFILE%\.claude\skills\c-drive-cleaner`

在 Windows Claude Code 会话中请求诊断，或使用 `/c-drive-cleaner` 调用。若仓库放在 Linux / WSL 文件系统中，仍须在 Windows 主机执行这些脚本，不能在 Linux 中处理 Windows 系统项目。

以下示例中的 `<skill目录>` 都要替换为实际安装的绝对路径。默认用 Windows 自带的 `powershell`；如已安装 PowerShell 7，可换成 `pwsh`。`-ExecutionPolicy Bypass` 仅用于本次进程，不需要全局修改执行策略。

先在原用户普通终端扫描。系统修改（除只报告的 PageFile）和受保护目录需要管理员；请在 Windows 中手动打开“以管理员身份运行”的终端，不绕过 UAC。提权前通过点引用 `common.ps1`、调用 `Get-CleanerContext` 记录原用户 SID 和目录。同账户（含同账户提权）按当前令牌 SID 核对；若提供身份值，SID / 目录须成对并与 ProfileList 匹配，用户路径也须安全。

跨账户时，`clean-system.ps1` 必须显式成对传入 `-OriginalUserSid` / `-OriginalUserProfile`；共享库要求 ProfileList 匹配，并用 CIM 核实 `explorer.exe` 的所有者 SID 为原 SID、SessionId 与当前进程相同且大于 0，无法核实则不验证通过。`CLEANER_ORIGINAL_USER_SID` / `CLEANER_ORIGINAL_USER_PROFILE` 可成对传递同账户身份，不能单独证明跨账户来源，也不能补齐缺失的显式参数。`scan.ps1`、`clean-cache.ps1`、`migrate.ps1` 没有这两个入口参数，应在原用户会话运行，受保护文件按需同账户提权。开发工具清理、迁移和回收站均要求当前 SID 与原 SID 一致。

## 脚本与示例

下面的清理、迁移示例均为演练。实际执行前先查看输出、核实范围并明确确认，再移除 `-WhatIf`；高风险项逐项执行。迁移实际执行时加 `-Confirm`，在交互终端逐步确认，不选择“全部是”。

### scan.ps1：只读诊断

记录 C 盘总量与可用空间，扫描已知系统项、用户目录及常见应用数据，生成按预计可释放量排序的摘要与完整 JSON 报告。正常扫描会写报告，并可能写查询审计日志，不改系统配置。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\scan.ps1" -Top 30
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\scan.ps1" -Quick -OutputPath "D:\CleanerReports\scan-before.json"
```

`-Top` 默认 25、范围 1–1000；`-Quick` 不递归计量、不做深层分类或 DISM 分析，跳过值标为未知。`-OutputPath` 必须指向尚不存在的新报告；省略时使用共享日志目录的唯一文件名。扫描加 `-WhatIf` 不写报告、不运行外部查询，完整基线请用正常扫描获取。

JSON 报告为 `SchemaVersion=2`。目录计量不完整时，`Status=partial`，`KnownLogicalBytes` / `KnownAllocatedBytes` 保存已知小计，`KnownSizeKind=lower-bound`；总量和 `EstimatedReclaimableBytes` 保持 `null`。控制台显示 `unknown (partial >= …)`，排序只按可释放量，未知在后，不拿已知下限代替收益。

`HandlerScript`、`HandlerParameters`、`ExecutionCommand` 提供清理脚本及选择器，控制台显示“执行选择器”：如 `Network\Cache` 对应 `-Category BrowserCache`，`LiveKernelReports` 对应 `-Action CrashDumps`。同一选择器可能清理同类多个路径，须核实整个作用范围；这些字段不代表已经获准执行。没有整项清理执行器的候选项标记 `manual`，迁移条目保留 `migrate` 指引，应保留项保持 `keep`；无选择器时脚本名为空、参数为空对象、命令为 `null`，按 `Notes` 处理。所有用户回收站汇总不能套用仅清原用户的命令来估算整项收益。

### clean-cache.ps1：第 1 层缓存

`-Category` 可选 `UserTemp`、`WindowsTemp`、`ThumbnailCache`、`BrowserCache`、`DevCache`。省略会选择全部，建议始终指定类别；统一的 `-File` 调用每次传一个类别，多项分次执行。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\clean-cache.ps1" -Category UserTemp -MinAgeHours 48 -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\clean-cache.ps1" -Category BrowserCache -MinAgeHours 24 -WhatIf
```

先关闭相关应用。文件清理默认保留最近 24 小时修改的内容，`-MinAgeHours` 范围为 `0..876000`；被占用的文件跳过。`UserTemp` 只授权原用户已解析的 `LocalAppData\Temp` 内容；上下文解析和 UserTemp 授权均按机器 ProfileList 检查账户边界，拒绝 TEMP / LocalAppData 重定向到其他账户目录或非原用户的 Users 子目录。其他非标准 TEMP 位置报告需要人工确认并跳过，不自动授权自定义目录。`WindowsTemp` 检测到安装 / 更新活动、待重启或待完成标志，或查询失败时整类跳过。

浏览器和缩略图使用共享上下文的 `LocalAppData`，缺失时停止。`BrowserCache` 执行范围为 Chrome / Edge 各 profile 的 `Cache`、`Code Cache`、`GPUCache`、`Network\Cache`；浏览器运行或无法查询进程时跳过。白名单中的其他浏览器不表示此入口已经实现对应清理。

`DevCache` 实际执行时依次查询 `npm config get cache`、`pip cache dir`、`conda info --json` 的 `pkgs_dirs`、`dotnet nuget locals all --list --force-english-output` 的四类 locals；并核对 `NUGET_PACKAGES`、`NUGET_HTTP_CACHE_PATH`、`NUGET_PLUGINS_CACHE_PATH`、`NUGET_SCRATCH`。每条路径须通过 `Test-SafeTarget -Category DevCache`；查询 / 解析失败或任一路径不通过（包括非 C 盘、自定义未知位置、同步目录、重解析点）就跳过整个工具，不清理其中一部分。

npm / pip 清理时显式固定已验证目录；conda / NuGet 在确认后重查路径，配置变化则停止。实际执行时逐路径持有祖先防替换句柄至工具结束及后置校验完成，运行前后复查路径，`finally` 释放句柄；祖先缺失或句柄获取失败则跳过整个工具。为允许官方工具删除缓存根，不锁根本身，根及子项仍有并发替换风险。官方命令不受年龄筛选，可能清掉近期缓存；释放量按系统卷空闲变化估算。`DevCache -WhatIf` 不启动 npm / pip / conda / dotnet，仅报告计划查询和清理的命令，路径标为“待解析”，不执行查询或清理、不写审计日志。Maven / Gradle 没有此入口的清理命令，不整棵删除 `.m2` / `.gradle`。

### clean-system.ps1：逐项系统清理

每次必须选择一个 `-Action`。第 2 层为 `ComponentStore`、`UpdateCache`、`DeliveryOptimization`，第 3 层为 `RecycleBin`、`CrashDumps`、`WindowsOld`、`Hibernate`、`ShadowStorage`、`ReservedStorage`、`PageFile`。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\clean-system.ps1" -Action ComponentStore -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\clean-system.ps1" -Action Hibernate -Mode Reduced -AcknowledgeIrreversible -WhatIf
```

组件存储先分析再按结果清理。第 3 层即使演练或只报告也需要 `-AcknowledgeIrreversible`，该开关不能代替用户实际确认或备份。休眠 `-Mode` 必须显式选 `Off` 或 `Reduced`；Off 会同时禁用休眠、快速启动、混合睡眠，Reduced 不保留完整休眠能力。

`UpdateCache` 采用微软文档中的停服务清理方法，不使用系统清理界面，仅清理 `%SystemRoot%\SoftwareDistribution\Download` 的内容，保留根目录。脚本快照 BITS / wuauserv 状态及启动类型，原为 `Running` + `Disabled` 时拒绝执行；在已确认事务内检查 COM / BITS 更新活动，再临时将两服务启动类型设为 `Disabled` 后停止服务。删除前复查更新、待重启及服务状态，通过 `Remove-SafeItem -MinAgeHours 0` 清理；逐项删除前后检查服务仍为停止状态，重启或查询失败即禁止后续删除，`finally` 还原原启动类型及运行状态。忙碌或状态不明则停止清理，恢复失败需人工检查；不删 DataStore 或整棵 SoftwareDistribution。

`CrashDumps` 清理 `%ProgramData%\Microsoft\Windows\WER`、`%SystemRoot%\Minidump`、`%SystemRoot%\LiveKernelReports` 的内容并保留目录根，另处理 `%SystemRoot%\MEMORY.DMP`，不含用户 `LocalAppData\CrashDumps`；旧诊断现场不可恢复。

VSS 先核对实际关联，再考虑 `-ForVolume`、`-OnVolume` 和 `-MaxSize`；缩小可能立即永久删除旧还原点，不能假定存储卷一定是 C 盘。保留存储默认只查询，加 `-DisableReservedStorage` 才请求禁用，默认不建议且不保证立刻释放空间。`PageFile` 只给报告与人工指引，保持系统管理为默认建议。

### migrate.ps1：保留数据的迁移

检查非系统盘的本地固定 NTFS 目标、空间与权限，停止应用，复制并校验；普通目标必须为空或不存在。复制继承目标父目录权限，不复制源 ACL，个人数据应先核对目标的访问权限。

普通迁移在实际复制及后续校验期间持有源、目标根和全部祖先的保护句柄；复制后、校验后复查目标路径，异常阻止切换，`finally` 释放句柄。robocopy 仍按路径访问子项，子项被并发替换的残余风险尚未完全消除，仍须关闭相关程序并限制目录写权限；根目录保护不代表整个树的原子快照。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\migrate.ps1" -Item UserFolder -Folder Downloads -Destination "D:\UserData\Downloads" -VerifyHash -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\migrate.ps1" -Item DevCache -Cache npm -Source "C:\Users\me\AppData\Local\npm-cache" -Destination "D:\DevCache\npm" -CopyExisting -VerifyHash -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\migrate.ps1" -Item WSL -Distro Ubuntu -NewDistroName Ubuntu-D -Destination "D:\WSL\Ubuntu-Migration" -VerifyHash -WhatIf
```

源路径、用户名、发行版名仅为示例，必须替换成查询到的真实值，不匹配白名单时停止。

| `-Item` | 支持范围与结果 |
| --- | --- |
| `UserFolder` | `-Folder` 为 `Desktop`、`Documents`、`Downloads`、`Pictures`、`Videos`；从 Known Folder 解析源，不接受 `-Source`；复制后按“属性 → 位置”人工切换。 |
| `DevCache` | `-Cache` 为 `npm`、`pip`、`gradle`、`maven`、`conda`；复制旧数据需同时指定 `-Source` 与 `-CopyExisting`；只改配置时不传 `-Source`，只给源而不加复制开关会被拒绝。 |
| `AppData` | `-App` 仅为 `WeChat`、`QQ`，须给白名单内的 `-Source`；只复制支持的具体文件数据目录，再由应用界面切换，不整体搬迁 AppData。 |
| `WSL` | 导出后以不同的 `-NewDistroName` 导入；默认新名为旧名加 `-Migrated`。保留旧发行版和归档，不注销旧发行版；仍须人工验证默认用户、数据及服务。 |
| `Junction` | 必须指定 `-Cache` 与 `-Source`；只支持白名单缓存，先复制校验、源改名保留，再创建 NTFS 联接和清单，作为最后手段。 |

`-VerifyHash` 加 SHA-256 校验，不能代替应用试用。所有迁移均需 `-Destination`；WSL 源从注册信息解析，不接受 `-Source`。脚本没有阶段选择开关，执行时通过 `-Confirm` 的交互提示和官方界面逐步确认；复制、切换、试用是不同完成状态。源仍保留时，不应声称其 C 盘空间已经释放。

WSL 的列表、终止、导出 / 导入管理命令显式按 UTF-16LE 解码 stdout / stderr，并保留 NUL 清理；Linux `--exec` 输出保持默认解码。这不是迁移入口的新参数，中文名称和实际输出仍须在 Windows 验证。

联接清单默认为共享日志同目录的 `junctions.json`，也可通过 `-ManifestPath` 指向白名单认可的位置。回滚仅移除核实过的联接本身，恢复保留目录名称，保留目标数据；切回前先保护 D 盘新增内容。先演练单项回滚：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\migrate.ps1" -Rollback -Source "C:\Users\me\AppData\Local\pip\Cache" -WhatIf
```

`-Rollback` 不与 `-Item`、`-Destination` 混用；省略 `-Source` 会处理清单中的所有未回滚且未取消记录。游戏、其他应用、Docker Desktop 和 VHDX 压缩只按 [迁移参考](references/migration.md) 的官方人工流程处理，没有额外脚本选择器。

### common.ps1 与 targets.psd1：共享安全层

`common.ps1` 由其他脚本点引用，提供原用户上下文、白名单与重解析点校验、目录计量、安全删除、外部命令包装、管理员检查、服务状态恢复和 UTF-8 JSONL 日志。仅点引用不会创建日志或提权。`targets.psd1` 是纯数据白名单与禁止区，不是清理入口，不应为了处理被拒绝的未知数据而临时放宽规则。

只读查看共享上下文的示例（在 Windows 原用户终端中）：

```powershell
. "<skill目录>\scripts\common.ps1"
$context = Get-CleanerContext
$context | Select-Object OriginalUserSid, OriginalUserProfile, LogPath
```

## 结果、日志与验证

执行后再次扫描，使用新的报告文件名，对比前后 `Baseline.FreeBytes`，以卷可用空间变化评估实际效果。后台下载和更新会影响差值；系统工具日志中的零字节可能表示未计量，不能当成实际无收益。列出成功、跳过、失败、等待人工操作和仍保留源数据的项目。

默认日志位于原用户 `%LOCALAPPDATA%\CDriveCleaner\Logs`，JSON 报告、JSONL 审计日志和联接清单的具体路径以输出及共享上下文为准。`-WhatIf` 不写日志或清单；保存演练终端输出用于确认。配置备份、迁移副本及经验证的独立备份与审计日志用途不同。

在 Windows 10 / 11 虚拟机中覆盖普通用户 / 管理员、PowerShell 5.1 / 7、中文与长路径、占用和拒绝访问、跨盘联接、OneDrive 占位、中断与磁盘写满。重点验证身份 / 同一 SessionId 的 Explorer 所有者核实、跨账户目录重定向拒绝、实际工具路径与编码、更新服务启动类型及运行状态恢复、逐项删除状态检查、`Running` + `Disabled` 拒绝执行及 NTFS 句柄；检查演练不删除、不写配置 / 报告 / 审计日志或改变服务，DevCache 不启动开发工具查询或清理且路径标为“待解析”。实际操作后重启，检查 Windows 更新、电源功能、WSL / Docker、聊天软件和开发工具，再比较空间。Linux 静态检查和模拟逻辑验证不能替代这些实测。

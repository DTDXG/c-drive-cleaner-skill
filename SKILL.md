---
name: c-drive-cleaner
description: 当用户说“C 盘满了”“清理 C 盘”“磁盘空间不足”或“把文件迁移到 D 盘”等，需要处理 Windows 系统盘占用时使用。先诊断并解释空间报告，再经用户明确确认清理白名单缓存或系统项目，或逐步迁移需要保留的数据。
---

# C 盘清理与迁移

你负责诊断、解释选项、取得确认并调度脚本。目标环境为 Windows 10 / 11，脚本面向 Windows PowerShell 5.1 / PowerShell 7；已在 Linux 做过静态检查及部分模拟逻辑验证，真实 Windows 行为与 PowerShell 5.1 运行仍须先在虚拟机验证。Linux 上不要执行清理或迁移。

选择清理项时阅读 [references/targets.md](references/targets.md)，查风险、版本、数据定位和禁止区；选择迁移时再阅读 [references/migration.md](references/migration.md)，查验证与回滚步骤。参考路径只是定位线索，不能扩大 `scripts/targets.psd1` 的白名单。参数以当前脚本的 `param` 和帮助为准，不编造额外选项。

## 调用与权限

将 `<skill目录>` 替换为本 skill 的实际绝对路径，路径始终加引号。统一调用形式：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\scan.ps1" -Top 30
```

其他入口同样使用 `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\xxx.ps1" ...`。使用已安装的 PowerShell 7 时可把主机程序换成 `pwsh`。执行策略仅对本次进程生效，不全局修改策略。

优先在原用户普通终端诊断。系统清理（除只报告的 `PageFile`）及 Windows 临时目录等受保护项需要管理员；权限不足时明确说明具体动作和原因，请用户在“以管理员身份运行”的终端执行给出的命令。不要自行绕过 UAC、自动提权或夺取所有权。

提权前可点引用 `scripts/common.ps1`，用 `Get-CleanerContext` 记录 `OriginalUserSid`、`OriginalUserProfile`、`LogPath`。同账户（含同账户提权）以当前令牌 SID 核对身份；提供 SID / 目录时须成对并与 ProfileList 匹配，用户路径也须安全。跨账户必须向 `clean-system.ps1` 显式成对传入 `-OriginalUserSid`、`-OriginalUserProfile`，共享库还要求 ProfileList 匹配，并通过 CIM 核实 `explorer.exe` 的所有者 SID 为原 SID、SessionId 与当前进程相同且大于 0；查询失败或无匹配会话则不验证通过。

`CLEANER_ORIGINAL_USER_SID` / `CLEANER_ORIGINAL_USER_PROFILE` 只可成对传递同账户身份，不能单独作为跨账户可信来源，也不能与单个显式参数拼成身份。`scan.ps1`、`clean-cache.ps1`、`migrate.ps1` 没有上述身份参数，应在原用户会话运行；受保护文件可按需同账户提权。身份无法核实时停止用户目录操作；开发工具清理、迁移及回收站还要求当前 SID 等于原 SID，不能借用另一管理员账户。

## 1. 运行扫描，解读报告

运行 `scan.ps1` 获取基线和 JSON 报告。它对系统只读，但正常运行会创建报告，并可能记录查询命令的审计日志。

- `-Top` 为 1–1000，默认 25，只影响控制台条目数，JSON 仍保留全部条目。
- `-OutputPath` 指定新报告文件；已有文件会被拒绝，不覆盖。省略时在共享日志目录生成唯一文件名。
- `-Quick` 跳过递归计量、深层分类及 DISM 分析，适合初筛；未知大小仍需后续完整扫描核实。
- 扫描加 `-WhatIf` 时不写报告、不运行外部查询工具，不能用它代替完整扫描。

按预计实际释放量降序展示条目，同时说明风险和迁移成本。列出具体路径、类别、逻辑大小、实际占用、预计可释放量、建议动作、风险和跳过原因。保留 `Baseline.FreeBytes` 作为前后比较基线。

`null` / unknown 是未知，拒绝访问不是零。目录计量不完整时 `Status=partial`、`KnownSizeKind=lower-bound`，`KnownLogicalBytes` / `KnownAllocatedBytes` 保留已知下限；总量及 `EstimatedReclaimableBytes` 仍为 `null`，控制台显示 `unknown (partial >= …)`，不把下限当可释放量排序。upper-bound 是上限而非保证收益；父子目录及专项条目有重叠，不能相加。WinSxS 以 DISM 分析为依据；OneDrive 云占位不计为本地可释放量；VSS 按实际关联单列。重解析点只报告、不跟随。未识别数据、其他用户数据和自定义未知路径不获得清理授权。

JSON `SchemaVersion=2` 的 `HandlerScript`、`HandlerParameters`、`ExecutionCommand` 给出清理脚本及选择器，控制台也显示执行选择器；例如 `Network\Cache` 对应 `-Category BrowserCache`，`LiveKernelReports` 对应 `-Action CrashDumps`。同一选择器可能处理同类多个路径，仍须演练并确认完整范围。未覆盖候选项转为 `manual` 或保留 `migrate` 指引，应保留项保持 `keep`；无选择器时脚本名为空、参数为 `{}`、命令为 `null`，按 `Notes` 处理。

## 2. 让用户选择条目

给出少量收益明确的候选项，让用户选择具体条目；“帮我清理 C 盘”不等于允许直接删除全部候选项。对仍有诊断价值、唯一副本或需要离线使用的内容先建议保留或备份。

第 1 层可按明确清单批量选择；第 2 层逐项选择；第 3 层每项独立选择。按收益、风险和成本排序处理，不必按层级顺序执行。

## 3. 先演练，再展示确认清单

对所选项使用同一组参数先运行 `-WhatIf`。例如：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\clean-cache.ps1" -Category UserTemp -MinAgeHours 24 -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\clean-system.ps1" -Action ComponentStore -WhatIf
```

整理演练输出，向用户逐项列出：**完整路径 / 实际作用范围、具体动作、预计释放量及估算依据、跳过项、是否可再生、不可逆后果、所需停机或重启**。扫描、缓存清理、系统清理和迁移演练均不启动外部工具；`DevCache -WhatIf` 仅报告计划查询和清理的命令，路径标为“待解析”，不执行查询或清理、不写审计日志。无法计量时写“未知 / 待执行后验证”；不要保证释放报告中的上限。系统界面可能同时清理多个旧安装项，须展示全部作用范围。

任何删除前必须得到用户对这份具体清单的明确确认；演练成功、用户选择条目、脚本开关都不能代替确认。路径、参数、作用范围或应用状态变化后重新演练并确认。

## 4. 确认后执行清理

只执行已确认的条目：使用已演练的参数移除 `-WhatIf`，保留脚本确认提示，必要时加 `-Confirm`；不得自动回答“全部是”或关闭确认来扩大授权。先要求用户关闭相关应用，跳过占用、近期修改、拒绝访问等项，失败不扩大权限重试。

`clean-cache.ps1` 的 `-Category` 可选 `UserTemp`、`WindowsTemp`、`ThumbnailCache`、`BrowserCache`、`DevCache`；省略会选择全部，所以始终显式指定已确认类别。统一的 `-File` 示例每次只传一个类别，需要多项时分次调用。`-MinAgeHours` 默认 24，范围 `0..876000`；不要擅自降到 0。

`UserTemp` 仅授权原用户已解析的 `LocalAppData\Temp` 内容；上下文解析和 UserTemp 授权均按机器 ProfileList 检查账户边界，拒绝 TEMP / LocalAppData 重定向到其他账户目录或非原用户的 Users 子目录。其他非标准 TEMP 位置仍需人工确认，脚本跳过，不因确认而自动放宽白名单。`WindowsTemp` 检测到安装 / 更新进程、待完成或待重启标志，或状态查询失败时整类跳过。浏览器与缩略图使用上下文已解析的 `LocalAppData`，缺失时停止；`BrowserCache` 仅执行 Chrome / Edge 各 profile 的 `Cache`、`Code Cache`、`GPUCache`、`Network\Cache`，浏览器仍运行或进程查询失败则跳过。

`DevCache` 实际执行时先查询 npm、pip、conda、dotnet NuGet 的实际缓存位置，并检查 NuGet 环境变量覆盖；每条路径均须通过 `Test-SafeTarget -Category DevCache`。查询 / 解析失败或任一路径不通过（含非 C 盘、自定义未知位置、同步目录、重解析点）就跳过整个工具。逐路径持有祖先防替换句柄直至工具结束及后置校验完成，祖先缺失或句柄获取失败则跳过整个工具，`finally` 释放句柄；运行前后复查路径。为允许官方工具删除缓存根，不锁根本身，根及子项仍有并发替换风险。npm / pip 清理参数固定已验证目录；conda / NuGet 确认后重查配置，变化则停止。官方清理命令不受年龄筛选，释放量只按系统卷空闲变化估算；不清 Maven / Gradle，不直接删除整棵 `.m2` / `.gradle`。

`clean-system.ps1` 每次 `-Action` 只能选一项：第 2 层为 `ComponentStore`、`UpdateCache`、`DeliveryOptimization`。`UpdateCache` / `DeliveryOptimization` 在更新活动、待重启安装或状态不明时跳过清理；组件存储先分析，只有确有清理价值才清理，不使用 `/ResetBase`。

`UpdateCache` 采用微软文档中的停服务清理方法，不使用系统清理界面，只处理精确的 `%SystemRoot%\SoftwareDistribution\Download` 内容：快照 BITS / wuauserv 状态及启动类型，原为 `Running` + `Disabled` 时拒绝执行；事务内核实 COM / BITS 更新空闲，临时将两服务启动类型设为 `Disabled` 后停止服务，再检查更新、待重启及服务状态，通过 `Remove-SafeItem -MinAgeHours 0` 清理并保留 Download 根。逐项删除前后检查服务仍为停止状态，重启或查询失败即禁止后续删除；`finally` 还原原启动类型及运行状态。状态不明则停止清理，恢复失败须人工检查；不处理 DataStore 或整棵 SoftwareDistribution。

第 3 层如下，每项须独立说明后果并确认；脚本要求显式 `-AcknowledgeIrreversible`，演练也需要。演练中的该开关仅满足脚本前置要求，不代表用户已授权实际执行。

| `-Action` | 必须解释的后果与附加参数 |
| --- | --- |
| `RecycleBin` | 永久删除授权用户 C 盘回收站内容，不能从回收站恢复。 |
| `CrashDumps` | 清理 `%ProgramData%\Microsoft\Windows\WER`、`%SystemRoot%\Minidump`、`LiveKernelReports` 的内容并保留根目录，另删 `MEMORY.DMP`；不含用户 `LocalAppData\CrashDumps`。永久丢失诊断现场，排障需要时先备份。 |
| `WindowsOld` | 失去对应系统版本回退能力；先检查旧用户数据，通过系统工具清理。 |
| `Hibernate` | 必须显式 `-Mode Off` 或 `-Mode Reduced`；Off 禁用休眠、快速启动、混合睡眠；Reduced 只保留快速启动所需精简文件。 |
| `ShadowStorage` | 先核实实际 VSS 关联；`-ForVolume` 默认 `C:`，`-OnVolume` 按实际存储卷指定，不默认假设同盘。省略 `-MaxSize` 只列出；如指定 `10GB`、`500MB` 或 `10%`，缩小可能立即永久删除旧快照和还原点。 |
| `ReservedStorage` | 默认只查询；只有加 `-DisableReservedStorage` 才请求禁用，默认不建议，不保证立即释放空间。 |
| `PageFile` | 脚本只报告和给指引，不自动调整；默认保持系统管理。缩小降低提交上限，移盘影响崩溃转储，变更后需重启验证。此只读动作仍要求确认开关。 |

第 3 层演练示例（实际执行仍须先取得该项明确确认）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\clean-system.ps1" -Action Hibernate -Mode Reduced -AcknowledgeIrreversible -WhatIf
```

## 5. 迁移按统一流程逐步确认

先读 [references/migration.md](references/migration.md) 对应章节。每一步展示结果、等待用户确认后继续：**检查 D 盘容量、本地固定 NTFS、路径与权限 → 备份并停止应用写入 → 复制并校验 → 切换路径 → 试用确认 → 有可靠且验证可恢复的独立备份后，才另行讨论删除 C 盘旧源**。D 盘与 C 盘同属一块物理盘时不能当独立备份。

先演练，例如迁移下载文件夹：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\migrate.ps1" -Item UserFolder -Folder Downloads -Destination "D:\UserData\Downloads" -VerifyHash -WhatIf
```

确认后执行迁移时使用 `-Confirm`，在脚本的分步提示处等待用户确认；先核对复制校验结果再允许切换。脚本没有阶段选择参数，不编造阶段开关；不能提供交互确认时，给出命令让用户在交互终端逐步确认，不一次性代答后续步骤。

| `-Item` | 实际参数与边界 |
| --- | --- |
| `UserFolder` | `-Folder` 选 `Desktop`、`Documents`、`Downloads`、`Pictures`、`Videos`；不接受 `-Source`。复制后仍需在“属性 → 位置”切换，保留旧副本。 |
| `DevCache` | `-Cache` 选 `npm`、`pip`、`gradle`、`maven`、`conda`。先查真实位置；复制旧数据须同时提供 `-Source` 与 `-CopyExisting`；只改配置时不传 `-Source`，只给源而不加复制开关会被拒绝。 |
| `AppData` | `-App` 仅支持 `WeChat`、`QQ`，必须给白名单内的 `-Source`；只复制受支持的文件数据目录，完成后仍需应用内切换，不表示整棵 AppData 或聊天库都能迁移。 |
| `WSL` | 必须给准确的 `-Distro`，可给不同的 `-NewDistroName`（默认旧名加 `-Migrated`），不接受 `-Source`。脚本导出后新名导入，保留旧发行版与归档，不注销旧发行版；人工核实默认 Linux 用户、业务数据与集成。 |
| `Junction` | 最后手段，必须给 `-Cache` 和白名单缓存 `-Source`；源改名保留、联接登记清单，不释放旧源空间。可用 `-ManifestPath` 指定白名单认可的清单位置。 |

所有迁移都须给 `-Destination`，使用非系统盘上专用、为空或不存在的安全目标。`-VerifyHash` 为普通复制逐文件加 SHA-256 校验，WSL 比对稳定文件集合摘要；不能代替应用试用与备份验证。

普通迁移实际复制及后续校验期间，持有源、目标根和全部祖先的保护句柄，复制后、校验后复查目标路径，异常阻止切换并在 `finally` 释放句柄。此保护不能消除 robocopy 按路径访问子项时被并发替换的残余风险，仍须关闭相关程序并限制目录写权限；不是整个目录树的原子快照。

联接回滚使用 `migrate.ps1 -Rollback`，可用 `-ManifestPath` 选择清单、`-Source` 限定单项；不与 `-Item` / `-Destination` 混用。先演练并单独确认，只移除已核实联接本身、恢复保留目录名称，不递归删除 D 盘目标；切回前保护目标中的新增数据。

游戏、其他聊天软件、Docker Desktop、虚拟磁盘压缩没有额外迁移选择器，按参考文档走官方人工流程。脚本不会删除迁移旧源；源数据仍在时不能声称已释放其空间。旧源删除必须另行确认、满足白名单及官方流程边界，不能用缓存清理绕过。WSL 注销是独立高风险人工步骤，须验证新发行版、备份、准确旧名称后另行确认。

## 6. 对比空间并交付结果

重新运行 `scan.ps1`，使用新的报告文件，对比前后 `Baseline.FreeBytes`，给出 C 盘可用空间变化；注明后台下载、更新等并发活动可能造成偏差。区分已执行、跳过、失败、仅给指引、等待试用，以及仍保留旧源的迁移项。需要重启的项目在重启后验证功能和空间。

列出实际 JSON 报告、每次会话的 JSONL 审计日志、迁移配置备份及联接清单路径。默认日志在原用户 `%LOCALAPPDATA%\CDriveCleaner\Logs`，联接清单默认为日志同目录的 `junctions.json`；以脚本实际输出和上下文为准。演练不生成日志或清单，不虚构文件。日志用于审计，不等于数据备份，也不保证可回滚。

## 始终遵守的安全边界

- 只删除当前脚本支持且共享校验通过的白名单具体项。执行前重新检查目标及每一级父目录，不跟随联接或符号链接；未知类别、未知数据只报告。路径操作使用 `-LiteralPath`，不拼接通配递归删除命令，不绕过脚本校验。
- 禁止手删 `C:\Windows\WinSxS`、`System32`、`Installer`、`DriverStore`、`servicing`、`Recovery`、`System Volume Information`、`WindowsApps`、`C:\ProgramData\Package Cache`。这些项目只能在授权范围内使用系统受支持工具处理。
- 不直接删除 `Program Files` / `Program Files (x86)` 下的软件目录；走卸载或官方移动。不整体移动或删除 `AppData` / `ProgramData`，不做注册表清理，不触碰浏览器书签、密码、Cookie、会话及站点用户数据。
- 不直接删除 `.vhdx`，不使用 DISM `/ResetBase`，复制不用 `robocopy /MIR`、`/PURGE`、`/MOVE`。Docker 容器清理不是现有系统脚本动作，卷清理须单独解释和确认，不能自动附加卷删除选项。
- 不删除 OneDrive 或其他同步目录文件；核实已上传且可取回后，只用客户端“释放空间 / 仅在线”。退出客户端不等于删除不会在下次同步时传播。
- 任何删除都必须先得到用户明确确认；失败、中断、空间不足或校验不符时停止当前项，保留两端数据与证据，不跳过校验、不扩大权限、不自动清空目标重试。

# c-drive-cleaner-skill

面向 Windows 的 Claude Code skill，以“磁盘规划顾问”的方式处理 C 盘：AI 先扫描，给出 A「只需确认（AI 执行）」、B「需要你一步步操作」、C「长期规划建议」。用户一次回复编号后，AI 自己演练、展示简短差异，再提供一条管理员命令统一执行，最后读取结果报告空间变化与剩余人工项。

C: 只放系统和必须装在系统盘的程序；个人文件、开发缓存、虚拟机 / WSL、游戏优先放数据卷。不要长期依赖单分区或单磁盘，备份放另一物理磁盘、外置盘或云端；同盘 D: 便于整理，但不是独立备份。优先官方工具，不以安全换空间。可用“C 盘满了，先帮我检查”“帮我清理 C 盘”“把下载迁移到 D 盘”等请求触发。

**尚未在真实 Windows 验证。已在 Linux 做过静态检查及部分模拟逻辑验证，真实 Windows 行为仍须先在虚拟机验证。** 真实身份 / 会话、DISM、VSS、服务恢复、OneDrive 占位、NTFS 句柄 / 联接与实际释放效果不视为已验证。脚本面向 Windows 10 / 11、Windows PowerShell 5.1 / PowerShell 7；5.1 实际运行仍待验证。Linux 仅运行静态检查和模拟测试，不执行清理或迁移。

## 授权与安全

- “帮我清理 C 盘”不是删除许可。AI 展示完整作用范围、收益上限、用户影响、风险、需退出程序 / 管理员 / 重启要求后，用户确认编号清单才授予执行权。
- A 的常规项给出默认推荐，仍需确认；RecycleBin、CrashDumps、WindowsOld、Hibernate、ShadowStorage 在同一表末尾，默认不选，必须明确点名编号，再经 `apply-plan.ps1 -AcknowledgeIrreversible` 传入。不按项目再问多轮，只有范围改变、报告过旧需重扫或新增项目时重新确认。
- 只处理脚本支持且校验通过的白名单具体项，不跟随重解析点，不夺取所有权、不绕过 UAC、不自动提权或杀进程；占用、权限不足和状态不明按脚本跳过。
- 不手删 WinSxS、System32、Installer、DriverStore、servicing、Recovery、System Volume Information、WindowsApps、ProgramData\Package Cache 或软件安装目录；不整体搬删 AppData / ProgramData，不做注册表清理。
- 不删浏览器书签、密码、Cookie、会话或站点用户数据，不直接删 `.vhdx`，不用 DISM `/ResetBase`。同步目录只在核实上传和可取回后通过客户端“释放空间 / 仅在线”处理。
- B 中的大文件、旧安装包、已安装软件只报告并给具体人工步骤；迁移始终逐步确认、保留源，不用 `robocopy /MIR`、`/PURGE`、`/MOVE`，不自动注销旧 WSL。旧源未删就不能声称其空间已释放。
- 未知不等于零、估算上限不等于实得、重叠目录不能相加。审计日志不能恢复已删数据。

操作约定和完整三段模板见 [SKILL.md](SKILL.md)；路径、分类和损失详见 [targets.md](references/targets.md)；迁移步骤、校验与回滚见 [migration.md](references/migration.md)。参考路径不能扩大 [targets.psd1](scripts/targets.psd1) 的授权范围。

## 目录结构

```text
c-drive-cleaner-skill/
├── SKILL.md                    顾问定位、A/B/C 模板、一次确认流程和安全边界
├── README.md                   项目说明、真实参数和测试方法
├── scripts/
│   ├── common.ps1              身份、路径、计量、删除、日志和服务安全层
│   ├── targets.psd1            白名单与永久禁止区（纯数据）
│   ├── scan.ps1                SchemaVersion 3 扫描报告与规划建议
│   ├── apply-plan.ps1          按已确认 Id 一次调度并生成结果 JSON
│   ├── clean-cache.ps1         白名单文件缓存及开发工具官方缓存清理
│   ├── clean-system.ps1        系统清理处理器和报告动作
│   └── migrate.ps1             保留源的复制校验、配置切换及联接回滚
├── references/
│   ├── targets.md              分类、路径、影响、门控和规划规则
│   └── migration.md            B 类迁移、验证与回滚
└── tests/
    ├── t1-targets.tests.ps1     白名单、排除规则和参数约束
    ├── t1-execution.tests.ps1   缓存执行门控和开发工具内存模拟
    ├── t2-scan-logic.tests.ps1  扫描分类、聚合、清单和建议
    └── t3-apply-plan.tests.ps1  报告校验、计划分发与结果模拟
```

## 安装与一次确认流程

把完整仓库放到 `~/.claude/skills/c-drive-cleaner`，Windows 对应 `%USERPROFILE%\.claude\skills\c-drive-cleaner`；保留脚本和参考文档的相对位置。在 Windows Claude Code 会话中请求诊断，或用 `/c-drive-cleaner` 调用。仓库位于 WSL / Linux 时，也必须在 Windows 主机执行实际清理脚本。

1. AI 在原用户普通终端完整扫描并读取 JSON，展示恰好 A / B / C 三段；A 使用报告原始整数 Id，B 使用 M 编号，C 来自 Advisory。
2. 用户回复如“确认 1-6,9”（示例编号，以本表为准）；常规项可写范围，不可逆项须单列其编号，“全部/推荐项”不含不可逆项。
3. AI 对同一报告与编号运行 apply-plan 的演练，展示将做 / 跳过什么及与清单的差异；无范围变化就继续，不再重复询问。
4. AI 给出一条命令，用户以扫描时同一账户打开管理员 PowerShell 粘贴执行；若 AI 当前会话已同账户提权且已获确认，则直接执行。不要先在普通终端执行部分清理，再重跑整表。
5. AI 读取结果 JSON，报告前后空闲空间、完成 / 部分完成 / 跳过 / 失败和剩余 B 项；需要重启或系统界面继续操作时如实说明。

下列 `<skill目录>`、报告路径及编号均须替换成实际值。扫描可用 Windows 自带 `powershell`；已安装 PowerShell 7 时可换 `pwsh`。`-ExecutionPolicy Bypass` 仅限本次进程。为可靠传递整数数组，计划示例使用 PowerShell 内的调用运算符 `&`，直接粘贴到 PowerShell，勿改成由 cmd 传数组的形式。

`-WhatIf` / `-Confirm` 是入口通过 CmdletBinding 的 SupportsShouldProcess 启用的 PowerShell 通用参数；NoProfile / ExecutionPolicy / File / NonInteractive 属于 PowerShell 主机选项，不是脚本入口参数。

计划入口要求同机、同原用户 SID 和用户目录，支持同账户提权，不支持借另一管理员账户。它没有身份覆盖参数。共享库的身份与 ProfileList / 用户目录边界仍需核实；完整的底层跨账户限制见 [目标参考](references/targets.md)。

## 脚本与参数

### scan.ps1：只读诊断与版本 3 报告

正常扫描会创建报告及必要父目录，外部只读查询可能写审计日志，不删除文件、不改系统配置。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\scan.ps1" -Top 30 -OutputPath "C:\CleanerReports\scan-before.json"
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\scan.ps1" -LargeFileCount 50 -LargeFileMinMB 1024 -InstallerAgeDays 60
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\scan.ps1" -Quick
```

| 参数 | 实际含义 |
| --- | --- |
| `-OutputPath` | 只接受新报告文件，拒绝覆盖；默认共享日志目录唯一文件名。 |
| `-Top` | 默认 25，1–1000；仅限制控制台，JSON 保留全部发现项。 |
| `-Quick` | 跳过递归计量、深层分类、DISM 分析、大文件 / 安装包 / 软件清单和磁盘布局；相关大小及状态未知。 |
| `-LargeFileCount` | 默认 30，0–500，0 关闭大文件发现；在原用户 C: 目录发现，排除 AppData、同步目录和重解析点。 |
| `-LargeFileMinMB` | 默认 500 MiB，1–1048576；大文件逻辑大小门槛。 |
| `-InstallerAgeDays` | 默认 30 天，0–36500；下载 / 桌面中安装包及归档的最短年龄。 |

扫描支持 `-WhatIf`，不运行外部命令、不写报告，不能用作执行基线。普通权限无法完成 DISM / VSS 等查询时保留未知，不承诺已扫描所有路径。

`SchemaVersion=3` 的主要字段：

| 字段 | 用途 |
| --- | --- |
| `Baseline`、`StartedAtUtc`、`CompletedAtUtc`、`Context`、`ComputerName` | C: 容量 / 空闲基线、报告时间、原身份与机器。 |
| `Entries` | 原始条目，含逻辑 / 实际 / 预计量、`Disposition`、`Impact`、`ManualReason`、`ManualSteps`、`DefaultSelected`、`Irreversible`。 |
| `ConfirmationItems` | A 表：同一 `HandlerScript` 与 `HandlerParameters` 归组，含整数 `Id`、`Title`、`Paths`、`EntryKeys`、影响、权限和估算；不可逆项最后且默认不选。 |
| `ManualItems` | B 表：`M1…` 编号、`Reason`、`Steps`、`Paths`、`Category`、参考 `EstimatedBytes`。 |
| `Advisory`、`AdvisoryEvidence` | C 段：有证据的规则建议及占用依据；每条建议含 `Id`、`Severity`、`Title`、`Detail`、`Steps`。 |
| `DiskLayout`、`StorageSenseEnabled` | 物理磁盘 / 卷、系统盘号、是否有固定数据卷、数据卷是否都与系统同盘、系统盘分区数；未知为 null。 |
| `Inventories` | `LargeFiles`、`OldInstallers`、`InstalledSoftware`：只读清单，逻辑大小或厂商报告大小不是可释放量。 |
| `DiscoveryIssues`、`OneDriveRoots`、`AccountingNotes` | 遗漏 / 访问限制、同步目录和计量限制。 |

`Disposition` 是 `ai` / `manual` / `keep`；非 ai 项的处理器清空，不生成可执行清理命令。`Impact` 解释损失、可逆性、关闭程序、管理员、重启、风险和附带影响。`HandlerScript` / `HandlerParameters` / `ExecutionCommand` 只表示选择器，不能代替用户授权；同一类别可能清理多个路径，必须解释完整范围。

`partial` 条目的 `KnownLogicalBytes` / `KnownAllocatedBytes`、确认组的 `KnownLowerBoundBytes` 只是已知下限；完整大小和预计量可为 null。组内去除父子路径重复，组间仍可能重叠，不能累加总收益。大文件发现有时间 / 数量 / 深度上限；旧安装包不是按年龄自动认定为垃圾；软件大小来自卸载信息 EstimatedSize，未声明位置时不能确认在 C:，清单还会排除部分共享运行时、SDK 和驱动。

### apply-plan.ps1：一次执行已确认的编号

以下是假设用户已确认 1、2、9，且 9 为不可逆项的示例；实际编号只取当前报告，禁止照抄示例选择。

AI 自己先演练：

```powershell
& "<skill目录>\scripts\apply-plan.ps1" -ReportPath "C:\CleanerReports\scan-before.json" -Items @(1,2,9) -AcknowledgeIrreversible @(9) -WhatIf
```

演练差异核对完且范围未改变后，给用户粘贴到同账户管理员 PowerShell 的唯一执行命令：

```powershell
& "<skill目录>\scripts\apply-plan.ps1" -ReportPath "C:\CleanerReports\scan-before.json" -Items @(1,2,9) -AcknowledgeIrreversible @(9)
```

| 参数 | 实际含义 |
| --- | --- |
| `-ReportPath` | 必填，scan 生成的版本 3 JSON；拒绝旧版、未来时间、其他机器 / 身份或演练报告。 |
| `-Items` | 必填，用户已确认的整数 Id 数组；不能空、重复或含未知编号，不接受 M 编号。 |
| `-AcknowledgeIrreversible` | 整数数组，须覆盖所有所选不可逆编号，不能含未选编号；无不可逆项时省略。 |
| `-MaxReportAgeHours` | 默认 24，1–168；从扫描开始时间计龄。skill 流程中过期应重扫重确认，不为继续执行放宽时限。 |
| `-ResultPath` | 新结果 JSON，不覆盖；默认共享日志目录唯一名称。 |
| `-SkipRescan` | 跳过执行后的 Quick 复扫；正常流程保留默认复扫。 |

`-WhatIf` 不启动外部工具、不改服务、不删除、不复扫、不写结果或日志。普通权限下需管理员的项目连演练处理器也会跳过，AI 要说明该限制；DevCache 演练仅说明命令，实际工具位置待执行时查询。展示“将做 / 跳过、关闭程序 / 权限 / 重启要求、与确认清单有无范围变化”的短差异；仅计划改变才重确认。

执行器先完整校验计划，只分发白名单 clean-cache / clean-system，保留报告原参数，不执行 JSON 中的任意命令；先用户缓存、再系统项、最后不可逆项。底层不重复询问已确认 A 项。每项独立捕获结果，失败不妨碍其他已确认项目；权限不足则跳过，不自动提权、不扩大权限重试。

结果 JSON 为 `SchemaVersion=1`，包含 `Items` 的 `Id` / `Title` / `Result` / `FreedBytes` / `Messages`，以及 `FreeBytesBefore`、`FreeBytesAfter`、`RescanReportPath`。Result 为 `done`、`partial`、`skipped`、`failed`；释放量取 C: 空闲变化，可能为负或未知，后台活动会影响差值。系统工具返回不等于后台清理全部结束，仍须核实。

### clean-cache.ps1：缓存处理器

`-Category` 可多选 `UserTemp`、`WindowsTemp`、`ThumbnailCache`、`BrowserCache`、`AppCache`、`ShaderCache`、`InetCache`、`SystemLogs`、`DevCache`；省略会处理全部，所以必须显式指定。统一清理应经 apply-plan 调度；以下仅示范处理器演练：

```powershell
& "<skill目录>\scripts\clean-cache.ps1" -Category AppCache,ShaderCache,InetCache,SystemLogs -WhatIf
& "<skill目录>\scripts\clean-cache.ps1" -Category BrowserCache -MinAgeHours 48 -WhatIf
```

文件清理 `-MinAgeHours` 默认 24，范围 0–876000；SystemLogs 强制至少 168 小时，只处理 CBS 持久化归档及 WindowsUpdate 的直接 ETL 文件，不删 CBS.log。UserTemp 只授权已解析的原用户 LocalAppData\Temp，自定义 TEMP 不扩大权限；WindowsTemp 遇安装 / 更新活动、待重启或状态未知时整类跳过。

BrowserCache 覆盖白名单全部浏览器：Chrome / Edge 各 profile 的 Cache、Network\Cache、Code Cache、GPUCache；Brave / Chromium 的 Cache、Code Cache；Firefox 的 cache2；Opera Stable 的 Cache、Code Cache。AppCache 覆盖 VS Code、经典 Teams、Discord、Slack、JetBrains 的指定缓存 / 日志。对应应用运行或进程查询失败就跳过该应用；ShaderCache / InetCache 无专门进程名门控，仍须用户退出游戏、图形及相关应用，占用文件跳过，INetCache 的 Content.Outlook 始终保留。

DevCache 使用 npm、pip、conda、dotnet NuGet、yarn、pnpm、go 官方命令；不受文件年龄筛选，可能影响近期缓存及离线构建。先查询真实目录，所有路径通过 C: 白名单 / 身份检查后才清理；任一查询失败、不安全或配置变化就跳过整个工具，不手删 `.m2` / `.gradle`。演练不启动工具，路径为待解析。详细路径、命令、祖先句柄及残余竞争限制见 [目标参考](references/targets.md)。

### clean-system.ps1：系统处理器

每次 `-Action` 只接收一项：ComponentStore、UpdateCache、DeliveryOptimization、RecycleBin、CrashDumps、WindowsOld、Hibernate、ShadowStorage、ReservedStorage、PageFile。普通流程由 apply-plan 调度 A 项；PageFile / ReservedStorage 是 B 类，默认保留。

```powershell
& "<skill目录>\scripts\clean-system.ps1" -Action ComponentStore -WhatIf
& "<skill目录>\scripts\clean-system.ps1" -Action Hibernate -Mode Reduced -AcknowledgeIrreversible -WhatIf
```

底层的 `-AcknowledgeIrreversible` 是开关，后七种动作即使演练 / 只报告也要求提供，不能代替用户授权。`-Mode` 仅供 Hibernate，须显式 Off 或 Reduced；skill 仅推荐 Reduced。VSS 用 `-ForVolume`（默认 C:）、`-OnVolume` 核实实际关联，`-MaxSize` 省略则仅报告；缩小可能立即丢失还原点。ReservedStorage 默认只查询，只有 `-DisableReservedStorage` 才请求禁用，默认不建议，也不保证立即释放。PageFile 只报告，默认保持系统管理。

除 PageFile 外需要管理员。只有此底层入口提供成对的 `-OriginalUserSid` / `-OriginalUserProfile`；跨账户共享验证还要求 ProfileList 匹配、同一非零 SessionId 的 Explorer 原 SID，环境变量不能单独证明来源；回收站仍要求当前 SID 等于原 SID。不要把底层身份参数传给 apply-plan、scan、clean-cache 或 migrate。

组件存储先 DISM 分析再清理，不用 ResetBase。UpdateCache 仅处理 SoftwareDistribution\Download 内容，在已授权事务内核实更新空闲、临时禁用并停止 BITS / wuauserv、逐项检查停止状态，finally 还原启动类型与运行状态；忙碌、待重启、查询失败或 Running + Disabled 状态拒绝清理，不碰 DataStore。CrashDumps 不含用户 LocalAppData\CrashDumps；WindowsOld 的 cleanmgr /AUTOCLEAN 可能覆盖升级残留且继续后台运行。详细后果见 [目标参考](references/targets.md)。

### migrate.ps1：B 类逐步迁移

目标必须为非系统盘本地固定 NTFS 的专用空目录，检查容量、权限和独立备份，先停写入再复制校验、切换、试用。源始终保留；复制及校验期间保护源、目标根和祖先，仍不能消除子项并发替换风险。实际执行使用 `-Confirm` 逐步确认，不能由 A 的编号授权代替。

```powershell
& "<skill目录>\scripts\migrate.ps1" -Item UserFolder -Folder Downloads -Destination "D:\UserData\Downloads" -VerifyHash -WhatIf
& "<skill目录>\scripts\migrate.ps1" -Item DevCache -Cache npm -Source "C:\Users\me\AppData\Local\npm-cache" -Destination "D:\DevCache\npm" -CopyExisting -VerifyHash -WhatIf
& "<skill目录>\scripts\migrate.ps1" -Item WSL -Distro Ubuntu -NewDistroName Ubuntu-D -Destination "D:\WSL\Ubuntu-Migration" -VerifyHash -WhatIf
```

| 选择器 | 参数和边界 |
| --- | --- |
| `-Item UserFolder` | `-Folder` 为 Desktop、Documents、Downloads、Pictures、Videos；Known Folder 解析源，不接受 `-Source`；复制后人工属性→位置切换。 |
| `-Item DevCache` | `-Cache` 仅 npm、pip、gradle、maven、conda；只改配置时不传源；复制须同时给 `-Source` / `-CopyExisting`。清理支持的 yarn / pnpm / go 不表示此处支持迁移。 |
| `-Item AppData` | `-App` 仅 WeChat / QQ，必须给白名单 `-Source`；只复制支持的文件数据，再在应用内切换。 |
| `-Item WSL` | `-Distro` 为准确旧名称；`-NewDistroName` 默认旧名加 -Migrated，必须不同；不接受源参数，保留旧发行版与归档。 |
| `-Item Junction` | 最后手段，须 `-Cache`、白名单 `-Source`，可给 `-ManifestPath`；源改名保留，建立联接并登记清单。 |

所有迁移给 `-Destination`；`-VerifyHash` 增加 SHA-256 校验，不能代替业务试用。脚本无阶段选择参数。联接回滚使用 `-Rollback`，可给 `-Source` 限定单项、`-ManifestPath` 选择认可的清单位置；不与 `-Item` / `-Destination` 混用，默认清单在共享日志目录的 junctions.json，只移除核实的联接，保留目标。游戏、其他应用、Docker、VHDX 压缩走 [官方人工步骤](references/migration.md)，没有额外选择器。

### common.ps1 / targets.psd1：共享安全层

common 由入口点引用，提供原用户上下文、路径 / 重解析点校验、计量、安全删除、外部命令、服务恢复及 UTF-8 JSONL 审计；仅点引用不创建日志、不提权。targets 是纯数据，不为处理未知路径而放宽规则。默认日志目录为原用户 `%LOCALAPPDATA%\CDriveCleaner\Logs`，扫描 / 结果 / JSONL / 清单实际路径以输出为准，演练不虚构日志文件。配置备份、源副本与独立备份用途不同。

## 测试与 Windows 验证

Linux 上需预先安装 `pwsh`，这些测试是自包含断言脚本，无需 Pester、无网络下载。它们只点引用共享函数或从 AST 提取函数，用内存模拟 Windows / 工具行为，不运行清理入口的脚本体。在仓库根目录从 Bash 运行，每份测试独立 PowerShell 进程：

```bash
for test_file in tests/*.tests.ps1; do
  pwsh -NoProfile -NonInteractive -File "$test_file" || exit "$?"
done
```

可单独运行 `pwsh -NoProfile -NonInteractive -File tests/t3-apply-plan.tests.ps1`。覆盖白名单 / 排除项、进程门控、日志最短年龄、yarn / pnpm / go 路径与失败跳过、扫描分类 / 聚合 / 规划规则、报告过期 / 身份 / 参数拒绝及统一执行结果；不证明真实删除、Windows 权限或服务行为正确。

仍须在 Windows 10 / 11 虚拟机验证普通 / 同账户管理员、PowerShell 5.1 / 7、中文和长路径、拒绝访问、占用、同步占位、跨盘联接、中断与磁盘写满。重点核对：原身份 / ProfileList 边界、DISM / VSS、更新服务完整恢复、NTFS 句柄、真实开发工具路径及 WSL 编码；演练不启动外部工具、不写报告 / 配置 / 审计 / 结果、不改变服务；不可逆项未点名时拒绝执行。实际操作后检查空间与更新、电源、应用、开发构建、WSL / Docker 功能，必要时重启验证。Linux 模拟不能替代这些实测。

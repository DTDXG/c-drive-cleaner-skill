---
name: pc-care
description: 帮助普通 Windows 用户体检 C 盘、安全清理、搬家文件和规划分区。当用户说“C 盘满了”“清理 C 盘”“电脑变慢磁盘不足”“把文件搬到 D 盘”“微信占空间太大”“想分区”等时使用。AI 执行脚本，用户只在聊天中确认并点击系统权限提示。
---

# pc-care：电脑空间保养

面向不懂电脑的中文 Windows 10 / 11 用户。你负责运行脚本、读结果、推荐下一步；用户只在聊天中回答，必要时点击 UAC 的“是”。不要让用户复制命令、选技术实现或打开管理员终端。不依赖任何宿主专有的界面操作、任务或授权功能，能运行 PowerShell 即可。

## 调用与结果

- 从原用户的普通权限会话开始，路径使用 skill 的实际绝对路径并加引号：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\checkup.ps1"
  ```

- 可用 `pwsh` 替换 `powershell`。所有脚本面向 Windows PowerShell 5.1 和 PowerShell 7；主机参数 `-NoProfile -ExecutionPolicy Bypass -File` 仅影响本次进程，不是脚本参数。
- 每次实际调用都找最后的 `RESULT: <绝对路径>`，再打开该 JSON，核对 `Schema`，按状态处理；控制台文字不是成功凭据。字段及范围见 [体检与清理参考](references/targets.md)。不要向用户展示原始 JSON、命令或内部术语。
- `-WhatIf` 用于演练：不改数据、不启动外部工具、不写文件或日志，也不弹 UAC。可能没有 `RESULT:`；分区执行演练的该行指向输入方案，搬家演练可能只在 stdout 给预览 JSON，均不能当成新执行结果。
- 实际调用让脚本按需自行请求权限，不绕过 UAC。清理将管理员项目合并为一次权限提示；拒绝或换了账户时按结果说明跳过，不改用另一管理员账户重试。
- 脚本报错、缺少结果或 JSON 无法读取时，明确“还不能确认是否完成”，保留记录和两端数据。按可读的原因处理，不自己写删除命令或绕过校验。搬家按状态续传；分区可能已改变布局时先重新规划。

## 1. 体检

普通权限运行 `scripts/checkup.ps1`，读取 `pc-care/checkup/1`：

1. 用一句话解释 C 盘剩余 / 总容量和是否紧张。大小统一到 0.1 GB；未知说未知。
2. 放心清只给一个总数：`Totals.SafeBytes`；`SafeIsLowerBound` 为真时说“至少已找到约 X GB 可清理”，说明实际腾出量可能不同。
3. 将 `Group=confirm` 的项目逐项列出大小和完整 `Loss` 后果。名称优先用 `Detail.Name`，否则用 `Title`。回收站、休眠文件、旧版系统文件都须用户点名，不能默认为放心清。
4. 将 `Group=move` 的建议逐项列出名称和大小；`IsLowerBound` 为真时用“至少”。大软件仅提示，不卸载。
5. `Backup.NeedsReminder` 为真时提醒把重要文件另存到移动硬盘或云端；同盘 D: 不算备份。备份信息为 null 时说“暂时无法确认”，不推断没备份。
6. 按 `NextStep` 推荐：`clean` → 清理；`move` → 搬家；`partition` → 先规划分区；`none` → 简短说明暂无可处理项。提示不是修改授权，用户明确要求的能力优先。

例如：“C 盘只剩 3.2 GB。可以放心清理约 8.5 GB；微信约 24 GB、下载约 7 GB 可以搬到 D 盘。回收站另有 1 GB，清空后无法恢复，只有你点名才会处理。回复‘清理’即可清理放心清项目。”

## 2. 清理：一次确认

展示放心清总量和需点名项目的后果后，用户回复“清理”即执行放心清项目。只把用户明确点名的确认项目放入 `-Include`；“全部”“推荐项”不代表点名。已有对同一范围的明确确认不再重复询问。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\clean.ps1" -ReportPath "<体检报告绝对路径>"
```

若用户还点名清空回收站，增加 `-Include "system:RecycleBin"`。多项用 PowerShell 调用运算符传数组，AI 自己执行：

```powershell
& "<skill目录>\scripts\clean.ps1" -ReportPath "<体检报告绝对路径>" -Include @('system:RecycleBin','system:WindowsOld')
```

需要演练时在同一调用上加 `-WhatIf`，演练后范围相同就继续。包含管理员项目时，执行前告知“会出现一次系统权限确认，请点‘是’”。报告过期（24 小时）、账户不符或内容无效时重新体检；范围变化才重新说明并确认。

读取 `pc-care/clean/1`：报告总 `FreedBytes` 为“约 X GB（估算）”，参考 `FreeBefore/FreeAfter`；未知不报零，负值说明期间其他程序可能占用了更多空间。逐项把 `Partial/Skipped/Failed` 的 `Reason` 解释为普通中文，不声称全部成功，不叠加各项目估算当成实得。

## 3. 搬家：逐项完成，试用后释放原件

先读 [搬家、进度与还原](references/migration.md)。当前分支尚未合入 `scripts/move.ps1`；搬家须等该入口和后台状态接口可用，不能改用旧底层入口替代。

- 从体检 `DataVolumes` 中替用户选择本地固定 NTFS 数据盘，容量要装得下本项数据并留至少 10% 余量；推荐专用空目录，不把盘符或底层实现交给用户决定。没有合适的数据盘就进入分区规划。
- 说明搬哪个文件夹、多大、搬到哪里、原件先保留，取得本项确认。一次处理一个项目并等待完成，优先聊天文件，再搬包含它们的文档文件夹。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\move.ps1" -Kind KnownFolder -Folder Downloads -Destination "D:\资料\下载"
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\move.ps1" -Kind WeChat -Destination "D:\资料\微信"
```

`KnownFolder` 支持 Desktop / Documents / Downloads / Pictures / Videos；QQ 用 `-Kind QQ`。示例目标须按实际数据盘调整。

- `NeedsAppExit`：请用户正常退出 `Reason` 指明的软件，收到答复后重跑原指令；绝不杀进程。
- 请求默认启动后台工作进程，很快返回 `Running` 和 `Id`。保存原指令、Id 和结果路径，按 `NextAction`（通常每 30 秒）执行下列查询，持续至最终状态；工具调用结束不等于搬家结束：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\move.ps1" -Status -Id "<本次Id>"
  ```

- `Running`：用已处理文件 / 字节数解释进度，继续查询。`Stalled`：重跑同一条操作指令以续传，沿用原目标和记录，不清空目标、不创建第二项。`-Status`、`NextAction` 及后台行为待 v1/move 合入。
- 复制期间用户文件变化会自动补拷，最多 3 轮；仍变化时请用户暂时停止修改该文件夹后续传。微信、QQ 始终需退出。
- `Done`：结合本次操作和 `SourceKept` 判断；搬家完成后，请用户正常使用软件或文件夹一段时间。原件还在时不能说 C 盘已腾出这部分空间。`SkippedLinks` 是正常跳过的链接数量，无需用户处理。
- 用户明确确认使用正常并同意删除保留原件后，再运行释放指令，并同样查询至结束：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\move.ps1" -ReleaseSource -Id "<本次Id>"
  ```

- 试用后目标新增或修改文件正常；释放校验接受 `ChangedAfterMove`，且允许目标缺失的原文件数和字节数分别不超过 2%。这不是让用户选择的容差，不因正常变化要求用户撤销编辑。旧原件有变化或目标缺失过多时会拒绝释放，说明原因并保留数据。
- 释放前用户要还原时，AI 执行 `scripts/move.ps1 -Rollback -Id "<本次Id>"`，继续按 `NextAction` 查询。新位置数据保留；搬家后的新文件或修改须继续保管，不能保证自动合并回旧位置。原件已释放后不能承诺还原。

## 4. 分区：先方案，再二次确认

当 `NextStep=partition` 或用户要求分区时，读 [分区与加密规则](references/partition.md)，普通权限运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\partition.ps1" -Plan
```

1. 读取 `pc-care/partition-plan/1`。向用户用人话展示 `Summary`、`Before/After` 大小变化和 `Warnings`；提醒先备份，同一硬盘不同分区不算备份。`Feasible=false` 则解释 `Blockers` 并停止。
2. 用户要调整用途或盘数时，由 AI 构造 `-Layout` 的布局 JSON 重新规划；不把 JSON 或参数给用户选择。已有合适数据盘时通常直接搬家。
3. `PendingChecks` 是执行前待验证项，不能说已通过，也不为补检查而先提权。执行时脚本会验证；失败须遵从结果。
4. `RequiresRecoveryKeyConfirmation=true`：展示 `RecoveryKeyHint`，补充可在 https://aka.ms/myrecoverykey、打印件、U 盘或保存的文件中找恢复密钥；请用户在聊天中确认能找到。不要要求发送密钥本身，也不代替用户确认。
5. 展示最终方案后，必须得到第二次明确的聊天确认才运行下列执行指令；“想分区”或“帮我看看”不算。恢复密钥确认可与方案二次确认在同一条回复里完成，但两者都须明确。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\partition.ps1" -Apply -PlanPath "<方案绝对路径>"
```

仅在用户已确认能找到密钥时加 `-RecoveryKeyConfirmed`。`NeedsRecoveryKeyConfirmation` 表示尚未改分区，请先问清并在确认后带该开关重跑；若之前从未得到方案二次确认，也必须补齐。C 盘正在加密 / 解密、执行时状态未知、没有恢复密码保护器或无法读取保护器均会阻止压缩；未加密或只使用空闲空间新建分区无需密钥确认。

执行会按需弹 UAC；C 盘保留至少“已用空间 + 60 GB”且不少于 120 GB。脚本先建无盘符分区、格式化，再分配盘符，避免弹出“格式化磁盘”。读取 `pc-care/partition/1`，按实际布局解释结果；成功后重新体检，再逐项搬家。

任何可能已修改布局的失败（包括管理员结果缺失），都不重跑 `-Apply`：先重新 `-Plan`、核实当前布局，说明新方案并再次明确确认。不要自动删除新分区、重新格式化或补做未完成步骤。

## 安全与范围

- 所有路径和动作交给脚本及其白名单重新校验，不凭报告路径自行删除。占用、权限不足、同步目录、无法核实的位置按原因跳过，不夺取所有权、不强行停止程序。
- V1 不处理开发者缓存（npm/pip 等）、WSL、Docker、卷影副本 / 还原点存储、系统保留存储、页面文件、组件存储 / DISM、注册表清理、卸载软件。大软件只报告；不因底层处理器留有旧能力而调用它们。
- 不手删系统目录、软件安装目录、聊天记录、浏览器登录信息或同步文件；搬家只复制并验证允许的数据，释放仅删除本次记录中的保留原件。
- 不移动、合并或删除已有分区，不扩容 C 盘，不低于保留空间压缩，不处理特殊磁盘组合或有数据的其他硬盘。
- 尚未在真实 Windows 上完成验证；Linux 模拟通过不代表真机通过。真实修改流程须先在 Windows 10 / 11 测试环境验证。

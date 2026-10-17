#Requires -Version 7.0
<#
  备份保留策略（BackupRetention）—— 备份会越攒越多，但**绝不因为"目录变大"就删掉唯一能恢复的那份**
  ─────────────────────────────────────────────────────────────────────
  背景：WriteGuard 每次真写都留一份 `.writeguard\<原名>@<来源hash8>.bak-<时间戳>-<tag>`（规矩②）。
        长期使用后目录会变大。这份脚本给出"什么时候可以删、删哪些、怎么删"的**最小纪律**。

  ★ 三条硬规则（不是建议，是代码里的不变量）：
    1. **默认演练**：不加 `-Commit` 就只打印清单，一个字节不删；
    2. **每个目标文件至少留 1 份**（`-KeepLatest` 最小按 1 算）——
       哪怕它已经很老：**唯一的可恢复版本不能因为超龄被删掉**；
    3. 只有**同时**满足「超出最新 N 份」且「超过保留天数」的才进候选。

  ⚠️ **归属是启发式，不是证明**（2026-10-17 外部审计指出）：
     `@hash8` 只保证"不同目录的同名文件不撞名"，它**不能证明**这份备份真的属于那个文件 ——
     一个恰好叫 `笔记@aabbccdd.bak-20240101-090000-a` 的用户文件会被当成备份、按规则清理掉
     （实测：4 份里被删 3 份）。所以 **别把 `-BackupDir` 指向满是用户自命名文件的目录**；
     真正的归属证明要 sidecar 元数据或签名，那是另一个复杂度，本脚本**不做**。
     ⇒ 它只能清理"WriteGuard 自己写出来的东西"，不能当通用垃圾清理器用。

  ⚠️ 它**不**检查审计日志引用了哪些备份。清理会让老审计记录里的 `backup` 字段指向已删除的路径 ——
     这是保留策略的代价。要长期追溯就别删，或者把 `-OlderThanDays` 设得比你的追溯期更久。

  用法：
    pwsh -NoProfile -File .\Prune-Backups.ps1 -BackupDir .\.writeguard                      # 演练
    pwsh -NoProfile -File .\Prune-Backups.ps1 -BackupDir .\.writeguard -Commit              # 真删
    pwsh -NoProfile -File .\Prune-Backups.ps1 -BackupDir .\.writeguard -KeepLatest 10 -OlderThanDays 90
  退出码：0 = 正常（演练或有清理）· 2 = 参数/目录有问题
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)][string]$BackupDir,
  [int]$KeepLatest = 5,
  [int]$OlderThanDays = 30,
  [switch]$Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Say([string]$s = '') { Write-Host $s }

try {
  if (-not [System.IO.Directory]::Exists($BackupDir)) {
    throw "备份目录不存在：$BackupDir（这个目录通常是目标文件旁边的 .writeguard）"
  }
  $keep = [Math]::Max(1, $KeepLatest)   # ★ 硬规则 2：至少留 1 份，参数写 0 也不算数
  $now = Get-Date

  Say ('=' * 74)
  Say '  BackupRetention —— 备份保留策略（默认演练，不删任何东西）'
  Say ('=' * 74)
  Say ("目录：$([System.IO.Path]::GetFullPath($BackupDir))")
  Say ("规则：每个目标文件保留最新 $keep 份，且只清理超过 $OlderThanDays 天的")
  Say '⚠️ 归属靠命名模式判断（启发式）：只清理 WriteGuard 自己写的备份，别拿它清用户文件目录。'
  Say ''

  # 命名：<原名>@<来源hash8>.bak-<yyyyMMdd-HHmmss>-<tag>[-N]
  #   ★ 新格式带 `@来源hash`：不同目录下的同名文件**不会合体**（2026-10-17 修 · 外部审计实测坐实）。
  #   ★ 旧格式（没有 @hash）**无法确定来源** ⇒ 本脚本**不清理它**，只告警 —— 宁可留着，也不猜。
  $rxBak = [regex]'^(?<stem>.+?)\.bak-(?<stamp>\d{8}-\d{6})-'
  $rxKey = [regex]'^(?<orig>.+)@(?<src>[0-9a-f]{8})$'
  $items = New-Object System.Collections.ArrayList
  foreach ($f in @(Get-ChildItem -LiteralPath $BackupDir -File -ErrorAction SilentlyContinue)) {
    $m = $rxBak.Match($f.Name)
    if (-not $m.Success) { continue }
    $stem = $m.Groups['stem'].Value
    $km = $rxKey.Match($stem)
    $hasSource = $km.Success
    $orig = if ($hasSource) { $km.Groups['orig'].Value } else { $stem }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($m.Groups['stamp'].Value, 'yyyyMMdd-HHmmss',
          [System.Globalization.CultureInfo]::InvariantCulture,
          [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
      $d = $f.LastWriteTime
    }
    [void]$items.Add([pscustomobject]@{
      Name = $f.Name; Full = $f.FullName; Orig = $orig; Key = $stem; HasSource = $hasSource
      When = $d; AgeDays = [Math]::Round(($now - $d).TotalDays, 1); Bytes = $f.Length
    })
  }

  if ($items.Count -eq 0) {
    Say '⚠️ 没找到任何符合命名规则的备份（*.bak-<时间戳>-*）—— 确认 -BackupDir 指对了地方'
    exit 0
  }

  # ⚠️ 必须 `@()` 包起来：`Group-Object` 只有**一个分组**时会解包成单个 GroupInfo，
  #    它的 `.Count` 是"该组的备份份数"而不是"目标数" ⇒ 文案会说谎（实测：2 份备份同属一个文件，
  #    打印"分属 2 个目标"，表格却只有 1 行）。2026-10-17 外部审计抓到。
  $groups = @($items | Group-Object -Property Key)
  Say ("共 {0} 份备份，分属 {1} 个目标" -f $items.Count, $groups.Count)
  Say ''
  Say ('{0,-30} {1,6} {2,8} {3,10}' -f '目标文件', '份数', '可清理', '最早(天)')
  Say ('-' * 74)

  $plan = New-Object System.Collections.ArrayList
  $legacyCount = 0
  foreach ($g in ($groups | Sort-Object Name)) {
    $sorted = @($g.Group | Sort-Object -Property When -Descending)
    if (-not $sorted[0].HasSource) {
      $legacyCount += $sorted.Count
      Say ('{0,-30} {1,6} {2,8}   ⚠️ 旧命名（无法确定来源）' -f $sorted[0].Orig, $sorted.Count, 0)
      continue
    }
    # ★ 硬规则 3：跳过最新 N 份；再要求超龄
    $inLatest = @($sorted | Select-Object -First $keep)
    $rest = @($sorted | Select-Object -Skip $keep)
    $fresh = @($rest | Where-Object { $_.AgeDays -le $OlderThanDays })
    $cand = @($rest | Where-Object { $_.AgeDays -gt $OlderThanDays })
    # ★ 硬规则 2 的兜底：无论上面怎么筛，都不许删到 0 份。
    #   （正常路径下 Skip($keep) 已经保证了；这里是防御 —— 删最老的、留最新的）
    $maxDel = [Math]::Max(0, $sorted.Count - 1)
    if ($cand.Count -gt $maxDel) { $cand = @($cand | Select-Object -Last $maxDel) }
    Say ('{0,-30} {1,6} {2,8} {3,10}' -f $sorted[0].Orig, $sorted.Count, $cand.Count, $sorted[-1].AgeDays)
    # ★ 可解释（外部审计建议）：不只报"可清理几份"，还要说清"**为什么保留**"。
    #   三档原因：在最新 N 内 / 未超龄 / 被兜底救回（后两种不该同时为 0 时又没删光）
    $kept = $sorted.Count - $cand.Count
    if ($kept -gt 0) {
      $why = @()
      if ($inLatest.Count -gt 0) { $why += "$($inLatest.Count) 份在最新 $keep 内" }
      if ($fresh.Count -gt 0) { $why += "$($fresh.Count) 份未超龄" }
      $rescued = $kept - $inLatest.Count - $fresh.Count
      if ($rescued -gt 0) { $why += "$rescued 份被「至少留 1 份」兜底救回" }
      Say ("       ↳ 保留 {0} 份：{1}" -f $kept, ($why -join '、'))
    }
    foreach ($c in $cand) { [void]$plan.Add($c) }
  }
  Say ('-' * 74)
  if ($legacyCount -gt 0) {
    Say ("⚠️ 其中 {0} 份是**旧命名**（没有 @来源hash）：无法判断它们属于哪个文件 ⇒ 一律不删。" -f $legacyCount)
    Say '   要清理它们，先确认真实来源（或直接人工删除）。'
    Say ''
  }

  if ($plan.Count -eq 0) {
    Say ''
    Say '✅ 没有可清理的备份（都在保留期内，或都在最新 N 份里）'
    exit 0
  }

  Say ''
  Say ("候选清理清单（{0} 份，合计 {1:N1} KB）：" -f $plan.Count, (($plan | Measure-Object -Property Bytes -Sum).Sum / 1KB))
  foreach ($p in ($plan | Sort-Object -Property When)) {
    Say ("  {0,-52} {1,6} 天前" -f $p.Name, $p.AgeDays)
  }
  Say ''

  if (-not $Commit) {
    Say '⚠️ 演练：**一个都没删**。确认清单无误后加 -Commit 才会真删。'
    exit 0
  }

  $n = 0
  foreach ($p in $plan) {
    try { [System.IO.File]::Delete($p.Full); $n++ }
    catch { Write-Host ("  删除失败（跳过）：{0} —— {1}" -f $p.Name, $_.Exception.Message) }
  }
  Say ("已删除 {0} 份；每组至少保留 1 份（唯一可恢复版本不会被删掉）" -f $n)
  exit 0
} catch {
  Write-Host "⚠️ 跑不起来（退出码 2）：$($_.Exception.Message)"
  exit 2
}

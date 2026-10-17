<#
  WriteGuard 0.1.0 ── 「写操作五规矩」的可复用函数库（PowerShell 7+）
  ────────────────────────────────────────────────────────────────────────
  干什么：把"一个脚本要**替人改文件**"时的五条规矩，做成**一套可复用的护栏**：

    ① 默认不开   ⇒ `Invoke-WgWrite -Commit` 是**显式开关**；不传 = 只演练（DryRun），一个字节都不写。
    ② 原样备份   ⇒ 写盘**之前**按原始字节备份（`Backup-WgSnapshot`），写完还读回来核对哈希。
    ③ 只改白名单 ⇒ 用 `Set-WgUniqueSpan` / `Set-WgJsonScalar`，**唯一匹配才改**；
                    0 处或多处匹配都**拒绝**（"不猜"）；`-MaxChangedLines` 再兜一层改动面上限。
    ④ 读回复验   ⇒ 写完**重新读磁盘**比对文本 + BOM 状态，并跑调用方给的 `-Verify` 断言。
    ⑤ 失败回滚   ⇒ 复验不过 ⇒ 按备份字节还原 —— 但**回滚之前先核对目标**：
                     还是写前那一份 ⇒ 写入没生效，无需恢复；
                     还是本次写进去的那一份（`Sha256After`）⇒ 按备份还原；
                     **两个都不是**（这期间别人插进来改过）⇒ 报 `RollbackRefused`，**拒绝覆盖更新的数据**；
                     **回滚本身失败** ⇒ 单独报 `RollbackFailed`（不装成功）。

  外加两条本项目用血换来的规矩（写进 §5 的坑）：
    · **"没算出来" ≠ "没问题"** —— 复验脚本抛异常一律算**失败**，绝不静默放过。
    · **算差异 / 做清理的循环必须能报出失败** —— 库内部一律 `try/catch` + 结构化结果，
      不靠"看着像执行了"（我们曾因此出现"清理看着跑了、计数一条没少"）。

  设计取舍（诚实写在前面）：
    · 只处理**文本文件**；二进制请直接用 `Backup-WgSnapshot` + `Restore-WgSnapshot`。
    · `ChangedLines` 用的是**同索引逐行比较**（保守算法）：插入一行会让其后所有行都算"变了"。
      ⇒ 它**不会漏报**，但可能**多报**；多报的后果是"拒绝写入"，不是"越界改坏"，这是刻意的偏向。
    · 编码默认 UTF-8（有无 BOM 都按原样保留）；其它编码用 `-Encoding gb2312` 这类名字显式指定。
    · 需要 PowerShell 7+（本机 7.6.6）。Windows PowerShell 5.1 未验证（5.1 读脚本要 BOM，见坑 #23/#65）。

  用法见同目录 README.md；自带自测 `tests\SelfTest.ps1`（零依赖，退出码 0/1/2）。
#>

Set-StrictMode -Version Latest

$script:WgVersion = '0.1.6'

# ───────────────────────── 内部工具（不导出） ─────────────────────────

function Get-WgHash {
  param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $h = $sha.ComputeHash($Bytes)
    return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
}

function Resolve-WgCaseInsensitive {
  <# 三态解析"是否按不区分大小写处理"：显式传入优先，否则按平台。
     ⚠️ 这是**平台策略假设**，不是普遍保证：macOS 可以是大小写不敏感、Windows 也有大小写敏感目录
        （per-directory case sensitivity）。所以"非 Windows ⇒ 敏感"只是默认值，调用方可以显式覆盖。
     抽成一处，是为了让这条假设**只有一份**，且能被测试直接注到两边。 #>
  [CmdletBinding()]
  param([Nullable[bool]]$CaseInsensitive)
  if ($null -ne $CaseInsensitive) { return [bool]$CaseInsensitive }
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Get-WgPathKey {
  <# 路径归一化键 —— "这是不是同一个文件"的唯一判定基准。
     -CaseInsensitive 显式可注入（默认按平台）：**这样 Windows 上也能测 Unix 语义**，
     不必等一台 Linux 机器才能验证另一条分支（外部审计 2026-10-17 建议）。
     ⚠️ 用途有两处：备份来源 hash（`Backup-WgSnapshot`）与批量重复路径检测（`Invoke-WgBatch`）。
     ⚠️ **但光有它不够**：批量那边用字典装键，而 PowerShell 的 `@{}` **默认不区分大小写**，
        会在敏感策略下把两个不同的键当成同一个 ⇒ 那边必须用显式比较器的字典（2026-10-17 外部审计指出）。 #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [Nullable[bool]]$CaseInsensitive = $null
  )
  $ci = Resolve-WgCaseInsensitive -CaseInsensitive $CaseInsensitive
  if ($ci) { return $Path.ToLowerInvariant() }
  return $Path
}

function New-WgEncoding {
  # $HasBom 只影响"写盘时要不要 BOM"；读的时候我们自己剥 BOM（见 Get-WgSnapshot）
  # $Strict：**读**时要求"无效字节 ⇒ 报错"，绝不静默替换成 U+FFFD（�）——
  #   替换式解码会把损坏**原样写回磁盘**（外部审计 2026-10-17 指出的编码风险）。
  param([string]$Name = 'auto', [bool]$HasBom = $false, [bool]$Strict = $false)
  if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq 'auto' -or $Name -ieq 'utf8' -or $Name -ieq 'utf-8') {
    return [System.Text.UTF8Encoding]::new($HasBom, $Strict)
  }
  try {
    if ($Strict) {
      return [System.Text.Encoding]::GetEncoding($Name, [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback)
    }
    return [System.Text.Encoding]::GetEncoding($Name)
  } catch { throw "不认识的编码名 '$Name'（$($_.Exception.Message)）⇒ 显式指定 -Encoding 或先转成 UTF-8" }
}

function Get-WgProp {
  # ⚠️ 别用 `.ContainsKey()`：OrderedDictionary 没这个方法，异常会被 Continue 静默吞掉（坑 #22）。
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $null
}

function Get-WgLineDiff {
  # ⚠️ 先**剥公共前后缀**，再对中间段做同索引比较 —— 否则"插入一行"会让其后所有行都算"变了"，
  #    改动面虚高 ⇒ `-MaxChangedLines` 会把**合法改动误判成越界**（本库自测真踩到过：插 2 行报 4 行）。
  #    与 Get-WgDiffText 同一口径（预览与计数必须一致，否则报告会自相矛盾）。
  #    仍然是**保守**的：中间段内部只做同索引比较 ⇒ 不会漏报，可能多报。
  param([AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
  $lo = @($Old -split "`r?`n")
  $ln = @($New -split "`r?`n")
  $pre = 0
  while ($pre -lt $lo.Count -and $pre -lt $ln.Count -and $lo[$pre] -ceq $ln[$pre]) { $pre++ }
  $suf = 0
  while ($suf -lt ($lo.Count - $pre) -and $suf -lt ($ln.Count - $pre) -and
         $lo[$lo.Count - 1 - $suf] -ceq $ln[$ln.Count - 1 - $suf]) { $suf++ }
  $changed = New-Object System.Collections.ArrayList
  # ★ 中间段：先试「纯插入 / 纯删除」（我们的用法几乎全是这类）。
  #   ⚠️ 不做这层的话，在**文件前部**插入几行会让中间段一路延伸到文件末尾（同索引比较全线错位）⇒
  #      改动面虚高 ⇒ `-MaxChangedLines` **误拒**（外部审计 P2 点出的"误拒过多"，本库自测当场应验：
  #      改 README 第 8 行的状态行，报出 228 行"改动"）。
  $midLo = New-Object System.Collections.ArrayList
  for ($i = $pre; $i -lt ($lo.Count - $suf); $i++) { [void]$midLo.Add($lo[$i]) }
  $midLn = New-Object System.Collections.ArrayList
  for ($i = $pre; $i -lt ($ln.Count - $suf); $i++) { [void]$midLn.Add($ln[$i]) }
  $isSub = {
    param($short, $long)
    if ($short.Count -eq 0) { return $true }
    if ($short.Count -gt $long.Count) { return $false }
    for ($s = 0; $s -le ($long.Count - $short.Count); $s++) {
      $ok = $true
      for ($j = 0; $j -lt $short.Count; $j++) { if ($long[$s + $j] -cne $short[$j]) { $ok = $false; break } }
      if ($ok) { return $true }
    }
    return $false
  }
  if ((& $isSub $midLo $midLn) -or (& $isSub $midLn $midLo)) {
    $maxN = [Math]::Max($midLo.Count, $midLn.Count)
    for ($i = 0; $i -lt $maxN; $i++) { [void]$changed.Add($pre + $i + 1) }
  } else {
    $maxMid = [Math]::Max($midLo.Count, $midLn.Count)
    for ($i = 0; $i -lt $maxMid; $i++) {
      $oi = $pre + $i
      $a = if ($i -lt $midLo.Count) { $midLo[$i] } else { $null }
      $b = if ($i -lt $midLn.Count) { $midLn[$i] } else { $null }
      if ($a -cne $b) { [void]$changed.Add($oi + 1) }   # 行号按**改动前**的文件坐标
    }
  }
  return [pscustomobject]@{ ChangedLines = @($changed); LineDelta = ($ln.Count - $lo.Count) }
}

function Get-WgDiffText {
  <#
    「看得见」：生成改动预览 —— 先剥掉公共前后缀，只显示**真正变了的那一段** + 3 行上下文。
    ⚠️ 与 Get-WgLineDiff 同一个口径（同索引比较）⇒ 它**只会多报、不会漏报**；
       多报的代价是预览长一点，而不是"看着没事、其实改了"。
  #>
  param(
    [AllowEmptyString()][string]$Old,
    [AllowEmptyString()][string]$New,
    [int]$Context = 3,
    [string]$Header = ''
  )
  $lo = @($Old -split "`r?`n")
  $ln = @($New -split "`r?`n")
  $pre = 0
  while ($pre -lt $lo.Count -and $pre -lt $ln.Count -and $lo[$pre] -ceq $ln[$pre]) { $pre++ }
  $suf = 0
  while ($suf -lt ($lo.Count - $pre) -and $suf -lt ($ln.Count - $pre) -and
         $lo[$lo.Count - 1 - $suf] -ceq $ln[$ln.Count - 1 - $suf]) { $suf++ }

  $out = New-Object System.Collections.ArrayList
  if ($Header) { [void]$out.Add("@ $Header") }
  for ($i = [Math]::Max(0, $pre - $Context); $i -lt $pre; $i++) {
    [void]$out.Add(('  {0,5} | {1}' -f ($i + 1), $lo[$i]))
  }
  # ⚠️ 这里**刻意不用** `$x = if (...) { @($arr[a..b]) } else { @() }` ——
  #    if 语句的输出流会把**单元素数组展开成标量** ⇒ StrictMode 下 `$x.Count` 当场报错。
  #    （与"pipeline 展开嵌套数组"是同一族坑；这一处是本次扩功能时**被自测抓到的**。）
  $oldMid = New-Object System.Collections.ArrayList
  if (($lo.Count - $suf - 1) -ge $pre) {
    for ($i = $pre; $i -le ($lo.Count - $suf - 1); $i++) { [void]$oldMid.Add($lo[$i]) }
  }
  $newMid = New-Object System.Collections.ArrayList
  if (($ln.Count - $suf - 1) -ge $pre) {
    for ($i = $pre; $i -le ($ln.Count - $suf - 1); $i++) { [void]$newMid.Add($ln[$i]) }
  }
  $maxMid = [Math]::Max($oldMid.Count, $newMid.Count)
  for ($i = 0; $i -lt $maxMid; $i++) {
    $a = if ($i -lt $oldMid.Count) { $oldMid[$i] } else { $null }
    $b = if ($i -lt $newMid.Count) { $newMid[$i] } else { $null }
    if ($a -ceq $b) { [void]$out.Add(('  {0,5} | {1}' -f ($pre + $i + 1), $a)) }
    else {
      if ($null -ne $a) { [void]$out.Add(('- {0,5} | {1}' -f ($pre + $i + 1), $a)) }
      if ($null -ne $b) { [void]$out.Add(('+ {0,5} | {1}' -f ($pre + $i + 1), $b)) }
    }
  }
  $tailEnd = [Math]::Min($ln.Count, $ln.Count - $suf + $Context)
  for ($i = $ln.Count - $suf; $i -lt $tailEnd; $i++) {
    [void]$out.Add(('  {0,5} | {1}' -f ($i + 1), $ln[$i]))
  }
  return ($out -join "`n")
}

# ───────────────────────── 公开 API ─────────────────────────

function Get-WgInfo {
  <# 库的自述：版本 + 五规矩 → 供自测 / 交接件 / 自证清单引用 #>
  [CmdletBinding()]
  param()
  return [pscustomobject]@{
    Name    = 'WriteGuard'
    Version = $script:WgVersion
    Rules   = @(
      '① 默认不开：-Commit 才写，不传 = DryRun',
      '② 原样备份：写盘前按原始字节备份，写完读回核对',
      '③ 只改白名单：唯一匹配才改，0/多处匹配一律拒绝',
      '④ 读回复验：重新读磁盘比对文本 + BOM，并跑调用方 -Verify',
      '⑤ 失败回滚：复验不过即按备份字节还原；回滚失败单独报'
    )
  }
}

function Get-WgSnapshot {
  <# 读文件快照：原始字节 + BOM 判定 + 换行风格 + 文本 + SHA256（"写前状态"的唯一凭据） #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [string]$Encoding = 'auto'
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not [System.IO.File]::Exists($full)) {
    return [pscustomobject]@{
      Path = $full; Exists = $false; Bytes = $null; Length = 0
      HasBom = $false; NewLine = "`n"; Text = $null; Encoding = $Encoding; Sha256 = $null
    }
  }
  $bytes = [System.IO.File]::ReadAllBytes($full)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  # ⚠️ 两种 UTF-16 BOM 都要挡（外部审计 2026-10-17：原实现只挡了 LE，**BE 漏了**）
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    throw "只支持 UTF-8 / 单字节编码：'$full' 检测到 UTF-16LE BOM ⇒ 先转码或显式指定编码"
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    throw "只支持 UTF-8 / 单字节编码：'$full' 检测到 UTF-16BE BOM ⇒ 先转码或显式指定编码"
  }
  try {
    # ★ 严格解码：无效字节 ⇒ 报错（绝不静默替换成 � 再写回去）
    $text = (New-WgEncoding -Name $Encoding -HasBom $false -Strict $true).GetString($bytes)
  } catch {
    throw "文件不是合法的 $Encoding 编码（含无效字节）：'$full' ⇒ 显式指定 -Encoding，或先转码再改（本库拒绝把损坏写回去）"
  }
  # ★★ 往返保真闸门（外部审计建议）：Decode → Encode 必须逐字节回到原样。
  #   严格解码只挡"无效字节"；这道闸门还挡"能解码、但再编码就变了"的编码错配
  #   （典型：GBK 文件配缺省 UTF-8 —— 中文会变成 � 且读不回来）。
  #   ⇒ 合法搭配（UTF-8+utf8 / GBK+gb2312）往返自洽、不误伤。
  # ⚠️ 必须**先剥 BOM 再验往返**：否则 U+FEFF 会被重新编码成 BOM，与"去 BOM 的原始体"不等
  #    （本库自测当场抓到：带 BOM 的 UTF-8 文件被误判成"编码不自洽"）
  if ($hasBom -and $text.Length -ge 1 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
  $bodyStart = if ($hasBom) { 3 } else { 0 }
  $round = (New-WgEncoding -Name $Encoding -HasBom $false).GetBytes($text)
  $bodyLen = $bytes.Length - $bodyStart
  $sameRound = ($round.Length -eq $bodyLen)
  if ($sameRound) {
    for ($i = 0; $i -lt $bodyLen; $i++) {
      if ($round[$i] -ne $bytes[$bodyStart + $i]) { $sameRound = $false; break }
    }
  }
  if (-not $sameRound) {
    throw "编码往返不自洽（解码后再编码 ≠ 原始字节）：'$full' ⇒ 该文件多半不是 $Encoding 编码，请显式指定 -Encoding（例如 gb2312）"
  }
  $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  return [pscustomobject]@{
    Path = $full; Exists = $true; Bytes = $bytes; Length = $bytes.Length
    HasBom = $hasBom; NewLine = $nl; Text = $text; Encoding = $Encoding; Sha256 = (Get-WgHash $bytes)
  }
}

function Backup-WgSnapshot {
  <# 按**原始字节**备份（规矩②）。返回备份文件路径；写完立刻读回核对哈希，对不上就抛。 #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]$Snapshot,
    [string]$BackupDir,
    [string]$Tag = 'wguard'
  )
  if (-not (Get-WgProp $Snapshot 'Exists')) { throw '快照标记"文件原本不存在" ⇒ 无法备份（也拒绝凭空新建）' }
  $srcPath = [string](Get-WgProp $Snapshot 'Path')
  $dir = if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    Join-Path ([System.IO.Path]::GetDirectoryName($srcPath)) '.writeguard'
  } else { $BackupDir }
  if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $safeTag = ($Tag -replace '[^\w\-]', '_')
  $name = [System.IO.Path]::GetFileName($srcPath)
  # ★ 来源标识（2026-10-17 修 · 外部审计实测坐实）：备份名里**必须带来源**，
  #   否则不同目录下的同名文件在同一个备份目录里会"合体"——Prune-Backups 按文件名分组时
  #   把它们当成同一个目标，"每组至少留 1 份"就只保住了一份，另一个目标的历史备份会被当垃圾清掉
  #   （实测：两个 config.json 各 3 份备份，清理后 A 源剩 0 份、B 源剩 3 份）。
  #   用**完整路径的小写**取 8 位 SHA256：同一文件的多次备份同组，不同目录的同名文件不同组。
  $shaSrc = [System.Security.Cryptography.SHA256]::Create()
  try {
    # ⚠️ 只在该平台**路径不区分大小写**时才归一化（Windows）：C:\A\x 与 c:\a\x 是同一个文件。
    #    Linux/macOS 上 /home/A/x 与 /home/a/x 是两个**真实不同**的文件 —— 归一化会把它们算成同一来源，
    #    等于在 Unix 上重新制造"合体误删"（外部审计指出，2026-10-17）。
    #    平台判断收敛到 Get-WgPathKey（可注入），不在这里再写一套。
    $keyPath = Get-WgPathKey -Path $srcPath
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($keyPath)
    $srcKey = [System.BitConverter]::ToString($shaSrc.ComputeHash($keyBytes)).Replace('-', '').Substring(0, 8).ToLowerInvariant()
  } finally { $shaSrc.Dispose() }
  $cand = Join-Path $dir "$name@$srcKey.bak-$stamp-$safeTag"
  $i = 1
  # ⚠️ 冲突分支**同样要带 @来源hash** —— 漏掉它的话，同一秒内的第二份备份会落成旧命名，
  #    然后被 Prune-Backups 的"旧命名一律不删"永久保住（永远清不掉）。2026-10-17 修。
  while ([System.IO.File]::Exists($cand)) { $cand = Join-Path $dir "$name@$srcKey.bak-$stamp-$safeTag-$i"; $i++ }
  $bytes = [byte[]](Get-WgProp $Snapshot 'Bytes')
  [System.IO.File]::WriteAllBytes($cand, $bytes)
  if ((Get-WgHash ([System.IO.File]::ReadAllBytes($cand))) -ne [string](Get-WgProp $Snapshot 'Sha256')) {
    throw "备份写入后读回不一致 ⇒ 备份不可信：$cand"
  }
  return $cand
}

function Restore-WgSnapshot {
  <# 按备份**原始字节**还原（规矩⑤）。还原后读回核对哈希；核不上就抛（不装成功）。 #>
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)]$Snapshot)
  if (-not (Get-WgProp $Snapshot 'Exists')) { throw '快照标记"文件原本不存在" ⇒ 拒绝还原（避免误删文件），请人工处理' }
  $path = [string](Get-WgProp $Snapshot 'Path')
  $bytes = [byte[]](Get-WgProp $Snapshot 'Bytes')
  [System.IO.File]::WriteAllBytes($path, $bytes)
  if ((Get-WgHash ([System.IO.File]::ReadAllBytes($path))) -ne [string](Get-WgProp $Snapshot 'Sha256')) {
    throw "还原后读回字节与备份不一致 ⇒ 还原失败：$path"
  }
  return $path
}

function New-WgSnapshotFromBackup {
  <# 用**本次提交前的备份文件**构造一个可还原的快照。
     外部审计 2026-10-17（问题 A）的修复核心：批次回滚**不能**再用"演练阶段"那份快照 ——
     演练与提交之间若被第三方改过，拿旧快照还原会把第三方的更新一起抹掉。
     回滚凭据必须绑定到**实际提交前**的那一份字节，而它正好就在这次提交自己的备份里。 #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][string]$BackupPath,
    [Parameter(Mandatory, Position = 1)][string]$TargetPath
  )
  if (-not [System.IO.File]::Exists($BackupPath)) { throw "本次提交的备份不在了 ⇒ 无法安全还原：$BackupPath" }
  $bytes = [System.IO.File]::ReadAllBytes($BackupPath)
  return [pscustomobject]@{
    Path   = [System.IO.Path]::GetFullPath($TargetPath)
    Exists = $true
    Bytes  = $bytes
    Length = $bytes.Length
    Sha256 = (Get-WgHash $bytes)
  }
}

function Assert-WgUniqueMatch {
  <# 规矩③的地基：目标必须**唯一**。0 处或多处匹配都抛（"不猜"）。返回那个唯一的 Match。 #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory, Position = 1)][string]$Pattern,
    [string]$What = '目标',
    [System.Text.RegularExpressions.RegexOptions]$Options = [System.Text.RegularExpressions.RegexOptions]::Multiline
  )
  $ms = @([regex]::Matches($Text, $Pattern, $Options))
  if ($ms.Count -eq 0) { throw "定位不到$What（正则：$Pattern）⇒ 拒绝写入（不猜）" }
  if ($ms.Count -gt 1) { throw "$What 匹配到 $($ms.Count) 处（正则：$Pattern）⇒ 目标不唯一，拒绝写入（不猜）" }
  return $ms[0]
}

function Set-WgUniqueSpan {
  <# 规矩③：**唯一匹配才替换**，且只动匹配到的那一段**文本**。
     ⚠️ 这不等于"其余原始字节原样"（2026-10-18 外部审计 P0 指出的措辞过强）：
        本函数是**字符串**操作（Remove/Insert），字节保真依赖"解码 → 匹配 → 编码"往返自洽 + BOM 保留
        （由 Get-WgSnapshot 的往返闸门与 HasBom 兜底）。只在库支持且往返自洽的编码上成立；
        任意编码下的字节级保证需要**字节级 span** 实现（ROADMAP H 项，尚未做）。
        当前的 ㊿f 测的是：在支持的编码上，未修改区域的字节确实一致（证据到此为止，别外推）。 #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory, Position = 1)][string]$Pattern,
    [string]$Replacement = '',
    [scriptblock]$ReplacementScript,
    [string]$What = '目标',
    [System.Text.RegularExpressions.RegexOptions]$Options = [System.Text.RegularExpressions.RegexOptions]::Multiline
  )
  $m = Assert-WgUniqueMatch -Text $Text -Pattern $Pattern -What $What -Options $Options
  $rep = $Replacement
  if ($ReplacementScript) {
    $v = & $ReplacementScript $m
    if ($null -eq $v) { throw "$What：ReplacementScript 返回 `$null ⇒ 拒绝替换（不猜）" }
    $rep = [string]$v
  }
  return $Text.Remove($m.Index, $m.Length).Insert($m.Index, $rep)
}

function Set-WgJsonScalar {
  <#
    规矩③的 JSON 版：**只改那一行**，绝不 `ConvertTo-Json` 整份重写
    （整份重写会重排键序 / 改缩进 / 动转义 —— 其余条目就不再"逐字节不变"了）。
    字段不存在时：给了 -InsertAfter 才插（插在那一行之后，并处理逗号）；没给 ⇒ 抛。
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory, Position = 1)][string]$Field,
    [AllowNull()]$Value,
    [string]$InsertAfter,
    [switch]$AsNumber,
    [string]$Indent = '  '
  )
  # ⚠️ 值一律交给 **JSON 序列化器**（外部审计 2026-10-17 指出的真缺陷：手工拼接的转义不完整 ——
  #    那行 `-replace '\\','\\'` 其实等于没做，`C:\temp` 会被写成 `"C:\temp"`，其中 `\t` 变成制表符）
  $valText = ConvertTo-Json -InputObject $(if ($AsNumber) { $Value } else { [string]$Value }) -Compress
  # 两处出口共用：改完**必须仍是合法 JSON**，否则拒绝（别交出一个坏文件）
  $finalize = {
    param([string]$txt)
    try { [void]($txt | ConvertFrom-Json) }
    catch { throw "替换后会得到非法 JSON ⇒ 拒绝写入（不猜）：$($_.Exception.Message)" }
    return $txt
  }
  $esc = [regex]::Escape($Field)
  # ⚠️ 换行风格必须**跟原文件一致**：否则"只改一行"会顺带把整份文件的 CRLF 全换成 LF
  $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($l in @($Text -split "`r?`n")) { $lines.Add($l) }

  $hit = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ([regex]::IsMatch($lines[$i], '^\s*"' + $esc + '"\s*:')) { $hit += $i }
  }
  if ($hit.Count -gt 1) { throw "JSON 字段 '$Field' 在文本里出现 $($hit.Count) 次 ⇒ 不唯一，拒绝写入（不猜）" }

  if ($hit.Count -eq 1) {
    $i = $hit[0]
    # 只替换该行的值部分：保留缩进与冒号后的空格风格
    # 严格词法：字符串（**含转义**）· 布尔 · null · 数字（审计：原正则漏了转义串/布尔/null）
    $linePat = '("' + $esc + '"\s*:\s*)("(?:[^"\\]|\\.)*"|true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)'
    $newLine = [regex]::Replace($lines[$i], $linePat, { param($m) $m.Groups[1].Value + $valText }, 1)
    if ($newLine -ceq $lines[$i] -and $lines[$i] -cnotmatch [regex]::Escape($valText)) {
      throw "字段 '$Field' 找到了，但值部分没匹配上（格式不认识）⇒ 拒绝写入（不猜）：$($lines[$i].Trim())"
    }
    $lines[$i] = $newLine
    return (& $finalize ($lines -join $nl))
  }

  # 字段不存在 ⇒ 只有显式给了 InsertAfter 才插
  if ([string]::IsNullOrWhiteSpace($InsertAfter)) {
    throw "JSON 里没有字段 '$Field'，且未指定 -InsertAfter ⇒ 不知道插哪儿，拒绝写入（不猜）"
  }
  $escA = [regex]::Escape($InsertAfter)
  $anchors = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ([regex]::IsMatch($lines[$i], '^\s*"' + $escA + '"\s*:')) { $anchors += $i }
  }
  if ($anchors.Count -eq 0) { throw "找不到锚点字段 '$InsertAfter' ⇒ 拒绝写入（不猜）" }
  if ($anchors.Count -gt 1) { throw "锚点字段 '$InsertAfter' 出现 $($anchors.Count) 次 ⇒ 不唯一，拒绝写入（不猜）" }
  $ai = $anchors[0]
  # ⚠️ 逗号是这里唯一的"语法陷阱"：锚点后面还有成员（原行末尾有逗号）⇒ **新行也得带逗号**，
  #    否则会插出 `..., "a": 1` 换行 `"b": 2` 这种非法 JSON（本库自测就抓到过这一条）。
  $hadComma = $lines[$ai].TrimEnd().EndsWith(',')
  $anchorLine = $lines[$ai].TrimEnd()
  if (-not $hadComma) { $anchorLine += ',' }     # 锚点行后面现在一定有新行了 ⇒ 补逗号
  $lines[$ai] = $anchorLine
  $ind = ([regex]::Match($lines[$ai], '^[ \t]*')).Value
  if ([string]::IsNullOrEmpty($ind)) { $ind = $Indent }
  $newLine = $ind + '"' + $Field + '": ' + $valText
  if ($hadComma) { $newLine += ',' }
  $lines.Insert($ai + 1, $newLine)
  return (& $finalize ($lines -join $nl))
}

function Resolve-WgSingleTarget {
  <# 规矩③/清单⑪：目标必须唯一。0 个或多于 1 个候选都抛（"不猜"）。 #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Candidates,
    [string]$What = '目标'
  )
  $c = @($Candidates)
  if ($c.Count -eq 0) { throw "没有任何$What 候选 ⇒ 失败，不猜" }
  if ($c.Count -gt 1) { throw "$What 候选有 $($c.Count) 个 ⇒ 不唯一，失败，不猜" }
  return $c[0]
}

function Select-WgUniqueLatest {
  <# 按 key 取最新（如"文件名里的时间戳"，**不用 mtime** —— 复制/同步都会改它）；同 key 多个 ⇒ 抛。 #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Candidates,
    [Parameter(Mandatory, Position = 1)][scriptblock]$KeyScript,
    [string]$What = '候选'
  )
  $pairs = New-Object System.Collections.ArrayList
  foreach ($x in @($Candidates)) {
    $k = & $KeyScript $x
    if ($null -eq $k) { continue }        # key 解析不出来 = 不合格候选，跳过（不是"猜"）
    [void]$pairs.Add([pscustomobject]@{ Item = $x; Key = [string]$k })
  }
  if ($pairs.Count -eq 0) { throw "$What 里没有 key 可解析的候选 ⇒ 失败，不猜" }
  $sorted = @($pairs | Sort-Object -Property Key -Descending)
  $top = $sorted[0].Key
  $same = @($sorted | Where-Object { $_.Key -eq $top })
  if ($same.Count -gt 1) { throw "$What 里 key=$top 有 $($same.Count) 个 ⇒ 不唯一，失败，不猜" }
  return $same[0].Item
}

function Invoke-WgWriteCore {
  <#
    一次受护栏保护的文件改写（内核）。**五条规矩全在里面**。
    Mutator（必填）：`param($snap)`，用 $snap.Text / $snap.NewLine 算出新文本；
                    返回 字符串 | @{Text=...;Note=...} | **$null（= 放弃，不写）**；抛异常也算拒绝。
    Verify（可选）  ：`param($textAfter,$path)`，返回问题清单（空/$null = 通过）；**抛异常一律算失败**。
    返回结构化结果：Status / Path / Backup / Note / ChangedLines / LineDelta / DiffText /
                    Sha256Before / Sha256After / VerifyIssues / Wrote / AuditPath / AuditError。
                    ⚠️ Sha256After = **本次写进磁盘的那份内容**的哈希（"写后哈希"）。
                       回滚前用它判定"现在磁盘上的是不是我写的"—— 见规矩⑤。
    Status：Written · NoChange · DryRun · Refused · RolledBack · RollbackRefused · RollbackFailed · Error
                    （每个状态的语义与退出码见 `Get-WgStatusTable` / `Get-WgExitCode`）
    ⚠️ 对外请用 `Invoke-WgWrite`（它是内核 + 审计记录）；这个名字不导出。
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [Parameter(Mandatory, Position = 1)][scriptblock]$Mutator,
    [scriptblock]$Verify,
    [switch]$Commit,
    [string]$Tag = 'wguard',
    [string]$BackupDir,
    [int]$MaxChangedLines = [int]::MaxValue,
    [int]$MaxDiffLines = 200,
    # ★ 并发协调：Commit 时对目标加独占文件锁（`<目标>.wglock`），挡住"另一个进程正写同一文件"。
    #   默认关 —— 加锁会多一次文件操作、崩死时可能残留锁文件，这两条代价不该强加给所有调用方。
    [switch]$Lock,
    [string]$Encoding = 'auto'
  )
  $res = [ordered]@{
    Status       = 'Error'
    Path         = [System.IO.Path]::GetFullPath($Path)
    Backup       = $null
    Note         = ''
    ChangedLines = @()
    LineDelta    = 0
    DiffText     = ''
    Sha256Before = $null
    Sha256After  = $null
    VerifyIssues = @()
    Wrote        = $false
    Committed    = [bool]$Commit
    AuditPath    = $null
    AuditError   = ''
  }

  # ── 并发协调（可选）：在 Commit 路径上对目标加独占锁 ──
  #   锁的是"写前复核 → 写入 → 读回 → 失败回滚"这一整段（ROADMAP 说的那个真实窗口）。
  #   ⚠️ 只在 -Commit 时加锁：不 Commit 就**一个字节都不碰**（连锁文件也不建）。
  $lockHandle = $null
  $lockPath = $null
  if ($Lock -and $Commit) {
    $lockPath = [System.IO.Path]::GetFullPath($res.Path) + '.wglock'
    $acquired = $false
    for ($attempt = 1; $attempt -le 2 -and -not $acquired; $attempt++) {
      try {
        $lockHandle = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
          [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $acquired = $true
      } catch {
        # 陈旧锁：本库一次写入是毫秒级，超过 120 秒还能占着锁的，基本可以断定持有者已经不在了
        $stale = $false
        try { $stale = (((Get-Date) - [System.IO.File]::GetLastWriteTime($lockPath)).TotalSeconds -gt 120) }
        catch { $stale = $true }
        if ($stale -and $attempt -eq 1) {
          try { [System.IO.File]::Delete($lockPath) } catch { }   # 接管一次，下一轮再抢
        } else {
          $res.Status = 'Refused'
          $res.Note = "另一个进程正在写这个文件（锁：$lockPath）⇒ 本次拒绝写入（并发保护）。" +
                      "确认没有别的进程在写时，删掉这个锁文件即可重试。"
          return [pscustomobject]$res
        }
      }
    }
  }

  try {
    $snap = Get-WgSnapshot -Path $res.Path -Encoding $Encoding
    $res.Sha256Before = $snap.Sha256
    if (-not $snap.Exists) {
      $res.Status = 'Refused'; $res.Note = "文件不存在：$($res.Path) ⇒ 拒绝写入（本库不新建文件）"
      return [pscustomobject]$res
    }

    # ── Mutator：拿新文本；返回 $null = 主动放弃 ──
    $r = $null
    try { $r = & $Mutator $snap }
    catch {
      $res.Status = 'Error'; $res.Note = "Mutator 抛异常（未改任何文件）：$($_.Exception.Message)"
      return [pscustomobject]$res
    }
    if ($null -eq $r) {
      $res.Status = 'Refused'; $res.Note = 'Mutator 返回 $null（定位不到 / 主动放弃）⇒ 未改任何文件'
      return [pscustomobject]$res
    }
    $newText = $null
    if ($r -is [string]) { $newText = $r }
    else {
      $t = Get-WgProp $r 'Text'
      if ($null -eq $t) { $res.Status = 'Error'; $res.Note = 'Mutator 返回的对象里没有 Text 字段 ⇒ 拒绝写入'; return [pscustomobject]$res }
      $newText = [string]$t
      $n = Get-WgProp $r 'Note'; if ($n) { $res.Note = [string]$n }
    }

    # ── 幂等：内容没变 ⇒ 不写、不备份 ──
    # ⚠️ 必须用 **-ceq**（大小写敏感）：PowerShell 的 -eq 对字符串**不区分大小写**，
    #    写成 -eq 时"只改大小写"会被判成"内容没变" ⇒ 静默返回 NoChange、把修改丢掉
    #    （2026-10-17 使用者发现，已复现：'Hello World' → 'hello world' 报 NoChange）。
    if ($newText -ceq $snap.Text) {
      $res.Status = 'NoChange'; $res.Wrote = $false
      if (-not $res.Note) { $res.Note = '内容与现状一致 ⇒ 本次不写盘（幂等）' }
      return [pscustomobject]$res
    }

    # ── 改动面（保守算法：只会多报，不会漏报）──
    $diff = Get-WgLineDiff -Old $snap.Text -New $newText
    $res.ChangedLines = @($diff.ChangedLines); $res.LineDelta = [int]$diff.LineDelta
    # ── 「看得见」：默认就把改动预览算出来（内存里，不改任何文件）──
    if ($res.ChangedLines.Count -le $MaxDiffLines) {
      $res.DiffText = Get-WgDiffText -Old $snap.Text -New $newText -Header ([System.IO.Path]::GetFileName($res.Path))
    } else {
      $res.DiffText = "（改动面 $($res.ChangedLines.Count) 行 > MaxDiffLines $MaxDiffLines ⇒ 预览省略；改动行号：$($res.ChangedLines -join '、')）"
    }
    if ($res.ChangedLines.Count -gt $MaxChangedLines) {
      $res.Status = 'Refused'
      $res.Note = "改动面 $($res.ChangedLines.Count) 行 > 上限 $MaxChangedLines ⇒ 拒绝写入（越界保护，未改任何文件）"
      return [pscustomobject]$res
    }

    # ── ① 默认不开：没有 -Commit 就到此为止 ──
    if (-not $Commit) {
      $res.Status = 'DryRun'
      if (-not $res.Note) { $res.Note = '演练（未传 -Commit）：已算出改动面，**未写盘、未备份**' }
      return [pscustomobject]$res
    }

    # ── ② 版本保护（外部审计 2026-10-17 建议）：**写之前再读一次**，确认"还是快照的那一份" ──
    #    ⚠️ 哈希复核只能**缩小** TOCTOU 竞争窗口，不能消除它；不一致时**拒绝覆盖别人的改动**。
    $recheck = Get-WgSnapshot -Path $res.Path -Encoding $Encoding
    if ($recheck.Sha256 -ne $snap.Sha256) {
      $res.Status = 'Refused'
      $res.Note = '文件在快照之后被改动过（写前哈希复核不一致）⇒ 拒绝覆盖，请重新计算变更（TOCTOU 保护）'
      return [pscustomobject]$res
    }

    # ── ③ 备份 + 写盘 + 复验：**备份之后的一切都纳入统一事务保护** ──
    #    （外部审计 P0-1：原实现里"写入抛异常"或"读回抛异常"会直落外层 catch ⇒
    #      文件可能已被截断/改写，却只返回 Error、不做恢复）
    $res.Backup = Backup-WgSnapshot -Snapshot $snap -BackupDir $BackupDir -Tag $Tag
    try {
      [System.IO.File]::WriteAllText($res.Path, $newText, (New-WgEncoding -Name $snap.Encoding -HasBom $snap.HasBom))
      $res.Wrote = $true
      # 写后哈希：外部审计 2026-10-17 的两条（P1「加写后哈希」/ P0「回滚前核对是不是我写的」）用**同一份凭据**。
      # ⚠️ 必须**写盘后立刻**算：写入若抛异常，这个值保持 $null，由 catch 里退化成"以第一次观察到的残留为准"。
      $res.Sha256After = Get-WgHash ([System.IO.File]::ReadAllBytes($res.Path))

      # ── ④ 读回复验：重新读磁盘，不看内存里的字符串 ──
      $issues = New-Object System.Collections.ArrayList
      $after = Get-WgSnapshot -Path $res.Path -Encoding $Encoding
      # ⚠️ **-cne**（大小写敏感）：-ne 会把"读回大小写不符"也当成一致，复验就形同虚设
      if ($after.Text -cne $newText) { [void]$issues.Add('读回文本与写入文本不一致') }
      if ($after.HasBom -ne $snap.HasBom) { [void]$issues.Add("BOM 状态变了（写前 $($snap.HasBom) → 写后 $($after.HasBom)）") }
      if ($Verify) {
        try {
          $vr = & $Verify $after.Text $res.Path
          foreach ($v in @($vr)) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { [void]$issues.Add([string]$v) } }
        } catch {
          # ⚠️ 复验跑不起来 ⇒ **算失败**（"没算出来" ≠ "没问题"）
          [void]$issues.Add("复验脚本抛异常（按失败处理）：$($_.Exception.Message)")
        }
      }
      if ($issues.Count -gt 0) {
        $res.VerifyIssues = @($issues)
        throw "WG-VERIFY-FAIL|$($issues -join '；')"
      }
      $res.Status = 'Written'
      $n = if ($res.Note) { "$($res.Note) · " } else { '' }
      $res.Note = "$($n)已写入 $($res.ChangedLines.Count) 行 · 读回复验一致 · 备份 $(Split-Path -Leaf $res.Backup)"
      return [pscustomobject]$res
    } catch {
      # ── ⑤ 统一恢复：只要可能动过文件，就先核对现状，再决定恢复 ──
      $why = $_.Exception.Message
      $verifyFail = $why.StartsWith('WG-VERIFY-FAIL|')
      if ($verifyFail) { $why = $why.Substring('WG-VERIFY-FAIL|'.Length) }

      $changed = $true
      # 现状哈希：读不出来 ⇒ $null（后面按"判不了"处理，比乱猜保守）
      $nowHash = $null
      try { $nowHash = [string](Get-WgSnapshot -Path $res.Path -Encoding $Encoding).Sha256 } catch { $nowHash = $null }
      $changed = ($null -eq $nowHash -or $nowHash -ne [string]$snap.Sha256)
      if (-not $changed) {
        $res.Status = 'Error'
        $res.Note = "事务中失败，但**目标文件与快照逐字节一致**（写入未生效）⇒ 无需恢复：$why"
        return [pscustomobject]$res
      }

      # ② 写入过程本身就抛异常（拿不到写后哈希）⇒ 把"此刻第一次观察到的残留"当作我们的痕迹。
      #    这样"写坏了半截"仍会被还原（保住原有能力），而"期间第三方插进来"仍由 ③ 挡住。
      if ($null -eq $res.Sha256After) { $res.Sha256After = $nowHash }

      # ③ ★ 回滚前核对"现在这份到底是不是我写的"（外部审计 2026-10-17 P0-3）
      #    既不是写前那份、也不是我写的 ⇒ 一定有第三方在中间改过 ⇒ **拒绝回滚**，
      #    绝不拿旧备份去覆盖别人更新的数据（那会把"没救回来"变成"又毁一份"）。
      if ($null -eq $nowHash -or $nowHash -ne [string]$res.Sha256After) {
        $nowShown = if ($null -eq $nowHash) { '（读不出来）' } else { $nowHash }
        $mineShown = if ($null -eq $res.Sha256After) { '（无）' } else { $res.Sha256After }
        $res.Status = 'RollbackRefused'
        $res.Note = "复验未通过（$why），但**回滚前发现目标已被改动**：当前 $nowShown ≠ 本次写入的 $mineShown" +
                    " ⇒ **拒绝回滚**（按备份覆盖会毁掉这期间别人写进去的内容）。备份留着：$($res.Backup)；请人工核对后处置。"
        return [pscustomobject]$res
      }

      try {
        # ⚠️ 元验证 M3 的锚点就是这一行：**全文件只能出现一次**（以后改动时别复制这一行）
        [void](Restore-WgSnapshot -Snapshot $snap)
        $res.Status = 'RolledBack'; $res.Wrote = $false
        $res.Note = "$(if ($verifyFail) { '复验未通过' } else { '写入或复验过程异常' }) ⇒ **已按备份字节回滚**（$why）"
      } catch {
        $res.Status = 'RollbackFailed'; $res.Wrote = $true
        $res.Note = "复验未通过**且回滚失败**：$($_.Exception.Message) ⇒ 请手工用备份还原：$($res.Backup)"
      }
      return [pscustomobject]$res
    }
  } catch {
    $res.Status = 'Error'
    $res.Note = "**写入尚未开始**的未预期失败（文件应未改动）：$($_.Exception.Message)"
    return [pscustomobject]$res
  } finally {
    # ★ 无论成功 / 抛异常 / 提前 return，锁都要放（不然下一次写入会被自己的残留锁挡住）
    if ($null -ne $lockHandle) {
      try { $lockHandle.Dispose() } catch { }
      try { if ([System.IO.File]::Exists($lockPath)) { [System.IO.File]::Delete($lockPath) } } catch { }
    }
  }
}

function Invoke-WgWrite {
  <#
    对外入口 = 内核（`Invoke-WgWriteCore`）+ **审计记录**。
    -Audit    ：把这次操作记进**默认审计日志**（目标文件同目录 `.writeguard\audit.jsonl`）
    -AuditLog ：自定义审计日志路径（传了它就等于开了审计）
    ⚠️ 审计**默认不开** —— 保持"不传 -Commit 就一个字节都不动"的干净语义；
       审计日志写失败**不改变**主操作结果，但会记进结果的 `AuditError`（失败要报出来）。
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [Parameter(Mandatory, Position = 1)][scriptblock]$Mutator,
    [scriptblock]$Verify,
    [switch]$Commit,
    [string]$Tag = 'wguard',
    [string]$BackupDir,
    [int]$MaxChangedLines = [int]::MaxValue,
    [int]$MaxDiffLines = 200,
    [switch]$Audit,
    [string]$AuditLog,
    # ★ 强制审计（ROADMAP G 项）：审计写不进去 ⇒ 这次写入**不算数**，按备份还原（状态 AuditBlocked）。
    #   刻意做成**开关而不是默认**：改默认会悄悄改变所有既有调用方的语义。
    [switch]$StrictAudit,
    # ★ 并发协调：见内核里的说明。默认关。
    [switch]$Lock,
    # ★ 审计轮转（ROADMAP H 项 P1）：主日志超过这个字节数就先归档成 audit-<时间戳>.jsonl，
    #   主文件重新开始 ⇒ 读当前日志的代价有界。0 = 不轮转。
    [int]$MaxAuditBytes = 5242880,
    [string]$Encoding = 'auto'
  )
  $res = Invoke-WgWriteCore -Path $Path -Mutator $Mutator -Verify $Verify -Commit:$Commit -Tag $Tag `
    -BackupDir $BackupDir -MaxChangedLines $MaxChangedLines -MaxDiffLines $MaxDiffLines -Lock:$Lock -Encoding $Encoding

  # ⚠️ **只在真要写盘时才落审计** —— 否则"传 -Audit 但不传 -Commit"会在目标目录建
  #    `.writeguard\audit.jsonl`，破掉规矩①"不传 -Commit 就一个字节都不动"
  #    （外部审计 2026-10-17 抓到的破口）。
  if ($res.Committed -and ($Audit -or -not [string]::IsNullOrWhiteSpace($AuditLog))) {
    $ap = if (-not [string]::IsNullOrWhiteSpace($AuditLog)) { $AuditLog }
          else { Join-Path ([System.IO.Path]::GetDirectoryName([string]$res.Path)) '.writeguard\audit.jsonl' }
    try {
      # 外部审计 P1「审计日志增强」：补**操作 ID · 写后哈希 · 恢复状态**三个字段 ——
      # 出事后要能回答"这是哪一次操作、我们写进去的是什么、最后怎么处置的"。
      $opId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
      $recovery = switch ([string]$res.Status) {
        'RolledBack'      { 'rolled-back' }
        'RollbackRefused' { 'rollback-refused' }
        'RollbackFailed'  { 'rollback-failed' }
        default           { 'none' }
      }
      $apFull = [System.IO.Path]::GetFullPath($ap)
      $apDir = [System.IO.Path]::GetDirectoryName($apFull)
      if (-not [System.IO.Directory]::Exists($apDir)) { [void][System.IO.Directory]::CreateDirectory($apDir) }
      # ★ 轮转（ROADMAP H 项 P1 · 实测 647 B/条 ⇒ 每天 200 次就是 45 MB/年，且 Get-WgAudit 整文件读入）
      #   超过上限就把主文件归档为 audit-<时间戳>.jsonl，主文件重新开始 ⇒ **读当前日志的代价有界**。
      #   ⚠️ 轮转失败**不该**让这次写入作废（归档是维护动作，不是审计内容本身），只记 AuditError。
      if ($MaxAuditBytes -gt 0 -and [System.IO.File]::Exists($apFull)) {
        try {
          if ([System.IO.FileInfo]::new($apFull).Length -ge $MaxAuditBytes) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $arch = Join-Path $apDir "audit-$stamp.jsonl"
            $n = 1
            while ([System.IO.File]::Exists($arch)) { $arch = Join-Path $apDir "audit-$stamp-$n.jsonl"; $n++ }
            [System.IO.File]::Move($apFull, $arch)
          }
        } catch {
          $res.AuditError = "审计轮转失败（不影响本次写入，主日志继续追加）：$($_.Exception.Message)"
        }
      }
      $rec = [ordered]@{
        ts           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        opId         = $opId
        tool         = "WriteGuard/$($script:WgVersion)"
        status       = [string]$res.Status
        path         = [string]$res.Path
        sha256Before = [string]$res.Sha256Before
        sha256After  = [string]$res.Sha256After
        recovery     = $recovery
        changedLines = @($res.ChangedLines)
        lineDelta    = [int]$res.LineDelta
        backup       = [string]$res.Backup
        tag          = $Tag
        committed    = [bool]$res.Committed
        verifyIssues = @($res.VerifyIssues)
        note         = [string]$res.Note
      }
      [System.IO.File]::AppendAllText($apFull, (($rec | ConvertTo-Json -Compress -Depth 6) + "`n"), [System.Text.UTF8Encoding]::new($false))
      $res.AuditPath = $apFull
    } catch {
      $auditWhy = $_.Exception.Message
      if (-not $StrictAudit) {
        # 默认：审计失败**不改变**主操作结果，但必须报出来（不静默吞掉）
        $res.AuditError = "审计日志写不进去（主操作不受影响）：$auditWhy"
      } else {
        # ★ 严格审计：审计是硬要求 ⇒ 这次写入作废，按**本次提交的备份**还原。
        #   回滚前仍核对"现在这份是不是我写的"（规矩⑤）—— 期间被第三方改过就拒绝回滚。
        $res.AuditError = "严格审计：$auditWhy"
        $nowHash = $null
        try { $nowHash = (Get-WgHash ([System.IO.File]::ReadAllBytes([string]$res.Path))) } catch { $nowHash = $null }
        if ($null -eq $nowHash -or $nowHash -ne [string]$res.Sha256After) {
          $res.Status = 'RollbackRefused'
          $res.Note = "严格审计：审计写不进去（$auditWhy），且回滚前发现目标已被改动 ⇒ **拒绝回滚**。请人工核对后用备份处置：$($res.Backup)"
        } else {
          try {
            $snap2 = New-WgSnapshotFromBackup -BackupPath ([string]$res.Backup) -TargetPath ([string]$res.Path)
            [void](Restore-WgSnapshot -Snapshot $snap2)
            $res.Status = 'AuditBlocked'
            $res.Committed = $false
            $res.Note = "严格审计：审计记录写不进去（$auditWhy）⇒ 写入作废，已按备份还原（文件回到写前状态）"
          } catch {
            $res.Status = 'RollbackFailed'
            $res.Note = "严格审计：审计失败**且回滚失败** ⇒ 请人工用备份还原：$($res.Backup)（$($_.Exception.Message)）"
          }
        }
      }
    }
  }
  return $res
}

function Get-WgAudit {
  <#
    读回审计日志（JSONL）→ 对象数组。**解析不出来就抛**（"没算出来" ≠ "没问题"）：
    日志被改过 / 写坏了一半，必须让人看见，而不是静默跳过那一行。
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [int]$Tail = 20
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not [System.IO.File]::Exists($full)) { throw "找不到审计日志：$full ⇒ 这次还没开过 -Audit / -AuditLog？" }
  $rows = New-Object System.Collections.ArrayList
  $n = 0
  foreach ($l in [System.IO.File]::ReadAllLines($full, [System.Text.Encoding]::UTF8)) {
    $n++
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    try { [void]$rows.Add(($l | ConvertFrom-Json)) }
    catch { throw "审计日志第 $n 行不是合法 JSON ⇒ 日志被改过或写坏了（不猜）：$($_.Exception.Message)" }
  }
  if ($rows.Count -eq 0) { return @() }
  if ($Tail -gt 0 -and $rows.Count -gt $Tail) { return @($rows[($rows.Count - $Tail)..($rows.Count - 1)]) }
  return @($rows)
}

function Invoke-WgBatch {
  <#
    「多文件原子」：一组改动的**事务**。
      ① 先**全部演练**（一个字节都不写）—— 任何一项不能安全执行 ⇒ **整批拒绝**；
      ② 传了 -Commit 才逐项真写；**任何一项失败 ⇒ 把本次已经写过的文件按备份字节全部回滚**；
      ③ 全成 ⇒ `Committed`；全都不需要改 ⇒ `NoChange`（幂等）。
    Plan：数组，每项 `@{ Path=...; Mutator={...}; Verify={...}; Tag=... }`（Path / Mutator 必填）。
    返回：BatchStatus · Note · Items（逐项结果）· Wrote · RollbackIssues。
    BatchStatus：Committed · AllDryRun · NoChange · Refused · RolledBack · RollbackRefused · RollbackFailed · Error
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Plan,
    [switch]$Commit,
    [string]$BackupDir,
    [int]$MaxChangedLines = [int]::MaxValue,
    [int]$MaxDiffLines = 200,
    [switch]$Audit,
    [string]$AuditLog,
    # ★ 透传给每一项（2026-10-17 补，外部审计指出"批量没接这两个开关"）：
    #   -Lock：每项各自加锁；某一项抢不到锁 ⇒ 该项 Refused ⇒ 走既有的整批回滚路径。
    #   -StrictAudit：某一项审计写不进去 ⇒ 该项 AuditBlocked ⇒ 同样走整批回滚。
    #   ⚠️ 批量的语义是**沿用既有的"一项失败 ⇒ 整批回退"**，不是新增一套。
    [switch]$StrictAudit,
    [switch]$Lock,
    [Nullable[bool]]$CaseInsensitive = $null,
    [string]$Encoding = 'auto'
  )
  $out = [ordered]@{
    BatchStatus     = 'Error'
    Note            = ''
    Items           = @()
    Wrote           = 0
    RollbackIssues  = @()
    DriftedPlans    = @()
    Committed       = [bool]$Commit
  }
  try {
    $items = @($Plan)
    if ($items.Count -eq 0) {
      $out.BatchStatus = 'Refused'; $out.Note = 'Plan 是空的 ⇒ 没有可做的事（拒绝，不猜）'
      return [pscustomobject]$out
    }
    foreach ($it in $items) {
      $p = [string](Get-WgProp $it 'Path')
      $mu = Get-WgProp $it 'Mutator'
      if ([string]::IsNullOrWhiteSpace($p) -or $null -eq $mu) {
        $out.BatchStatus = 'Refused'; $out.Note = 'Plan 里有一项缺 Path 或 Mutator ⇒ 整批拒绝（不猜），未改任何文件'
        return [pscustomobject]$out
      }
    }

    # ── 外部审计（2026-10-17）：**重复目标路径必须整批拒绝** ──
    #    同一文件被两项改两次时，"回滚到批次开始前"的语义会含糊（按索引恢复快照会互相覆盖）。
    #    ⚠️ 2026-10-17 外部审计指出：**光归一化 key 不够** —— PowerShell 的 `@{}` 默认**不区分大小写**，
    #       敏感策略下两个不同的键仍会被 ContainsKey 当成同一个 ⇒ 误判"重复目标"。
    #       ⇒ 必须用**显式比较器**的字典，策略与 key 归一化用同一个（Resolve-WgCaseInsensitive）。
    $ciMode = Resolve-WgCaseInsensitive -CaseInsensitive $CaseInsensitive
    $pathCmp = if ($ciMode) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $seenPaths = [System.Collections.Generic.Dictionary[string, bool]]::new($pathCmp)
    foreach ($it in $items) {
      $full = [System.IO.Path]::GetFullPath([string](Get-WgProp $it 'Path'))
      $key = Get-WgPathKey -Path $full -CaseInsensitive $ciMode
      if ($seenPaths.ContainsKey($key)) {
        $out.BatchStatus = 'Refused'
        $out.Note = "Plan 里有两项指向同一个文件（$full）⇒ 整批拒绝（重复目标会让回滚语义含糊），未改任何文件"
        return [pscustomobject]$out
      }
      $seenPaths[$key] = $true
    }

    # ── 阶段 1：全部演练（不写、不备份）──
    $snaps = New-Object System.Collections.ArrayList
    $dry = New-Object System.Collections.ArrayList
    foreach ($it in $items) {
      $p = [string](Get-WgProp $it 'Path')
      # ⚠️ 这一份**不是回滚凭据**！它只是"演练基准"：用来事后判断某项在演练之后有没有被动过。
      #    回滚凭据必须是**本次提交自己的备份**（见阶段 2 的失败处理）—— 外部审计 2026-10-17 问题 A。
      [void]$snaps.Add((Get-WgSnapshot -Path $p -Encoding $Encoding))
      $tg = Get-WgProp $it 'Tag'; if (-not $tg) { $tg = 'wg-batch' }
      [void]$dry.Add((Invoke-WgWrite -Path $p -Mutator (Get-WgProp $it 'Mutator') -Verify (Get-WgProp $it 'Verify') `
            -Tag ([string]$tg) -BackupDir $BackupDir -MaxChangedLines $MaxChangedLines -MaxDiffLines $MaxDiffLines -Encoding $Encoding))
    }
    $out.Items = @($dry)
    $bad = @($dry | Where-Object { $_.Status -notin @('DryRun', 'NoChange') })
    if ($bad.Count -gt 0) {
      $why = @($bad | ForEach-Object { [System.IO.Path]::GetFileName([string]$_.Path) + '：' + [string]$_.Status })
      $out.BatchStatus = 'Refused'
      $out.Note = "演练阶段有 $($bad.Count) 项不能安全执行（$($why -join '；')）⇒ **整批拒绝，一个文件都没动**"
      return [pscustomobject]$out
    }
    if (@($dry | Where-Object { $_.Status -eq 'NoChange' }).Count -eq $dry.Count) {
      $out.BatchStatus = 'NoChange'; $out.Note = '整批内容都与现状一致 ⇒ 一个字节都没写（幂等）'
      return [pscustomobject]$out
    }
    if (-not $Commit) {
      $out.BatchStatus = 'AllDryRun'
      $out.Note = "演练完成：$($dry.Count) 项都可安全执行（**未写盘、未备份**）"
      return [pscustomobject]$out
    }

    # ── 阶段 2：逐项真写；任一失败 ⇒ 回滚本次已写的 ──
    $done = New-Object System.Collections.ArrayList
    $drift = New-Object System.Collections.ArrayList   # 演练之后被改动过的项（演练预览已过时）
    $failAt = -1; $failWhy = ''
    for ($i = 0; $i -lt $items.Count; $i++) {
      $it = $items[$i]
      $tg = Get-WgProp $it 'Tag'; if (-not $tg) { $tg = 'wg-batch' }
      $r = Invoke-WgWrite -Path ([string](Get-WgProp $it 'Path')) -Mutator (Get-WgProp $it 'Mutator') `
        -Verify (Get-WgProp $it 'Verify') -Commit -Tag ([string]$tg) -BackupDir $BackupDir `
        -MaxChangedLines $MaxChangedLines -MaxDiffLines $MaxDiffLines -Audit:$Audit -AuditLog $AuditLog `
        -StrictAudit:$StrictAudit -Lock:$Lock -Encoding $Encoding
      [void]$done.Add($r)
      # ★ 问题 A 顺带暴露的一个真实信号：某项在**演练之后、提交之前**被改过
      #   ⇒ 调用方看到的演练预览对它就过时了。这里**只记录、不拒绝**（写入安全由写前复核兜着）。
      if ($null -ne $snaps[$i] -and [string]$r.Sha256Before -ne [string](Get-WgProp $snaps[$i] 'Sha256')) {
        [void]$drift.Add([System.IO.Path]::GetFileName([string]$r.Path))
      }
      if ($r.Status -notin @('Written', 'NoChange')) {
        $failAt = $i
        $failWhy = [System.IO.Path]::GetFileName([string]$r.Path) + '：' + [string]$r.Status + '（' + [string]$r.Note + '）'
        break
      }
    }
    $out.Items = @($done)
    $out.DriftedPlans = @($drift)
    if ($failAt -ge 0) {
      $rb = New-Object System.Collections.ArrayList
      $refused = New-Object System.Collections.ArrayList
      $nWritten = 0; $nRolled = 0
      for ($i = 0; $i -lt $done.Count; $i++) {
        if ([string]$done[$i].Status -ne 'Written') { continue }
        $nWritten++
        $fName = [System.IO.Path]::GetFileName([string]$done[$i].Path)
        # ★ 与单文件路径**同一判据**（外部审计同一个 P0：别只修一半）—— 回滚前先看现在这份是不是我写的
        $nowHash = $null
        try { $nowHash = [string](Get-WgSnapshot -Path ([string]$done[$i].Path) -Encoding $Encoding).Sha256 } catch { $nowHash = $null }
        # ★★ 回滚凭据 = **本次提交前**的那一份，不是演练阶段那份（外部审计 2026-10-17 问题 A）：
        #     演练与提交之间文件若被第三方改过，拿旧快照还原会把第三方的更新一起抹掉。
        #     本次提交自己的备份里，装的正是"提交前那一刻"的字节。
        $beforeHash = [string](Get-WgProp $done[$i] 'Sha256Before')
        if ($null -ne $nowHash -and $nowHash -eq $beforeHash) { continue }   # 已回到提交前状态 ⇒ 无需回滚
        if ($null -eq $nowHash -or $nowHash -ne [string](Get-WgProp $done[$i] 'Sha256After')) {
          [void]$refused.Add("$fName（当前 $nowHash ≠ 本次写入的 $(Get-WgProp $done[$i] 'Sha256After')）")
          continue
        }
        try {
          $snapBack = New-WgSnapshotFromBackup -BackupPath ([string](Get-WgProp $done[$i] 'Backup')) `
                                               -TargetPath ([string]$done[$i].Path)
          [void](Restore-WgSnapshot -Snapshot $snapBack); $nRolled++
        } catch { [void]$rb.Add($fName + '：' + $_.Exception.Message) }
      }
      if ($rb.Count -eq 0 -and $refused.Count -eq 0) {
        $out.BatchStatus = 'RolledBack'; $out.Wrote = 0
        $out.Note = "第 $($failAt + 1) 项失败（$failWhy）⇒ **已把本次写过的 $nWritten 个文件按备份字节全部回滚**"
      } elseif ($refused.Count -gt 0) {
        $out.BatchStatus = 'RollbackRefused'; $out.Wrote = $nWritten - $nRolled
        $out.RollbackIssues = @($refused) + @($rb)
        $out.Note = "第 $($failAt + 1) 项失败（$failWhy）；**有 $($refused.Count) 个文件在回滚前已被改动 ⇒ 拒绝回滚**（按备份覆盖会毁掉别人写的内容）：$($refused -join '；')" +
                    $(if ($rb.Count -gt 0) { "；另有 $($rb.Count) 处回滚失败：$($rb -join '；')" } else { '' })
      } else {
        $out.BatchStatus = 'RollbackFailed'; $out.Wrote = $nWritten - $nRolled
        $out.RollbackIssues = @($rb)
        $out.Note = "第 $($failAt + 1) 项失败（$failWhy），且回滚有 $($rb.Count) 处失败：$($rb -join '；')"
      }
      if ($drift.Count -gt 0) {
        $out.Note += " ⚠️ 另有 $($drift.Count) 个文件在**演练之后**被改动过（$($drift -join '、')）⇒ 本次演练预览对它们已过时。"
      }
      return [pscustomobject]$out
    }
    $out.Wrote = @($done | Where-Object { [string]$_.Status -eq 'Written' }).Count
    $out.BatchStatus = 'Committed'
    $out.Note = "整批提交：$($out.Wrote) 个文件已写 · $(@($done | Where-Object { [string]$_.Status -eq 'NoChange' }).Count) 项无需改"
    if ($drift.Count -gt 0) {
      $out.Note += " ⚠️ 有 $($drift.Count) 个文件在**演练之后**被改动过（$($drift -join '、')）⇒ 演练预览对它们已过时（写入本身按最新内容算，已过写前复核）。"
    }
    return [pscustomobject]$out
  } catch {
    $out.BatchStatus = 'Error'
    $out.Note = "批量执行出错：$($_.Exception.Message) ⇒ 如有已写文件，请用各自备份核对（本库不猜）"
    return [pscustomobject]$out
  }
}

# ───────────── 状态语义表 —— API 语义的**单一事实源**（外部审计 2026-10-17 P1）─────────────
# 病根：状态值散落在代码各处、CLI 退出码每处各写一遍 ⇒ 调用方"没法可靠区分
#      成功 / 拒绝 / 失败 / 恢复失败"，同一个状态在不同地方还可能配不同的退出码。
# 药方：**只写一遍**。文档（README 状态语义表）、命令行门面（wg.ps1）、自测（㊲ 契约断言）
#       都读这张表 ⇒ 加状态却忘了配套，会被自测当场抓住（而不是等上线后被人发现）。
$script:WgStatusTable = [ordered]@{
  'Written'         = @{ Kind = 'Write'; Exit = 0; Meaning = '已写入并复验通过（有备份）' }
  'NoChange'        = @{ Kind = 'Both';  Exit = 0; Meaning = '内容与现状一致 ⇒ 不写盘、不备份（幂等）' }
  'DryRun'          = @{ Kind = 'Write'; Exit = 0; Meaning = '演练：算出改动面与预览，未写盘、未备份' }
  'Committed'       = @{ Kind = 'Batch'; Exit = 0; Meaning = '整批提交：每一项都已写' }
  'AllDryRun'       = @{ Kind = 'Batch'; Exit = 0; Meaning = '整批演练通过：都可安全执行，未写盘' }
  'Refused'         = @{ Kind = 'Both';  Exit = 1; Meaning = '写前主动拒绝（定位不到 / 不唯一 / 越界 / TOCTOU 复核不一致 / 文件不存在 / Plan 非法）—— 文件未动' }
  'RolledBack'      = @{ Kind = 'Both';  Exit = 1; Meaning = '复验未通过 ⇒ 已按备份字节回滚（文件回到写前状态）' }
  'RollbackRefused' = @{ Kind = 'Both';  Exit = 1; Meaning = '回滚前发现目标已被第三方改动 ⇒ **拒绝回滚**（按备份覆盖会毁掉更新的数据）；备份路径在结果里，请人工处置' }
  'RollbackFailed'  = @{ Kind = 'Both';  Exit = 1; Meaning = '复验未通过**且回滚失败** ⇒ 请人工用备份还原' }
  'AuditBlocked'    = @{ Kind = 'Write'; Exit = 1; Meaning = '严格审计（-StrictAudit）：审计记录写不进去 ⇒ 已按备份还原，文件回到写前状态（写入不算数）' }
  'Error'           = @{ Kind = 'Both';  Exit = 1; Meaning = '未预期失败（写入尚未开始 / 目标读不出来）⇒ 原则上文件未改动' }
}

function Get-WgStatusTable {
  <# 状态语义表（机器可读）：Status · Kind(Write/Batch/Both) · ExitCode · Meaning。
     文档与命令行门面都读它 ⇒ 语义只维护一处，不会再漂。 #>
  [CmdletBinding()] param()
  return @(
    foreach ($k in $script:WgStatusTable.Keys) {
      $v = $script:WgStatusTable[$k]
      [pscustomobject]@{
        Status   = [string]$k
        Kind     = [string]$v['Kind']
        ExitCode = [int]$v['Exit']
        Meaning  = [string]$v['Meaning']
      }
    }
  )
}

function Get-WgExitCode {
  <# 状态 ⇒ 进程退出码（与 wg.ps1 共用同一张表）。
     0 = 做成或演练（Written / NoChange / DryRun / Committed / AllDryRun）；
     1 = 没做成（Refused / RolledBack / RollbackRefused / RollbackFailed / Error）。
     ⚠️ 未知状态**抛异常**（不猜）—— 出现了新状态却忘了进表，应该当场炸，而不是悄悄返回 0。 #>
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string]$Status)
  if (-not $script:WgStatusTable.Contains($Status)) {
    throw "未知状态「$Status」⇒ 没进 Get-WgStatusTable（不猜退出码）"
  }
  return [int]$script:WgStatusTable[$Status]['Exit']
}

Export-ModuleMember -Function @(
  'Get-WgInfo',
  'Get-WgSnapshot',
  'Backup-WgSnapshot',
  'Restore-WgSnapshot',
  'Assert-WgUniqueMatch',
  'Set-WgUniqueSpan',
  'Set-WgJsonScalar',
  'Resolve-WgSingleTarget',
  'Select-WgUniqueLatest',
  'Get-WgDiffText',
  'Invoke-WgWrite',
  'Invoke-WgBatch',
  'Get-WgAudit',
  'Get-WgStatusTable',
  'Get-WgExitCode'
)

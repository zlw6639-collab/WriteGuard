#Requires -Version 7.0
<#
  WriteGuard 元验证 ── **给自测本身做故障注入**
  ─────────────────────────────────────────────────────────
  为什么要有它（我们自己的清单第 1、2 条）：
    · "检查通过" ≠ "检查有效" —— 一个永远 16/16 全绿的自测，和没有自测，在事故当天是一样的。
    · 所以这里**反向验证自测**：把库按某个规矩**故意改坏**（改在临时副本上，绝不碰真文件），
      再跑一遍自测 —— **它必须报红，而且必须是期望的那一条**。
      如果注入后自测**照样全绿**，说明那条自测是装饰品 ⇒ 报 FAIL。

  三个可能的结论（都明说，不含糊）：
    OK           注入生效，自测按预期报红        ← 我们要的
    GREEN        注入生效，自测**还是全绿**      ← 最坏：自测撒谎
    WRONG-CASE   注入生效，自测红了，但不是期望那条（可能另有覆盖点，需人工看）
    INJECT-MISS  注入点找不到了（库代码改过）    ← 尺子坏了，退出码 2

  用法：
    pwsh -NoProfile -File .\tests\MutationCheck.ps1
    pwsh -NoProfile -File .\tests\MutationCheck.ps1 -WorkDir <你的可写目录>\wg-mutation
  退出码：0 = 全部按预期 · 1 = 有场景没按预期 · 2 = 注入点失效（先修本脚本，别信结论）
#>
[CmdletBinding()]
param(
  [string]$WorkDir,
  [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path $PSScriptRoot -Parent
$srcModule = Join-Path $rootDir 'WriteGuard.psm1'
$selfTest = Join-Path $PSScriptRoot 'SelfTest.ps1'
$script:lines = New-Object System.Collections.ArrayList
function Say([string]$s) { Write-Host $s; [void]$script:lines.Add($s) }

# 每个场景：把库的一处**规矩**改坏，然后指出"自测里哪一条应该因此报红"
# ⚠️ From 是**行首锚定的正则**（`(?m)^…`），不是裸字符串 —— 裸字符串会在"别处出现相同片段"时命中多次，
#    把注入变成静默的隔靴搔痒（本库扩功能时真撞过一次：批量里的 `if (-not $Commit)` 是 4 空格缩进，
#    而裸串 `  if (-not $Commit) {` 会在它里面再命中一次）。
$scenarios = @(
  @{ Id = 'M1'; What = '规矩① 默认不开（把 -Commit 门拆掉）'
     From = '(?m)^    # ── ① 默认不开：没有 -Commit 就到此为止 ──\r?\n    if \(-not \$Commit\) \{'; To = '    if ($false) {'
     Expect = '③ 规矩① 默认不开' }
  @{ Id = 'M2'; What = '规矩② 原样备份（假装备过了）'
     From = '(?m)^    \$res\.Backup = Backup-WgSnapshot -Snapshot \$snap -BackupDir \$BackupDir -Tag \$Tag\s*$'
     To = '    $res.Backup = ''skipped'''
     Expect = '④ 规矩② 正常写' }
  @{ Id = 'M3'; What = '规矩⑤ 失败回滚（只报状态、不还原字节）'
     From = '(?m)^        \[void\]\(Restore-WgSnapshot -Snapshot \$snap\)\s*$'
     To = '        $null = $null'
     Expect = '⑧ 规矩⑤ 复验报问题' }
  @{ Id = 'M4'; What = '规矩③ 唯一性（放松成允许多处匹配）'
     From = '(?m)^  if \(\$ms\.Count -gt 1\) \{ throw'
     To = '  if ($false) { throw'
     Expect = '⑭ 规矩③ 唯一替换' }
  @{ Id = 'M5'; What = 'JSON 插入的尾逗号（漏掉）'
     From = '(?m)^  if \(\$hadComma\) \{ \$newLine \+= '','' \}\s*$'
     To = '  if ($false) { $newLine += '','' }'
     Expect = '⑮ 规矩③ JSON 只改一行' }
  @{ Id = 'M6'; What = '多文件事务（失败时不回滚已写文件）'
     # 2026-10-17：回滚改成"用本次提交的备份构造快照"后，注入点必须跟着代码走（否则就是 INJECT-MISS）
     From = '(?m)^          \[void\]\(Restore-WgSnapshot -Snapshot \$snapBack\); \$nRolled\+\+$'
     To = '          $null = $null'
     Expect = '㉒ 「多文件事务」' }
  @{ Id = 'M7'; What = '审计失败要报出来（静默吞掉）'
     # 2026-10-17：加 -StrictAudit 后这行进了 `if (-not $StrictAudit)` 分支（缩进 6→8）⇒ 注入点跟着代码走
     From = '(?m)^        \$res\.AuditError = "审计日志写不进去'
     To = '        $null = "审计日志写不进去'
     Expect = '⑲ 「失败要报出来」' }
  # ★ 规矩④「读回复验」的显式注入证据（外部审计 2026-10-17 指出：7 个场景里唯独缺它）
  @{ Id = 'M8'; What = '规矩④ 读回复验（把"读回不一致"的判断反过来）'
     From = '(?m)^      if \(\$after\.Text -cne \$newText\) \{ \[void\]\$issues\.Add\(''读回文本与写入文本不一致''\) \}$'
     To = '      if ($after.Text -eq $newText) { [void]$issues.Add(''读回文本与写入文本不一致'') }'
     Expect = '④ 规矩② 正常写' }
  # ★ 「回滚前核对是不是我写的」这条新规矩的注入证据（外部审计 P0-3 的修复，2026-10-17）
  @{ Id = 'M10'; What = '规矩⑤ 回滚前的第三方核对（拆掉"拒绝回滚"这一关）'
     From = '(?m)^      if \(\$null -eq \$nowHash -or \$nowHash -ne \[string\]\$res\.Sha256After\) \{$'
     To = '      if ($false) {'
     Expect = '㉟ 规矩⑤：回滚前目标被第三方改动' }
  # ★ 批量回滚凭据的注入证据（外部审计 2026-10-17 问题 A 的修复）：
  #   把凭据改回"用演练阶段那份旧快照"（= 修复前的 bug 行为）⇒ ㊵ 必须报红。
  @{ Id = 'M11'; What = '批量回滚凭据（改回"拿演练旧快照还原"这个 bug 行为）'
     From = '(?m)^          \[void\]\(Restore-WgSnapshot -Snapshot \$snapBack\); \$nRolled\+\+$'
     To = '          [void](Restore-WgSnapshot -Snapshot $snaps[$i]); $nRolled++'
     Expect = '㊵ 批量回滚必须回到' }
  # ★ 大小写敏感的两处注入证据（2026-10-17 使用者发现的 -eq 不敏感问题）：
  #   M12 把"幂等判断"改回 -eq ⇒ ㊶ 必须报红；M13 把"改动行判定"改回 -ne ⇒ ㊷ 必须报红。
  @{ Id = 'M12'; What = '大小写敏感：幂等判断（把 -ceq 改回不敏感的 -eq）'
     From = '(?m)^    if \(\$newText -ceq \$snap\.Text\) \{$'
     To = '    if ($newText -eq $snap.Text) {'
     Expect = '㊶ 大小写敏感：只改大小写也必须真写' }
  @{ Id = 'M13'; What = '大小写敏感：改动行判定（把 -cne 改回不敏感的 -ne）'
     From = '(?m)^      if \(\$a -cne \$b\) \{ \[void\]\$changed\.Add\(\$oi \+ 1\) \}   # 行号按'
     To = '      if ($a -ne $b) { [void]$changed.Add($oi + 1) }   # 行号按'
     Expect = '㊷ 大小写敏感：diff 预览与改动行计数' }
  # ★ 强制审计（ROADMAP G 项）的注入证据：拆掉"审计失败就作废"这一关 ⇒ ㊸ 必须报红。
  #   注意这也顺带证明 ㊹（对照用例）：M14 下 ㊸ 红、㊹ 绿 —— 开关的两侧都有证据。
  @{ Id = 'M14'; What = '严格审计：拆掉"审计写不进去就作废并回滚"这一关'
     From = '(?m)^      if \(-not \$StrictAudit\) \{$'
     To = '      if ($true) {'
     Expect = '㊸ 严格审计' }
  # ★ 并发协调（ROADMAP G 项）的注入证据：拆掉"加锁"这一关 ⇒ ㊻（锁被占住）必须报红
  @{ Id = 'M15'; What = '并发协调：拆掉"Commit 时加独占锁"这一关'
     From = '(?m)^  if \(\$Lock -and \$Commit\) \{$'
     To = '  if ($false) {'
     Expect = '㊻ -Lock：锁被别人占住' }
  # ★ 备份保留（2026-10-17 修的真误删）的注入证据：
  #   把"按来源分组"退回"按原名分组" ⇒ 两个目录的同名文件会合体 ⇒ ⑥ 必须报红。
  #   这是本脚本第一次改**模块以外**的文件（Target/Test 两个字段就是为此加的）。
  #   ⚠️ 2026-10-17 晚：分组行加了 `@()`（修单分组解包），注入点跟着改 —— 否则 INJECT-MISS。
  @{ Id = 'M16'; What = '备份保留：把分组键从「来源」退回「原名」（同名跨目录会合体、误删）'
     Target = 'Prune-Backups.ps1'
     Test   = 'BackupRetention.ps1'
     From = '(?m)^  \$groups = @\(\$items \| Group-Object -Property Key\)$'
     To = '  $groups = @($items | Group-Object -Property Orig)'
     Expect = '⑥ 两个目录里的同名 config.json' }
  # ★ ⑦（旧命名一律不删）的专属注入 —— 外部审计指出：M16 只证明"分组键退化会被抓"，
  #   而 HasSource 那个 skip 分支删掉的话，只有 ⑦ 自己拦着，元验证层面没有证据。
  @{ Id = 'M17'; What = '备份保留：删掉"旧命名一律不删"这一关（HasSource 判断永假）'
     Target = 'Prune-Backups.ps1'
     Test   = 'BackupRetention.ps1'
     From = '(?m)^    if \(-not \$sorted\[0\]\.HasSource\) \{$'
     To = '    if ($false) {'
     Expect = '⑦ 旧命名' }
  # ★ 审计轮转（ROADMAP H 项 P1）的注入证据：拆掉"超过上限就归档"这一关 ⇒ ㊽ 必须报红
  @{ Id = 'M18'; What = '审计轮转：拆掉"主日志超过上限就归档"这一关'
     From = '(?m)^      if \(\$MaxAuditBytes -gt 0 -and \[System\.IO\.File\]::Exists\(\$apFull\)\) \{$'
     To = '      if ($false) {'
     Expect = '㊽ 审计轮转' }
  # ★ 单分组解包的注入证据（2026-10-17 外部审计抓到）：把 `@()` 去掉 ⇒ ⑨（目标数=表格行数）必须报红
  @{ Id = 'M19'; What = '备份保留：把 Group-Object 的 @() 去掉（单分组解包 ⇒ 文案数字说谎）'
     Target = 'Prune-Backups.ps1'
     Test   = 'BackupRetention.ps1'
     From = '(?m)^  \$groups = @\(\$items \| Group-Object -Property Key\)$'
     To = '  $groups = $items | Group-Object -Property Key'
     Expect = '⑨ 只有一个目标' }
  # ★ 路径键可注入性（2026-10-17）：把注入忽略、永远按平台判断 ⇒ ㊿a 的"敏感"分支必须报红
  #   ⚠️ 2026-10-17 晚：判断挪进了 Resolve-WgCaseInsensitive，注入点跟着改（否则 INJECT-MISS）。
  @{ Id = 'M21'; What = '路径键：忽略 -CaseInsensitive 注入（永远按平台判断）'
     From = '(?m)^  if \(\$null -ne \$CaseInsensitive\) \{ return \[bool\]\$CaseInsensitive \}$'
     To = '  if ($false) { return [bool]$CaseInsensitive }'
     Expect = '㊿a 路径键' }
  # ★ 字典比较器（2026-10-17 外部审计指出）：把显式比较器的字典换回默认 @{}（忽略大小写）
  #   ⇒ 敏感策略下会把两个不同的键当成同一个 ⇒ ㊿b 必须报红
  @{ Id = 'M22'; What = '批量重复检测：把显式比较器的字典换回默认 @{ }（@{} 忽略大小写）'
     From = '(?m)^    \$seenPaths = \[System\.Collections\.Generic\.Dictionary\[string, bool\]\]::new\(\$pathCmp\)$'
     To = '    $seenPaths = @{}'
     Expect = '㊿b 批量重复检测' }
  # ★ 批量透传（2026-10-17）：把传给每一项的 -StrictAudit/-Lock 摘掉 ⇒ ㊿e 必须报红
  #   ⚠️ 2026-10-18 外部审计 P1：原 M23 一次摘两个开关，而 ㊿e 只证明 StrictAudit ⇒ 拆成两条单点注入，
  #      各自对应一条独立用例（M23a → ㊿e1 / M23b → ㊿e2）。一个注入不能同时证明两个开关。
  @{ Id = 'M23a'; What = '批量透传 StrictAudit：只把 -StrictAudit 从内部调用里摘掉'
     From = '(?m)^        -StrictAudit:\$StrictAudit -Lock:\$Lock -Encoding \$Encoding$'
     To = '        -Lock:$Lock -Encoding $Encoding'
     Expect = '㊿e1 批量透传 -StrictAudit' }
  @{ Id = 'M23b'; What = '批量透传 Lock：只把 -Lock 从内部调用里摘掉'
     From = '(?m)^        -StrictAudit:\$StrictAudit -Lock:\$Lock -Encoding \$Encoding$'
     To = '        -StrictAudit:$StrictAudit -Encoding $Encoding'
     Expect = '㊿e2 批量透传 -Lock' }
  # ★ 下面五条补「有测试但没证明测试有效」的空白（2026-10-17 对照表里点出来的）
  @{ Id = 'M24'; What = '备份命名碰撞：补号后缀丢掉来源 hash（回到旧命名）'
     From = '(?m)^  while \(\[System\.IO\.File\]::Exists\(\$cand\)\) \{ \$cand = Join-Path \$dir "\$name@\$srcKey\.bak-\$stamp-\$safeTag-\$i"; \$i\+\+ \}$'
     To = '  while ([System.IO.File]::Exists($cand)) { $cand = Join-Path $dir "$name.bak-$stamp-$safeTag-$i"; $i++ }'
     Expect = '④a 备份命名碰撞' }
  @{ Id = 'M25'; What = 'TOCTOU：拆掉写前哈希复核（允许覆盖别人刚改的内容）'
     From = '(?m)^    if \(\$recheck\.Sha256 -ne \$snap\.Sha256\) \{$'
     To = '    if ($false) {'
     Expect = '㉗ 版本保护' }
  #   ⚠️ ㉛「编码严格」**没有**元验证，而且试过之后确认不该硬造：
  #      严格解码（Get-WgSnapshot 的 -Strict $true）与往返保真检查（round-trip 比对）是**两层**，
  #      只拆一层，另一层仍然会抛 ⇒ 单点注入永远 GREEN。这不是测试弱，恰恰说明它守的是整体行为。
  #      真要覆盖，得同时拆两层 —— 那是"组合注入"，本脚本只做单点。
  @{ Id = 'M27'; What = '越界保护：关掉 -MaxChangedLines 判断'
     From = '(?m)^    if \(\$res\.ChangedLines\.Count -gt \$MaxChangedLines\) \{$'
     To = '    if ($false) {'
     Expect = '⑩ 规矩③ 越界保护' }
  @{ Id = 'M28'; What = 'CLI 退出码：让 Get-WgExitCode 永远返回 0'
     Test = 'CliSmoke.ps1'
     From = '(?m)^  return \[int\]\$script:WgStatusTable\[\$Status\]\[''Exit''\]$'
     To = '  return 0'
     # ⚠️ 红的是 CLI-4 不是 CLI-3：`check` 命令在"重复"时自己 `exit 1`（硬编码），
     #    只有走 `Get-WgExitCode` 的 json/replace 才会被这个注入影响。
     Expect = 'CLI-4 replace' }
  # ★ 不新建文件（2026-10-18 补，第二份审计指出第 12 条标"无专属注入"却没写理由）
  #   拆掉"文件不存在 ⇒ Refused"这一关 ⇒ ⑪ 的 Mutator 返回 'X' 会真的新建文件。
  @{ Id = 'M29'; What = '不新建文件：拆掉"文件不存在 ⇒ Refused"这一关'
     From = '(?m)^    if \(-not \$snap\.Exists\) \{$'
     To = '    if ($false) {'
     Expect = '⑪ 本库不新建文件' }
  # ★ 控制台编码（2026-10-18 补，第二份审计实测）：跨进程捕获若不钉死 UTF-8，
  #   输出断言就依赖宿主代码页（GBK 下 ↳ 变 ?、cp437 下中文全变 ?）。
  #   把函数内"父进程侧钉 UTF-8"摘掉 ⇒ ⑩（敌意控制台下仍可读）必须红。
  @{ Id = 'M30'; What = '控制台编码：摘掉父进程侧的 UTF-8 钉死（输出断言会依赖宿主代码页）'
     Target = 'tests\BackupRetention.ps1'
     Test   = 'BackupRetention.ps1'
     From = '(?m)(?<=^  \$prevEnc = \[Console\]::OutputEncoding\r?\n)  \[Console\]::OutputEncoding = \[System\.Text\.Encoding\]::UTF8$'
     To = '  $null = $null'
     Expect = '⑩ 非 UTF-8 控制台' }
  @{ Id = 'M31'; What = '控制台编码（CLI）：摘掉 CliSmoke 父进程侧的 UTF-8 钉死'
     Target = 'tests\CliSmoke.ps1'
     Test   = 'CliSmoke.ps1'
     From = '(?m)(?<=^  \$prevEnc = \[Console\]::OutputEncoding\r?\n)  \[Console\]::OutputEncoding = \[System\.Text\.Encoding\]::UTF8$'
     To = '  $null = $null'
     Expect = 'CLI-5 非 UTF-8 控制台' }
  # ★ 回滚失败（2026-10-18 审计建议：真实失败路径）：把 RollbackFailed 伪装成 RolledBack
  #   ⇒ ⑧a（回滚本身失败）必须红。
  @{ Id = 'M32'; What = '回滚失败：把 RollbackFailed 伪装成 RolledBack'
     From = '(?m)^        \$res\.Status = ''RollbackFailed''; \$res\.Wrote = \$true$'
     To = '        $res.Status = ''RolledBack''; $res.Wrote = $false'
     Expect = '⑧a 复验失败且回滚本身失败' }
  # ★ 噪声场景（自证清单第 ② 条要求"不该报红的改动必须仍绿"）：只追加一行注释 ⇒ 自测必须**全绿**
  #   ⚠️ 注入点**不要选版本号**（0.1.5→0.1.6 时它当场 INJECT-MISS —— 已踩过一次）；
  #     选一条永远不会变的行：`Set-StrictMode` 只出现一次，加行尾空格对行为零影响。
  @{ Id = 'M9'; What = '只加一个行尾空格（噪声：不许把自测搞红）'
     From = '(?m)^Set-StrictMode -Version Latest$'
     To = 'Set-StrictMode -Version Latest '
     ExpectGreen = $true
     Assert = { param($t) $false } }     # 噪声场景不期望报红；最终判定交给 ExpectGreen（看自测退出码）
)

try {
  if (-not (Test-Path -LiteralPath $srcModule)) { throw "找不到模块：$srcModule" }
  if (-not (Test-Path -LiteralPath $selfTest)) { throw "找不到自测：$selfTest" }
  $work = if ($WorkDir) { $WorkDir } else { Join-Path ([System.IO.Path]::GetTempPath()) ('WriteGuard-mutation-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  [void][System.IO.Directory]::CreateDirectory($work)

  Say "=== WriteGuard 元验证（$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')）==="
  Say "模块：$srcModule"
  Say "工作目录：$work"
  Say ''
  Say '口径：对库的**临时副本**注入故障 → 跑自测 → 必须报红，且必须是期望的那一条。'
  Say ''

  $srcText = [System.IO.File]::ReadAllText($srcModule, [System.Text.Encoding]::UTF8)
  $ok = 0; $bad = 0; $miss = 0

  foreach ($sc in $scenarios) {
    $id = [string]$sc['Id']
    $dir = Join-Path $work $id
    [void][System.IO.Directory]::CreateDirectory($dir)

    # 场景可指定「改哪个文件、跑哪个测试」；默认仍是改模块 + 跑 SelfTest。
    #   Target/Test 是给"模块以外的东西"用的（M16 改 Prune-Backups.ps1、跑 BackupRetention.ps1）。
    $targetRel = if ($sc.ContainsKey('Target')) { [string]$sc['Target'] } else { 'WriteGuard.psm1' }
    $testRel = if ($sc.ContainsKey('Test')) { [string]$sc['Test'] } else { 'SelfTest.ps1' }
    $pkgDir = $null
    $injectText = $srcText
    # ⚠️ 只要 Target **或** Test 不是默认的（psm1 + SelfTest），就得整目录复制 ——
    #    否则"改了 psm1 却跑原始目录的 CliSmoke"会测到没被改的那份。
    if ($targetRel -ne 'WriteGuard.psm1' -or $testRel -ne 'SelfTest.ps1') {
      $pkgDir = Join-Path $dir 'pkg'
      Copy-Item -LiteralPath $rootDir -Destination $pkgDir -Recurse
      $injectText = [System.IO.File]::ReadAllText((Join-Path $pkgDir $targetRel), [System.Text.Encoding]::UTF8)
    }

    $rx = [regex]([string]$sc['From'])
    $hits = $rx.Matches($injectText).Count
    if ($hits -ne 1) {
      $miss++
      Say ("INJECT-MISS  $id  $($sc['What'])")
      Say ("             注入点命中 $hits 次（必须恰好 1 次）⇒ 库代码结构变了，先修本脚本的 From 正则")
      continue
    }
    $to = [string]$sc['To']
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $to }
    $patched = $rx.Replace($injectText, $evaluator, 1)

    $out = Join-Path $dir 'test-stdout.txt'
    if ($null -eq $pkgDir) {
      $modCopy = Join-Path $dir 'WriteGuard.psm1'
      [System.IO.File]::WriteAllText($modCopy, $patched, [System.Text.UTF8Encoding]::new($false))
      $rep = Join-Path $dir 'selftest-report.txt'
      & pwsh -NoProfile -File $selfTest -ModulePath $modCopy -TestDir (Join-Path $dir 'sandbox') -ReportTo $rep *> $out
      $code = $LASTEXITCODE
    } else {
      [System.IO.File]::WriteAllText((Join-Path $pkgDir $targetRel), $patched, [System.Text.UTF8Encoding]::new($false))
      $testPath = Join-Path $pkgDir "tests\$testRel"
      & pwsh -NoProfile -File $testPath *> $out
      $code = $LASTEXITCODE
      $rep = Join-Path $pkgDir ("tests\" + ($testRel -replace '\.ps1$', '-latest.txt'))
    }

    $repText = if (Test-Path -LiteralPath $rep) { [System.IO.File]::ReadAllText($rep, [System.Text.Encoding]::UTF8) } else { '' }
    $expectFail = [bool]($repText -match ('(?m)^FAIL\s+' + [regex]::Escape([string]$sc['Expect'])))

    $expectGreen = [bool]$sc['ExpectGreen']
    if ($expectGreen) {
      if ($code -eq 0) {
        $ok++
        Say ("OK(噪声)      $id  $($sc['What'])")
        Say '              ⇒ 只改注释 / 空行，自测仍全绿（尺子不过敏）'
      } else {
        $bad++
        Say ("FALSE-RED     $id  $($sc['What'])")
        Say "              ⇒ 本该无辜的改动把自测搞红了（退出码 $code）—— 尺子太敏感"
      }
    } elseif ($code -eq 1 -and $expectFail) {
      $ok++
      Say ("OK            $id  $($sc['What'])")
      Say ("              ⇒ 自测确实报红：$($sc['Expect'])")
    } elseif ($code -eq 0) {
      $bad++
      Say ("GREEN         $id  $($sc['What'])")
      Say ("              ⇒ **注入后自测仍然全绿**：这条规矩没有对应的反向验证（自测是装饰品）")
    } else {
      $bad++
      Say ("WRONG-CASE    $id  $($sc['What'])")
      Say ("              ⇒ 自测红了（退出码 $code），但不是期望的「$($sc['Expect'])」；详见 $rep")
    }
  }

  Say ''
  Say ('─' * 60)
  Say "结果：OK $ok · 异常 $bad · 注入失效 $miss（共 $($scenarios.Count) 个场景）"
  $verdict = if ($miss -gt 0) { '⚠️ 有注入点失效 ⇒ 本脚本自己不可信，先修它' }
             elseif ($bad -gt 0) { "❌ 有 $bad 个场景没按预期 ⇒ 自测或库需要补" }
             else { '✅ 全部按预期：每条规矩都有"改坏了会被抓到"的证据' }
  Say "结论：$verdict"
  $exitCode = if ($miss -gt 0) { 2 } elseif ($bad -gt 0) { 1 } else { 0 }
  Say "退出码：$exitCode"

  $reportFile = Join-Path $PSScriptRoot 'MutationCheck-latest.txt'
  $script:lines -join "`r`n" | Set-Content -LiteralPath $reportFile -Encoding UTF8
  Write-Host "报告：$reportFile"

  if (-not $Keep) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  exit $exitCode
} catch {
  Write-Host "⚠️ 元验证跑不起来（退出码 2）：$($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  exit 2
}

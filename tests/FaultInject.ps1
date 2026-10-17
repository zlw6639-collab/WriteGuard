#Requires -Version 7.0
<#
  FaultInject —— 「注入 → 断言 → 还原」的**可参数化骨架**
  ─────────────────────────────────────────────────────────────────────────────
  它回答一个问题：**我怎么证明我的检查器 / 测试不是装饰品？**
  办法：把被测对象**故意改坏**（注入一个已知故障），跑一遍**断言**，看它有没有报红；
  然后**还原**，并逐字节证明"还原到位"。

  能力（都是被真实迁移逼出来的，不是设想）：
    · 目标 / 场景 / 断言 / **场景参数**全部走参数（脚本里没有写死的路径）；
    · `-Prepare`：跑场景前先把工作区摆好（复制整棵目录、升级基线…），并**返回被测对象路径**
      ⇒ 支持"被测对象是一个目录"的场景，不只是单文件；
    · 场景字段 `Patches`：**跨文件、多处**注入（每处都要求命中恰好 1 次）；
    · 补丁可写 `Expand = $true` ⇒ `To` 当**正则模板**展开（`$&` / `$1`，用来表达"把这行复制一份"）；默认是**字面替换**；
    · 补丁可写 `Append = '文本'` ⇒ 追加到文件末尾（噪声注入：只加注释 / 空行）；
    · 场景字段 `Files` + `Mutate`：补丁表达不了的改动（如改 JSON 嵌套字段）交给 `Mutate` 自己做，
      但它改的文件**必须先写进 `Files`** —— 骨架一定把它们还原（这是允许逃生舱的前提）；
      ⚠️ **边界**：还原范围是"被改动 / 被声明过的文件" ⇒ `Mutate` **新建**的文件不会被清掉，
      会污染后续场景（示例 `minimal-checker` 第一版就踩过：一个场景新建的文件让下一个场景误报红）。
      能改成"改现有文件"就别新建；非新建不可时，自己在场景里清掉、或把它写进场景的外部收尾。
    · 注入点命中不是 1 次 ⇒ 报 `INJECT-MISS` 并以退出码 2 结束（**尺子坏了就别信结论**）；
    · 支持**噪声场景**（`ExpectRed = $false`）：故意做一处"不该报警"的改动 ⇒ 它必须**保持绿**；
    · 还原是**逐字节**的、并对哈希（多文件逐个校验）；还原失败 ⇒ 退出码 2；
    · 默认 **Copy 模式**：只对**副本**动手（`-Mode InPlace` 才改真文件，靠快照 + 哈希兜底）。

  用法：
    pwsh -NoProfile -File .\FaultInject.ps1 -Target <被测文件> -ScenariosFile <场景.ps1>
    pwsh -NoProfile -File .\FaultInject.ps1 -Target <文件> -ScenariosFile <场景.ps1> `
         -Prepare { param($work) <摆工作区>; return <被测对象路径> } -ScenarioParams @{ Root = 'D:\别的根' }

  场景文件（`.ps1`，`return` 一个数组；可带 `param(...)` 供 `-ScenarioParams` 换路径）：
    return @(
      @{ Id = 'FI1'; What = '把版本号改坏'
         From = '(?m)^\$Ver = ''1\.0''$'; To = "`$Ver = '9.9'"
         ExpectRed = $true
         Assert = { param($t) & pwsh -NoProfile -File $t *> $null; $LASTEXITCODE -ne 0 } },      # $true = 红
      @{ Id = 'N1'; What = '只加一句注释（噪声：不许报红）'
         From = '(?m)^#region$'; To = "#region`n# 注释"
         ExpectRed = $false
         Patches = @( @{ Path = '另一个文件.ps1'; From = '(?m)^\$X = 1$'; To = '$X = 2' } )          # 可选：跨文件补丁
         Assert = { param($t) & pwsh -NoProfile -File $t *> $null; $LASTEXITCODE -ne 0 } }
    )

  断言契约：`Assert = { param($被测对象路径) ... }`
    · 返回 **`$true` = 报红了** / `$false` = 没报红（骨架拿它跟 `ExpectRed` 比）；
    · 或返回 `@{ Red = <bool>; Issues = @('问题1','问题2') }` —— **Issues 非空即算"不符预期"**。
      ⚠️ 关键词校验这类**硬判据必须放进 Issues**：塞进 bool 里会被静默掉（本骨架迁移时就吃了一次
      "把'符合期望'当成'报红'返回"的亏，8 个场景里 4 个判反）。

  退出码：0 = 全部按预期 · 1 = 有场景不符预期（该红没红 / 不该红却红 / Issues 非空）· 2 = 尺子坏了（命中数不对 / 断言跑不起来 / 还原失败）

  ★ 写场景时的两个坑（**我们真踩过**）：
    · **正则一律用单引号字符串写**：`From = '(?m)^\$Foo = ''bar''$'`。
      双引号里 `$Foo` 会被 PowerShell **插值成空**、`` `$ `` 又要转义，两者一混就会写出"命中 0 次"的**假故障**
      （本骨架会把这种情况报成 `INJECT-MISS`，不给你假结论 —— 但它会耗掉你一轮排查时间）。
    · **行尾锚点 `$` 不要写成 `\$`**：`\$` 在正则里是"字面美元符号"，匹配不到任何东西。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)][string]$Target,
  [Parameter(Mandatory, Position = 1)][string]$ScenariosFile,
  [ValidateSet('Copy', 'InPlace')][string]$Mode = 'Copy',
  [string]$WorkDir,
  [string]$BackupDir,
  [scriptblock]$Prepare,
  [hashtable]$ScenarioParams,
  [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WriteGuard.psm1') -Force

function Prop($o, [string]$n) {
  # ⚠️ 不用 `.ContainsKey()`：OrderedDictionary 上没这个方法，异常会被静默吞掉
  if ($null -eq $o) { return $null }
  if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n)) { return $o[$n] } return $null }
  $p = $o.PSObject.Properties[$n]
  if ($null -ne $p) { return $p.Value }
  return $null
}
function Say([string]$s) { Write-Host $s }
function HashOf([byte[]]$b) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
function Restore-Touched($touched) {
  $bad = @()
  foreach ($k in @($touched.Keys)) {
    $bytes = [byte[]]$touched[$k]
    try {
      [System.IO.File]::WriteAllBytes([string]$k, $bytes)
      if ((HashOf ([System.IO.File]::ReadAllBytes([string]$k))) -ne (HashOf $bytes)) { $bad += [string]$k }
    } catch { $bad += "$k（$($_.Exception.Message)）" }
  }
  return $bad
}

$script:ok = 0; $script:bad = 0; $script:broken = 0
try {
  if (-not (Test-Path -LiteralPath $Target)) { throw "找不到被测文件：$Target" }
  if (-not (Test-Path -LiteralPath $ScenariosFile)) { throw "找不到场景文件：$ScenariosFile" }
  $srcSnap = Get-WgSnapshot -Path $Target

  $work = if ($WorkDir) { $WorkDir } else { Join-Path ([System.IO.Path]::GetTempPath()) ('faultinject-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  [void][System.IO.Directory]::CreateDirectory($work)

  # ── 被测对象：-Prepare 优先（可摆一整棵目录）；否则 Copy 单文件；否则直接动真文件 ──
  if ($Prepare) {
    $subject = [string](& $Prepare $work)
    if ([string]::IsNullOrWhiteSpace($subject)) { throw '-Prepare 没有返回被测对象路径（它必须 return 一个文件路径）' }
  } elseif ($Mode -eq 'Copy') {
    $subject = Join-Path $work ([System.IO.Path]::GetFileName($Target))
    [System.IO.File]::WriteAllBytes($subject, $srcSnap.Bytes)
  } else {
    $subject = $Target
  }
  if (-not (Test-Path -LiteralPath $subject)) { throw "被测对象不存在：$subject" }

  # ── 场景（可带参数 ⇒ 换一套路径仍能跑）──
  # ⚠️ 用 **dot-source** 加载（不是 `&`）：这样场景文件里定义的**辅助函数**会落在骨架的作用域里，
  #    断言 scriptblock 才看得见它们。跨脚本传 scriptblock 时，`&` 加载会让断言报"术语不被识别"
  #    （scriptblock 在执行处的作用域解析命令，看不到原脚本的函数）—— 这是本次迁移实测踩到的。
  #    ⇒ 场景文件里**别用**骨架的内部变量名（$work / $subject / $sc / $patches / $touched），会被覆盖。
  $scenarios = if ($ScenarioParams -and $ScenarioParams.Count -gt 0) { @(. $ScenariosFile @ScenarioParams) } else { @(. $ScenariosFile) }
  if ($scenarios.Count -eq 0) { throw "场景文件返回了空清单：$ScenariosFile" }

  Say "=== FaultInject（$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')）==="
  Say "被测：$Target"
  Say "模式：$Mode ⇒ 实际动手的对象：$subject"
  Say "场景：$($scenarios.Count) 个 · 工作目录：$work"
  Say ''

  foreach ($sc in $scenarios) {
    $id = [string](Prop $sc 'Id'); if (-not $id) { $id = '?' }
    $what = [string](Prop $sc 'What')
    $expectRed = [bool](Prop $sc 'ExpectRed')
    $assert = Prop $sc 'Assert'
    $tag = "$id · $what"

    # 补丁清单：主补丁（默认打在被测对象上；场景给了 Path 就打在那儿）+ 可选 Patches（跨文件、多处）
    $patches = New-Object System.Collections.ArrayList
    $from = [string](Prop $sc 'From')
    if (-not [string]::IsNullOrWhiteSpace($from)) {
      $sp = [string](Prop $sc 'Path')
      if ([string]::IsNullOrWhiteSpace($sp)) { $sp = $subject }
      elseif (-not [System.IO.Path]::IsPathRooted($sp)) { $sp = Join-Path $work $sp }
      [void]$patches.Add(@{ Path = $sp; From = $from; To = [string](Prop $sc 'To'); Expand = (Prop $sc 'Expand') })
    }
    foreach ($p in @(Prop $sc 'Patches')) {
      if ($null -eq $p) { continue }
      $pp = [string](Prop $p 'Path')
      if ([string]::IsNullOrWhiteSpace($pp)) { [void]$patches.Add(@{ Broken = 'Patches 里有一项没有 Path' }); continue }
      if (-not [System.IO.Path]::IsPathRooted($pp)) { $pp = Join-Path $work $pp }
      [void]$patches.Add(@{ Path = $pp; From = [string](Prop $p 'From'); To = [string](Prop $p 'To'); Append = (Prop $p 'Append'); Expand = (Prop $p 'Expand') })
    }

    $touched = [ordered]@{}
    # 额外要纳入"快照 → 还原"保护的文件（配合场景的 Mutate 逃生舱用）
    foreach ($fx in @(Prop $sc 'Files')) {
      if ($null -eq $fx) { continue }
      $fp = [string]$fx
      if (-not [System.IO.Path]::IsPathRooted($fp)) { $fp = Join-Path $work $fp }
      if (Test-Path -LiteralPath $fp) { $touched[$fp] = [System.IO.File]::ReadAllBytes($fp) }
    }
    $mutate = Prop $sc 'Mutate'

    try {
      # ① 注入（每处都必须命中恰好 1 次）
      $miss = @()
      foreach ($pt in $patches) {
        if (Prop $pt 'Broken') { $miss += [string](Prop $pt 'Broken'); continue }
        $path = [string]$pt.Path
        if (-not (Test-Path -LiteralPath $path)) { $miss += "$([System.IO.Path]::GetFileName($path))：文件不存在"; continue }
        if (-not $touched.Contains($path)) { $touched[$path] = [System.IO.File]::ReadAllBytes($path) }
        $b = [byte[]]$touched[$path]
        $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        # 追加型补丁（噪声场景常用：只在文件末尾加注释 / 空行）
        $app = [string](Prop $pt 'Append')
        if (-not [string]::IsNullOrEmpty($app)) {
          $t2 = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
          $nl2 = if ($t2.Contains("`r`n")) { "`r`n" } else { "`n" }
          if (-not $t2.EndsWith("`n")) { $t2 += $nl2 }        # 别把追加内容粘到最后一个 token 上
          [System.IO.File]::WriteAllText($path, ($t2 + $app), [System.Text.UTF8Encoding]::new([bool]$hasBom))
          continue
        }
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $rx = [regex]([string]$pt.From)
        $hits = $rx.Matches($text).Count
        if ($hits -ne 1) { $miss += "$([System.IO.Path]::GetFileName($path))：命中 $hits 次"; continue }
        $to = [string]$pt.To
        if (Prop $pt 'Expand') {
          # 模板展开（`$&` = 整个匹配、`$1` = 第一个分组）—— 用来表达"把这一行复制一份"这类注入；
          # ⚠️ 默认是**字面替换**（更安全）：要展开必须显式 Expand
          $patched = $rx.Replace($text, $to, 1)
        } else {
          $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $to }
          $patched = $rx.Replace($text, $evaluator, 1)
        }
        [System.IO.File]::WriteAllText($path, $patched, [System.Text.UTF8Encoding]::new([bool]$hasBom))
      }
      # 逃生舱：补丁表达不了的改动（如"把 JSON 里某个嵌套字段改掉"）交给场景自己做；
      # ⚠️ 它改的文件**必须**在场景的 Files 里声明过 —— 骨架一定把它们还原（这是允许逃生舱的前提）
      if ($null -ne $mutate) { [void](& $mutate $work $subject) }
      if ($miss.Count -gt 0) {
        $script:broken++
        Say "INJECT-MISS   $tag"
        Say "              $($miss -join '；') ⇒ 必须每处恰好 1 次（被测对象的代码结构变了，先修场景）"
        continue
      }
      if ($null -eq $assert) {
        $script:broken++
        Say "NO-ASSERT     $tag"
        Say '              场景没给 Assert ⇒ 不知道该看什么算"红"（不猜）'
        continue
      }

      # ② 断言：约定 `$true` = "报红了"；也可返回 @{ Red = <bool>; Issues = @(...) }（Issues 非空 = 不符预期）
      $red = $null; $aIssues = @(); $detail = ''
      try {
        $ar = & $assert $subject
        if ($ar -is [bool]) { $red = [bool]$ar }
        else {
          $rv = Prop $ar 'Red'
          if ($null -eq $rv) { throw '断言返回的对象里没有 Red 字段（约定：$true/$false，或 @{Red=..;Issues=..}）' }
          $red = [bool]$rv
          $aIssues = @(Prop $ar 'Issues')
        }
      } catch { $detail = $_.Exception.Message; $red = $null }
      if ($null -eq $red) {
        $script:broken++
        Say "ASSERT-ERROR  $tag"
        Say "              断言跑不起来（按尺子坏了处理）：$detail"
        continue
      }

      # ③ 判定（还原在 finally 里做）
      $mismatch = @()
      if ($red -ne $expectRed) {
        $mismatch += $(if ($expectRed) { '期望它报红，但它没报红（这条检查可能是装饰品）' }
                        else { '不该报红的改动**报了红**（噪声边界没守住）' })
      }
      foreach ($i in $aIssues) { if (-not [string]::IsNullOrWhiteSpace([string]$i)) { $mismatch += [string]$i } }
      if ($mismatch.Count -eq 0) {
        $script:ok++
        if ($red) { Say "OK            $tag"; Say '              ⇒ 注入生效，断言确实报红' }
        else { Say "OK(噪声)      $tag"; Say '              ⇒ 不该报红的改动，确实没报红' }
      } else {
        $script:bad++
        Say "MISMATCH      $tag"
        foreach ($x in $mismatch) { Say "              · $x" }
      }
    } finally {
      # ④ 还原（逐字节 + 哈希校验）
      if ($touched.Count -gt 0) {
        $badRestore = @(Restore-Touched $touched)
        if ($badRestore.Count -gt 0) {
          $script:broken++
          Say "RESTORE-FAIL  $tag"
          Say "              还原后哈希对不上：$($badRestore -join '；') ⇒ **别信本次结论**，先人工核对"
        }
      }
    }
  }

  Say ''
  Say ('─' * 60)
  Say "结果：按预期 $script:ok · 不符预期 $script:bad · 尺子坏了 $script:broken（共 $($scenarios.Count) 个场景）"
  $code = if ($script:broken -gt 0) { 2 } elseif ($script:bad -gt 0) { 1 } else { 0 }
  $verdict = if ($code -eq 2) { '⚠️ 有尺子坏了 ⇒ 本脚本的结论不可信，先修它' }
             elseif ($code -eq 1) { "❌ 有 $script:bad 个场景不符预期" }
             else { '✅ 全部按预期：注入被抓住、噪声不误报、还原逐字节一致' }
  Say "结论：$verdict"
  Say "退出码：$code"

  if (-not $Keep) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  exit $code
} catch {
  Write-Host "⚠️ 骨架跑不起来（退出码 2）：$($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  exit 2
}

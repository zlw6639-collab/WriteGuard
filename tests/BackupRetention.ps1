#Requires -Version 7.0
<#
  备份保留策略的**反向验证**（BackupRetention）
  ─────────────────────────────────────────────────────────────
  保留策略这种东西，最怕的不是"没删"，而是**删错**：把唯一能恢复的那份删了。
  所以这里测的不是"能不能删"，而是三条不变量：

    ① **演练不删**：不加 -Commit 一个文件都不许少；
    ② **保底留一份**：哪怕全都超龄、KeepLatest 写 0，每个目标也至少留 1 份；
    ③ **只删"又超龄又不在最新 N 份"的**：年轻人一份都不许动。

  用法：pwsh -NoProfile -File .\tests\BackupRetention.ps1
  退出码：0 = 全过 · 1 = 有失败 · 2 = 跑不起来
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$prune = Join-Path $root 'Prune-Backups.ps1'

$script:pass = 0; $script:fail = 0
$script:lines = New-Object System.Collections.ArrayList
function Say([string]$s = '') { [void]$script:lines.Add($s); Write-Host $s }
function Case([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; Say ('PASS  ' + $name) }
  catch { $script:fail++; Say ('FAIL  ' + $name); Say ('        → ' + $_.Exception.Message) }
}
function Assert-Eq($a, $b, [string]$msg) { if ("$a" -cne "$b") { throw "$msg（期望「$b」，实际「$a」）" } }

function New-Bak([string]$dir, [string]$orig, [int]$daysAgo, [string]$srcKey = 'aaaaaaaa') {
  $stamp = (Get-Date).AddDays(-$daysAgo).ToString('yyyyMMdd-HHmmss')
  $p = Join-Path $dir ("$orig@$srcKey.bak-$stamp-wguard")
  [System.IO.File]::WriteAllText($p, "backup $orig -$daysAgo d")
  return $p
}
function Count-Bak([string]$dir) { @(Get-ChildItem -LiteralPath $dir -File -Filter '*.bak-*').Count }
# ─────────────────────────────────────────────────────────────
# 跨进程捕获输出：**自己把编码钉死成 UTF-8**，不依赖宿主默认代码页。
#   2026-10-18 第二份审计实测：GBK 控制台下 `↳`（U+21B3）被换成 `?` ⇒ ⑨ 假红；
#   cp437 控制台下更糟（中文全变 `?`）。中文社区定位 ≠ 只在 UTF-8 环境下可靠。
#   ⚠️ 参数名（-Commit / -KeepLatest）必须原样写进命令串——加引号会变成字符串位置参数。
# ─────────────────────────────────────────────────────────────
function ConvertTo-CmdArg([string]$a) {
  if ($a -like '-*') { return $a }
  return "'" + ($a -replace "'", "''") + "'"
}
function Invoke-NativeUtf8([string]$Script, [string[]]$ArgList) {
  $parts = @("& '" + ($Script -replace "'", "''") + "'")
  foreach ($a in $ArgList) { $parts += (ConvertTo-CmdArg $a) }
  $cmd = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; " + ($parts -join ' ')
  # ★ 父进程这一侧也要钉死：子进程按 UTF-8 写，父进程必须按 UTF-8 解码，两边一致才不假红。
  #   钉在**函数内部**（而不是只在脚本开头钉一次）：这样即便调用方中途改过控制台编码，捕获仍然正确。
  #   ⚠️ 这一行是 ⑩ 的守卫 —— 摘掉它 ⑩ 必须红（M30）。
  $prevEnc = [Console]::OutputEncoding
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  try { return & pwsh -NoProfile -Command $cmd 2>&1 }
  finally { [Console]::OutputEncoding = $prevEnc }
}
function Run-Prune([string]$dir, [string[]]$extra) {
  $args = @('-NoProfile', '-File', $prune, '-BackupDir', $dir) + $extra
  & pwsh @args *> $null
  return $LASTEXITCODE
}
# 需要**看输出**的用例用这个（比如核对"文案里的目标数"是否等于"表格行数"）
function Run-PruneOut([string]$dir, [string[]]$extra) {
  $o = Invoke-NativeUtf8 -Script $prune -ArgList (@('-BackupDir', $dir) + $extra) | Out-String
  return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}

try {
  $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wg-retention-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  [void][System.IO.Directory]::CreateDirectory($work)

  Say ('=' * 70)
  Say '  BackupRetention —— 备份保留策略的反向验证'
  Say ('=' * 70)
  Say ''

  # ── ① 演练不删 ────────────────────────────────────────────
  $d1 = Join-Path $work 'case1'; [void][System.IO.Directory]::CreateDirectory($d1)
  foreach ($d in 60, 50, 40, 20, 10) { [void](New-Bak $d1 'a.md' $d) }
  Case '① 演练（无 -Commit）：一个文件都不许少' {
    Assert-Eq (Count-Bak $d1) 5 '造了 5 份'
    $code = Run-Prune $d1 @('-KeepLatest', '2', '-OlderThanDays', '30')
    Assert-Eq $code 0 '退出码'
    Assert-Eq (Count-Bak $d1) 5 '演练后必须仍是 5 份'
  }

  # ── ② 真删：只删"又超龄又不在最新 N 份"的 ──────────────────
  Case '② -Commit + KeepLatest 2：应删 3 份超龄的、留最新 2 份' {
    $code = Run-Prune $d1 @('-KeepLatest', '2', '-OlderThanDays', '30', '-Commit')
    Assert-Eq $code 0 '退出码'
    Assert-Eq (Count-Bak $d1) 2 '应剩最新 2 份'
  }

  # ── ③ 保底留一份：全都超龄 + KeepLatest 写 0 ───────────────
  $d2 = Join-Path $work 'case3'; [void][System.IO.Directory]::CreateDirectory($d2)
  foreach ($d in 400, 380, 360, 340) { [void](New-Bak $d2 'c.md' $d) }
  Case '③ 全都超龄且 -KeepLatest 0：每个目标仍必须留 1 份' {
    $code = Run-Prune $d2 @('-KeepLatest', '0', '-OlderThanDays', '30', '-Commit')
    Assert-Eq $code 0 '退出码'
    Assert-Eq (Count-Bak $d2) 1 '唯一可恢复版本不能被删'
  }

  # ── ④ 年轻人不许动 ─────────────────────────────────────────
  $d3 = Join-Path $work 'case4'; [void][System.IO.Directory]::CreateDirectory($d3)
  foreach ($d in 1, 2, 3, 4, 5) { [void](New-Bak $d3 'd.md' $d) }   # 都在 30 天内，且时间戳不撞
  Case '④ 全部在保留期内：即使超过 KeepLatest 也一份都不许删' {
    Assert-Eq (Count-Bak $d3) 5 '造了 5 份'
    $code = Run-Prune $d3 @('-KeepLatest', '1', '-OlderThanDays', '30', '-Commit')
    Assert-Eq $code 0 '退出码'
    Assert-Eq (Count-Bak $d3) 5 '年轻人不该被清理'
  }

  # ── ⑤ 分组独立 ─────────────────────────────────────────────
  $d4 = Join-Path $work 'case5'; [void][System.IO.Directory]::CreateDirectory($d4)
  foreach ($d in 60, 50, 40) { [void](New-Bak $d4 'e.md' $d) }
  foreach ($d in 60, 50, 40) { [void](New-Bak $d4 'f.md' $d) }
  Case '⑤ 两个目标文件：清理要按目标独立算，各留 1 份' {
    $code = Run-Prune $d4 @('-KeepLatest', '1', '-OlderThanDays', '30', '-Commit')
    Assert-Eq $code 0 '退出码'
    Assert-Eq (Count-Bak $d4) 2 'e/f 各留 1 份'
  }

  # ── ⑥ 同名跨目录（2026-10-17 修的真实误删场景）─────────────
  #   修复前：备份名不带来源 ⇒ 两个 config.json 合成一组 ⇒ 清理后 A 源剩 0 份。
  #   这条用例就是那个 bug 的回归测试：只要分组又退回合体，它立刻报红。
  $d5 = Join-Path $work 'case6'; [void][System.IO.Directory]::CreateDirectory($d5)
  foreach ($d in 60, 50, 40) { [void](New-Bak $d5 'config.json' $d 'aaaabbbb') }
  foreach ($d in 55, 45, 35) { [void](New-Bak $d5 'config.json' $d 'ccccdddd') }
  Case '⑥ 两个目录里的同名 config.json：必须各留 1 份（不许合体）' {
    Assert-Eq (Count-Bak $d5) 6 '造了 6 份'
    $code = Run-Prune $d5 @('-KeepLatest', '1', '-OlderThanDays', '30', '-Commit')
    Assert-Eq $code 0 '退出码'
    Assert-Eq (Count-Bak $d5) 2 '两个来源必须各留 1 份'
  }

  # ── ⑦ 旧命名（没有 @来源hash）⇒ 无法确定来源，一律不删 ──────
  $d6 = Join-Path $work 'case7'; [void][System.IO.Directory]::CreateDirectory($d6)
  foreach ($d in 200, 190, 180) {
    $stamp = (Get-Date).AddDays(-$d).ToString('yyyyMMdd-HHmmss')
    [System.IO.File]::WriteAllText((Join-Path $d6 "legacy.md.bak-$stamp-wguard"), 'old')
  }
  Case '⑦ 旧命名（无 @来源hash）：无法确定来源 ⇒ 一份都不许删' {
    Assert-Eq (Count-Bak $d6) 3 '造了 3 份'
    $code = Run-Prune $d6 @('-KeepLatest', '1', '-OlderThanDays', '30', '-Commit')
    Assert-Eq $code 0 '退出码'
    Assert-Eq (Count-Bak $d6) 3 '旧命名必须原样保留（宁可留着，也不猜）'
  }

  # ── ⑥ 不存在的目录必须报错，而不是"删了个寂寞" ─────────────
  # ── ⑨ 只有一个目标时，文案的数字必须等于表格行数 ────────────
  #   2026-10-17 外部审计抓到的真 bug：`Group-Object` 单分组会解包，
  #   导致"分属 2 个目标"而表格只有 1 行（.Count 是备份份数，不是目标数）。
  $d7 = Join-Path $work 'case9'; [void][System.IO.Directory]::CreateDirectory($d7)
  foreach ($d in 5, 3) { [void](New-Bak $d7 'x.md' $d '1377e33c') }
  Case '⑨ 只有一个目标：文案的"分属 N 个目标"必须等于表格行数' {
    $r = Run-PruneOut $d7 @()
    Assert-Eq $r.Code 0 '退出码'
    $m = [regex]::Match($r.Out, '分属 (\d+) 个目标')
    Assert-Eq ([bool]$m.Success) $true '输出里应有「分属 N 个目标」'
    # 表格行 = 名字 + 三个数字列（表头第二列是中文、分隔线是横杠，都匹配不上）
    $rows = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^\S+\s+\d+\s+\d+\s+[\d.]+$' })
    Assert-Eq ([int]$m.Groups[1].Value) $rows.Count '文案目标数必须等于表格行数（这行数字不许说谎）'
    # 可解释：必须说明"为什么保留"，不能只报"可清理几份"
    Assert-Eq ([regex]::Matches($r.Out, '↳ 保留').Count) 1 '应输出「↳ 保留 N 份：原因」这一行'
  }

  Case '⑩ 非 UTF-8 控制台：中文与 ↳ 不许变成 ?（断言不许依赖宿主代码页）' {
    # 2026-10-18 实测：GBK 控制台下 `↳`（U+21B3）被换成 `?` ⇒ ⑨ 假红；cp437 下连中文都会变 `?`。
    # 这里**主动**把控制台换成敌意编码再跑同样的断言 —— 证明钉编码那一处真在起作用，
    # 而不是"恰好我的机器是 UTF-8 所以没红"。摘掉它 ⇒ 本条必须红（M30）。
    $d10 = Join-Path $work 'case10'; [void][System.IO.Directory]::CreateDirectory($d10)
    foreach ($dd in 5, 3) { [void](New-Bak $d10 'y.md' $dd '1377e33c') }
    $prevEnc2 = [Console]::OutputEncoding
    try {
      # 敌意编码 = 系统 ANSI（中文 Windows=936、英文 Windows=1252）；避免依赖 codepage 936 是否注册
      [Console]::OutputEncoding = [System.Text.Encoding]::ASCII   # 敌意：中文/↳ 无法表示（跨平台可用）   # GBK：U+21B3 无法表示
      $r10 = Run-PruneOut $d10 @()
      Assert-Eq $r10.Code 0 '退出码'
      Assert-Eq ([regex]::IsMatch($r10.Out, '分属 1 个目标')) $true '中文输出必须可读（不许变成 ?）'
      Assert-Eq ([regex]::Matches($r10.Out, '↳ 保留').Count) 1 'U+21B3 必须原样可读（不许变成 ?）'
    } finally { [Console]::OutputEncoding = $prevEnc2 }
  }

  Case '⑧ 目录不存在 ⇒ 退出码 2（不静默成功）' {
    $code = Run-Prune (Join-Path $work 'nope') @()
    Assert-Eq $code 2 '不存在应当报错'
  }

  Say ''
  Say ('─' * 60)
  Say ("结果：PASS {0} / FAIL {1}" -f $script:pass, $script:fail)
  $verdict = if ($script:fail -gt 0) { '❌ 保留策略有反例通过不了 —— 别拿它去清理真备份' } else { '✅ 全绿：三条不变量都守住了' }
  Say "结论：$verdict"
  Say ('退出码：' + $(if ($script:fail -gt 0) { 1 } else { 0 }))

  $reportFile = Join-Path $PSScriptRoot 'BackupRetention-latest.txt'
  $script:lines -join "`r`n" | Set-Content -LiteralPath $reportFile -Encoding UTF8
  Write-Host "报告：$reportFile"

  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  exit $(if ($script:fail -gt 0) { 1 } else { 0 })
} catch {
  Write-Host "⚠️ 跑不起来（退出码 2）：$($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  exit 2
}

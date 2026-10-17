#Requires -Version 7.0
<#
  差异算法质量（DiffQuality）—— 先量化误拒率，再决定要不要换算法
  ─────────────────────────────────────────────────────────────
  背景：ROADMAP G 项「差异算法专项测试」。
        `Get-WgLineDiff` 用的是「剥公共前后缀 + 同索引逐行比较」的**保守算法**：
        **只会多报、不会漏报**。多报的代价是 `-MaxChangedLines` **误拒合法改动**。
        外部审计 P2 点过"误拒过多"，但我们一直没有**数字** —— 没有数字就没法决定要不要上 LCS。

  这份脚本只做一件事：把"报告改动面 vs 真实改动行数"摆成一张表。

  判据（硬性，不达标就 exit 1）：
    · **漏报必须为 0** —— 报告的行数少于真实改动 = 有改动没被看见，这是安全问题（不是精度问题）；
    · 5000 行文件单次 diff < 1000ms —— 否则脚本日常用法不可接受。
  误报率只**统计**、不设阈值：它是"要不要换算法"的依据，不是判据
  （阈值一旦写死，就等于替未来的人做了决定）。

  用法：pwsh -NoProfile -File .\tests\DiffQuality.ps1
  退出码：0 = 判据达标 · 1 = 有漏报或过慢 · 2 = 跑不起来
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:lines = New-Object System.Collections.ArrayList
function Say([string]$s = '') { [void]$script:lines.Add($s); Write-Host $s }
function NL([object[]]$a) { ($a | ForEach-Object { [string]$_ }) -join "`n" }

try {
  Import-Module (Join-Path $root 'WriteGuard.psd1') -Force
  # ⚠️ 白盒：`Get-WgLineDiff` 是**内部函数**（故意不导出），而这里要测的就是它本身。
  #    标准做法是在模块作用域里调 `& $mod { ... }` —— 不为了测试方便去改对外导出面。
  $mod = Get-Module WriteGuard

  Say ('=' * 76)
  Say '  DiffQuality —— 报告改动面 vs 真实改动行数（保守算法的账本）'
  Say ('=' * 76)
  Say ''

  $base = @(0..99 | ForEach-Object { "line $_" })
  $big = @(0..4999 | ForEach-Object { "big line $_" })

  $cases = New-Object System.Collections.ArrayList

  [void]$cases.Add(@{
    Id = 'D1'; Name = '中部插入 1 行'
    Old = (NL $base); New = (NL (@($base[0..49]) + @('NEW LINE') + @($base[50..99]))); Real = 1 })
  [void]$cases.Add(@{
    Id = 'D2'; Name = '中部插入 5 行'
    Old = (NL $base); New = (NL (@($base[0..49]) + @(1..5 | ForEach-Object { "NEW $_" }) + @($base[50..99]))); Real = 5 })
  [void]$cases.Add(@{
    Id = 'D3'; Name = '中部删除 1 行'
    Old = (NL $base); New = (NL (@($base[0..49]) + @($base[51..99]))); Real = 1 })
  [void]$cases.Add(@{
    Id = 'D4'; Name = '中部删除 5 行'
    Old = (NL $base); New = (NL (@($base[0..49]) + @($base[55..99]))); Real = 5 })
  [void]$cases.Add(@{
    Id = 'D5'; Name = '文件头部插入 1 行（无公共前缀）'
    Old = (NL $base); New = (NL (@('HEAD NEW') + $base)); Real = 1 })
  [void]$cases.Add(@{
    Id = 'D6'; Name = '文件尾部追加 2 行（无公共后缀）'
    Old = (NL $base); New = (NL ($base + @('TAIL A', 'TAIL B'))); Real = 2 })

  $mut = @($base)
  $mut[60] = 'line 60 CHANGED'
  [void]$cases.Add(@{
    Id = 'D7'; Name = '插入 1 行 + 改 1 行（两处相距 10 行）'
    Old = (NL $base); New = (NL (@($mut[0..49]) + @('NEW LINE') + @($mut[50..99]))); Real = 2 })

  $mut2 = @($base)
  $mut2[10] = 'line 10 CHANGED'
  $mut2[90] = 'line 90 CHANGED'
  [void]$cases.Add(@{
    Id = 'D8'; Name = '两处远距修改（第 11 行 / 第 91 行）'
    Old = (NL $base); New = (NL $mut2); Real = 2 })

  [void]$cases.Add(@{
    Id = 'D9'; Name = '重复行：只改两行相同中的第二行'
    Old = (NL @('A', 'B', 'B', 'C')); New = (NL @('A', 'B', 'X', 'C')); Real = 1 })

  $bigMut = @($big)
  $bigMut[2500] = 'big line 2500 CHANGED'
  [void]$cases.Add(@{
    Id = 'D10'; Name = '5000 行文件里改 1 行'
    Old = (NL $big); New = (NL $bigMut); Real = 1 })
  [void]$cases.Add(@{
    Id = 'D11'; Name = '5000 行文件中部插入 1 行'
    Old = (NL $big); New = (NL (@($big[0..2499]) + @('BIG NEW') + @($big[2500..4999]))); Real = 1 })
  [void]$cases.Add(@{
    Id = 'D12'; Name = '全文件重写（100 行全变）'
    Old = (NL $base); New = (NL (0..99 | ForEach-Object { "REWRITTEN $_" })); Real = 100 })

  $rows = New-Object System.Collections.ArrayList
  $totalOver = 0
  $totalMiss = 0
  $maxOver = 0
  $slowest = 0.0

  foreach ($c in $cases) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { param($o, $n) Get-WgLineDiff -Old $o -New $n } $c.Old $c.New
    $sw.Stop()
    $ms = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    if ($ms -gt $slowest) { $slowest = $ms }

    $got = @($r.ChangedLines).Count
    $miss = if ($got -lt $c.Real) { $c.Real - $got } else { 0 }
    $over = if ($got -gt $c.Real) { $got - $c.Real } else { 0 }
    $totalMiss += $miss
    $totalOver += $over
    if ($over -gt $maxOver) { $maxOver = $over }

    $flag = if ($miss -gt 0) { '⚠️漏报' } elseif ($over -gt 0) { '多报' } else { '准确' }
    [void]$rows.Add([pscustomobject]@{
      Id = $c.Id; Name = $c.Name; Real = $c.Real; Got = $got
      Over = $over; Miss = $miss; Ms = $ms; Flag = $flag
    })
  }

  Say ('{0,-4} {1,-34} {2,4} {3,4} {4,5} {5,5} {6,8}  {7}' -f 'ID', '场景', '真实', '报告', '误报', '漏报', '耗时ms', '判定')
  Say ('-' * 76)
  foreach ($x in $rows) {
    Say ('{0,-4} {1,-34} {2,4} {3,4} {4,5} {5,5} {6,8}  {7}' -f $x.Id, $x.Name, $x.Real, $x.Got, $x.Over, $x.Miss, $x.Ms, $x.Flag)
  }
  Say ('-' * 76)

  # 只看 5000 行那两个（D10/D11）的耗时作为性能判据
  $bigMs = ($rows | Where-Object { $_.Id -in @('D10', 'D11') } | Measure-Object -Property Ms -Maximum).Maximum

  Say ''
  Say ("统计：漏报合计 {0} · 误报合计 {1} · 单例最大误报 {2} 行 · 5000 行最慢 {3} ms" -f $totalMiss, $totalOver, $maxOver, $bigMs)
  Say ''

  $fail = 0
  if ($totalMiss -gt 0) {
    Say ("❌ 有漏报（{0} 行）—— 保守算法的底线是不漏，这条必须为 0" -f $totalMiss)
    $fail = 1
  } else {
    Say '✅ 无漏报：保守算法的底线守住了（只会多报，不会漏报）'
  }
  if ($bigMs -ge 1000) {
    Say ("❌ 5000 行 diff 耗时 {0} ms ≥ 1000ms —— 日常用法不可接受" -f $bigMs)
    $fail = 1
  } else {
    Say ("✅ 性能达标：5000 行 diff {0} ms < 1000ms" -f $bigMs)
  }

  Say ''
  Say ('─' * 60)
  Say ("结果：漏报 {0} · 误报合计 {1} · 判据 {2}" -f $totalMiss, $totalOver, $(if ($fail -eq 0) { '全过' } else { '未过' }))
  Say "退出码：$fail"

  $reportFile = Join-Path $PSScriptRoot 'DiffQuality-latest.txt'
  $script:lines -join "`r`n" | Set-Content -LiteralPath $reportFile -Encoding UTF8
  Write-Host "报告：$reportFile"

  exit $fail
} catch {
  Write-Host "⚠️ DiffQuality 跑不起来（退出码 2）：$($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  exit 2
}

#Requires -Version 7.0
<#
  接手入口（Start-Here）—— 一屏看清：这是什么 / 现在好不好 / 还剩什么没做
  ─────────────────────────────────────────────────────────────────────
  用法：
    pwsh -NoProfile -File .\Start-Here.ps1
    pwsh -NoProfile -File .\Start-Here.ps1 -SkipTests     # 只列清单，不跑测试
  退出码：0 = 全绿 · 1 = 有测试没过 · 2 = 跑不起来（先修尺子）
#>
[CmdletBinding()]
param([switch]$SkipTests, [switch]$WithProbes)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Line([string]$s = '') { Write-Host $s }

try {
  Line ('=' * 68)
  Line '  WriteGuard —— 写操作五规矩护栏'
  Line ('=' * 68)
  Line '  这是什么：脚本要替人改文件时，把「默认不开 / 原样备份 / 只改白名单 /'
  Line '              读回复验 / 失败回滚」交给这个库，别在每个开关里手写一遍。'
  Line '  依赖：只有 PowerShell 7 + .NET 原生（不依赖任何平台、不依赖第三方模块）'
  Line '  五个特色：看得见 diff 预览 · 可追溯审计日志 · 多文件事务（全成或全退）· 元验证 · 命令行门面 wg.ps1'
  Line '  ★ 灵魂：注入 ——「检查通过」≠「检查有效」：把规矩故意改坏，看它会不会被抓到（元验证必须跑）'
  Line ''

  $fail = 0
  if ($SkipTests) {
    Line '── 测试：按 -SkipTests 跳过（⚠️ 没跑 ≠ 通过）──'
  } else {
    Line '── 1/5 自测（反向验证：故意让它拒绝 / 回滚 / 原子化）──'
    & pwsh -NoProfile -File (Join-Path $root 'tests\SelfTest.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
    Line ''
    Line '── 2/5 元验证（把库故意改坏 ⇒ 自测必须报红）──'
    & pwsh -NoProfile -File (Join-Path $root 'tests\MutationCheck.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
    Line ''
    Line '── 3/5 文档数字一致性（文档里的现状数字必须等于上面两份报告）──'
    & pwsh -NoProfile -File (Join-Path $root 'tests\CliSmoke.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
    & pwsh -NoProfile -File (Join-Path $root 'tests\DocCounts.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
    Line ''
    Line '── 4/5 差异算法质量（改动面账本：硬判据只有「不漏报 + 不变慢」）──'
    & pwsh -NoProfile -File (Join-Path $root 'tests\DiffQuality.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
    Line ''
    Line '── 5/5 备份保留策略（演练不删 / 保底留一份 / 只删超龄的）──'
    & pwsh -NoProfile -File (Join-Path $root 'tests\BackupRetention.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
    Line ''
    # ★ 实验探针（2026-10-18 补）：**默认不跑**（它们不是发布门槛），
    #   `-WithProbes` 才跑；**无论结果如何都不改变本入口的退出码** ——
    #   探针是实验资产，不是发布门槛（否则等于把"实验"变成"硬性门"）。
    if ($WithProbes) {
      Line '── 附加：实验探针（不进五套件，**不是发布门槛**：只报告，不影响退出码）──'
      $probeFail = 0
      & pwsh -NoProfile -File (Join-Path $root 'tests\ByteSpanProbe.ps1')
      if ($LASTEXITCODE -ne 0) { $probeFail++ }
      & pwsh -NoProfile -File (Join-Path $root 'tests\AtomicWriteProbe.ps1')
      if ($LASTEXITCODE -ne 0) { $probeFail++ }
      & pwsh -NoProfile -File (Join-Path $root 'tests\ProbeSafetyCheck.ps1')
      if ($LASTEXITCODE -ne 0) { $probeFail++ }
      if ($probeFail -gt 0) {
        Line ('  ⚠️ 探针有 ' + $probeFail + ' 项 FAIL —— 已报告，但**不影响本入口退出码**（探针不是门槛）。')
      } else {
        Line '  ✅ 探针全部按预期（PASS/BLOCKED/NOT_TESTED 均见各自报告）。'
      }
      Line ''
    }
  }

  Line '── 还剩什么没做（读自 ROADMAP.md：只有一份清单，不会漂）──'
  $roadmap = Join-Path $root 'ROADMAP.md'
  if (-not (Test-Path -LiteralPath $roadmap)) {
    Line '  ⚠️ 找不到 ROADMAP.md ⇒ 无法列出未完成项（不猜）'
    exit 2
  }
  $txt = [System.IO.File]::ReadAllText($roadmap, [System.Text.Encoding]::UTF8)
  $nSec = 0
  $nItem = 0
  # ⚠️ 分两组输出：已完成的不该挂在"还剩什么没做"下面（外部审计 2026-10-17 指出入口件自相矛盾）
  $gTodo = New-Object System.Collections.ArrayList
  $gDone = New-Object System.Collections.ArrayList
  $curTodo = $false
  foreach ($l in @($txt -split "`r?`n")) {
    if ($l -match '^###\s+([A-Z])\.\s+(.+?)\s*$') {
      $nSec++
      $title = ($Matches[2] -replace '\*\*', '')
      $item = ('  [' + $Matches[1] + '] ' + $title)
      if ($title -match '✅') { [void]$gDone.Add($item); $curTodo = $false }
      else { [void]$gTodo.Add($item); $curTodo = $true }
    } elseif ($l -match '^\s*-\s+\[\s\]\s+(.+?)\s*$') {
      $nItem++
      if ($curTodo) { [void]$gTodo.Add('        · ' + ($Matches[1] -replace '\*\*', '')) }
    }
  }
  foreach ($x in $gTodo) { Line $x }
  if ($gDone.Count -gt 0) {
    Line ''
    Line '  ── 已完成（留档，别重做）──'
    foreach ($x in $gDone) { Line $x }
  }
  if ($nSec -eq 0) {
    Line '  ⚠️ ROADMAP.md 里一条「### X.」都没解析到 ⇒ 先修解析或修文件（不猜）'
    exit 2
  }
  Line ''
  Line ("  合计：{0} 个大项 / {1} 个待勾选小项" -f $nSec, $nItem)
  Line ''
  Line ('─' * 68)
  $verdict = if ($SkipTests) { '⚠️ 测试被跳过（没跑 ≠ 通过）：只能看清单，别据此判断库好不好' }
             elseif ($fail -eq 0) { '✅ 全绿：库现在是可用的 —— 上面那些未完成项随便挑一条接着做' }
             else { '❌ 有测试没过 ⇒ 先修红，别在红的基础上加功能' }
  Line "结论：$verdict"
  # ⚠️ 这里**不能写死**"从 A 开始" —— A–D 早已完成，那句话会把接手人指向不存在的工作
  #    （2026-10-17 修：外部审计抓过同一类"入口件自相矛盾"，这行是漏网的那一处）
  #    再补一层：优先指向**非"可选"**的大项 —— 否则接手人会被先引到 [E] 可选（Node 版）去。
  $nextPick = @($gTodo | Where-Object { $_ -notmatch '可选' })
  $nextHint = if ($nextPick.Count -gt 0) { [string]$nextPick[0] }
              elseif ($gTodo.Count -gt 0) { [string]$gTodo[0] }
              else { '（没有待办了）' }
  Line "下一步：打开 ROADMAP.md，先挑这一个大项 ——$nextHint"
  exit $fail
} catch {
  Write-Host "⚠️ 跑不起来（退出码 2）：$($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  exit 2
}

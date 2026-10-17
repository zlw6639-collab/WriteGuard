#Requires -Version 7.0
<#
  文档数字一致性（DocCounts）—— 让"同一个数字"只有一份事实源
  ─────────────────────────────────────────────────────────────
  病：README / 接手说明 / 自证清单 / 英文版里都写着「自测 42/42 · 元验证 13/13 · CLI 4/4」。
      这些数字靠**手改** ⇒ 2026-10-17 一天就查出错漏 4 处
      （英文版停在旧数字、README §5.2 写 7/7 而实际是 9、接手说明指向已归档脚本、打包脚本写死条数）。
      ci.yml 的治法是一律不写条数；但**给人读的文档需要数字**，所以换个治法：
      **数字可以写，但必须能被机器验证。**

  契约（这份脚本就是契约的执行者）：
    · 事实源 = 三份报告里各套件自己的「结果：」行，不引入任何别的输入；
    · 文档里的**现状数字**一律写成斜杠形式：`自测 42/42` · `元验证 13/13` · `CLI 4/4`，
      或命令注释形式：`PASS 42 / FAIL 0` · `OK 13 / 异常 0`；
    · **历史数字**一律写成「N 条」（不写斜杠）⇒ 断言只认斜杠形式，历史叙述不会被误判；
    · ROADMAP.md 不参与（它是历史日志，每一条都该保留当时的数字）；
    · ⚠️ 一个现状数字都找不到 ⇒ 也报错（否则"把数字全删掉"就能绕过这条断言）。

  用法：pwsh -NoProfile -File .\tests\DocCounts.ps1
  退出码：0 = 全一致 · 1 = 有漂移 · 2 = 跑不起来（报告/文档缺失，或契约失效）
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:lines = New-Object System.Collections.ArrayList
function Say([string]$s = '') { [void]$script:lines.Add($s); Write-Host $s }

function Read-Fact([string]$file, [string]$pattern, [string]$who) {
  $p = Join-Path $PSScriptRoot $file
  if (-not (Test-Path -LiteralPath $p)) { throw "找不到报告 $file —— 先跑 $who 生成它" }
  $txt = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
  $hits = [regex]::Matches($txt, $pattern)
  if ($hits.Count -eq 0) { throw "报告 $file 里没有「结果：」行（输出格式变了？先修 $who）" }
  $m = $hits[$hits.Count - 1]   # 取最后一处：报告末尾的总结行
  return [pscustomobject]@{ Pass = [int]$m.Groups[1].Value; Fail = [int]$m.Groups[2].Value }
}

try {
  Say ('=' * 68)
  Say '  DocCounts —— 文档里的现状数字 vs 三份报告'
  Say ('=' * 68)
  Say ''

  $facts = @{
    selftest = Read-Fact 'SelfTest-latest.txt'      '结果：PASS\s+(\d+)\s*/\s*FAIL\s+(\d+)' 'tests\SelfTest.ps1'
    mutation = Read-Fact 'MutationCheck-latest.txt' '结果：OK\s+(\d+)\s*·\s*异常\s+(\d+)'   'tests\MutationCheck.ps1'
    cli      = Read-Fact 'CliSmoke-latest.txt'      '结果：PASS\s+(\d+)\s*/\s*FAIL\s+(\d+)' 'tests\CliSmoke.ps1'
  }

  Say '事实源（各套件自己的「结果：」行）：'
  Say ("  SelfTest-latest.txt        PASS {0} / FAIL {1}" -f $facts.selftest.Pass, $facts.selftest.Fail)
  Say ("  MutationCheck-latest.txt   OK   {0} / 异常 {1}" -f $facts.mutation.Pass, $facts.mutation.Fail)
  Say ("  CliSmoke-latest.txt        PASS {0} / FAIL {1}" -f $facts.cli.Pass, $facts.cli.Fail)
  Say ''

  $docs = @('README.md', 'README.en.md', '接手说明.md', '检查器自证清单.md')
  Say ('扫描：' + ($docs -join ' · '))
  Say '  （ROADMAP.md 不参与：它是历史日志，每条都该保留当时的数字）'
  Say ''

  # Second = 斜杠右边那个数的含义：
  #   'fail'  = 失败数（`PASS 42 / FAIL 0`）
  #   'total' = 总数  （`自测 42/42` —— 通过 / 总数）
  $rules = @(
    @{ Kind = 'selftest'; Label = '自测 N/N';        Rx = '自测\s*\*{0,2}\s*(\d+)\s*/\s*(\d+)'; Second = 'total' }
    @{ Kind = 'selftest'; Label = 'PASS N / FAIL M'; Rx = 'PASS\s+(\d+)\s*/\s*FAIL\s+(\d+)';   Second = 'fail' }
    @{ Kind = 'mutation'; Label = '元验证 N/N';      Rx = '元验证\s*\*{0,2}\s*(\d+)\s*/\s*(\d+)'; Second = 'total' }
    @{ Kind = 'mutation'; Label = 'OK N / 异常 M';   Rx = 'OK\s+(\d+)\s*/\s*(?:异常\s*)?(\d+)'; Second = 'fail' }
    @{ Kind = 'cli';      Label = 'CLI N/N';         Rx = 'CLI\s*\*{0,2}\s*(\d+)\s*/\s*(\d+)'; Second = 'total' }
  )

  $ok = 0
  $drift = New-Object System.Collections.ArrayList
  foreach ($doc in $docs) {
    $p = Join-Path $root $doc
    if (-not (Test-Path -LiteralPath $p)) { throw "找不到文档 $doc" }
    $rows = [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)
    for ($i = 0; $i -lt $rows.Count; $i++) {
      foreach ($r in $rules) {
        foreach ($m in [regex]::Matches($rows[$i], $r.Rx)) {
          $a = [int]$m.Groups[1].Value
          $b = [int]$m.Groups[2].Value
          $exp = $facts[$r.Kind]
          $expSecond = if ($r.Second -eq 'total') { $exp.Pass + $exp.Fail } else { $exp.Fail }
          $where = ('{0}:{1}' -f $doc, ($i + 1))
          if ($a -eq $exp.Pass -and $b -eq $expSecond) {
            $ok++
            Say ("OK    {0} 「{1}」" -f $where, $m.Value.Trim())
          } else {
            [void]$drift.Add([pscustomobject]@{
              Where = $where; Label = $r.Label; Found = $m.Value.Trim()
              Expect = ('{0}/{1}' -f $exp.Pass, $expSecond); Actual = ('{0}/{1}' -f $a, $b)
            })
            Say ("FAIL  {0} 「{1}」 —— 期望 {2}/{3}，实际 {4}/{5}" -f $where, $m.Value.Trim(), $exp.Pass, $expSecond, $a, $b)
          }
        }
      }
    }
  }

  Say ''
  Say ('─' * 60)

  if (($ok + $drift.Count) -eq 0) {
    Say '结果：一个现状数字都没扫到'
    Say '结论：⚠️ 契约失效 —— 文档里的现状数字要么全被删了、要么写法变了（斜杠形式是唯一被认可的）'
    Say '退出码：2'
    $script:lines -join "`r`n" | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'DocCounts-latest.txt') -Encoding UTF8
    exit 2
  }

  Say ("结果：OK {0} · 漂移 {1}" -f $ok, $drift.Count)
  $exitCode = if ($drift.Count -gt 0) { 1 } else { 0 }
  $verdict = if ($drift.Count -gt 0) {
    "❌ 有 $($drift.Count) 处文档数字与报告不一致 ⇒ 改文档（或改报告），别让读者看到两个版本"
  } else {
    '✅ 文档与报告一致：数字还是那一个数字'
  }
  Say "结论：$verdict"
  Say "退出码：$exitCode"

  $reportFile = Join-Path $PSScriptRoot 'DocCounts-latest.txt'
  $script:lines -join "`r`n" | Set-Content -LiteralPath $reportFile -Encoding UTF8
  Write-Host "报告：$reportFile"

  exit $exitCode
} catch {
  Write-Host "⚠️ DocCounts 跑不起来（退出码 2）：$($_.Exception.Message)"
  Write-Host "  提示：先按顺序跑 SelfTest / MutationCheck / CliSmoke，再跑这一步。"
  exit 2
}

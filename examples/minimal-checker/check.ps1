#Requires -Version 7.0
<#
  最小检查器（示例）—— 给「检查器自证清单」当靶子用
  ─────────────────────────────────────────────────────────────
  它检查一件事：`-DataDir` 里所有 .md 的二级标题（`## xxx`）**不许重复**，且不许出现 `FIXME`。
  退出码三态：0 = 全绿 · 1 = 有需处理 · 2 = 有检查没跑起来（**别把跑不起来当通过**）
#>
[CmdletBinding()]
param(
  [string]$DataDir,
  [string]$ReportTo
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = New-Object System.Collections.ArrayList
function Say([string]$s) { Write-Host $s; [void]$lines.Add($s) }

try {
  if ([string]::IsNullOrWhiteSpace($DataDir)) { Say '用法：check.ps1 -DataDir <目录>'; exit 2 }
  if (-not (Test-Path -LiteralPath $DataDir)) { Say "找不到数据目录：$DataDir"; exit 2 }
  $files = @(Get-ChildItem -LiteralPath $DataDir -Filter '*.md' -File)
  if ($files.Count -eq 0) { Say '没有可检查的文件 ⇒ 算不出来，不等于没问题'; exit 2 }   # ★ 清单 ⑤

  Say "=== 最小检查器（$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')）==="
  Say "数据目录：$DataDir（$($files.Count) 个文件）"
  $issues = New-Object System.Collections.ArrayList
  $seen = @{}                                    # 标题 → 首次出现的文件（Hashtable，可用 ContainsKey）

  foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, '(?m)^##\s+(.+?)\s*$')) {
      $t = $m.Groups[1].Value.Trim()
      if ($seen.ContainsKey($t)) { [void]$issues.Add("$($f.Name)：标题重复「$t」（首次出现在 $($seen[$t])）") }
      else { $seen[$t] = $f.Name }               # ★ 清单 ⑪：目标必须唯一，重复要报出来
    }
    if ($text -match 'FIXME') { [void]$issues.Add("$($f.Name)：含 FIXME 标记") }
  }

  Say ''
  if ($issues.Count -eq 0) { Say '✅ 全绿'; $code = 0 }
  else {
    foreach ($i in $issues) { Say "❌ $i" }
    Say ''
    Say "结论：❌ 有 $($issues.Count) 项需处理"
    $code = 1
  }
  Say "退出码：$code"
  if ($ReportTo) { $lines -join "`r`n" | Set-Content -LiteralPath $ReportTo -Encoding UTF8 }
  exit $code
} catch {
  Write-Host "⚠️ 检查器自己出错了（退出码 2）：$($_.Exception.Message)"
  exit 2
}

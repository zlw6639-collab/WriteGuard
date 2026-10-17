#Requires -Version 7.0
<#
  ProbeSafetyCheck —— 探针的「目录安全」回归测试（2026-10-18 审计 P0）
  ─────────────────────────────────────────────────────────────
  病：探针曾直接 `Remove-Item -Recurse` 用户传入的 -WorkDir。
      如果用户传了一个已有数据的目录，就会被整个删掉。

  本测试的判据：
    在 -WorkDir 里放一个**哨兵文件**，跑两个探针，哨兵必须**仍在**（内容也不变）。
    探针只允许在 -WorkDir 下创建/清理**它自己的唯一子目录**。

  用法：pwsh -NoProfile -File .\tests\ProbeSafetyCheck.ps1
  退出码：0 = 安全 · 1 = 有探针动了用户目录 · 2 = 测试自己跑不起来
#>
[CmdletBinding()]
param([string]$ProbeDir)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# 探针目录可指定（用于"注入坏探针"的自证：证明本测试确实能抓住"删用户目录"）
$probeDir = if ($ProbeDir) { $ProbeDir } else { Join-Path $root 'tests' }

$script:pass = 0; $script:fail = 0
function Say([string]$s = '') { Write-Host $s }
function Check([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; Say ('PASS  ' + $name) }
  catch { $script:fail++; Say ('FAIL  ' + $name); Say ('        → ' + $_.Exception.Message) }
}
function Assert($cond, [string]$msg) { if (-not $cond) { throw $msg } }

try {
  # 自己也要安全：只在"本次创建的 GUID 子目录"里做，绝不删别人目录
  $base = [System.IO.Path]::GetTempPath()
  $runDir = Join-Path $base ('wg-probe-safety-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  [void][System.IO.Directory]::CreateDirectory($runDir)
  $sentinel = Join-Path $runDir 'sentinel-do-not-delete.txt'
  [System.IO.File]::WriteAllText($sentinel, 'keep me', [System.Text.UTF8Encoding]::new($false))
  $sentinelBefore = [System.IO.File]::ReadAllBytes($sentinel)

  Say ('=' * 70)
  Say '  ProbeSafetyCheck —— 探针不得删除用户目录'
  Say ('=' * 70)
  Say ('  测试目录：' + $runDir)
  Say ''

  $probe1 = Join-Path $probeDir 'AtomicWriteProbe.ps1'
  $probe2 = Join-Path $probeDir 'ByteSpanProbe.ps1'
  $rep1 = Join-Path $runDir 'atomic-report.json'
  $rep2 = Join-Path $runDir 'bytespan-report.json'

  Check 'AtomicWriteProbe 不得清空 -WorkDir（哨兵必须还在）' {
    & pwsh -NoProfile -File $probe1 -WorkDir $runDir -ReportTo $rep1 *> $null
    if ($LASTEXITCODE -ne 0) { throw "探针退出码 $LASTEXITCODE（探针自己没跑完，本测试无法判定）" }
    Assert (Test-Path -LiteralPath $sentinel) '哨兵文件被删了 ⇒ 探针删了用户目录'
    $now = [System.IO.File]::ReadAllBytes($sentinel)
    Assert ($now.Length -eq $sentinelBefore.Length) '哨兵文件被改写了'
    for ($i = 0; $i -lt $now.Length; $i++) { Assert ($now[$i] -eq $sentinelBefore[$i]) '哨兵文件字节变了' }
  }

  Check 'ByteSpanProbe 不得清空 -WorkDir（哨兵必须还在）' {
    & pwsh -NoProfile -File $probe2 -WorkDir $runDir -ReportTo $rep2 *> $null
    if ($LASTEXITCODE -ne 0) { throw "探针退出码 $LASTEXITCODE（探针自己没跑完，本测试无法判定）" }
    Assert (Test-Path -LiteralPath $sentinel) '哨兵文件被删了 ⇒ 探针删了用户目录'
    $now = [System.IO.File]::ReadAllBytes($sentinel)
    Assert ($now.Length -eq $sentinelBefore.Length) '哨兵文件被改写了'
    for ($i = 0; $i -lt $now.Length; $i++) { Assert ($now[$i] -eq $sentinelBefore[$i]) '哨兵文件字节变了' }
  }

  Say ''
  Say ('结果：PASS {0} / FAIL {1}' -f $script:pass, $script:fail)
  Say ('结论：' + $(if ($script:fail -gt 0) { '❌ 探针会动用户目录 —— 先修，别拿去跑' } else { '✅ 探针只动自己的子目录' }))
  Say ('退出码：' + $(if ($script:fail -gt 0) { 1 } else { 0 }))

  [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ProbeSafetyCheck-latest.txt'), (("结果：PASS {0} / FAIL {1}" -f $script:pass, $script:fail)), [System.Text.UTF8Encoding]::new($false))
  # 清理：只删本次创建的 runDir（里面只有哨兵 + 报告 + 探针子目录）
  Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
  exit $(if ($script:fail -gt 0) { 1 } else { 0 })
} catch {
  Write-Host ('⚠️ 测试自己跑不起来（退出码 2）：' + $_.Exception.Message)
  Write-Host $_.ScriptStackTrace
  exit 2
}

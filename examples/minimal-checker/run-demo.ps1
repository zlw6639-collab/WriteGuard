#Requires -Version 7.0
<#
  一键演示：给「最小检查器」做故障注入（跑的就是 WriteGuard 的通用骨架）
  ─────────────────────────────────────────────────────────────────────────────
  用法：
    pwsh -NoProfile -File .\run-demo.ps1
    pwsh -NoProfile -File .\run-demo.ps1 -Keep     # 保留工作目录供复看
  退出码：0 = 三个场景全按预期（该绿的绿、该红的红）
#>
[CmdletBinding()]
param([switch]$Keep)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 2026-10-18 CI（ubuntu）发现：
#   ① GitHub Actions 的 pwsh shell 以 `-command ". '脚本'"` 方式执行时，$PSScriptRoot 可能为空；
#   ② 路径拼接不能用 `..\..\` —— Linux 把反斜杠当普通字符。
# 所以：$here 有兜底，路径一律用 [IO.Path]::Combine / Join-Path 多段。
$here = if ($PSScriptRoot) { $PSScriptRoot }
        elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
        else { (Get-Location).Path }
$skeleton = [System.IO.Path]::Combine($here, '..', '..', 'tests', 'FaultInject.ps1')
$checker = [System.IO.Path]::Combine($here, 'check.ps1')
$work = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'wg-minimal-demo')

# 摆工作目录：把检查器与数据复制进去（骨架随后只动副本，真文件一个字节都不碰）
$prepare = {
  param($work)
  $c = Join-Path $work 'check.ps1'
  Copy-Item ([System.IO.Path]::Combine($here, 'check.ps1')) $c -Force
  $d = Join-Path $work 'data'
  [void][System.IO.Directory]::CreateDirectory($d)
  Copy-Item ([System.IO.Path]::Combine($here, 'data', '*.md')) $d -Force
  return $c
}

& $skeleton -Target $checker -ScenariosFile ([System.IO.Path]::Combine($here, 'scenarios.ps1')) `
  -WorkDir $work -Prepare $prepare -Keep:$Keep
exit $LASTEXITCODE

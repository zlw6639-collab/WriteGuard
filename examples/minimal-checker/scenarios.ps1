#Requires -Version 7.0
<#
  三个场景 —— 演示「检查器自证清单」的 ① ② ③：
    S0 对照（什么都不改）          ⇒ 期望绿（清单 ①：静置必须绿）
    S1 塞一个**标题重复**的文件     ⇒ 期望红（清单 ②：**见过它报红**）
    S2 只加一个空行（噪声）         ⇒ 期望绿（清单 ②：噪声边界，不许误报）
  跑法：run-demo.ps1（负责摆工作目录并调用通用骨架 tests\FaultInject.ps1）
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 跑被测检查器（副本），拿退出码：0 绿 / 1 有需处理 / 2 检查器自己出错
function Run-Checker([string]$subject) {
  $dataDir = Join-Path (Split-Path $subject -Parent) 'data'
  & pwsh -NoProfile -File $subject -DataDir $dataDir *> $null
  return [int]$LASTEXITCODE
}
# ★ 关键：把"报红(1)"与"尺子坏了(2)"分开 —— 后者不是红，是环境/检查器自身的问题
function Get-Verdict([string]$subject) {
  $code = Run-Checker $subject
  $issues = @()
  if ($code -eq 2) { $issues += '检查器自己出错（退出码 2）—— 这不算"红"，先修它再谈别的' }
  return [pscustomobject]@{ Red = ($code -eq 1); Issues = $issues }
}

return @(
  @{ Id = 'S0'; What = '对照：什么都不改 ⇒ 期望绿'
     ExpectRed = $false
     Assert = { param($t) Get-Verdict $t } },

  @{ Id = 'S1'; What = '制造一个标题重复（改现有文件）⇒ 期望红（证明"见过它报红"）'
     # ★ 用"改现有文件"而不是"新建文件"：骨架的还原范围是**被改动过的文件**，
     #   新建的文件不会被清掉，会污染后续场景（本示例第一版就踩了这个坑，S2 因此误报红）。
     Patches = @(@{ Path = 'data\a.md'; From = '(?m)^## 标题二$'; To = '## 标题一' })
     ExpectRed = $true
     Assert = { param($t) Get-Verdict $t } },

  @{ Id = 'S2'; What = '只在已有文件末尾加一个空行（噪声：不许报红）'
     Patches = @(@{ Path = 'data\a.md'; Append = "`r`n" })
     ExpectRed = $false
     Assert = { param($t) Get-Verdict $t } }
)

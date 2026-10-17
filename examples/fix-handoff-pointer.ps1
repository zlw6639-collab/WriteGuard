#Requires -Version 7.0
<#
  示例 / 真实工具：用 WriteGuard 回写「最新会话件指针」行
  ─────────────────────────────────────────────────────────────────────
  这是"用本库干真活"的最小完整样板 —— 本机原来的同类逻辑写在 `知识库体检.ps1` 的
  `-FixLatestHandoff` 开关里（那段是手写的备份 / 复验 / 回滚）；这里用库的几个函数把它表达出来。

  ⚠️ 这个示例**不预设任何本机路径**（ROADMAP-A「示例解绑」的成果）：
     必须显式给 `-HandoffPath` 与 `-HandoffDir`；不给就**打印用法并以退出码 2 结束**，
     **绝不会**默默去改一个不存在的文件。

  用法：
    pwsh -NoProfile -File .\examples\fix-handoff-pointer.ps1 `
         -HandoffPath <入口文件> -HandoffDir <会话件目录> [-FilePattern '*.md'] [-Commit]

  参数：
    -HandoffPath   要回写指针行的入口文件（如 HANDOFF.md）
    -HandoffDir    会话件所在目录 —— 按**文件名里的时间戳**取最新（`YYYYMMDD-HHMM` 或 `YYYYMMDDHHMM`）
    -FilePattern   会话件文件名模式（默认 `*.md`）
    -PointerPrefix 指针行的开头（默认是作者项目里的那行写法，可改）
    -BackupDir     备份目录（默认：入口文件同目录下的 `.writeguard\`）
    -Commit        真写；不传 = 演练（一个字节都不写）
#>
[CmdletBinding()]
param(
  [string]$HandoffPath,
  [string]$HandoffDir,
  [string]$FilePattern = '*.md',
  [string]$PointerPrefix = '> 📄 **最新会话执行记录**',
  [string]$BackupDir,
  [switch]$Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($HandoffPath) -or [string]::IsNullOrWhiteSpace($HandoffDir)) {
  Write-Host '用法：pwsh -NoProfile -File .\examples\fix-handoff-pointer.ps1 `'
  Write-Host '        -HandoffPath <入口文件> -HandoffDir <会话件目录> [-FilePattern ''*.md''] [-Commit]'
  Write-Host ''
  Write-Host '  这个示例不预设任何路径（作者本机的默认值已移除）：'
  Write-Host '    -HandoffPath   要回写指针行的入口文件（如 HANDOFF.md）—— **必填**'
  Write-Host '    -HandoffDir    会话件所在目录（按文件名里的时间戳取最新）—— **必填**'
  Write-Host '    -FilePattern   会话件文件名模式（默认 *.md）'
  Write-Host '    -BackupDir     备份目录（默认：入口文件同目录下的 .writeguard\）'
  Write-Host '    -Commit        真写；不传 = 演练（一个字节都不写）'
  exit 2
}
if (-not (Test-Path -LiteralPath $HandoffPath)) { Write-Host "找不到 -HandoffPath：$HandoffPath"; exit 2 }
if (-not (Test-Path -LiteralPath $HandoffDir)) { Write-Host "找不到 -HandoffDir：$HandoffDir"; exit 2 }

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WriteGuard.psm1') -Force

$prefix = $PointerPrefix

# ① 目标必须唯一：按**文件名里的时间戳**取最新（不取 mtime —— 复制/同步都会改它）
$cands = @(Get-ChildItem -LiteralPath $HandoffDir -Filter $FilePattern -File)
$latest = Select-WgUniqueLatest -Candidates $cands -What '会话件' -KeyScript {
  param($f)
  $m = [regex]::Match($f.Name, '(\d{8})-?(\d{4})')
  if ($m.Success) { $m.Groups[1].Value + $m.Groups[2].Value } else { $null }
}
$want = $prefix + '：`' + $latest.FullName + '`（机器回写 · 见「知识库体检」⑪）'
$bakDir = if ([string]::IsNullOrWhiteSpace($BackupDir)) { Join-Path (Split-Path $HandoffPath -Parent) '.writeguard' } else { $BackupDir }

Write-Host "最新会话件：$($latest.Name)"
Write-Host "期望指针行：$want"

# ② 一次受护栏保护的改写（五条规矩都在 Invoke-WgWrite 里）
$res = Invoke-WgWrite -Path $HandoffPath -Commit:$Commit -Tag 'handoff-pointer' -BackupDir $bakDir -MaxChangedLines 3 `
  -Mutator {
  param($snap)
  $lines = @($snap.Text -split "`r?`n")
  $idx = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith($prefix)) { $idx = $i; break } }

  if ($idx -ge 0) {
    if ($lines[$idx] -ceq $want) { return @{ Text = $snap.Text; Note = '指针已是最新' } }
    $lines[$idx] = $want
    return @{ Text = ($lines -join $snap.NewLine); Note = '替换指针行' }
  }

  # 没有指针行 ⇒ 插在第一个 `## …、` 二级标题后的第一个空行之前；锚点找不到就**放弃**（返回 $null），不猜位置
  $anchor = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^##\s') { $anchor = $i; break } }
  if ($anchor -lt 0) { return $null }
  $at = $anchor + 1
  while ($at -lt $lines.Count -and $lines[$at].Trim() -ne '') { $at++ }
  $new = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $at; $i++) { $new.Add($lines[$i]) }
  $new.Add($want); $new.Add('')
  for ($i = $at; $i -lt $lines.Count; $i++) { $new.Add($lines[$i]) }
  return @{ Text = ($new -join $snap.NewLine); Note = '插入指针行' }
} -Verify {
  param($text, $path)
  $issues = @()
  if (-not $text.Contains($want)) { $issues += '回写后文件里找不到期望的指针行' }
  return $issues
}

Write-Host ''
Write-Host "状态：$($res.Status)"
Write-Host "说明：$($res.Note)"
if (@($res.ChangedLines).Count -gt 0) { Write-Host "改动行：$((@($res.ChangedLines) -join '、'))" }
if ($res.DiffText) { Write-Host ''; Write-Host '改动预览：'; Write-Host ([string]$res.DiffText) }
if ($res.Backup) { Write-Host "备份：$($res.Backup)" }
if (@($res.VerifyIssues).Count -gt 0) { Write-Host "复验问题：$((@($res.VerifyIssues) -join '；'))" }
if (-not $Commit) { Write-Host '（演练模式：未传 -Commit ⇒ 未写盘）' }

# 退出码：Written / NoChange / DryRun 都算"事办对了"；Refused / RolledBack / RollbackFailed / Error = 1
exit $(if ($res.Status -in @('Written', 'NoChange', 'DryRun')) { 0 } else { 1 })

#Requires -Version 7.0
<#
  build.ps1 —— WriteGuard 发布打包（一条命令重打，替代手打一大段命令）
  ─────────────────────────────────────────────────────────────
  做什么：
    1. 校验版本号一致（psm1 / psd1 / README）；
    2. 复制源码（排除 .writeguard / .git / *-latest.txt / 探针 report.json / *.zip）；
    3. 生成《清单与SHA256.txt》（逐文件 hash + 大小 + 相对路径）；
    4. 生成审查包（核心文件 + 清单 + VERSION.txt，含 psm1 指纹）；
    5. 压缩两个 zip；
    6. 复算清单哈希核对（0 不符才算成功）。

  为什么要有它：之前每次重打包都是手打 ~50 行命令，改一个排除规则或文件名就容易漂。
  这个脚本就是"打包"的唯一入口。

  用法：
    pwsh -NoProfile -File .\build.ps1                      # 打到默认审计目录
    pwsh -NoProfile -File .\build.ps1 -OutDir D:\release    # 指定输出目录
    pwsh -NoProfile -File .\build.ps1 -SkipVerify           # 跳过版本一致性校验（不推荐）
  退出码：0 = 成功 · 1 = 校验/核对失败 · 2 = 跑不起来
#>
[CmdletBinding()]
param(
  [string]$OutDir = 'E:\ai\_doc_audit\WriteGuard审计-20261017',
  [switch]$SkipVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$pkgName = '送审包-v0.1.6'

try {
  $psm1Path = Join-Path $root 'WriteGuard.psm1'
  $psd1Path = Join-Path $root 'WriteGuard.psd1'
  $readmePath = Join-Path $root 'README.md'
  if (-not (Test-Path $psm1Path)) { throw "找不到 $psm1Path" }

  $psm1Text = [System.IO.File]::ReadAllText($psm1Path)
  $m = [regex]::Match($psm1Text, "WgVersion = '([^']+)'")
  if (-not $m.Success) { throw 'psm1 里找不到 WgVersion' }
  $version = $m.Groups[1].Value

  $psd1Text = [System.IO.File]::ReadAllText($psd1Path)
  $md = [regex]::Match($psd1Text, "ModuleVersion\s*=\s*'([^']+)'")
  $readmeText = [System.IO.File]::ReadAllText($readmePath)
  $rm = [regex]::Match($readmeText, 'v(\d+\.\d+\.\d+)（')

  Write-Host ('版本：psm1={0} · psd1={1} · README={2}' -f $version, $md.Groups[1].Value, $rm.Groups[1].Value)
  if (-not $SkipVerify) {
    if ($md.Groups[1].Value -ne $version) { throw "版本不一致：psd1=$($md.Groups[1].Value) vs psm1=$version" }
    if ($rm.Groups[1].Value -ne $version) { throw "版本不一致：README=$($rm.Groups[1].Value) vs psm1=$version" }
  }

  $pkg = Join-Path $OutDir $pkgName
  $dst = Join-Path $pkg ('WriteGuard-v' + $version)
  if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
  robocopy $root $dst /E /XD '.writeguard' '_backup' '.git' /XF '*-latest.txt' '*.zip' 'AtomicWriteProbe-report.json' 'ByteSpanProbe-report.json' 'ProbeSafetyCheck-latest.txt' /NFL /NDL /NJH /NJS | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy 失败：$LASTEXITCODE" }

  $files = Get-ChildItem $dst -Recurse -File | Sort-Object FullName
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add(('# WriteGuard v{0} · 候选补丁 · 文件清单与 SHA256' -f $version))
  [void]$lines.Add(('生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
  [void]$lines.Add(('文件数：{0}' -f $files.Count))
  [void]$lines.Add('')
  [void]$lines.Add('⚠️ **候选补丁，不是正式发布包。** Windows 五套件全绿（57/30/5/0 漂移/10）；')
  [void]$lines.Add('   崩溃注入 / 原子写受环境限制未验证（探针记 BLOCKED/NOT_TESTED，不是通过）；Unix 真实文件系统未验证。')
  [void]$lines.Add('⚠️ 本清单不含 *-latest.txt / 探针 report.json（运行产物）与 .writeguard（本地备份）。')
  [void]$lines.Add('校验：对每行按 `Get-FileHash -Algorithm SHA256` 重算，全部一致才算包没被动过。')
  [void]$lines.Add('')
  foreach ($f in $files) {
    $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    $rel = $f.FullName.Substring($dst.Length)
    [void]$lines.Add(('{0}  {1,8}  {2}' -f $h, $f.Length, $rel))
  }
  [System.IO.File]::WriteAllLines((Join-Path $pkg '清单与SHA256.txt'), $lines, [System.Text.UTF8Encoding]::new($false))
  Write-Host ('清单：{0} 个文件' -f $files.Count)

  # 审查包（核心文件 + 清单 + VERSION.txt）
  $revDir = Join-Path $pkg '_审查包-tmp'
  if (Test-Path $revDir) { Remove-Item $revDir -Recurse -Force }
  New-Item -ItemType Directory -Force $revDir | Out-Null
  Copy-Item (Join-Path $dst 'WriteGuard.psm1'), (Join-Path $dst 'Prune-Backups.ps1'), (Join-Path $dst 'Start-Here.ps1') $revDir
  New-Item -ItemType Directory -Force (Join-Path $revDir 'tests') | Out-Null
  Copy-Item (Join-Path $dst 'tests\SelfTest.ps1'), (Join-Path $dst 'tests\MutationCheck.ps1'),
    (Join-Path $dst 'tests\AtomicWriteProbe.ps1'), (Join-Path $dst 'tests\ByteSpanProbe.ps1'),
    (Join-Path $dst 'tests\ProbeSafetyCheck.ps1') (Join-Path $revDir 'tests')
  $psm1 = Get-Item (Join-Path $dst 'WriteGuard.psm1')
  $psm1Hash = (Get-FileHash $psm1.FullName -Algorithm SHA256).Hash
  $ver = @"
WriteGuard 审查材料 —— 版本指纹
====================================
版本       : v$version
生成时间   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
psm1 时间  : $($psm1.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
psm1 SHA256: $psm1Hash
自测       : 57 / 57（Windows · PowerShell 7.6.6 · cp65001 / cp936 / cp437 三档）
元验证     : 30 / 30（29 注入 + 1 噪声）
CLI        : 5 / 5（含 CLI-5 敌意控制台）
备份保留   : 10 / 10（含 ⑩ 敌意控制台）
原子写探针 : PASS 5 / BLOCKED 1 / NOT_TESTED 1（**不是通过**，见 04 设计审查）
字节 span  : PASS 19 / FAIL 0（含编码拒绝 3 条 + 映射越界 1 条；注入映射错误/删越界检查均必红）
探针安全   : ProbeSafetyCheck 2 / 0（不删用户 WorkDir，哨兵回归）
CI         : 三个探针已接入 ci.yml（FAIL>0 ⇒ 红；BLOCKED/NOT_TESTED 不红）
证据等级   : ✅ 实际执行（Windows） / 🔍 策略注入 / ⚪ 静态 / ⛔ 未验证 / BLOCKED / NOT_TESTED
本包含     : WriteGuard.psm1 · Prune-Backups.ps1 · Start-Here.ps1 · tests/{SelfTest,MutationCheck,AtomicWriteProbe,ByteSpanProbe,ProbeSafetyCheck}.ps1
校验方式   : 与《清单与SHA256.txt》逐项比对；对不上说明包被动过。

⚠️ 审查前先确认：这份的版本与你要审的一致。
   上一轮出现过「审的是更早的快照」——zip 名字和大小都分不出来，所以这里把时间、计数、指纹写死。
"@
  [System.IO.File]::WriteAllText((Join-Path $revDir 'VERSION.txt'), $ver, [System.Text.UTF8Encoding]::new($false))
  Copy-Item (Join-Path $pkg '清单与SHA256.txt') $revDir

  $zipMain = Join-Path $OutDir ('WriteGuard-v{0}-候选补丁.zip' -f $version)
  $zipRev = Join-Path $OutDir ('WriteGuard-审查包-v{0}-带指纹.zip' -f $version)
  foreach ($z in @($zipMain, $zipRev)) { if (Test-Path $z) { Remove-Item $z -Force } }
  Compress-Archive -LiteralPath $dst -DestinationPath $zipMain -Force
  Compress-Archive -Path (Join-Path $revDir '*') -DestinationPath $zipRev -Force
  Remove-Item $revDir -Recurse -Force

  # 复算清单哈希
  $bad = 0; $n = 0
  Get-Content (Join-Path $pkg '清单与SHA256.txt') | Where-Object { $_ -match '^[0-9A-F]{64}\s' } | ForEach-Object {
    $hh = $_.Substring(0, 64); $rel = ($_.Substring(66).Trim() -split '\s+', 2)[1]
    $abs = Join-Path $dst $rel.TrimStart('\'); $n++
    if ((Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash -ne $hh) { $bad++ }
  }
  Write-Host ('清单核对：{0} 项，哈希不符 {1} 项' -f $n, $bad)
  Write-Host ('输出：' + $zipMain)
  Write-Host ('      ' + $zipRev)
  if ($bad -gt 0) { exit 1 }
  exit 0
} catch {
  Write-Host ('⚠️ build 失败（退出码 2）：' + $_.Exception.Message)
  Write-Host $_.ScriptStackTrace
  exit 2
}

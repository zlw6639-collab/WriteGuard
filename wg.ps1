#Requires -Version 7.0
<#
  wg —— WriteGuard 的命令行门面（"最基础就能用"的那一层）
  ─────────────────────────────────────────────────────────────
  不想写 PowerShell 代码，只想安全地改一个文件？用这个。
  四条子命令：

    # 改 JSON 里某个标量字段（只动那一行；默认演练，加 -Commit 才真写）
    pwsh -NoProfile -File .\wg.ps1 json -File .\config.json -Field version -Value 2.1.0
    pwsh -NoProfile -File .\wg.ps1 json -File .\config.json -Field port -Value 8080 -AsNumber -Commit -Audit

    # 唯一匹配的文本替换（0 处或多处匹配一律拒绝，并告诉你匹配到几处）
    pwsh -NoProfile -File .\wg.ps1 replace -File .\doc.md -Pattern '旧的标题' -Replacement '新的标题' -Commit

    # 只检查"这个模式在文件里唯一吗"（不写任何东西）
    pwsh -NoProfile -File .\wg.ps1 check -File .\doc.md -Pattern '^## 一、'

    # 读审计日志（配合 -Audit / -AuditLog 用）
    pwsh -NoProfile -File .\wg.ps1 audit -File .\.writeguard\audit.jsonl -Tail 20

  退出码：0 = 做成或演练 · 1 = 没做成（拒绝 / 回滚 / 拒绝回滚 / 回滚失败 / 错误）· 2 = 用法或环境错误
          ⚠️ 退出码的**单一事实源**是模块里的 `Get-WgStatusTable` / `Get-WgExitCode`；
             本文件不再自己写一套状态→码的映射（外面那个"每处手写一遍"正是审计指出的漂移源）。
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command,
  [Parameter(Position = 1)][string]$File,
  [string]$Field,
  [string]$Value,
  [switch]$AsNumber,
  [string]$Pattern,
  [string]$Replacement,
  [switch]$Commit,
  [switch]$Audit,
  [string]$AuditLog,
  # ★ 严格审计：审计写不进去 ⇒ 这次写入作废并回滚（状态 AuditBlocked）。默认关闭。
  [switch]$StrictAudit,
  [int]$MaxChangedLines = 10,
  [int]$Tail = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WriteGuard.psm1') -Force

function Show-Usage {
  Write-Host @'
wg —— WriteGuard 命令行门面

  wg json    -File <路径> -Field <字段> -Value <值> [-AsNumber] [-Commit] [-Audit [-StrictAudit]]
  wg replace -File <路径> -Pattern <正则> -Replacement <文本>     [-Commit] [-Audit [-StrictAudit]]
  wg check   -File <路径> -Pattern <正则>
  wg audit   -File <日志路径> [-Tail 20]

  不加 -Commit 就是演练（DryRun）：算出改动面、打印预览，但**一个字节都不写**。
'@
}

function Show-Result($r) {
  Write-Host ("状态：{0}" -f $r.Status)
  Write-Host ("说明：{0}" -f $r.Note)
  if ($r.DiffText) { Write-Host ''; Write-Host '改动预览：'; Write-Host ([string]$r.DiffText) }
  if ($r.Backup) { Write-Host ("备份：{0}" -f $r.Backup) }
  # 拒绝回滚是最需要"看得见"的一种结局：文件**没有**回到写前状态，而且我们刻意没动它
  if ([string]$r.Status -eq 'RollbackRefused') {
    Write-Host '⚠️ 未回滚：目标在回滚前已被改动，按备份覆盖会毁掉更新的数据。'
    Write-Host '   ⇒ 请人工核对上面的备份文件与当前文件，再决定保留哪一份。'
  }
  if ($r.AuditPath) { Write-Host ("审计：{0}" -f $r.AuditPath) }
  if ($r.AuditError) { Write-Host ("⚠️ {0}" -f $r.AuditError) }
}

try {
  switch ($Command) {
    'json' {
      if ([string]::IsNullOrWhiteSpace($File) -or [string]::IsNullOrWhiteSpace($Field)) { Show-Usage; exit 2 }
      # ★ 参数校验（外部审计 2026-10-17：原来"不给 -Value"会把字段写成空串、"‑AsNumber 传 abc"会写出非法 JSON，
      #   而且两条都 EXIT=0、都报 Written —— 门面在骗人）
      # ⚠️ `[string]$Value` 未传时给的是**空串**而不是 $null ⇒ 一条判空就够
      #    （拆成两条会给出误导性文案：没传 -Value 却报"空串"—— 本文件实测踩到过）
      if ([string]::IsNullOrEmpty([string]$Value)) { Write-Host '缺少或为空的 -Value（要写入的值）⇒ 拒绝（不猜）'; exit 2 }
      if ($AsNumber -and ($Value -notmatch '^-?\d+(\.\d+)?([eE][+-]?\d+)?$')) {
        Write-Host "-AsNumber 需要一个数字，拿到「$Value」⇒ 拒绝（不猜）"; exit 2
      }
      $v = $Value
      $r = Invoke-WgWrite -Path $File -Commit:$Commit -Audit:$Audit -AuditLog $AuditLog -StrictAudit:$StrictAudit -MaxChangedLines $MaxChangedLines -Tag 'wg-json' `
        -Mutator { param($s) Set-WgJsonScalar -Text $s.Text -Field $Field -Value $v -AsNumber:$AsNumber } `
        -Verify { param($t, $p)
          $iss = @()
          try { $o = $t | ConvertFrom-Json } catch { return @("复验：结果不是合法 JSON（$($_.Exception.Message)）") }
          $prop = $o.PSObject.Properties[$Field]
          if ($null -eq $prop) { $iss += "复验：解析后找不到字段 $Field" }
          elseif ([string]$prop.Value -cne [string]$v) { $iss += "复验：字段值是「$($prop.Value)」，期望「$v」" }
          return $iss
        }
      Show-Result $r
      exit (Get-WgExitCode -Status ([string]$r.Status))
    }

    'replace' {
      if ([string]::IsNullOrWhiteSpace($File) -or [string]::IsNullOrWhiteSpace($Pattern)) { Show-Usage; exit 2 }
      $r = Invoke-WgWrite -Path $File -Commit:$Commit -Audit:$Audit -AuditLog $AuditLog -StrictAudit:$StrictAudit -MaxChangedLines $MaxChangedLines -Tag 'wg-replace' `
        -Mutator { param($s) Set-WgUniqueSpan -Text $s.Text -Pattern $Pattern -Replacement $Replacement -What '替换目标' } `
        -Verify { param($t, $p)
          # ★ 严格复验（审计：原来的 Contains(值) 在空值下恒真）
          $iss = @()
          if ([string]::IsNullOrEmpty([string]$Replacement)) {
            # ⚠️ -cmatch（大小写敏感）：-match 不敏感 ⇒ "旧内容其实还在、只是换了个大小写"会被漏检
            if ($t -cmatch [regex]::Escape([string]$Pattern)) { $iss += '复验：旧内容仍在（删除未生效）' }
          } elseif ($t -notmatch [regex]::Escape([string]$Replacement)) { $iss += '复验：替换后的内容没找到' }
          return $iss
        }
      Show-Result $r
      exit (Get-WgExitCode -Status ([string]$r.Status))
    }

    'check' {
      if ([string]::IsNullOrWhiteSpace($File) -or [string]::IsNullOrWhiteSpace($Pattern)) { Show-Usage; exit 2 }
      $snap = Get-WgSnapshot -Path $File
      if (-not $snap.Exists) { Write-Host "找不到文件：$File"; exit 2 }
      # ★ 退出码一致性（外部审计 P1）："不唯一"不是一个**异常**，而是一个明确判定 ⇒
      #   说清匹配到几处 + 退出码 1。（原实现靠 Assert 抛异常落到 catch，码虽也是 1，但信息量少一截。）
      $ms = @([regex]::Matches($snap.Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline))
      if ($ms.Count -eq 0) { Write-Host '❌ 定位不到目标（匹配到 0 处）⇒ 拒绝（不猜）'; exit 1 }
      if ($ms.Count -gt 1) { Write-Host "❌ 目标不唯一：匹配到 $($ms.Count) 处 ⇒ 拒绝（不猜）"; exit 1 }
      $line = @($snap.Text.Substring(0, $ms[0].Index) -split "`n").Count
      Write-Host "✅ 唯一匹配：第 $line 行 —— 「$($ms[0].Value)」"
      exit 0
    }

    'audit' {
      $log = if (-not [string]::IsNullOrWhiteSpace($AuditLog)) { $AuditLog } else { $File }
      if ([string]::IsNullOrWhiteSpace($log)) { Show-Usage; exit 2 }
      $rows = @(Get-WgAudit -Path $log -Tail $Tail)
      if ($rows.Count -eq 0) { Write-Host '（审计日志是空的）'; exit 0 }
      $rows | Select-Object ts, status, @{ n = '文件'; e = { [System.IO.Path]::GetFileName([string]$_.path) } },
        @{ n = '改动行'; e = { @($_.changedLines).Count } }, tag |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
      exit 0
    }

    default { Show-Usage; exit 2 }
  }
} catch {
  Write-Host "⚠️ 没做成（$($_.Exception.Message)）"
  exit 1
}

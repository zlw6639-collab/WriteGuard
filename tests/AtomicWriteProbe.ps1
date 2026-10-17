#Requires -Version 7.0
<#
  AtomicWriteProbe —— 原子写 / 崩溃安全的**实验探针**
  ─────────────────────────────────────────────────────────────
  ⚠️ 定位（先读这一行）：
    · **不是产品实现** —— 不改库、不进 `WriteGuard.psm1`、不走主路径；
    · **不是发布门槛** —— 不进 `Start-Here.ps1` 的五套件、不参与 DocCounts 数字；
    · **只记录观察，不归因 OS** —— 异常就记下类型/消息/环境，由人判断；
      脚本**不会**自动写"Windows 不支持"。

  四态（这四种**不能混用**）：
    PASS       实验跑了，且观察符合预期
    FAIL       实验跑了，但观察**不符合**预期（这是真的有问题）
    BLOCKED    实验**没跑成**（环境阻挡：权限拒绝等）—— **权限拒绝 ≠ 原子写失败**
    NOT_TESTED 实验**没有运行**（缺手段/环境）—— **没跑 ≠ 测试通过**

  为什么普通成功/失败测试不够：
    正常路径写成功 ⇒ 只证明"这次没报错"；**不能**证明崩溃时不留半截，
    也**不能**证明并发读者不会看到中间态。这两条要专门的实验：
      · 崩溃安全：在 Move 之前中断（模拟进程被杀）⇒ 原文件必须原样；
      · 并发可见性：读者进程持续读，写者反复替换 ⇒ 读者只应看到"完整旧"或"完整新"。

  输出的两样东西：
    1. 屏幕：每个场景一行结果（四态 + 观察摘要）；
    2. 机器可读报告：JSON（默认 `tests/AtomicWriteProbe-report.json`）。

  用法：
    pwsh -NoProfile -File .\tests\AtomicWriteProbe.ps1
    pwsh -NoProfile -File .\tests\AtomicWriteProbe.ps1 -WorkDir <你的目录> -ReportTo <报告.json>
  退出码：0 = 探针跑完（BLOCKED / NOT_TESTED 也算跑完，**不是失败**）· 2 = 探针自己跑不起来
#>
[CmdletBinding()]
param(
  [string]$WorkDir,
  [string]$ReportTo,
  [int]$ConcurrentRounds = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:results = New-Object System.Collections.Generic.List[object]
function Say([string]$s = '') { Write-Host $s }

function New-Scenario([string]$id, [string]$what) {
  return [ordered]@{
    id          = $id
    what        = $what
    status      = 'not-run'
    exception   = $null
    observed    = [ordered]@{}
    proves      = @()
    notProven   = @()
  }
}
function Add-Result($sc) { [void]$script:results.Add($sc) }

# 跑一个场景。$expect 返回 $true/$false 决定 PASS/FAIL；
# 抛异常 ⇒ BLOCKED（实验没完成，异常记录在案，不归因）。
function Invoke-Probe([string]$id, [string]$what, [scriptblock]$body, [scriptblock]$expect, [string[]]$proves, [string[]]$notProven) {
  $sc = New-Scenario -id $id -what $what
  Say ''
  Say ('── ' + $id + ' · ' + $what)
  try {
    & $body $sc
    $ok = $true
    if ($expect) { $ok = [bool](& $expect $sc) }
    $sc.status = if ($ok) { 'PASS' } else { 'FAIL' }
  } catch {
    $sc.status = 'BLOCKED'
    $sc.exception = [ordered]@{
      type    = $_.Exception.GetType().FullName
      hresult = $_.Exception.HResult
      message = $_.Exception.Message
    }
    Say ('   BLOCKED · ' + $_.Exception.GetType().Name + ' · ' + $_.Exception.Message)
    Say '   （实验没完成：异常已记录，不归因 OS；换个有权限的环境再跑）'
  }
  $sc.proves = @($proves)
  $sc.notProven = @($notProven)
  Say ('   结果：' + $sc.status)
  Add-Result $sc
}

try {
  $work = if ($WorkDir) { $WorkDir } else { Join-Path ([System.IO.Path]::GetTempPath()) ('wg-atomic-probe-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  [void][System.IO.Directory]::CreateDirectory($work)
  $report = if ($ReportTo) { $ReportTo } else { Join-Path $PSScriptRoot 'AtomicWriteProbe-report.json' }

  $codePage = $null
  try { $codePage = [Console]::OutputEncoding.CodePage } catch { $codePage = $null }
  $envInfo = [ordered]@{
    os              = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    osArch          = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    pwsh            = ('{0} {1}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    workDir         = $work
    consoleCodePage = $codePage
    note            = 'BLOCKED = 实验没完成（如权限拒绝），不是原子写失败；NOT_TESTED = 没跑，不是通过'
  }

  Say ('=' * 72)
  Say '  AtomicWriteProbe —— 原子写 / 崩溃安全 实验探针（不是产品实现，不是发布门槛）'
  Say ('=' * 72)
  Say ('  环境：{0} · {1} · {2}' -f $envInfo.os, $envInfo.osArch, $envInfo.pwsh)
  Say '  ⚠️ 四态：PASS（跑了且符合预期）/ FAIL（跑了但不对）/ BLOCKED（没跑成）/ NOT_TESTED（没跑）'
  Say '  ⚠️ 权限拒绝 ≠ 原子写失败；没跑 ≠ 通过。'

  # ── ① File.Replace ─────────────────────────────────────────
  $t1 = Join-Path $work 'replace-target.txt'
  $s1 = Join-Path $work 'replace-src.txt'
  $b1 = Join-Path $work 'replace-bak.txt'
  [System.IO.File]::WriteAllText($t1, 'old')
  [System.IO.File]::WriteAllText($s1, 'new')
  Invoke-Probe -id '1-file-replace' -what 'File.Replace(src, target, backup) 在当前环境是否可用' `
    -body {
    param($sc)
    [System.IO.File]::Replace($s1, $t1, $b1)
    $sc.observed.content = [System.IO.File]::ReadAllText($t1)
    Say ('   观察：内容=' + $sc.observed.content)
  } -expect { param($sc) $sc.observed.content -eq 'new' } `
    -proves @('记录了 File.Replace 在本环境的实际行为（成功或异常类型/消息）') `
    -notProven @('即使 PASS，也不代表断电时原子（Replace 的崩溃语义未测）')

  # ── ② File.Move(overwrite) + 时间保留 ──────────────────────
  $t2 = Join-Path $work 'move-target.txt'
  [System.IO.File]::WriteAllText($t2, 'old2')
  $oldTime = (Get-Date).AddDays(-3)
  [System.IO.File]::SetCreationTime($t2, $oldTime)
  [System.IO.File]::SetLastWriteTime($t2, $oldTime)
  $before2 = Get-Item $t2
  Invoke-Probe -id '2-file-move-overwrite' -what 'File.Move(src, target, $true) + 显式拷时间 ⇒ 内容/时间是否保留' `
    -body {
    param($sc)
    $tmp2 = $t2 + '.tmp'
    [System.IO.File]::WriteAllText($tmp2, 'new2')
    [System.IO.File]::SetCreationTime($tmp2, [System.IO.File]::GetCreationTime($t2))
    [System.IO.File]::SetLastWriteTime($tmp2, [System.IO.File]::GetLastWriteTime($t2))
    [System.IO.File]::Move($tmp2, $t2, $true)
    $after2 = Get-Item $t2
    $sc.observed.content      = [System.IO.File]::ReadAllText($t2)
    $sc.observed.mtimeKept    = ($after2.LastWriteTime -eq $before2.LastWriteTime)
    $sc.observed.createdKept  = ($after2.CreationTime -eq $before2.CreationTime)
    $sc.observed.tmpLeftover  = (Test-Path -LiteralPath $tmp2)
    Say ('   观察：内容=' + $sc.observed.content + ' · mtime保留=' + $sc.observed.mtimeKept +
         ' · 创建时间保留=' + $sc.observed.createdKept + ' · tmp残留=' + $sc.observed.tmpLeftover)
  } -expect { param($sc) $sc.observed.content -eq 'new2' -and $sc.observed.mtimeKept -and $sc.observed.createdKept -and -not $sc.observed.tmpLeftover } `
    -proves @('在临时目录（同卷）里，内容/时间可保留、无 tmp 残留') `
    -notProven @('不能证明 Move 瞬间断电/被杀时目标一定完整（rename 原子性只是理论，未实测）')

  # ── ③ File.Move 无 overwrite（目标已存在）──────────────────
  $t3 = Join-Path $work 'move-noov-target.txt'
  $s3 = Join-Path $work 'move-noov-src.txt'
  [System.IO.File]::WriteAllText($t3, 'keep')
  [System.IO.File]::WriteAllText($s3, 'replacement')
  Invoke-Probe -id '3-file-move-nooverwrite' -what 'File.Move 不带 overwrite、目标已存在 ⇒ 预期拒绝（证明必须显式覆盖）' `
    -body {
    param($sc)
    try {
      [System.IO.File]::Move($s3, $t3)
      $sc.observed.outcome = 'unexpected-success'
      Say '   观察：**没报错**（与预期不同，需人工复核）'
    } catch {
      $sc.observed.outcome = 'rejected-as-expected'
      $sc.observed.exceptionType = $_.Exception.GetType().FullName
      Say ('   观察：按预期拒绝 · ' + $_.Exception.GetType().Name)
    }
  } -expect { param($sc) $sc.observed.outcome -eq 'rejected-as-expected' } `
    -proves @('不带 overwrite 时不会静默覆盖（失败模式明确）') `
    -notProven @('拒绝本身不涉及崩溃安全')

  # ── ④ 中断模拟：Move 之前被杀 ──────────────────────────────
  $t4 = Join-Path $work 'interrupt-target.txt'
  [System.IO.File]::WriteAllText($t4, 'original')
  $tmp4 = $t4 + '.tmp'
  [System.IO.File]::WriteAllText($tmp4, 'half-written')
  Invoke-Probe -id '4-interrupt-before-move' -what '模拟"写 tmp 后、Move 前进程被杀" ⇒ 目标必须原样（不半截）' `
    -body {
    param($sc)
    $sc.observed.targetContent = [System.IO.File]::ReadAllText($t4)
    $sc.observed.tmpLeftover   = (Test-Path -LiteralPath $tmp4)
    Say ('   观察：目标=' + $sc.observed.targetContent + ' · tmp残留=' + $sc.observed.tmpLeftover +
         '（这是**模拟**，不是真杀进程）')
  } -expect { param($sc) $sc.observed.targetContent -eq 'original' } `
    -proves @('"Move 前中断"时目标文件原样、未写半截（模拟层面）') `
    -notProven @('真实的进程被杀/断电未测：沙箱内杀不掉子进程、也没有断电手段 ⇒ 崩溃安全仍是 NOT_TESTED')

  # ── ⑤ 并发可见性：读者进程持续读，写者反复替换 ─────────────
  $t5 = Join-Path $work 'concurrent-target.txt'
  $c5 = Join-Path $work 'concurrent-child.ps1'
  $o5 = Join-Path $work 'concurrent-child-out.txt'
  [System.IO.File]::WriteAllText($t5, ('A' * 64))
  $childSrc = @'
param([string]$Path, [string]$Out, [int]$Seconds)
$end = (Get-Date).AddSeconds($Seconds)
$seen = New-Object System.Collections.Generic.List[string]
$errs = New-Object System.Collections.Generic.List[string]
while ((Get-Date) -lt $end) {
  try {
    $b = [System.IO.File]::ReadAllBytes($Path)
    $seen.Add([System.BitConverter]::ToString($b))
  } catch { $errs.Add($_.Exception.GetType().Name + '|' + $_.Exception.Message) }
  Start-Sleep -Milliseconds 1
}
$all = @('CONTENT:') + @($seen | Select-Object -Unique) + @('ERRORS:') + @($errs | Select-Object -Unique)
[System.IO.File]::WriteAllLines($Out, $all, [System.Text.UTF8Encoding]::new($false))
'@
  [System.IO.File]::WriteAllText($c5, $childSrc, [System.Text.UTF8Encoding]::new($false))
  Invoke-Probe -id '5-concurrent-reader' -what '读者持续读 + 写者反复 Move 替换 ⇒ 读者只看到完整旧/新，不看到半截' `
    -body {
    param($sc)
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $c5, '-Path', $t5, '-Out', $o5, '-Seconds', '2') -PassThru
    for ($i = 0; $i -lt $ConcurrentRounds; $i++) {
      $tmp5 = $t5 + '.tmp'
      [System.IO.File]::WriteAllText($tmp5, ([string]([char](65 + ($i % 2))) * 64))
      [System.IO.File]::Move($tmp5, $t5, $true)
      Start-Sleep -Milliseconds 2
    }
    if (-not $proc.WaitForExit(15000)) { try { $proc.Kill() } catch { } }
    $lines = @(Get-Content -LiteralPath $o5 -Encoding UTF8)
    $idxErr = [array]::IndexOf($lines, 'ERRORS:')
    $contentLines = if ($idxErr -gt 0) { @($lines[1..($idxErr - 1)]) } else { @() }
    $errLines = if ($idxErr -ge 0 -and $idxErr -lt ($lines.Count - 1)) { @($lines[($idxErr + 1)..($lines.Count - 1)]) } else { @() }
    # BitConverter::ToString 用**连字符**分隔（41-41-...），不是空格
    $seen = @($contentLines | Where-Object { $_ -match '^[0-9A-F]{2}(-[0-9A-F]{2})*$' })
    $errs = @($errLines | Where-Object { $_.Trim() -ne '' })
    $unexpected = @($seen | Where-Object {
        $hex = ($_ -split '-')[0]
        ($hex -notin @('41', '42'))
      })
    $sc.observed.distinctContents = $seen.Count
    $sc.observed.unexpectedFirstByte = $unexpected.Count
    $sc.observed.readErrors = $errs.Count
    Say ('   观察：读到不同内容=' + $seen.Count + ' 种 · 非 A/B 首字节=' + $unexpected.Count +
         ' · 读异常=' + $errs.Count)
    if ($errs.Count -gt 0) { Say ('   读异常样例：' + (($errs | Select-Object -First 3) -join ' | ')) }
  } -expect { param($sc) $sc.observed.readErrors -eq 0 -and $sc.observed.unexpectedFirstByte -eq 0 -and $sc.observed.distinctContents -ge 1 } `
    -proves @('在并发读者视角，替换期间只观察到完整内容（旧或新），未观察到半截/空内容（本轮样本）') `
    -notProven @('2 秒窗口的采样不覆盖所有时序；断电/进程被杀仍不在本轮证明范围内')

  # ── ⑥ 只读属性：Move(overwrite) 是否被拒 ──────────────────
  $t6 = Join-Path $work 'readonly-target.txt'
  [System.IO.File]::WriteAllText($t6, 'ro-old')
  [System.IO.File]::SetAttributes($t6, [System.IO.FileAttributes]::ReadOnly)
  Invoke-Probe -id '6-readonly-target' -what '目标带只读属性时，Move(overwrite) 的行为（成功或异常都要记录）' `
    -body {
    param($sc)
    $tmp6 = $t6 + '.tmp'
    [System.IO.File]::WriteAllText($tmp6, 'ro-new')
    [System.IO.File]::Move($tmp6, $t6, $true)
    $sc.observed.content = [System.IO.File]::ReadAllText($t6)
    Say ('   观察：Move 成功 · 内容=' + $sc.observed.content + '（只读属性是否被保留需另测）')
  } -expect { param($sc) $sc.observed.content -eq 'ro-new' } `
    -proves @('记录了只读目标在 Move(overwrite) 下的实际行为') `
    -notProven @('属性/ACL 的完整保留不在本轮范围（rename 已知会重置属主，需对照实验）')

  # ── ⑦ 崩溃安全：明确 NOT_TESTED ───────────────────────────
  $sc7 = New-Scenario -id '7-crash-safety' -what 'Move 瞬间断电/进程被杀 ⇒ 目标是否完整（**唯一真正的崩溃安全命题**）'
  $sc7.status = 'NOT_TESTED'
  $sc7.observed.reason = '沙箱内杀不掉子进程、也没有断电手段；普通成功/失败测试不构成证明'
  $sc7.proves = @()
  $sc7.notProven = @('这是唯一的崩溃安全命题，本轮**没有运行**（NOT_TESTED，不是通过）')
  Say ''
  Say '── 7-crash-safety · Move 瞬间断电/被杀'
  Say '   NOT_TESTED · 本轮**没有运行**（缺手段：沙箱杀不掉子进程 / 无断电注入）'
  Add-Result $sc7

  # ── 汇总 ───────────────────────────────────────────────────
  Say ''
  Say ('─' * 72)
  $pass = @($script:results | Where-Object { $_.status -eq 'PASS' }).Count
  $fail = @($script:results | Where-Object { $_.status -eq 'FAIL' }).Count
  $blk  = @($script:results | Where-Object { $_.status -eq 'BLOCKED' }).Count
  $nt   = @($script:results | Where-Object { $_.status -eq 'NOT_TESTED' }).Count
  Say ("汇总：PASS {0} · FAIL {1} · BLOCKED {2} · NOT_TESTED {3}" -f $pass, $fail, $blk, $nt)
  Say '⚠️ BLOCKED = 实验没完成（如权限拒绝），不是原子写失败；NOT_TESTED = 没跑，不是通过。'

  $doc = [ordered]@{
    schema      = 1
    generatedAt = (Get-Date).ToString('o')
    environment = $envInfo
    scope       = '原子写/崩溃安全的实验探针；四态：PASS/FAIL/BLOCKED/NOT_TESTED；不归因 OS'
    scenarios   = @($script:results | ForEach-Object { [pscustomobject]$_ })
    summary     = [ordered]@{ pass = $pass; fail = $fail; blocked = $blk; notTested = $nt }
  }
  [System.IO.File]::WriteAllText($report, (ConvertTo-Json -InputObject $doc -Depth 8), [System.Text.UTF8Encoding]::new($false))
  Say ('报告：' + $report)

  if (-not $WorkDir) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  exit 0
} catch {
  Write-Host ('⚠️ 探针自己跑不起来（退出码 2）：' + $_.Exception.Message)
  Write-Host $_.ScriptStackTrace
  exit 2
}

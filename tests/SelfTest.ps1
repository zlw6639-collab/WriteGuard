#Requires -Version 7.0
<#
  WriteGuard 自测 ── 零依赖（不用 Pester），退出码 0/1/2
  ─────────────────────────────────────────────────────────
  设计原则（抄我们自己的自证清单）：
    · **"检查通过" ≠ "检查有效"** —— 所以这里主打的不是"正常路径能跑"，
      而是**反向验证**：故意让复验失败、让 Mutator 放弃、让正则匹配到 2 处……
      看库**是不是真的拒绝/回滚**（"看着执行了、其实没做"是我们踩过三次的坑）。
    · 全部在**临时目录**里做，不碰任何真实文件。
    · 报告留痕：tests\SelfTest-latest.txt

  用法：
    pwsh -NoProfile -File .\tests\SelfTest.ps1
    pwsh -NoProfile -File .\tests\SelfTest.ps1 -TestDir <你的可写目录>\wg-selftest   # 默认落系统临时目录
    pwsh -NoProfile -File .\tests\SelfTest.ps1 -Keep                            # 保留临时目录供复看
#>
[CmdletBinding()]
param(
  [string]$TestDir,
  [string]$ModulePath,
  # ⚠️ 参数名**刻意不叫 -ReportPath**：PowerShell 变量名大小写不敏感，
  #    $ReportPath 会和内部的 $reportPath 是同一个变量 ⇒ 被覆盖（我们自己踩过的坑）。
  [string]$ReportTo,
  [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:pass = 0
$script:fail = 0
$script:lines = New-Object System.Collections.ArrayList

function Say([string]$s) { Write-Host $s; [void]$script:lines.Add($s) }

function Case([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; Say ('PASS  ' + $name) }
  catch {
    $script:fail++
    Say ('FAIL  ' + $name)
    Say ('        → ' + $_.Exception.Message)
  }
}
function Assert-True($cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Assert-Eq($a, $b, [string]$msg) {
  # ⚠️ **-cne**：PowerShell 的 -ne 对字符串不区分大小写 ⇒ 尺子自己会把「A 与 a 不同」判成相同（漏报）。
  #    2026-10-17 使用者在库里发现同一个坑后，顺手把尺子也改成大小写敏感。
  if ([string]$a -cne [string]$b) { throw "$msg（期望「$b」，实际「$a」）" }
}
function Assert-Throws([scriptblock]$body, [string]$msg) {
  $threw = $false
  try { & $body } catch { $threw = $true }
  if (-not $threw) { throw "$msg —— 但它**没报错**（静默通过是最坏的一类）" }
}
function Same-Bytes([string]$path, [byte[]]$expected) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  $a = [System.IO.File]::ReadAllBytes($path)
  if ($a.Length -ne $expected.Length) { return $false }
  for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $expected[$i]) { return $false } }
  return $true
}
function New-TestFile([string]$name, [string]$content, [bool]$bom = $false) {
  $p = Join-Path $script:tmp $name
  [System.IO.File]::WriteAllText($p, $content, [System.Text.UTF8Encoding]::new($bom))
  return $p
}
function Get-Bytes([string]$p) { return [System.IO.File]::ReadAllBytes($p) }
# 只读构造的跨平台版（2026-10-18 CI 发现）：.NET 在 Unix 上 ReadOnly 语义与 Windows 不同，
# 统一用 chmod 444（非 root 写会被拒）与 Windows 的只读属性对齐。
function Set-TestReadOnly([string]$p) {
  if ($IsWindows) { (Get-Item -LiteralPath $p).IsReadOnly = $true }
  else {
    # ⚠️ 不用 GetMethod 探测（有重载 ⇒ 歧义匹配会抛）：直接试，失败退回 chmod
    try { [System.IO.File]::SetUnixFileMode($p, [System.IO.UnixFileMode]'UserRead, GroupRead, OtherRead') }
    catch { & chmod 444 -- $p }
  }
}
function Clear-TestReadOnly([string]$p) {
  if ($IsWindows) { (Get-Item -LiteralPath $p).IsReadOnly = $false }
  else {
    try { [System.IO.File]::SetUnixFileMode($p, [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead') }
    catch { & chmod 644 -- $p }
  }
}
function BaksOf([string]$file) {
  $dir = Join-Path $script:tmp '.writeguard'
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  $n = [System.IO.Path]::GetFileName($file)
  # 2026-10-17：备份名变成 <原名>@<来源hash8>.bak-<时间戳>-<tag>
  #   —— 来源 hash 是"不同目录同名文件不合体"的关键，所以这里也要按新格式找
  return @(Get-ChildItem -LiteralPath $dir -Filter "$n@*.bak-*" -File)
}

try {
  $modPath = if ($ModulePath) { $ModulePath } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'WriteGuard.psm1' }
  if (-not (Test-Path -LiteralPath $modPath)) { throw "找不到模块：$modPath" }
  Import-Module $modPath -Force

  $script:tmp = if ($TestDir) { $TestDir } else { Join-Path ([System.IO.Path]::GetTempPath()) ('WriteGuard-selftest-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
  if (Test-Path -LiteralPath $script:tmp) { Remove-Item -LiteralPath $script:tmp -Recurse -Force }
  [void][System.IO.Directory]::CreateDirectory($script:tmp)

  Say "=== WriteGuard 自测（$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')）==="
  Say "模块：$modPath"
  Say "临时目录：$script:tmp"
  Say ''

  Case '① 库自述：版本 + 五规矩齐全' {
    $info = Get-WgInfo
    # ⚠️ 版本断言**从 psd1 读** —— 写死的话每次升版本都要改测试
    #    （v0.1.1 就是这么被卡住的：代码升了、测试里还写着 0.1.0 ⇒ 解压验证直接 FAIL）
    $pjRaw = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'WriteGuard.psd1') -Raw
    $want = ([regex]::Match($pjRaw, "ModuleVersion\s*=\s*'([^']+)'")).Groups[1].Value
    Assert-Eq $info.Version $want '版本'
    Assert-Eq @($info.Rules).Count 5 '规矩条数'
  }

  Case '② 快照：BOM / 换行风格 / SHA256 判定正确' {
    $a = New-TestFile 'snap-bom.md' "第一行`r`n第二行`r`n" $true
    $s = Get-WgSnapshot -Path $a
    Assert-True $s.HasBom '应识别出 BOM'
    Assert-Eq $s.NewLine "`r`n" '换行风格应为 CRLF'
    Assert-Eq $s.Sha256.Length 64 'SHA256 长度'
    $b = New-TestFile 'snap-nobom.md' "只有一行`n" $false
    $s2 = Get-WgSnapshot -Path $b
    Assert-True (-not $s2.HasBom) '无 BOM 应判为无'
    Assert-Eq $s2.NewLine "`n" '换行风格应为 LF'
  }

  Case '③ 规矩① 默认不开：不传 -Commit ⇒ 不写盘、不备份、不建目录' {
    $f = New-TestFile 'dry.txt' "AAA`nBBB`n" $false
    $before = Get-Bytes $f
    $r = Invoke-WgWrite -Path $f -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') } -Tag 'dry' -BackupDir (Join-Path $script:tmp 'drybak')
    Assert-Eq $r.Status 'DryRun' '状态'
    Assert-True (-not $r.Wrote) '不该标记已写'
    Assert-True (Same-Bytes $f $before) '文件必须一个字节都没变'
    Assert-True ($null -eq $r.Backup) 'DryRun 不该产生备份'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:tmp 'drybak'))) '不该创建备份目录'
  }

  Case '④a 备份命名碰撞：递增后缀仍保留来源 hash' {
    $f = New-TestFile 'collision.txt' "before`n"
    $snap = Get-WgSnapshot -Path $f
    $backupDir = Join-Path $script:tmp 'collision-backups'
    $b1 = Backup-WgSnapshot -Snapshot $snap -BackupDir $backupDir -Tag 'same'
    Assert-True ([System.IO.Path]::GetFileName($b1) -match '^collision\.txt@[0-9a-f]{8}\.bak-') '首份备份应带来源 hash'
    # ⚠️ 碰撞只在"同一秒内两次备份"时发生。直接连调两次有极小概率跨秒 ⇒ 测试会随机红。
    #    这里重试到真撞上为止（最多 5 次），既稳定又确实覆盖了 while 补号分支。
    $b2 = $null
    for ($i = 0; $i -lt 5; $i++) {
      $b = Backup-WgSnapshot -Snapshot $snap -BackupDir $backupDir -Tag 'same'
      if ([System.IO.Path]::GetFileName($b) -match '-1$') { $b2 = $b; break }
    }
    Assert-True ($null -ne $b2) '5 次内应至少撞上一次命名冲突（否则覆盖不到补号分支）'
    Assert-True ([System.IO.Path]::GetFileName($b2) -match '^collision\.txt@[0-9a-f]{8}\.bak-.*-1$') '碰撞后缀仍应带来源 hash'
    Assert-True (Same-Bytes $b1 $snap.Bytes) '首份备份必须字节一致'
    Assert-True (Same-Bytes $b2 $snap.Bytes) '碰撞备份必须字节一致'
  }

  Case '㊿a 路径键：大小写敏感与否必须能显式注入（Windows 上也能测 Unix 语义）' {
    # 这条就是为了消掉"Unix 分支只做了静态检查"那个灰区：
    # 平台判断收敛到 Get-WgPathKey，而它的 -CaseInsensitive 可注入 ⇒ **两条分支在 Windows 上都能真跑**。
    $wgm = Get-Module WriteGuard
    $q = { param($p, $ci) & $wgm { param($pp, $cc) Get-WgPathKey -Path $pp -CaseInsensitive $cc } $p $ci }
    $s1 = & $q 'C:\Foo\Bar.txt' $false
    $s2 = & $q 'c:\foo\bar.txt' $false
    Assert-True ($s1 -cne $s2) '大小写敏感时：两个路径必须得到不同的键（Unix 语义）'
    $i1 = & $q 'C:\Foo\Bar.txt' $true
    $i2 = & $q 'c:\foo\bar.txt' $true
    Assert-True ($i1 -ceq $i2) '大小写不敏感时：两个路径必须是同一个键（Windows 语义）'
    $d1 = & $q 'C:\Foo\Bar.txt' $null
    $d2 = & $q 'c:\foo\bar.txt' $null
    if ($IsWindows) { Assert-True ($d1 -ceq $d2) '本平台默认应是不敏感' }
    else { Assert-True ($d1 -cne $d2) '本平台默认应是敏感' }

    # ② 确定性（原话是"完全相同的路径两种策略一致"）：同一策略 + 同一输入，重复调用必须给同一个键。
    #    ⚠️ 不能断言"两种策略产出同一字符串"——不敏感策略会把键变小写，那本来就不同；
    #       但它们指向同一个文件，靠的是"策略一致时才可比"，所以这里只测确定性。
    Assert-True ((& $q 'C:\Foo\Bar.txt' $true) -ceq (& $q 'C:\Foo\Bar.txt' $true)) '同一策略、同一输入：必须确定（不敏感）'
    Assert-True ((& $q 'C:\Foo\Bar.txt' $false) -ceq (& $q 'C:\Foo\Bar.txt' $false)) '同一策略、同一输入：必须确定（敏感）'

    # ③ 生产策略没被测试接口影响：默认调用必须等于"当前平台的显式策略"
    $platformExplicit = if ($IsWindows) { & $q 'C:\Foo\Bar.txt' $true } else { & $q 'C:\Foo\Bar.txt' $false }
    Assert-True ($d1 -ceq $platformExplicit) '默认策略必须等于当前平台的显式策略（不许被环境/残留影响）'

    # ④ 重构前后等价：旧实现（内联）与新实现，在**同一平台、同一输入**下必须得到相同键。
    #    预期差异只允许出现在"旧实现把大小写不同路径合并"的平台上，而这里比的是同平台同输入。
    $oldImpl = { param($p) if ($IsWindows) { $p.ToLowerInvariant() } else { $p } }
    foreach ($p in @('C:\A\x.txt', 'c:\a\x.txt', '/home/A/x', '/home/a/x')) {
      Assert-True ((& $oldImpl $p) -ceq (& $q $p $null)) "重构前后必须同结果：$p"
    }

    # ⑤ 空输入：必须**明确报错**，而不是静默返回一个可能与别的路径碰撞的键
    $threw = $false
    try { & $q '' $true | Out-Null } catch { $threw = $true }
    Assert-True $threw '空路径必须明确报错（不接受"静默返回"）'
  }

  Case '㊿b 批量重复检测：大小写策略必须真的能区分（默认 @{} 会忽略大小写）' {
    # 外部审计 2026-10-17 指出的洞：`Get-WgPathKey` 归一化得对，但 PowerShell 的 `@{}`
    # 默认用不区分大小写的比较器 ⇒ 敏感策略下两个不同的键仍被 ContainsKey 当成同一个。
    # 这条用例直接测**批量入口的行为**，不是只测函数返回值。
    $f = New-TestFile 'dupc.txt' "AAA`n" $false
    $dir = Split-Path $f -Parent
    $plan = @(
      @{ Path = (Join-Path $dir 'dupc.txt'); Mutator = { param($s) $s.Text.Replace('AAA', 'BBB') } },
      @{ Path = (Join-Path $dir 'DUPC.TXT'); Mutator = { param($s) $s.Text.Replace('AAA', 'CCC') } }
    )
    $rCi = Invoke-WgBatch -Plan $plan -CaseInsensitive $true
    Assert-True ([string]$rCi.Note -match '同一个文件') '不敏感策略：两项必须被判为重复目标'
    $rCs = Invoke-WgBatch -Plan $plan -CaseInsensitive $false
    Assert-True ([string]$rCs.Note -notmatch '同一个文件') '敏感策略：不许误判重复（两个键本来不同）'
  }

  Case '㊿c 多进程并发：持锁期间另一个真进程必须 Refused（不是单进程模拟）' {
    # ⚠️ 用 Start-Process + **文件**回传状态，不用管道 —— 沙箱会掐子进程管道（踩坑 91）。
    # 元验证：没有专属 M 场景。它依赖的是"Commit 时加锁"那一关，而 **M15 已经拆过那一关**
    #   （拆掉后 ㊻ 与 ㊿c 都会红，本脚本只断言期望的那一条）。不再造重复注入。
    $f = New-TestFile 'mp.txt' "AAA`n" $false
    $lockFile = "$f.wglock"
    $worker = Join-Path $script:tmp 'mp-worker.ps1'
    $workerCode = @'
param([string]$Module, [string]$Target, [string]$Id, [string]$Out, [int]$SleepMs = 0)
Import-Module $Module -Force
$mut = { param($s) if ($SleepMs -gt 0) { Start-Sleep -Milliseconds $SleepMs }; $s.Text.Replace('AAA', 'XYZ') }
$r = Invoke-WgWrite -Path $Target -Commit -Lock -Mutator $mut.GetNewClosure()
"$Id|$($r.Status)" | Set-Content -LiteralPath $Out -Encoding UTF8
'@
    [System.IO.File]::WriteAllText($worker, $workerCode, [System.Text.UTF8Encoding]::new($false))
    $mod = $modPath

    function Start-Worker([string]$id, [int]$sleepMs) {
      $out = Join-Path $script:tmp "mp-$id.txt"
      if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
      $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $worker, '-Module', $mod,
          '-Target', $f, '-Id', $id, '-Out', $out, '-SleepMs', $sleepMs) -PassThru -WindowStyle Hidden
      return [pscustomobject]@{ Proc = $p; Out = $out; Id = $id }
    }

    # A 持锁 1.5 秒；等锁文件真的出现，再起 B —— 保证 B 是在 A 的锁窗口内启动的
    $a = Start-Worker 'A' 1500
    $waited = 0
    while (-not (Test-Path -LiteralPath $lockFile) -and $waited -lt 100 -and -not $a.Proc.HasExited) {
      Start-Sleep -Milliseconds 50; $waited++
    }
    Assert-True (Test-Path -LiteralPath $lockFile) 'A 应当已经持有锁（否则这条用例证明不了并发）'
    $b = Start-Worker 'B' 0
    $a.Proc.WaitForExit(20000) | Out-Null
    $b.Proc.WaitForExit(20000) | Out-Null

    $sa = if (Test-Path -LiteralPath $a.Out) { (Get-Content -LiteralPath $a.Out -Raw).Trim() } else { '' }
    $sb = if (Test-Path -LiteralPath $b.Out) { (Get-Content -LiteralPath $b.Out -Raw).Trim() } else { '' }
    Assert-Eq $sa 'A|Written' 'A 应当写入成功'
    Assert-Eq $sb 'B|Refused' 'B 应当被锁拒绝（真进程争抢，不是模拟）'
  }

  Case '㊿e1 批量透传 -StrictAudit：某项审计失败 ⇒ 整批回退、两个文件都回到原样' {
    # 补的是外部审计指出的"批量没接这两个开关"：现在透传了，且语义沿用既有的"一项失败 ⇒ 整批回退"。
    # ⚠️ 2026-10-18 外部审计 P1：本条只证明 StrictAudit 被透传；-Lock 的透传另立 ㊿e2（两个开关各自一条证据）。
    $f1 = New-TestFile 'be1.txt' "AAA`n" $false
    $f2 = New-TestFile 'be2.txt' "AAA`n" $false
    $b1 = Get-Bytes $f1
    $b2 = Get-Bytes $f2
    $r = Invoke-WgBatch -Commit -StrictAudit -AuditLog $script:tmp -Plan @(
      @{ Path = $f1; Mutator = { param($s) $s.Text.Replace('AAA', 'X1') } },
      @{ Path = $f2; Mutator = { param($s) $s.Text.Replace('AAA', 'X2') } }
    )
    Assert-Eq $r.BatchStatus 'RolledBack' '某项 AuditBlocked ⇒ 整批应回退'
    Assert-True (Same-Bytes $f1 $b1) '第一项必须回到原样'
    Assert-True (Same-Bytes $f2 $b2) '第二项也必须是原样（不存在"改了一半"）'
  }

  Case '㊿e2 批量透传 -Lock：第 2 项被外部持锁 ⇒ 整批回退（锁真的传给了每一项）' {
    # 2026-10-18 外部审计 P1：㊿e1 只证明 StrictAudit；这条单独证明 -Lock 被透传。
    # 构造：父进程先占住第 2 个文件的 <目标>.wglock（FileShare.None），模拟"另一个进程正在写 f2"。
    # 判据：第 2 项抢锁失败 ⇒ 整批回退；**第 1 项已经写成也必须退回原样**。
    # 若 -Lock 没透传：f2 不会被锁挡住 ⇒ 整批成功 ⇒ 本用例必红。
    $f1 = New-TestFile 'lk1.txt' "AAA`n" $false
    $f2 = New-TestFile 'lk2.txt' "AAA`n" $false
    $b1 = Get-Bytes $f1
    $b2 = Get-Bytes $f2
    $lockPath = [System.IO.Path]::GetFullPath($f2) + '.wglock'
    $hold = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
      $r = Invoke-WgBatch -Commit -Lock -Plan @(
        @{ Path = $f1; Mutator = { param($s) $s.Text.Replace('AAA', 'X1') } },
        @{ Path = $f2; Mutator = { param($s) $s.Text.Replace('AAA', 'X2') } }
      )
    } finally {
      $hold.Dispose()
      if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }
    }
    Assert-Eq $r.BatchStatus 'RolledBack' '第 2 项被锁 ⇒ 整批应回退（而不是"绕开锁照写"）'
    Assert-True (Same-Bytes $f1 $b1) '第 1 项虽然先写成了，也必须退回原样'
    Assert-True (Same-Bytes $f2 $b2) '第 2 项被锁挡下，一个字节都不许写'
  }

  Case '㊿d 编码兼容矩阵：{4 编码} × {CRLF, LF} 要么写成后读回预期，要么明确拒绝且文件不变' {
    # 2026-10-18 外部审计 P0：原版三处证明力不足，已修：
    #   ① GetBytes() **不写 preamble** ⇒ 标 utf8-bom 的样本其实没有 BOM（本版自己拼 BOM）；
    #   ② utf16le/utf16be 不是 .NET 合法编码名 ⇒ 原版把"编码名不支持"当成了"UTF-16 支持"（本版拆出来单独断言拒绝）；
    #   ③ 成功路径只查 Contains ⇒ 本版断言"未修改内容还在"，字节保真另立 ㊿f（本用例只管兼容性）。
    $encs = @(
      @{ N = 'utf8';     E = [System.Text.UTF8Encoding]::new($false); T = 'utf8';     Bom = $false }
      @{ N = 'utf8-bom'; E = [System.Text.UTF8Encoding]::new($true);  T = 'utf8';     Bom = $true  }
      @{ N = 'gb2312';   E = [System.Text.Encoding]::GetEncoding('gb2312');  T = 'gb2312';   Bom = $false }
      @{ N = 'gb18030';  E = [System.Text.Encoding]::GetEncoding('gb18030'); T = 'gb18030';  Bom = $false }
    )
    foreach ($e in $encs) {
      foreach ($nl in @("`r`n", "`n")) {
        $nlName = if ($nl -eq "`r`n") { 'CRLF' } else { 'LF' }
        $label = "$($e.N)/$nlName"
        $f = Join-Path $script:tmp ('enc-' + ($label -replace '[^a-zA-Z0-9]', '_') + '.txt')
        $text = "中文内容${nl}第二行${nl}"
        $body = $e.E.GetBytes($text)
        # ★ 真写 BOM：GetBytes() 不加 preamble，必须自己拼（外部审计 P0 第 1 条）
        $preamble = [byte[]]@()
        if ($e.Bom) { $preamble = $e.E.GetPreamble() }
        $fileBytes = New-Object byte[] ($preamble.Length + $body.Length)
        [Array]::Copy($preamble, $fileBytes, $preamble.Length)
        [Array]::Copy($body, 0, $fileBytes, $preamble.Length, $body.Length)
        [System.IO.File]::WriteAllBytes($f, $fileBytes)
        $before = [System.IO.File]::ReadAllBytes($f)
        $r = Invoke-WgWrite -Path $f -Commit -Encoding $e.T -Mutator { param($s) $s.Text.Replace('中文', '替换') }
        if ($r.Status -eq 'Written') {
          $after = $e.E.GetString([System.IO.File]::ReadAllBytes($f))
          if ($after.Length -ge 1 -and [int]$after[0] -eq 0xFEFF) { $after = $after.Substring(1) }  # GetString 不剥 BOM
          Assert-True ($after.Contains('替换内容')) "$label：写成后必须能按同编码读回预期文本"
          Assert-True ($after.Contains('第二行')) "$label：未修改内容必须还在"
        } else {
          Assert-True (Same-Bytes $f $before) "$label：拒绝时必须逐字节未变（状态 $($r.Status)）"
        }
      }
    }
    # 不支持（也不是 .NET 合法名）的编码 ⇒ 必须明确报错，不能静默当 UTF-16 写
    $f16 = Join-Path $script:tmp 'enc-utf16-unsupported.txt'
    [System.IO.File]::WriteAllBytes($f16, [System.Text.UnicodeEncoding]::new($false, $false).GetBytes("A`n"))
    $b16 = [System.IO.File]::ReadAllBytes($f16)
    $r16 = Invoke-WgWrite -Path $f16 -Commit -Encoding 'utf16le' -Mutator { param($s) $s.Text.Replace('A', 'B') }
    Assert-Eq $r16.Status 'Error' 'utf16le 不是合法编码名 ⇒ 应报错拒绝（不是静默成功）'
    Assert-True (Same-Bytes $f16 $b16) 'utf16le 报错时文件必须一个字节都没变'
  }

  Case '㊿f 字节保真：BOM 原样、CRLF 不混裸 LF、未修改区域字节完全一致' {
    # 2026-10-18 外部审计 P0 的正面要求：真正构造带 BOM 的文件，逐字节核对未修改区域。
    # 判据：① BOM 有就留、没有就不许冒出来；② CRLF 文件里裸 LF 零命中；
    #       ③ 前缀（含 BOM）与后缀逐字节一致，中间那段恰好等于替换文本的字节。
    $cases = @(
      @{ N = 'utf8-bom'; E = [System.Text.UTF8Encoding]::new($true);  T = 'utf8';     Bom = $true;  NL = "`r`n" }
      @{ N = 'utf8';     E = [System.Text.UTF8Encoding]::new($false); T = 'utf8';     Bom = $false; NL = "`n" }
      @{ N = 'gb2312';   E = [System.Text.Encoding]::GetEncoding('gb2312');  T = 'gb2312';   Bom = $false; NL = "`r`n" }
      @{ N = 'gb18030';  E = [System.Text.Encoding]::GetEncoding('gb18030'); T = 'gb18030';  Bom = $false; NL = "`n" }
    )
    foreach ($c in $cases) {
      $nl = [string]$c.NL
      $label = [string]$c.N
      $f = Join-Path $script:tmp ('fid-' + $label + '.txt')
      # 前缀 / 匹配段 / 后缀 三段都含中文，确保"未修改区"真的跨多字节字符
      $prefixText = "第一行${nl}中文"
      $suffixText = "结尾${nl}"
      $old = $prefixText + '待替换段' + $suffixText
      $body = $c.E.GetBytes($old)
      $preamble = [byte[]]@()
      if ($c.Bom) { $preamble = $c.E.GetPreamble() }
      $fileBytes = New-Object byte[] ($preamble.Length + $body.Length)
      [Array]::Copy($preamble, $fileBytes, $preamble.Length)
      [Array]::Copy($body, 0, $fileBytes, $preamble.Length, $body.Length)
      [System.IO.File]::WriteAllBytes($f, $fileBytes)
      $before = [System.IO.File]::ReadAllBytes($f)

      $r = Invoke-WgWrite -Path $f -Commit -Encoding $c.T -Mutator { param($s) $s.Text.Replace('待替换段', '已替换') }
      Assert-Eq $r.Status 'Written' "$label：应写入成功（本用例要求走到写成功路径，不接受拒绝）"

      $now = [System.IO.File]::ReadAllBytes($f)
      $preBytes = $c.E.GetBytes($prefixText)
      $repBytes = $c.E.GetBytes('已替换')
      $sufBytes = $c.E.GetBytes($suffixText)

      # ① BOM 原样（有就保留、没有就不许冒出来）
      if ($c.Bom) {
        Assert-True ($now.Length -ge 3 -and $now[0] -eq 0xEF -and $now[1] -eq 0xBB -and $now[2] -eq 0xBF) "$label：BOM 必须保留"
      } else {
        Assert-True (-not ($now.Length -ge 3 -and $now[0] -eq 0xEF -and $now[1] -eq 0xBB -and $now[2] -eq 0xBF)) "$label：无 BOM 文件不许冒出一个 BOM"
      }

      # ② 未修改区域：BOM + 前缀区逐字节一致
      $headLen = $preamble.Length + $preBytes.Length
      Assert-True ($now.Length -ge $headLen) "$label：写完后文件比前缀还短（被截断？）"
      for ($i = 0; $i -lt $headLen; $i++) {
        Assert-True ($now[$i] -eq $before[$i]) "$label：第 $i 字节（未修改前缀区）被改了"
      }
      # ③ 未修改区域：后缀逐字节一致
      $tailLen = $sufBytes.Length
      for ($i = 0; $i -lt $tailLen; $i++) {
        Assert-True ($now[$now.Length - 1 - $i] -eq $before[$before.Length - 1 - $i]) "$label：倒数第 $($i + 1) 字节（未修改后缀区）被改了"
      }

      # ④ 中间那段 = 替换文本的字节（不多不少）
      $midLen = $now.Length - $headLen - $tailLen
      Assert-Eq $midLen $repBytes.Length "$label：替换段字节长度应等于新文本"
      for ($i = 0; $i -lt $midLen; $i++) {
        Assert-True ($now[$headLen + $i] -eq $repBytes[$i]) "$label：替换段第 $i 字节不对"
      }

      # ⑤ CRLF 文件里不许出现裸 LF（独立再查，不依赖上面的切片）
      if ($nl -eq "`r`n") {
        $afterText = $c.E.GetString($now)
        Assert-True (-not [regex]::IsMatch($afterText, "(?<!\r)\n")) "$label：CRLF 文件里出现了裸 LF（换行被改脏）"
      }
    }
  }

  Case '④ 规矩② 正常写：备份与写前字节逐字节一致 + 新内容落盘' {
    $f = New-TestFile 'ok.txt' "AAA`nBBB`n" $false
    $before = Get-Bytes $f
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'wtest' -MaxChangedLines 5 -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r.Status 'Written' '状态'
    Assert-True $r.Wrote '应标记已写'
    Assert-True ([System.IO.File]::ReadAllText($f).Contains('ZZZ')) '新内容应落盘'
    Assert-True (Same-Bytes $r.Backup $before) '备份必须与写前字节逐字节一致'
    Assert-Eq @(BaksOf $f).Count 1 '应恰好产生 1 个备份'
  }

  Case '⑤ Mutator 返回 $null（定位不到）⇒ Refused，未改任何文件' {
    $f = New-TestFile 'giveup.txt' "AAA`n" $false
    $before = Get-Bytes $f
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'giveup' -Mutator { param($s) $null }
    Assert-Eq $r.Status 'Refused' '状态'
    Assert-True (Same-Bytes $f $before) '文件不该变'
    Assert-Eq @(BaksOf $f).Count 0 '不该产生备份'
  }

  Case '⑥ Mutator 抛异常 ⇒ Error，未改任何文件' {
    $f = New-TestFile 'throw.txt' "AAA`n" $false
    $before = Get-Bytes $f
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'throw' -Mutator { param($s) throw '模拟：定位不到锚点' }
    Assert-Eq $r.Status 'Error' '状态'
    Assert-True (Same-Bytes $f $before) '文件不该变'
  }

  Case '⑦ 幂等：同输入跑第二次 ⇒ NoChange，一个字节都不改、不新增备份' {
    $f = New-TestFile 'idem.txt' "AAA`n" $false
    $r1 = Invoke-WgWrite -Path $f -Commit -Tag 'idem' -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r1.Status 'Written' '第一次状态'
    $b1 = Get-Bytes $f
    $r2 = Invoke-WgWrite -Path $f -Commit -Tag 'idem' -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r2.Status 'NoChange' '第二次状态'
    Assert-True (Same-Bytes $f $b1) '第二次不该改文件'
    Assert-Eq @(BaksOf $f).Count 1 '第二次不该新增备份'
  }

  Case '⑧ 规矩⑤ 复验报问题 ⇒ 按备份字节回滚（含 BOM 原样）' {
    $f = New-TestFile 'rollback.txt' "AAA`r`nBBB`r`n" $true
    $before = Get-Bytes $f
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'rb' -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') } -Verify { param($t, $p) @('故意报一个问题') }
    Assert-Eq $r.Status 'RolledBack' '状态'
    Assert-True (-not $r.Wrote) '不该标记已写'
    Assert-True (Same-Bytes $f $before) '必须逐字节还原（含 BOM）'
    Assert-Eq @($r.VerifyIssues).Count 1 '应带出复验问题清单'
  }

  Case '⑧a 复验失败且回滚本身失败 ⇒ RollbackFailed（不装成功，备份交给调用方）' {
    # 2026-10-18 审计建议（真实失败路径）：回滚**过程中再次发生异常**时，
    # 状态必须是 RollbackFailed，而不是"看起来回滚了"。构造：复验时把目标设成只读，
    # 让 Restore 的 WriteAllBytes 抛 Access denied。
    # ⚠️ 不能只看最终状态：还要证明 ① 复验确实被调用且失败原因被记录；
    #    ② 失败来自"回滚失败"这一支（Note 含固定文案）；③ 目标停在写后中间态（证明没回滚成功）；
    #    ④ 备份完整可读；⑤ 测试后只读属性已清（不污染后续用例）。
    $f = New-TestFile 'rbfail.txt' "AAA`n" $false
    $before = Get-Bytes $f
    $r = $null
    try {
      $r = Invoke-WgWrite -Path $f -Commit -Tag 'rbfail' `
        -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') } `
        -Verify {
        param($t, $p)
        Set-TestReadOnly $p   # 让回滚写不回去（跨平台）
        @('故意报一个问题')
      }
    } finally {
      try { Clear-TestReadOnly $f } catch { }
    }
    Assert-Eq $r.Status 'RollbackFailed' '状态（回滚失败不许报 RolledBack）'
    Assert-True ([bool]$r.Wrote) '应标记"写过"（没还原回来）'
    # ① 复验确实被调用（失败原因被记录）
    Assert-True ((@($r.VerifyIssues) -join ' ').Contains('故意报一个问题')) '复验必须被调用且失败原因被记录'
    # ② 失败来自"回滚失败"这一支，而不是别的路径意外抛错
    Assert-True ([string]$r.Note -match '回滚失败') '说明必须写明"回滚失败"'
    Assert-True ([string]$r.Note -match '请手工用备份还原') '说明必须告诉调用方手工还原'
    # ③ 目标停在写后中间态 ⇒ 证明回滚确实没成功（不是"看起来失败但实际恢复了"）
    Assert-Eq ([System.IO.File]::ReadAllText($f)) "ZZZ`n" '目标必须是写后中间态（证明确实没回滚成功）'
    # ④ 备份存在、可读、且等于写前原始字节
    Assert-True ([bool]$r.Backup) '必须把备份路径交给调用方（人工处置要用它）'
    Assert-True (Test-Path -LiteralPath $r.Backup) '备份必须还在'
    Assert-True (Same-Bytes $r.Backup $before) '备份必须是写前原始字节'
    # ⑤ 只读属性已清（否则会污染后续清理与用例）
    Assert-True (-not ((([System.IO.File]::GetAttributes($f)) -band [System.IO.FileAttributes]::ReadOnly) -eq [System.IO.FileAttributes]::ReadOnly)) '测试后只读属性必须已清除'
  }

  Case '⑨ 「没算出来 ≠ 没问题」：复验脚本抛异常也一律回滚' {
    $f = New-TestFile 'verifythrow.txt' "AAA`n" $false
    $before = Get-Bytes $f
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'vt' -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') } -Verify { param($t, $p) throw '尺子坏了' }
    Assert-Eq $r.Status 'RolledBack' '状态'
    Assert-True (Same-Bytes $f $before) '必须回滚'
    Assert-True ((@($r.VerifyIssues) -join ' ').Contains('复验脚本抛异常')) '应把异常记成失败理由'
  }

  Case '⑩ 规矩③ 越界保护：改动面 > -MaxChangedLines ⇒ 拒绝且未备份' {
    $f = New-TestFile 'maxlines.txt' "1`n2`n3`n4`n" $false
    $before = Get-Bytes $f
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'ml' -MaxChangedLines 1 -Mutator { param($s) $s.Text.Replace('1', 'a').Replace('2', 'b').Replace('3', 'c') }
    Assert-Eq $r.Status 'Refused' '状态'
    Assert-True (Same-Bytes $f $before) '不该写'
    Assert-True ($null -eq $r.Backup) '不该备份'
    Assert-Eq @(BaksOf $f).Count 0 '不该留下备份'
  }

  Case '⑪ 本库不新建文件：路径不存在 ⇒ Refused' {
    $f = Join-Path $script:tmp 'not-exist.txt'
    $r = Invoke-WgWrite -Path $f -Commit -Mutator { param($s) 'X' }
    Assert-Eq $r.Status 'Refused' '状态'
    Assert-True (-not (Test-Path -LiteralPath $f)) '不该凭空建文件'
  }

  Case '⑫ 安全阀：原文件不存在的快照 ⇒ 拒绝还原（不删文件）' {
    $snap = Get-WgSnapshot -Path (Join-Path $script:tmp 'ghost.txt')
    Assert-Throws { Restore-WgSnapshot -Snapshot $snap } '不该允许还原'
  }

  Case '⑬ 写盘保留原换行风格与 BOM 状态（不混入裸 LF）' {
    $f = New-TestFile 'nl.txt' "AAA`r`nBBB`r`n" $false
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'nl' -Mutator { param($s) $s.Text.Replace('BBB', 'CCC') }
    Assert-Eq $r.Status 'Written' '状态'
    $raw = [System.IO.File]::ReadAllBytes($f)
    $txt = [System.Text.Encoding]::UTF8.GetString($raw)
    Assert-True $txt.Contains("`r`n") 'CRLF 应保留'
    Assert-True (-not ($txt.Replace("`r`n", '')).Contains("`n")) '不该混入裸 LF'
    Assert-True (-not ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB)) '无 BOM 应保持无 BOM'
  }

  Case '⑭ 规矩③ 唯一替换：1 处成功 / 0 处与 2 处都拒绝' {
    $t = "aaa`nbbb`n"
    $ok = Set-WgUniqueSpan -Text $t -Pattern 'bbb' -Replacement 'ccc' -What '测试行'
    Assert-True $ok.Contains('ccc') '应替换成功'
    Assert-Throws { Set-WgUniqueSpan -Text $t -Pattern 'zzz' -Replacement 'x' -What '测试行' } '0 处匹配必须拒绝'
    Assert-Throws { Set-WgUniqueSpan -Text "a`na`n" -Pattern 'a' -Replacement 'x' -What '测试行' } '2 处匹配必须拒绝'
    $group = Set-WgUniqueSpan -Text 'value=42' -Pattern 'value=(\d+)' -ReplacementScript { param($m) 'value=' + ([int]$m.Groups[1].Value + 1) } -What '计数'
    Assert-Eq $group 'value=43' 'ReplacementScript 应可用'
  }

  Case '⑮ 规矩③ JSON 只改一行：其余行逐字节不变 + 新字段按锚点插入' {
    $json = @('{', '  "rulesVersion": "v4.4",', '  "authRowsSig": "abc",', '  "exempt": []', '}') -join "`r`n"
    $out = Set-WgJsonScalar -Text $json -Field 'rulesVersion' -Value 'v4.5'
    $inLines = @($json -split "`r?`n")
    $outLines = @($out -split "`r?`n")
    Assert-Eq $outLines.Count $inLines.Count '行数不该变'
    for ($i = 0; $i -lt $inLines.Count; $i++) {
      if ($i -ne 1) { Assert-Eq $outLines[$i] $inLines[$i] "第 $($i + 1) 行不该动" }
    }
    Assert-True $out.Contains('"rulesVersion": "v4.5"') '字段应更新'
    Assert-True $out.Contains("`r`n") 'CRLF 应保留'

    $out2 = Set-WgJsonScalar -Text $out -Field 'ruleCodeSig' -Value 'deadbeef' -InsertAfter 'authRowsSig'
    $o2 = $out2 | ConvertFrom-Json
    Assert-Eq $o2.ruleCodeSig 'deadbeef' '插入后应能解析出该字段'
    Assert-Eq $o2.rulesVersion 'v4.5' '原有字段应保留'
    Assert-Eq $o2.exempt.Count 0 '原有数组成员应保留'
    Assert-True $out2.Contains("`r`n") '插入后仍应 CRLF'

    Assert-Throws { Set-WgJsonScalar -Text $json -Field 'nope' -Value 'x' } '字段不存在且无锚点 ⇒ 必须拒绝'
    Assert-Throws { Set-WgJsonScalar -Text $json -Field 'nope' -Value 'x' -InsertAfter 'alsoNope' } '锚点不存在 ⇒ 必须拒绝'
    Assert-Throws { Set-WgJsonScalar -Text "  `"a`": 1,`n  `"a`": 2`n" -Field 'a' -Value '3' } '字段重复 ⇒ 必须拒绝'
  }

  Case '⑯ 目标必须唯一：0 / 多 ⇒ 失败，不猜；最新会话件取"文件名时间戳"' {
    Assert-Throws { Resolve-WgSingleTarget -Candidates @() -What '交接件' } '0 个候选'
    Assert-Eq (Resolve-WgSingleTarget -Candidates @('only') -What '交接件') 'only' '1 个候选应通过'
    Assert-Throws { Resolve-WgSingleTarget -Candidates @('a', 'b') -What '交接件' } '2 个候选'
    $key = { param($n) $m = [regex]::Match($n, '^交接-(\d{8})-?(\d{4})\.md$'); $m.Groups[1].Value + $m.Groups[2].Value }
    $cands = @('交接-20261016-1750.md', '交接-20261016-2234.md', '交接-20261015-0900.md')
    Assert-Eq (Select-WgUniqueLatest -Candidates $cands -KeyScript $key -What '会话件') '交接-20261016-2234.md' '应取最新'
    Assert-Throws { Select-WgUniqueLatest -Candidates @('交接-20261016-2234.md', '交接-20261016-2234.md') -KeyScript $key -What '会话件' } '同一时间戳多个文件'
  }

  Case '⑰ 「看得见」：DiffText 只显示真正变的那段（替换 / 插入 / 没变）' {
    $f = New-TestFile 'diff.txt' "AAA`nBBB`nCCC`n" $false
    $r = Invoke-WgWrite -Path $f -Mutator { param($s) $s.Text.Replace('BBB', 'ZZZ') }
    Assert-Eq $r.Status 'DryRun' '演练状态'
    Assert-True ($r.DiffText.Contains('- ') -and $r.DiffText.Contains('+ ')) '预览里应有 - 行与 + 行'
    Assert-True ($r.DiffText.Contains('BBB') -and $r.DiffText.Contains('ZZZ')) '应含改前 / 改后内容'
    Assert-True ($r.DiffText.Contains('AAA')) '应带上下文行'
    $r2 = Invoke-WgWrite -Path $f -Mutator { param($s) $s.Text.Replace("BBB`n", "BBB`nNEW`n") }
    $plus = @([regex]::Matches($r2.DiffText, '(?m)^\+')).Count
    Assert-Eq $plus 1 '插入场景应恰好 1 个 + 行（公共前后缀已剥掉）'
    $r3 = Invoke-WgWrite -Path $f -Mutator { param($s) $s.Text }
    Assert-Eq $r3.Status 'NoChange' '幂等'
    Assert-Eq $r3.DiffText '' 'NoChange 不该有预览'
  }

  Case '⑱ 「可追溯」：-Audit 落审计日志；不开审计则一个文件都不多' {
    $f = New-TestFile 'audit.txt' "AAA`n" $false
    $log = Join-Path $script:tmp 'audit\a.jsonl'
    $r0 = Invoke-WgWrite -Path $f -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-True ($null -eq $r0.AuditPath) '不开审计时不该有 AuditPath'
    Assert-True (-not (Test-Path -LiteralPath $log)) '不开审计不该凭空建日志（默认不动）'
    $beforeHash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
    $r1 = Invoke-WgWrite -Path $f -Commit -AuditLog $log -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r1.Status 'Written' '状态'
    Assert-Eq $r1.AuditPath ([System.IO.Path]::GetFullPath($log)) '应记下审计路径'
    $rows = @(Get-WgAudit -Path $log)
    Assert-Eq $rows.Count 1 '应有 1 条记录'
    Assert-Eq $rows[0].status 'Written' '记录的应是状态'
    Assert-Eq $rows[0].sha256Before $beforeHash '应记写前 SHA256'
    Assert-True (@($rows[0].changedLines).Count -ge 1) '应记改动行'
    Assert-True ([string]$rows[0].path.EndsWith('audit.txt')) '应记文件路径'
  }

  Case '⑲ 「失败要报出来」：审计日志写不进去 ⇒ AuditError 有值，主操作不受影响' {
    $f = New-TestFile 'auditfail.txt' "AAA`n" $false
    $bad = Join-Path $f 'nested\a.jsonl'      # 拿一个"文件"当目录用 ⇒ 必然写不进去
    $r = Invoke-WgWrite -Path $f -Commit -AuditLog $bad -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r.Status 'Written' '主操作仍应成功'
    Assert-True (-not [string]::IsNullOrWhiteSpace($r.AuditError)) '审计失败必须报出来（不许静默）'
  }

  Case '⑳ 「多文件事务」：全部演练 ⇒ AllDryRun，一个文件都没动' {
    $f1 = New-TestFile 'b1.txt' "AAA`n" $false
    $f2 = New-TestFile 'b2.txt' "BBB`n" $false
    $b1 = Get-Bytes $f1; $b2 = Get-Bytes $f2
    $b = Invoke-WgBatch -Plan @(
      @{ Path = $f1; Mutator = { param($s) $s.Text.Replace('AAA', 'X1') } },
      @{ Path = $f2; Mutator = { param($s) $s.Text.Replace('BBB', 'X2') } }
    )
    Assert-Eq $b.BatchStatus 'AllDryRun' '状态'
    Assert-True (Same-Bytes $f1 $b1) '文件 1 不该动'
    Assert-True (Same-Bytes $f2 $b2) '文件 2 不该动'
  }

  Case '㉑ 「多文件事务」：任一项不能安全执行 ⇒ 整批拒绝，一个都没写' {
    $f1 = New-TestFile 'c1.txt' "AAA`n" $false
    $f2 = New-TestFile 'c2.txt' "BBB`n" $false
    $b1 = Get-Bytes $f1
    $b = Invoke-WgBatch -Commit -Plan @(
      @{ Path = $f1; Mutator = { param($s) $s.Text.Replace('AAA', 'X1') } },
      @{ Path = $f2; Mutator = { param($s) $null } }        # 第二项放弃 ⇒ 演练阶段就该拦下
    )
    Assert-Eq $b.BatchStatus 'Refused' '状态'
    Assert-True (Same-Bytes $f1 $b1) '第一项也不该被写（整批拒绝）'
  }

  Case '㉒ 「多文件事务」：第 2 项写失败 ⇒ 第 1 项也被回滚（这才是原子）' {
    $f1 = New-TestFile 'd1.txt' "AAA`n" $false
    $f2 = New-TestFile 'd2.txt' "BBB`n" $false
    $b1 = Get-Bytes $f1; $b2 = Get-Bytes $f2
    $b = Invoke-WgBatch -Commit -Plan @(
      @{ Path = $f1; Mutator = { param($s) $s.Text.Replace('AAA', 'X1') } },
      @{ Path = $f2; Mutator = { param($s) $s.Text.Replace('BBB', 'X2') }; Verify = { param($t, $p) @('故意失败') } }
    )
    Assert-Eq $b.BatchStatus 'RolledBack' '状态'
    Assert-Eq $b.Wrote 0 '不该有净写入'
    Assert-True (Same-Bytes $f1 $b1) '**第一项必须被回滚**（事务的关键就在这儿）'
    Assert-True (Same-Bytes $f2 $b2) '第二项应已回滚'
  }

  Case '㉓ 「多文件事务」：全部成功 ⇒ Committed，两个文件都改到' {
    $f1 = New-TestFile 'e1.txt' "AAA`n" $false
    $f2 = New-TestFile 'e2.txt' "BBB`n" $false
    $b = Invoke-WgBatch -Commit -Plan @(
      @{ Path = $f1; Mutator = { param($s) $s.Text.Replace('AAA', 'X1') } },
      @{ Path = $f2; Mutator = { param($s) $s.Text.Replace('BBB', 'X2') } }
    )
    Assert-Eq $b.BatchStatus 'Committed' '状态'
    Assert-Eq $b.Wrote 2 '应写 2 个'
    Assert-True ((Get-Content -LiteralPath $f1 -Raw).Contains('X1')) '文件 1 应改到'
    Assert-True ((Get-Content -LiteralPath $f2 -Raw).Contains('X2')) '文件 2 应改到'
  }

  Case '㉔ 「多文件事务」幂等：同输入再跑 ⇒ NoChange' {
    $f1 = New-TestFile 'g1.txt' "AAA`n" $false
    $plan = @(@{ Path = $f1; Mutator = { param($s) $s.Text.Replace('AAA', 'X1') } })
    $x1 = Invoke-WgBatch -Commit -Plan $plan
    Assert-Eq $x1.BatchStatus 'Committed' '第一次'
    $x2 = Invoke-WgBatch -Commit -Plan $plan
    Assert-Eq $x2.BatchStatus 'NoChange' '第二次'
  }

  Case '㉕ 审计日志坏一行 ⇒ 读的时候必须抛（不许静默跳过）' {
    $dir = Join-Path $script:tmp 'audit'
    if (-not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $log = Join-Path $dir 'broken.jsonl'
    [System.IO.File]::AppendAllText($log, "{`"status`":`"Written`"}`n这不是 JSON`n", [System.Text.UTF8Encoding]::new($false))
    Assert-Throws { Get-WgAudit -Path $log } '坏行必须报错（"没算出来" ≠ "没问题"）'
  }

  Case '㉖ JSON 特殊字符：反斜杠 / 引号 / 换行 ⇒ 必须生成合法 JSON 且读回值相等' {
    $f = Join-Path $script:tmp 'json-special.json'
    [System.IO.File]::WriteAllText($f, "{`r`n  ""path"": ""old""`r`n}`r`n", [System.Text.UTF8Encoding]::new($false))
    $weird = "C:\temp\new" + '"' + 'x'
    $r1 = Invoke-WgWrite -Path $f -Commit -Tag 'json-special' -Mutator { param($s) Set-WgJsonScalar -Text $s.Text -Field 'path' -Value $weird }
    Assert-Eq $r1.Status 'Written' '写入状态'
    $o1 = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    Assert-Eq $o1.path $weird '反斜杠 + 引号必须原样往返'
    $multiline = "a`nb"
    $r2 = Invoke-WgWrite -Path $f -Commit -Tag 'json-special2' -Mutator { param($s) Set-WgJsonScalar -Text $s.Text -Field 'path' -Value $multiline }
    Assert-Eq $r2.Status 'Written' '含换行的值写入状态'
    $o2 = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    Assert-Eq $o2.path $multiline '含换行的值必须原样往返（不能被写成裸换行）'
  }

  Case '㉗ 版本保护：快照之后文件被外部改动 ⇒ 必须拒绝覆盖（TOCTOU）' {
    $f = New-TestFile 'toctou.txt' "AAA`n" $false
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'toctou' -Mutator {
      param($s)
      # 模拟"另一个进程在快照之后改了文件"
      [System.IO.File]::WriteAllText($s.Path, "AAA`nEXTERNAL`n", [System.Text.UTF8Encoding]::new($false))
      return $s.Text.Replace('AAA', 'ZZZ')
    }
    Assert-Eq $r.Status 'Refused' '状态（应拒绝而不是覆盖）'
    Assert-True ((Get-Content -LiteralPath $f -Raw).Contains('EXTERNAL')) '外部修改必须还在（不能被我们覆盖）'
  }

  Case '㉘ 批量：Plan 里两项指向同一文件 ⇒ 整批拒绝（一个都不写）' {
    $f = New-TestFile 'dup.txt' "AAA`n" $false
    $b0 = Get-Bytes $f
    $res = Invoke-WgBatch -Commit -Plan @(
      @{ Path = $f; Mutator = { param($s) $s.Text.Replace('AAA', 'X1') } },
      @{ Path = $f; Mutator = { param($s) $s.Text.Replace('AAA', 'X2') } }
    )
    Assert-Eq $res.BatchStatus 'Refused' '状态'
    Assert-True (Same-Bytes $f $b0) '文件不该被改'
  }

  Case '㉙ 备份失败 ⇒ 目标文件必须一个字节不变（且不报成功）' {
    $f = New-TestFile 'bakfail.txt' "AAA`n" $false
    $b0 = Get-Bytes $f
    $badDir = Join-Path $script:tmp 'not-a-dir.txt'
    [System.IO.File]::WriteAllText($badDir, 'x', [System.Text.UTF8Encoding]::new($false))   # 拿"文件"当目录用
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'bakfail' -BackupDir $badDir -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-True ($r.Status -ne 'Written') '不该报成功'
    Assert-True (Same-Bytes $f $b0) '备份失败 ⇒ 目标文件必须未动'
  }

  Case '㉚ 写入失败（目标只读）⇒ 报错且文件内容不变' {
    $f = New-TestFile 'readonly.txt' "AAA`n" $false
    $b0 = Get-Bytes $f
    Set-TestReadOnly $f
    try {
      $r = Invoke-WgWrite -Path $f -Commit -Tag 'ro' -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
      Assert-True ($r.Status -in @('Error', 'RolledBack')) "写入失败应报 Error / RolledBack（实际 $($r.Status)）"
      Assert-True (Same-Bytes $f $b0) '文件内容必须不变'
    } finally { Clear-TestReadOnly $f }
  }

  Case '㉛ 编码严格：含无效 UTF-8 字节 ⇒ 读快照必须抛（不许静默变 � 再写回去）' {
    $f = Join-Path $script:tmp 'bad-utf8.txt'
    [System.IO.File]::WriteAllBytes($f, [byte[]](0x41, 0x42, 0xFF, 0x43))
    Assert-Throws { Get-WgSnapshot -Path $f } '无效字节必须报错'
    $r = Invoke-WgWrite -Path $f -Commit -Mutator { param($s) 'x' }
    Assert-Eq $r.Status 'Error' '经 Invoke-WgWrite 也应是 Error（不是"成功改坏"）'
  }

  Case '㉜ 契约：psd1 的导出集合必须与 psm1 完全一致' {
    # 外部审计 2026-10-17：加了新函数却忘了同步 psd1 ⇒ 按目录 Import-Module 时那 3 个函数**根本不存在**，
    # 而 README 的 API 表里明写着。一条契约断言就能永久挡住这种漂移。
    $root = Split-Path $PSScriptRoot -Parent
    $psd1 = Get-Content -LiteralPath (Join-Path $root 'WriteGuard.psd1') -Raw
    $psm1 = Get-Content -LiteralPath (Join-Path $root 'WriteGuard.psm1') -Raw
    $exp = [regex]::Match($psd1, 'FunctionsToExport\s*=\s*@\(([^)]*)\)').Groups[1].Value
    $inPsd1 = @([regex]::Matches($exp, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    $exp2 = [regex]::Match($psm1, 'Export-ModuleMember -Function @\(([^)]*)\)').Groups[1].Value
    $inPsm1 = @([regex]::Matches($exp2, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Assert-True ($inPsm1.Count -gt 0) 'psm1 里应能解析出导出清单'
    Assert-Eq ($inPsd1 -join ',') ($inPsm1 -join ',') "psd1 与 psm1 的导出集合必须一致（psd1 $($inPsd1.Count) 个 / psm1 $($inPsm1.Count) 个）"
  }

  Case '㉝ 编码：非 UTF-8 文件不许被静默改坏（往返保真闸门）' {
    # 造一个 GBK 中文文件
    $f = Join-Path $script:tmp 'gbk.txt'
    $gbk = [System.Text.Encoding]::GetEncoding('gb2312')
    [System.IO.File]::WriteAllBytes($f, $gbk.GetBytes("中文内容`r`n"))
    $before = Get-Bytes $f
    # ① 缺省（UTF-8）⇒ 必须拒绝，绝不"静默改成 �"
    $r1 = Invoke-WgWrite -Path $f -Commit -Mutator { param($s) $s.Text.Replace('中文', 'X') }
    Assert-True ($r1.Status -in @('Error', 'Refused')) "缺省编码下必须拒绝（实际 $($r1.Status)）"
    Assert-True (Same-Bytes $f $before) '被拒时文件必须一个字节不变'
    # ② 显式 gb2312 ⇒ 放行，且中文往返保真
    $r2 = Invoke-WgWrite -Path $f -Commit -Encoding 'gb2312' -Mutator { param($s) $s.Text.Replace('中文', '替换') }
    Assert-Eq $r2.Status 'Written' '显式指定编码时应正常写入'
    Assert-Eq $gbk.GetString([System.IO.File]::ReadAllBytes($f)) "替换内容`r`n" 'GBK 往返必须保真'
  }

  Case '㉞ 规矩①：-Audit 不传 -Commit ⇒ 不许在目标目录留任何文件' {
    $d = Join-Path $script:tmp 'audit-dry'
    [void][System.IO.Directory]::CreateDirectory($d)
    $f = Join-Path $d 'x.txt'
    [System.IO.File]::WriteAllText($f, "AAA`n", [System.Text.UTF8Encoding]::new($false))
    $before = Get-Bytes $f
    $r = Invoke-WgWrite -Path $f -Audit -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r.Status 'DryRun' '状态'
    Assert-True (Same-Bytes $f $before) '演练不该动目标文件'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d '.writeguard'))) '演练**不该**建 .writeguard 目录（审计只在真写时落）'
  }

  Case '㉟ 规矩⑤：回滚前目标被第三方改动 ⇒ **拒绝回滚**（不许拿旧备份覆盖更新的数据）' {
    # 外部审计 2026-10-17 P0-3（我们已用 POC 复现）：写入成功后、回滚之前，第三方改了同一个文件。
    # 旧实现只问"和写前不一样吗" ⇒ 直接拿 v1 覆盖 ⇒ **把第三方写进去的内容抹掉**。
    # 判据：既不是写前那份、也不是我写的那份 ⇒ 拒绝回滚，且第三方内容必须原样还在。
    $f = New-TestFile 'third-party.txt' "v1-original`n"
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'tp' `
      -Mutator { param($s) $s.Text.Replace('v1-original', 'v2-our-write') } `
      -Verify { param($t, $p)
        # 模拟"复验期间第三方改了文件"（复验脚本是我们调用的，它可以跑任意久 ⇒ 这个窗口是真的）
        [System.IO.File]::WriteAllText($p, "v3-thirdparty-update`n", [System.Text.UTF8Encoding]::new($false))
        return @('故意报一个问题')
      }
    Assert-Eq $r.Status 'RollbackRefused' '必须拒绝回滚，而不是闷头覆盖'
    Assert-Eq ([System.IO.File]::ReadAllText($f)).Trim() 'v3-thirdparty-update' '第三方内容必须原样保留（本条的全部意义）'
    Assert-True ([bool]$r.Backup) '拒绝回滚时也必须把备份路径交给调用方（人工处置要用它）'
  }

  Case '㊱ 写后哈希：Written 时 Sha256After == 磁盘现状；DryRun 没写盘也就没有写后哈希' {
    # 写后哈希是"回滚前核对是不是我写的"的凭据 —— 审计 P1（加写后哈希）与 P0-3 共用同一份
    $f = New-TestFile 'after-hash.txt' "AAA`n"
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'ah' -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r.Status 'Written' '状态'
    Assert-Eq $r.Sha256After (Get-WgSnapshot -Path $f).Sha256 'Sha256After 必须等于磁盘现状'
    Assert-True ($r.Sha256After -ne $r.Sha256Before) '写前/写后哈希必须不同，否则这条断言没意义'
    $d = New-TestFile 'after-hash-dry.txt' "AAA`n"
    $r2 = Invoke-WgWrite -Path $d -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r2.Status 'DryRun' '演练状态'
    Assert-True ($null -eq $r2.Sha256After) '演练没写盘 ⇒ 不该有写后哈希'
  }

  Case '㊲ 契约：库源码里出现的每个状态都必须在 Get-WgStatusTable 里（退出码也因此不漂）' {
    # 与 ㉜（psd1 ≡ psm1）同一思路：**加了状态却忘了进表 ⇒ 当场炸**，
    # 而不是等上线后调用方发现"这个状态我该按成功还是失败处理"。
    $root = Split-Path $PSScriptRoot -Parent
    $psm1 = Get-Content -LiteralPath (Join-Path $root 'WriteGuard.psm1') -Raw
    $found = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($psm1, "\`$res\.Status\s*=\s*'([A-Za-z]+)'")) { [void]$found.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($psm1, "\`$out\.BatchStatus\s*=\s*'([A-Za-z]+)'")) { [void]$found.Add($m.Groups[1].Value) }
    $found = @($found | Sort-Object -Unique)
    Assert-True ($found.Count -ge 8) "应能从源码里解析出状态清单（实际 $($found.Count) 个）"
    $table = @(Get-WgStatusTable)
    $missing = @($found | Where-Object { $_ -notin @($table.Status) })
    Assert-True ($missing.Count -eq 0) "这些状态没进 Get-WgStatusTable：$($missing -join '、')"
    foreach ($s in $found) { Assert-True ((Get-WgExitCode -Status $s) -in @(0, 1)) "状态 $s 的退出码应只有 0 / 1 两种" }
    Assert-Eq (Get-WgExitCode -Status 'Written') 0 'Written 应退 0'
    Assert-Eq (Get-WgExitCode -Status 'RollbackRefused') 1 '拒绝回滚 = 没做成 ⇒ 应退 1'
    Assert-Throws { Get-WgExitCode -Status 'NoSuchStatus' } '未知状态必须抛（不猜退出码）'
  }

  Case '㊳ 批量事务：回滚前有一项被第三方改动 ⇒ BatchStatus=RollbackRefused，且那一项不被覆盖' {
    # 「别只修一半」：单文件路径挡住了，批量路径必须同样挡住（否则从批量走就破了）
    $f1 = New-TestFile 'batch-tp-1.txt' "AAA`n"
    $f2 = New-TestFile 'batch-tp-2.txt' "BBB`n"
    $r = Invoke-WgBatch -Commit -Plan @(
      @{ Path = $f1; Mutator = { param($s) $s.Text.Replace('AAA', 'A2') }; Tag = 'bt1' },
      @{ Path = $f2; Mutator = { param($s) $s.Text.Replace('BBB', 'B2') }; Tag = 'bt2'
         Verify = { param($t, $p)
           # 在第 2 项复验时改**第 1 项**的文件 —— 模拟第三方在批次中途插进来
           $other = Join-Path (Split-Path $p -Parent) 'batch-tp-1.txt'
           [System.IO.File]::WriteAllText($other, "FOREIGN`n", [System.Text.UTF8Encoding]::new($false))
           return @('故意失败')
         } }
    )
    Assert-Eq $r.BatchStatus 'RollbackRefused' '批量也必须拒绝覆盖第三方内容'
    Assert-Eq ([System.IO.File]::ReadAllText($f1)).Trim() 'FOREIGN' '第 1 项已被第三方改 ⇒ 不许回滚覆盖它'
    Assert-Eq ([System.IO.File]::ReadAllText($f2)).Trim() 'BBB' '第 2 项自己失败 ⇒ 应已回滚到写前'
    Assert-True (@($r.RollbackIssues).Count -ge 1) '拒绝回滚必须留下说明（机器可读）'
  }

  Case '㊴ 审计日志增强：每条记录都要有 opId / 写后哈希 / 恢复状态字段' {
    # 外部审计 2026-10-17 P1（审计日志增强）：只有"写前哈希"不够 ——
    # 出事后还得能回答"我们写进去的是什么"（sha256After）和"最后怎么处置的"（recovery）。
    $d = Join-Path $script:tmp 'audit-enh'
    [void][System.IO.Directory]::CreateDirectory($d)
    $log = Join-Path $d 'wg.jsonl'
    $f = New-TestFile 'audit-enh.txt' "AAA`n"
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'ae' -AuditLog $log -Mutator { param($s) $s.Text.Replace('AAA', 'ZZZ') }
    Assert-Eq $r.Status 'Written' '状态'
    $rows = @(Get-WgAudit -Path $log)
    Assert-Eq $rows.Count 1 '应有一条审计记录'
    $row = $rows[0]
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$row.opId)) '必须有操作 ID（同一次操作能被引用）'
    Assert-Eq ([string]$row.sha256After) ([string]$r.Sha256After) '审计里的写后哈希必须与结果一致'
    Assert-Eq ([string]$row.recovery) 'none' '写入成功 ⇒ 恢复状态应为 none'

    # 拒绝回滚那条路：审计里必须能看出"我们**刻意没有**回滚"
    $log2 = Join-Path $d 'wg2.jsonl'
    $f2 = New-TestFile 'audit-enh-2.txt' "v1`n"
    $r2 = Invoke-WgWrite -Path $f2 -Commit -Tag 'ae2' -AuditLog $log2 `
      -Mutator { param($s) $s.Text.Replace('v1', 'v2') } `
      -Verify { param($t, $p)
        [System.IO.File]::WriteAllText($p, "v3`n", [System.Text.UTF8Encoding]::new($false))
        return @('故意报一个问题')
      }
    Assert-Eq $r2.Status 'RollbackRefused' '状态'
    Assert-Eq ([string](@(Get-WgAudit -Path $log2)[0]).recovery) 'rollback-refused' '拒绝回滚必须能在审计里看出来'
  }

  Case '㊵ 批量回滚必须回到**本次提交前**的版本（不许拿演练阶段的旧快照还原）' {
    # 外部审计 2026-10-17 问题 A（已用 POC 复现）：演练与提交之间文件被第三方改过时，
    # 旧实现用"演练快照"还原 ⇒ 把第三方写进去的内容一起抹掉。修复后凭据绑定到本次提交自己的备份。
    # 构造手法：让**演练阶段**第 2 项的 Mutator 去改第 1 项的文件 —— 单进程内稳定造出那个窗口。
    $d = Join-Path $script:tmp 'batch-drift'
    [void][System.IO.Directory]::CreateDirectory($d)
    $f1 = Join-Path $d 'd1.txt'
    $f2 = Join-Path $d 'd2.txt'
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($f1, "AAA common`n", $enc)      # v1：演练阶段读到的版本
    [System.IO.File]::WriteAllText($f2, "BBB second`n", $enc)

    $r = Invoke-WgBatch -Commit -Plan @(
      @{ Path = $f1; Tag = 'd1'; Mutator = { param($s) $s.Text.Replace('AAA', 'A2') } },
      @{ Path = $f2; Tag = 'd2'
         Mutator = { param($s)
           $dd = Split-Path $s.Path -Parent
           $fl = Join-Path $dd 'tp.flag'
           if (-not (Test-Path -LiteralPath $fl)) {
             # 只在第一次（= 演练阶段）动手 ⇒ 模拟"演练之后、提交之前被第三方改动"
             [System.IO.File]::WriteAllText((Join-Path $dd 'd1.txt'), "AAA common thirdparty`n",
               [System.Text.UTF8Encoding]::new($false))
             [System.IO.File]::WriteAllText($fl, 'x', [System.Text.UTF8Encoding]::new($false))
           }
           return $s.Text.Replace('BBB', 'B2')
         }
         Verify = { param($t, $p) @('故意失败') } }
    )
    Assert-Eq $r.BatchStatus 'RolledBack' '批量应回滚'
    Assert-Eq ([System.IO.File]::ReadAllText($f1)).Trim() 'AAA common thirdparty' '必须回到**提交前**那一版（第三方内容要保住）'
    Assert-Eq @($r.DriftedPlans).Count 1 '应报出"演练之后被改动过"的那一项'
    Assert-True (([string]$r.Note).Contains('演练之后')) '说明里应点出演练预览已过时'
  }

  Case '㊶ 大小写敏感：只改大小写也必须真写（PowerShell 的 -eq 不区分大小写）' {
    # 2026-10-17 **使用者发现**：库多处用 -eq / -ne 做"有没有变"的判断，而 PowerShell 对字符串的
    # -eq **不区分大小写** ⇒ 'Hello World' → 'hello world' 被判成"内容一致" ⇒ 静默 NoChange、修改丢掉。
    $f = New-TestFile 'case-only.txt' "Hello World`n"
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'case' -Mutator { param($s) $s.Text.Replace('Hello World', 'hello world') }
    Assert-Eq $r.Status 'Written' '只改大小写也必须真写（不许报 NoChange）'
    Assert-Eq ([System.IO.File]::ReadAllText($f)).Trim() 'hello world' '磁盘上必须变成小写那一版'
    # 幂等仍然要成立：改完**再跑一遍**，这次才该是真 NoChange
    $r2 = Invoke-WgWrite -Path $f -Commit -Tag 'case' -Mutator { param($s) $s.Text.Replace('Hello World', 'hello world') }
    Assert-Eq $r2.Status 'NoChange' '内容确实一样时才该 NoChange（幂等没被修坏）'
  }

  Case '㊷ 大小写敏感：diff 预览与改动行计数必须看得见"只改大小写"的那一行' {
    # 与 ㊶ 同源、但更隐蔽：-eq 不敏感时，混在其它改动里的"大小写行"会被 diff 当成**没变** ⇒
    # **预览与实际写入不一致**（预览说这行没动，写盘却把它改了）。
    $f = New-TestFile 'case-diff.txt' "第一行 alpha`n第二行 BETA`n第三行 gamma`n"
    $r = Invoke-WgWrite -Path $f -Commit -Tag 'casediff' -Mutator {
      param($s)
      $s.Text.Replace('第一行 alpha', '第一行 ALPHA').Replace('第三行 gamma', '第三行 delta')
    }
    Assert-Eq $r.Status 'Written' '状态'
    Assert-True (@($r.ChangedLines) -contains 1) '第 1 行（只改大小写）必须算改动'
    Assert-True (@($r.ChangedLines) -contains 3) '第 3 行（真改字）必须算改动'
    Assert-True (([string]$r.DiffText).Contains('ALPHA')) '预览里必须看得见大小写变化'
  }

  Case '㊸ 严格审计：审计写不进去 ⇒ 写入作废、按备份还原（AuditBlocked）' {
    $f = Join-Path $script:tmp 'audit-strict.md'
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($f, "AAA`n", $enc)
    $before = [System.IO.File]::ReadAllBytes($f)
    # 把审计日志指向一个**已存在的目录** ⇒ AppendAllText 必然抛
    $r = Invoke-WgWrite -Path $f -Mutator { param($t) $t -replace 'AAA', 'BBB' } -Commit -StrictAudit -AuditLog $script:tmp
    Assert-Eq $r.Status 'AuditBlocked' '严格审计下状态'
    Assert-Eq ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f))) ([System.Convert]::ToBase64String($before)) '文件必须逐字节回到写前'
    Assert-Eq ([bool]$r.Committed) $false '作废时 Committed 必须为 false'
    Assert-True ([string]$r.AuditError -like '*严格审计*') 'AuditError 必须说明原因'
  }

  Case '㊹ 对照：不传 -StrictAudit ⇒ 审计失败不影响主操作（只报 AuditError）' {
    $f = Join-Path $script:tmp 'audit-loose.md'
    [System.IO.File]::WriteAllText($f, "AAA`n", [System.Text.UTF8Encoding]::new($false))
    $r = Invoke-WgWrite -Path $f -Mutator { param($t) $t -replace 'AAA', 'BBB' } -Commit -AuditLog $script:tmp
    Assert-Eq $r.Status 'Written' '默认模式下状态'
    Assert-True ([System.IO.File]::ReadAllText($f).Contains('BBB')) '主操作必须成功'
    Assert-True ($null -ne $r.AuditError) '审计失败必须报出来（不许静默）'
  }

  Case '㊺ -Lock：写入成功，且不留下锁文件' {
    $f = Join-Path $script:tmp 'lock-ok.md'
    [System.IO.File]::WriteAllText($f, "AAA`n", [System.Text.UTF8Encoding]::new($false))
    $r = Invoke-WgWrite -Path $f -Mutator { param($t) $t -replace 'AAA', 'BBB' } -Commit -Lock
    Assert-Eq $r.Status 'Written' '状态'
    Assert-Eq ([System.IO.File]::Exists("$f.wglock")) $false '锁文件必须被清理（否则下次自己挡自己）'
  }

  Case '㊻ -Lock：锁被别人占住 ⇒ 拒绝写入（不并发破坏）' {
    $f = Join-Path $script:tmp 'lock-busy.md'
    [System.IO.File]::WriteAllText($f, "AAA`n", [System.Text.UTF8Encoding]::new($false))
    $h = [System.IO.File]::Open("$f.wglock", [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
      $r = Invoke-WgWrite -Path $f -Mutator { param($t) $t -replace 'AAA', 'BBB' } -Commit -Lock
      Assert-Eq $r.Status 'Refused' '状态（并发保护）'
      Assert-Eq ([System.IO.File]::ReadAllText($f).Trim()) 'AAA' '文件必须一个字节没动'
    } finally {
      $h.Dispose()
      Remove-Item -LiteralPath "$f.wglock" -Force -ErrorAction SilentlyContinue
    }
  }

  Case '㊼ -Lock：陈旧锁（超过 120 秒）⇒ 接管并写入成功' {
    $f = Join-Path $script:tmp 'lock-stale.md'
    [System.IO.File]::WriteAllText($f, "AAA`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText("$f.wglock", 'stale')
    [System.IO.File]::SetLastWriteTime("$f.wglock", (Get-Date).AddMinutes(-5))
    $r = Invoke-WgWrite -Path $f -Mutator { param($t) $t -replace 'AAA', 'BBB' } -Commit -Lock
    Assert-Eq $r.Status 'Written' '陈旧锁应被接管'
    Assert-Eq ([System.IO.File]::Exists("$f.wglock")) $false '锁文件必须被清理'
  }

  Case '㊽ 审计轮转：主日志超过上限 ⇒ 归档旧记录、主文件重新开始' {
    $f = New-TestFile 'rot.txt' "v0`n" $false
    $log = Join-Path $script:tmp 'rot\audit.jsonl'
    foreach ($i in 1..3) {
      $n = $i
      $null = Invoke-WgWrite -Path $f -Commit -Tag 'rot' -AuditLog $log -MaxAuditBytes 1000 `
        -Mutator { param($t) $t -replace "v$($n-1)", "v$n" }
    }
    $dir = Split-Path $log -Parent
    $arch = @(Get-ChildItem -LiteralPath $dir -Filter 'audit-*.jsonl')
    Assert-True ($arch.Count -ge 1) '超过上限后应产生归档文件'
    Assert-True ((Get-Item -LiteralPath $log).Length -lt 1000) '主文件应重新开始（小于上限）'
    Assert-True ([System.IO.File]::ReadAllText($arch[0].FullName).Contains('"opId"')) '归档必须保留历史记录'
  }

  Case '㊾ 锁的平台断言：持锁期间删不掉（否则 120 秒"接管"就能误抢活锁）' {
    # ⚠️ 这是**平台断言**：它自己用 FileShare.None 打开锁文件，测的是**操作系统语义**，不是库的锁实现。
    #    所以它**没有对应的元验证**（改 psm1 影响不到它）—— 库那边的独占行为由 ㊻「锁被占住 ⇒ Refused」负责。
    #    分清楚这两件事：㊾ 证明"这个平台上删除会被挡住"，㊻ 证明"库确实拿独占锁"。
    $f = Join-Path $script:tmp 'lock-assert.md'
    [System.IO.File]::WriteAllText($f, "AAA`n", [System.Text.UTF8Encoding]::new($false))
    $lock = "$f.wglock"
    $h = [System.IO.File]::Open($lock, [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
      $deleted = $false
      try { [System.IO.File]::Delete($lock); $deleted = $true } catch { }
      if ($IsWindows) {
        # 实测三组（正常持锁 / mtime 改到 5 分钟前 / 再开第二句柄）全部失败
        Assert-Eq $deleted $false 'Windows：持锁期间删除必须失败 —— 这是"120 秒接管不会误抢活锁"的依据'
      } else {
        # Unix 允许删除打开的文件 ⇒ 接管可能双持。这条不是 bug，是已知风险，README 里写明了。
        Assert-Eq $deleted $true 'Unix：持锁期间仍可删除 ⇒ 陈旧接管存在双持风险（已知，文档已标注）'
      }
    } finally {
      $h.Dispose()
      Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
  }

  Say ''
  Say ('─' * 60)
  Say ("结果：PASS $script:pass / FAIL $script:fail")
  Say ("临时目录：$script:tmp")
  $verdict = if ($script:fail -gt 0) { "❌ 有 $script:fail 项未通过（自测不过 = 库不可信，别拿它去改真文件）" } else { "✅ 全绿（$script:pass 条反向验证都按预期拒绝 / 回滚 / 原子化）" }
  Say "结论：$verdict"
  Say ('退出码：' + $(if ($script:fail -gt 0) { 1 } else { 0 }))

  $reportFile = if ($ReportTo) { $ReportTo } else { Join-Path $PSScriptRoot 'SelfTest-latest.txt' }
  $script:lines -join "`r`n" | Set-Content -LiteralPath $reportFile -Encoding UTF8
  Write-Host "报告：$reportFile"

  if (-not $Keep) { Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
  else { Write-Host "（-Keep：临时目录保留）" }

  exit $(if ($script:fail -gt 0) { 1 } else { 0 })
} catch {
  Write-Host "⚠️ 自测跑不起来（退出码 2）：$($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  exit 2
}

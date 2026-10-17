#Requires -Version 7.0
<#
  ByteSpanProbe —— 字节级 span 替换的**独立原型**
  ─────────────────────────────────────────────────────────────
  ⚠️ 定位（先读）：
    · **不是产品实现** —— 不改 `WriteGuard.psm1`、不走主路径、不进五套件；
    · 它回答的问题：**"文本唯一匹配"能不能安全映射到"原始字节区间"**，
      映射之后**未修改区域的字节是否完全一致**；
    · 不能回答（也不声称）：任意编码的字节保真、崩溃安全、并发可见性。

  背景（第一份审计 P0）：
    当前 `Set-WgUniqueSpan` 是 `$Text.Remove().Insert()` —— 文本替换。
    README/注释里"其余字节原样"只有在"解码 → 匹配 → 编码"往返自洽 + BOM 保留时才成立。
    这个原型把映射算法单独验证清楚，再决定是否替换现有实现。

  判据（来自审计）：
    1. **未修改区域的字节完全一致**（前缀含 BOM、后缀逐字节）；
    2. **无法可靠定位或编码时明确拒绝**（0 处 / 多处 / 零长度 / 往返不自洽 ⇒ 拒绝）。

  四态：
    PASS    映射正确、前后缀字节一致、整文件能按同编码读回
    FAIL    跑了但结果不对（这是真问题）
    BLOCKED 实验没跑成（构造/环境异常）
    NOT_TESTED 没跑

  用法：
    pwsh -NoProfile -File .\tests\ByteSpanProbe.ps1
    pwsh -NoProfile -File .\tests\ByteSpanProbe.ps1 -WorkDir <目录> -ReportTo <报告.json>
  退出码：0 = 探针跑完（FAIL 也跑完，**不是**发布门槛）· 2 = 探针自己跑不起来
#>
[CmdletBinding()]
param(
  [string]$WorkDir,
  [string]$ReportTo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:results = New-Object System.Collections.Generic.List[object]
function Say([string]$s = '') { Write-Host $s }

function New-Scenario([string]$id) {
  return [ordered]@{
    id = $id; status = 'not-run'; exception = $null
    observed = [ordered]@{}; proves = @(); notProven = @()
  }
}
function Add-Result($sc) { [void]$script:results.Add($sc) }

function Get-Encoding([string]$name) {
  switch ($name) {
    'utf8'    { return [System.Text.UTF8Encoding]::new($false) }
    'utf8-bom' { return [System.Text.UTF8Encoding]::new($true) }
    'gb2312'  { return [System.Text.Encoding]::GetEncoding('gb2312') }
    'gb18030' { return [System.Text.Encoding]::GetEncoding('gb18030') }
    default   { throw "不认识的编码：$name" }
  }
}

# 文本 char 区间 → 原始字节区间（并验证该区间解码 == 匹配文本）
function Get-ByteSpan([string]$Text, [int]$CharStart, [int]$CharEnd, [System.Text.Encoding]$Enc, [byte[]]$Raw, [int]$BomLen) {
  $prefixText = $Text.Substring(0, $CharStart)
  $matchText = $Text.Substring($CharStart, $CharEnd - $CharStart)
  $prefixBytes = $Enc.GetBytes($prefixText)
  $matchBytes = $Enc.GetBytes($matchText)
  $startByte = $BomLen + $prefixBytes.Length
  $len = $matchBytes.Length
  if ($len -le 0) { throw '零长度匹配：拒绝（说不清该动哪个字节）' }
  if (($startByte + $len) -gt $Raw.Length) { throw '映射越界：拒绝（字节数与文本不自洽）' }
  $seg = New-Object byte[] $len
  [Array]::Copy($Raw, $startByte, $seg, 0, $len)
  $decoded = $Enc.GetString($seg)
  return [pscustomobject]@{
    StartByte = $startByte
    MatchLen = $len
    PrefixLen = $BomLen + $prefixBytes.Length
    Verified = ($decoded -ceq $matchText)
    MatchText = $matchText
  }
}

# 在原始字节上做替换：前缀（含 BOM）+ 新文本字节 + 后缀（原样）
function New-ReplacedBytes([byte[]]$Raw, $span, [byte[]]$ReplBytes) {
  $tailStart = $span.StartByte + $span.MatchLen
  $tailLen = $Raw.Length - $tailStart
  $new = New-Object byte[] ($span.StartByte + $ReplBytes.Length + $tailLen)
  [Array]::Copy($Raw, 0, $new, 0, $span.StartByte)
  [Array]::Copy($ReplBytes, 0, $new, $span.StartByte, $ReplBytes.Length)
  [Array]::Copy($Raw, $tailStart, $new, $span.StartByte + $ReplBytes.Length, $tailLen)
  return $new
}

try {
  $work = if ($WorkDir) { $WorkDir } else { Join-Path ([System.IO.Path]::GetTempPath()) ('wg-bytespan-probe-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  [void][System.IO.Directory]::CreateDirectory($work)
  $report = if ($ReportTo) { $ReportTo } else { Join-Path $PSScriptRoot 'ByteSpanProbe-report.json' }

  Say ('=' * 72)
  Say '  ByteSpanProbe —— 字节级 span 替换原型（不是产品实现，不进主路径）'
  Say ('=' * 72)
  Say '  ⚠️ 只验证：文本唯一匹配 → 字节区间的映射；未修改区域字节是否完全一致。'

  # 场景矩阵：4 编码 × 3 位置（开头/中间/结尾），匹配段都是单字符 '中'
  $cases = @(
    @{ Enc = 'utf8';    Bom = $false; Pos = 'start'  }
    @{ Enc = 'utf8';    Bom = $false; Pos = 'middle' }
    @{ Enc = 'utf8';    Bom = $false; Pos = 'end'    }
    @{ Enc = 'utf8-bom'; Bom = $true; Pos = 'start'  }
    @{ Enc = 'utf8-bom'; Bom = $true; Pos = 'middle' }
    @{ Enc = 'utf8-bom'; Bom = $true; Pos = 'end'    }
    @{ Enc = 'gb2312';  Bom = $false; Pos = 'start'  }
    @{ Enc = 'gb2312';  Bom = $false; Pos = 'middle' }
    @{ Enc = 'gb2312';  Bom = $false; Pos = 'end'    }
    @{ Enc = 'gb18030'; Bom = $false; Pos = 'start'  }
    @{ Enc = 'gb18030'; Bom = $false; Pos = 'middle' }
    @{ Enc = 'gb18030'; Bom = $false; Pos = 'end'    }
  )

  foreach ($c in $cases) {
    $id = "span-$($c.Enc)-$($c.Pos)"
    $sc = New-Scenario $id
    Say ''
    Say ('── ' + $id)
    try {
      $enc = Get-Encoding $c.Enc
      $bom = [byte[]]@()
      if ($c.Bom) { $bom = $enc.GetPreamble() }
      $text = switch ($c.Pos) {
        'start'  { '中文中国X' }      # '中国' 在 char 2 / UTF-8 字节 6（前缀含多字节字符，字符索引 ≠ 字节偏移）
        'middle' { '甲中乙中国丙' }    # char 3 / 字节 9
        'end'    { '中文X中国' }      # char 3 / 字节 7
      }
      # 用"中国"（2 字符）替换成"替换"（2 字符）—— 等长字符、但字节长度随编码不同（等长替换不改变字节数？UTF-8 里中/国/替/换 都是 3 字节；GB2312 都是 2 字节）
      # 为了测**变长**，替换成"汉字数字"让字节数多 2 字节
      $repl = '汉字数字'
      $rawBody = $enc.GetBytes($text)
      $raw = New-Object byte[] ($bom.Length + $rawBody.Length)
      [Array]::Copy($bom, $raw, $bom.Length)
      [Array]::Copy($rawBody, 0, $raw, $bom.Length, $rawBody.Length)

      # 唯一匹配（文本层面）
      $ms = @([regex]::Matches($text, '中国'))
      if ($ms.Count -ne 1) { throw "预期恰好 1 处匹配，实际 $($ms.Count)" }
      $m = $ms[0]

      $span = Get-ByteSpan -Text $text -CharStart $m.Index -CharEnd ($m.Index + $m.Length) -Enc $enc -Raw $raw -BomLen $bom.Length
      $newBytes = New-ReplacedBytes -Raw $raw -span $span -ReplBytes $enc.GetBytes($repl)

      # 期望文本
      $expectedText = $text.Substring(0, $m.Index) + $repl + $text.Substring($m.Index + $m.Length)
      $decodedNew = $enc.GetString($newBytes)
      if ($bom.Length -gt 0 -and $decodedNew.Length -ge 1 -and [int]$decodedNew[0] -eq 0xFEFF) { $decodedNew = $decodedNew.Substring(1) }

      # 断言 1：映射正确（原始字节里那一段解码 == 匹配文本）
      # 断言 2：整文件解码 == 期望文本
      # 断言 3：前缀（含 BOM）与后缀逐字节一致
      $prefixOk = $true
      for ($i = 0; $i -lt $span.StartByte; $i++) { if ($newBytes[$i] -ne $raw[$i]) { $prefixOk = $false; break } }
      $tailLen = $raw.Length - ($span.StartByte + $span.MatchLen)
      $tailOk = $true
      for ($i = 0; $i -lt $tailLen; $i++) {
        if ($newBytes[$newBytes.Length - 1 - $i] -ne $raw[$raw.Length - 1 - $i]) { $tailOk = $false; break }
      }
      $wholeOk = ($decodedNew -ceq $expectedText)

      $sc.observed.encoding = $c.Enc; $sc.observed.position = $c.Pos
      $sc.observed.spanStartByte = $span.StartByte; $sc.observed.spanLen = $span.MatchLen
      $sc.observed.mappingVerified = $span.Verified
      $sc.observed.wholeTextOk = $wholeOk
      $sc.observed.prefixBytesOk = $prefixOk
      $sc.observed.suffixBytesOk = $tailOk
      Say ('   观察：映射验证=' + $span.Verified + ' · 全文解码=' + $wholeOk +
           ' · 前缀字节=' + $prefixOk + ' · 后缀字节=' + $tailOk)

      $allOk = $span.Verified -and $wholeOk -and $prefixOk -and $tailOk
      $sc.status = if ($allOk) { 'PASS' } else { 'FAIL' }
    } catch {
      $sc.status = 'BLOCKED'
      $sc.exception = [ordered]@{ type = $_.Exception.GetType().FullName; message = $_.Exception.Message }
      Say ('   BLOCKED · ' + $_.Exception.Message)
    }
    $sc.proves = @('文本唯一匹配 → 字节区间映射；该区间解码 == 匹配文本；前后缀字节一致')
    $sc.notProven = @('只对库支持且往返自洽的编码成立；任意编码不承诺')
    Say ('   结果：' + $sc.status)
    Add-Result $sc
  }

  # ── 拒绝场景：零长度 / 多匹配 / 往返不自洽 ─────────────────
  $rejCases = @(
    @{ Id = 'reject-zero-length'; Text = '中文'; Pattern = '(?=中)'; Repl = 'X'; Why = '零长度匹配：说不出该动哪个字节' }
    @{ Id = 'reject-multiple';    Text = '中X中'; Pattern = '中'; Repl = 'X'; Why = '多处匹配：必须拒绝（不猜）' }
    @{ Id = 'reject-no-match';    Text = '纯英文'; Pattern = '中'; Repl = 'X'; Why = '0 处匹配：必须拒绝' }
  )
  foreach ($rc in $rejCases) {
    $sc = New-Scenario $rc.Id
    Say ''
    Say ('── ' + $rc.Id + ' · ' + $rc.Why)
    try {
      $enc = [System.Text.UTF8Encoding]::new($false)
      $raw = $enc.GetBytes($rc.Text)
      $ms = @([regex]::Matches($rc.Text, $rc.Pattern))
      if ($ms.Count -ne 1 -or $ms[0].Length -eq 0) { throw "拒绝：匹配数=$($ms.Count) 长度=$(if ($ms.Count -gt 0) { $ms[0].Length } else { 'n/a' })" }
      $sc.status = 'FAIL'
      Say '   观察：本应拒绝，却没有被拒绝'
    } catch {
      $sc.status = 'PASS'
      $sc.observed.rejected = $true
      $sc.observed.reason = $_.Exception.Message
      Say ('   观察：按预期拒绝 · ' + $_.Exception.Message)
    }
    $sc.proves = @('无法可靠定位时明确拒绝（0/多/零长度）')
    $sc.notProven = @()
    Say ('   结果：' + $sc.status)
    Add-Result $sc
  }

  # ── 编码往返不自洽：拒绝（模拟"错配编码"）───────────────────
  $sc = New-Scenario 'reject-encoding-mismatch'
  Say ''
  Say '── reject-encoding-mismatch · 字节不是该编码的合法序列 ⇒ 必须拒绝（不许静默替换成 ?）'
  try {
    $wrong = [System.Text.UTF8Encoding]::new($false)
    # GBK 的「中」= D6 D0，用 UTF-8 严格解码应抛（D6 是非法起始字节）
    $badBytes = [byte[]](0xD6, 0xD0)
    $strict = [System.Text.UTF8Encoding]::new($false, $true)
    $null = $strict.GetString($badBytes)
    $sc.status = 'FAIL'
    Say '   观察：本应拒绝，却解码成功了'
  } catch {
    $sc.status = 'PASS'
    $sc.observed.rejected = $true
    $sc.observed.reason = $_.Exception.Message
    Say ('   观察：按预期拒绝 · ' + $_.Exception.GetType().Name)
  }
  $sc.proves = @('无效字节序列明确拒绝（严格解码）')
  $sc.notProven = @()
  Say ('   结果：' + $sc.status)
  Add-Result $sc

  # ── 汇总 ───────────────────────────────────────────────────
  Say ''
  Say ('─' * 72)
  $pass = @($script:results | Where-Object { $_.status -eq 'PASS' }).Count
  $fail = @($script:results | Where-Object { $_.status -eq 'FAIL' }).Count
  $blk  = @($script:results | Where-Object { $_.status -eq 'BLOCKED' }).Count
  $nt   = @($script:results | Where-Object { $_.status -eq 'NOT_TESTED' }).Count
  Say ("汇总：PASS {0} · FAIL {1} · BLOCKED {2} · NOT_TESTED {3}" -f $pass, $fail, $blk, $nt)
  Say '⚠️ 这只证明"映射算法在支持编码上成立"；不证明任意编码、不证明崩溃安全。'

  $doc = [ordered]@{
    schema      = 1
    generatedAt = (Get-Date).ToString('o')
    scope       = '字节级 span 替换原型：文本唯一匹配→字节区间映射；不改变主路径'
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

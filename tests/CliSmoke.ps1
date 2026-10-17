#Requires -Version 7.0
<#
  CLI 冒烟测试 —— `wg.ps1` 是"**不改代码就能用**"的那一层，单独给它一份证据
  ─────────────────────────────────────────────────────────────
  为什么单独一个文件：它与库的反向验证是**两层东西**（一层测"规矩"，一层测"门面"），
  混在一起会让条数失去含义（那是库的规格，数字只认各套件自己的"结果："行）。
  用法：pwsh -NoProfile -File .\tests\CliSmoke.ps1
  退出码：0 = 全绿 · 1 = 有失败 · 2 = 跑不起来
#>
[CmdletBinding()]
param([string]$TestDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:pass = 0; $script:fail = 0
$script:lines = New-Object System.Collections.ArrayList
function Say([string]$s = '') { [void]$script:lines.Add($s); Write-Host $s }
function Case([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; Say ('PASS  ' + $name) }
  catch { $script:fail++; Say ('FAIL  ' + $name); Say ('        → ' + $_.Exception.Message) }
}
function Assert-Eq($a, $b, [string]$msg) { if ([string]$a -cne [string]$b) { throw "$msg（期望「$b」，实际「$a」）" } }
function Assert-True($c, [string]$msg) { if (-not $c) { throw $msg } }
function BytesEq([byte[]]$a, [byte[]]$b) {
  if ($a.Length -ne $b.Length) { return $false }
  for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
  return $true
}
# ─────────────────────────────────────────────────────────────
# 跨进程捕获输出：**自己把编码钉死成 UTF-8**，不依赖宿主默认代码页。
#   2026-10-18 第二份审计实测：cp437 控制台下 CLI-1/2/3 假红（中文输出变 `?`）。
#   中文社区定位 ≠ 只在 UTF-8 环境下可靠。
#   ⚠️ 参数名（-File / -Commit）必须原样写进命令串——加引号会变成字符串位置参数。
# ─────────────────────────────────────────────────────────────
function ConvertTo-CmdArg([string]$a) {
  if ($a -like '-*') { return $a }
  return "'" + ($a -replace "'", "''") + "'"
}
function Invoke-NativeUtf8([string]$Script, [string[]]$ArgList) {
  $parts = @("& '" + ($Script -replace "'", "''") + "'")
  foreach ($a in $ArgList) { $parts += (ConvertTo-CmdArg $a) }
  $cmd = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; " + ($parts -join ' ')
  # ★ 父进程这一侧也要钉死：子进程按 UTF-8 写，父进程必须按 UTF-8 解码，两边一致才不假红。
  #   钉在**函数内部**（而不是只在脚本开头钉一次）：这样即便调用方中途改过控制台编码，捕获仍然正确。
  #   ⚠️ 这一行是 CLI-5 的守卫 —— 摘掉它 CLI-5 必须红（M31）。
  $prevEnc = [Console]::OutputEncoding
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  try { return & pwsh -NoProfile -Command $cmd 2>&1 }
  finally { [Console]::OutputEncoding = $prevEnc }
}

try {
  $cli = Join-Path (Split-Path $PSScriptRoot -Parent) 'wg.ps1'
  if (-not (Test-Path -LiteralPath $cli)) { throw "找不到 CLI：$cli" }
  $tmp = if ($TestDir) { $TestDir } else { Join-Path ([System.IO.Path]::GetTempPath()) ('wg-cli-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
  [void][System.IO.Directory]::CreateDirectory($tmp)

  function Invoke-Cli([string[]]$CliArgs) {
    $out = Invoke-NativeUtf8 -Script $cli -ArgList $CliArgs | Out-String -Width 200
    return [pscustomobject]@{ Code = [int]$LASTEXITCODE; Out = $out }
  }

  $json = Join-Path $tmp 'cfg.json'
  # ⚠️ 用**单引号 here-string** 写 JSON：双引号字符串里 `\"` 不是 PowerShell 转义（反引号才是），
  #    会写出带反斜杠的非法 JSON ⇒ 被测 CLI 报"定位不到字段"（本测试第一版就这样误报了两条失败）。
  $jsonText = @'
{
  "version": "1.0.0",
  "name": "demo"
}
'@
  [System.IO.File]::WriteAllText($json, $jsonText, [System.Text.UTF8Encoding]::new($false))
  $before = [System.IO.File]::ReadAllBytes($json)

  Case 'CLI-1 json 演练：默认不写盘（DryRun + 原件未动）' {
    $r = Invoke-Cli @('json', '-File', $json, '-Field', 'version', '-Value', '9.9.9')
    Assert-Eq $r.Code 0 '退出码'
    Assert-True ($r.Out -match '状态：DryRun') '应报 DryRun'
    Assert-True ($r.Out -match '改动预览') '应给 diff 预览'
    Assert-True (BytesEq ([System.IO.File]::ReadAllBytes($json)) $before) '演练后文件必须一个字节没变'
  }

  Case 'CLI-2 json -Commit -AuditLog：只改那一行 + 审计可读回' {
    $log = Join-Path $tmp 'audit\wg.jsonl'
    $r = Invoke-Cli @('json', '-File', $json, '-Field', 'version', '-Value', '9.9.9', '-Commit', '-AuditLog', $log)
    Assert-Eq $r.Code 0 '退出码'
    Assert-True ($r.Out -match '状态：Written') '应报 Written'
    $txt = [System.IO.File]::ReadAllText($json, [System.Text.Encoding]::UTF8)
    Assert-True ($txt.Contains('"version": "9.9.9"')) '新值应落盘'
    Assert-True ($txt.Contains('"name": "demo"')) '其他字段应原样保留'
    $a = Invoke-Cli @('audit', '-File', $log)
    Assert-Eq $a.Code 0 'audit 退出码'
    Assert-True ($a.Out -match 'Written') '审计里应有这条记录'
  }

  Case 'CLI-3 check：唯一匹配 ⇒ 0；重复 ⇒ 1（拒绝，不猜）' {
    $r1 = Invoke-Cli @('check', '-File', $json, '-Pattern', 'version')
    Assert-Eq $r1.Code 0 '唯一时退出码'
    Assert-True ($r1.Out -match '唯一匹配') '应报唯一匹配'
    $r2 = Invoke-Cli @('check', '-File', $json, '-Pattern', '"')
    Assert-Eq $r2.Code 1 '重复时应退出码 1'
    Assert-True ($r2.Out -match '匹配到') '应报匹配到几处'
  }

  Case 'CLI-4 replace：唯一替换成功；找不到目标 ⇒ 拒绝（退出码 1）' {
    $f = Join-Path $tmp 'note.md'
    [System.IO.File]::WriteAllText($f, "## 标题一`n`n正文`n", [System.Text.UTF8Encoding]::new($false))
    $r1 = Invoke-Cli @('replace', '-File', $f, '-Pattern', '## 标题一', '-Replacement', '## 新标题', '-Commit')
    Assert-Eq $r1.Code 0 '退出码'
    Assert-True ([System.IO.File]::ReadAllText($f).Contains('## 新标题')) '应替换成功'
    $r2 = Invoke-Cli @('replace', '-File', $f, '-Pattern', '不存在的目标', '-Replacement', 'x', '-Commit')
    Assert-Eq $r2.Code 1 '找不到目标应退出码 1'
  }

  Case 'CLI-5 非 UTF-8 控制台：中文输出不许变成 ?（断言不依赖宿主代码页）' {
    # 2026-10-18 实测：cp437 下 CLI-1/2/3 假红（中文全变 ?）。
    # 这里**主动**把控制台换成敌意编码（GBK：中文可表示、U+21B3 不可表示）再跑同样的断言，
    # 证明钉编码真在起作用，而不是"恰好本机是 UTF-8"。摘掉它 ⇒ 本条必须红（M31）。
    $j5 = Join-Path $tmp 'enc.json'
    # ⚠️ 必须是**多行** JSON：Set-WgJsonScalar 按行首定位字段（`^\s*"field"\s*:`），
    #    单行 `{"version": ...}` 匹配不上 —— 这是库的既有边界，不是本用例要测的编码问题。
    $jsonText5 = @'
{
  "version": "1.0.0"
}
'@
    [System.IO.File]::WriteAllText($j5, $jsonText5, [System.Text.UTF8Encoding]::new($false))
    $prev = [Console]::OutputEncoding
    try {
      [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
      $r = Invoke-Cli @('json', '-File', $j5, '-Field', 'version', '-Value', '2.0.0')
      Assert-Eq $r.Code 0 '退出码'
      Assert-True ($r.Out -match '状态：DryRun') '中文输出必须可读（不许变成 ?）'
      Assert-True ($r.Out -match '改动预览') '中文输出必须可读（改动预览）'
    } finally { [Console]::OutputEncoding = $prev }
  }

  Say ''
  Say ('─' * 60)
  Say ("结果：PASS $script:pass / FAIL $script:fail")
  Say "结论：$(if ($script:fail -gt 0) { '❌ CLI 层有失败' } else { '✅ CLI 层全绿（门面这一层也有证据）' })"
  Say ('退出码：' + $(if ($script:fail -gt 0) { 1 } else { 0 }))

  $reportFile = Join-Path $PSScriptRoot 'CliSmoke-latest.txt'
  $script:lines -join "`r`n" | Set-Content -LiteralPath $reportFile -Encoding UTF8
  Write-Host "报告：$reportFile"

  if (-not $TestDir) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  exit $(if ($script:fail -gt 0) { 1 } else { 0 })
} catch {
  Write-Host "⚠️ CLI 冒烟跑不起来（退出码 2）：$($_.Exception.Message)"
  exit 2
}

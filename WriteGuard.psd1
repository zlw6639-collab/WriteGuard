@{
  RootModule           = 'WriteGuard.psm1'
  ModuleVersion        = '0.1.6'
  GUID                 = 'ab0bbd2d-357e-42f1-884f-470bd597b14f'
  Author               = '猫咖没有猫猫'
  Description          = '写操作五规矩的可复用护栏：默认不开 / 原样备份 / 只改白名单 / 读回复验 / 失败回滚。'
  PowerShellVersion    = '7.0'
  FunctionsToExport    = @(
    'Get-WgInfo',
    'Get-WgSnapshot',
    'Backup-WgSnapshot',
    'Restore-WgSnapshot',
    'Assert-WgUniqueMatch',
    'Set-WgUniqueSpan',
    'Set-WgJsonScalar',
    'Resolve-WgSingleTarget',
    'Select-WgUniqueLatest',
    'Get-WgDiffText',
    'Invoke-WgWrite',
    'Invoke-WgBatch',
    'Get-WgAudit',
    'Get-WgStatusTable',
    'Get-WgExitCode'
  )
  CmdletsToExport      = @()
  VariablesToExport    = @()
  AliasesToExport      = @()
  PrivateData          = @{
    PSData = @{
      Tags       = @('guard', 'file-write', 'safety', 'audit')
      ProjectUri = ''
    }
  }
}

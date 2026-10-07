param([string]$Serial = '2G0YC5ZF7V0664', [switch]$Install, [switch]$Software)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\Test-MpvShared.ps1" -Serial $Serial -Install:$Install -Diagnostic Audio -Hardware:(!$Software)

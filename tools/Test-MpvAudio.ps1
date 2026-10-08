param([Parameter(Mandatory=$true)][string]$Serial, [switch]$Install, [switch]$Software)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\Test-MpvShared.ps1" -Serial $Serial -Install:$Install -Diagnostic Audio -Hardware:(!$Software)

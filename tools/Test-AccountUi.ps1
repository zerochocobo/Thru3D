param([string]$Godot = $(if ($env:GODOT_EXE) { $env:GODOT_EXE } else { (Get-Command godot -ErrorAction Stop).Source }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'artifacts/account-ui'
New-Item -ItemType Directory -Force -Path $output | Out-Null
foreach ($case in @('test_account_panel', 'test_cloud_accounts', 'test_media_servers', 'test_library_menu', 'test_i18n')) {
    $stdout = Join-Path $output ($case + '.log')
    $stderr = Join-Path $output ($case + '-errors.log')
    $arguments = @('--headless', '--xr-mode', 'off', '--path', "$workspace/app/godot", '--quit-after', '1800', '--script', "res://tests/$case.gd")
    $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit(60000)) { throw "Test remains active: $case PID $($process.Id)" }
    $log = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    if ($process.ExitCode -ne 0 -or $log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw "Account UI regression failed: $case" }
    Write-Output ($log.Trim())
}

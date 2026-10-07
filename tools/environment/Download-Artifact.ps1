param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$Sha256,
    [long]$ExpectedBytes = 0
)

$ErrorActionPreference = 'Stop'
$parentDirectory = Split-Path -Parent $Destination
New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null

if (Test-Path -LiteralPath $Destination) {
    $existingHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($existingHash -eq $Sha256) {
        Write-Output "Verified cached artifact: $Destination"
        exit 0
    }
}

Write-Output "Downloading: $Uri"
if ($ExpectedBytes -gt 0) {
    $offset = if (Test-Path -LiteralPath $Destination) { (Get-Item -LiteralPath $Destination).Length } else { 0 }
    if ($offset -gt $ExpectedBytes) { throw 'Existing file is larger than the expected artifact.' }
    $chunkBytes = 16MB
    while ($offset -lt $ExpectedBytes) {
        $lastByte = [Math]::Min($offset + $chunkBytes - 1, $ExpectedBytes - 1)
        $chunkPath = "$Destination.part"
        $headerPath = "$Destination.part.headers"
        & curl.exe --fail --location --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 30 --max-time 120 --range "$offset-$lastByte" --silent --show-error --dump-header $headerPath --output $chunkPath $Uri
        if ($LASTEXITCODE -ne 0) { throw "Range download failed with exit code $LASTEXITCODE : $Uri" }
        $expectedChunkBytes = $lastByte - $offset + 1
        if ((Get-Item -LiteralPath $chunkPath).Length -ne $expectedChunkBytes) { throw 'Range response has the wrong size.' }
        $headers = Get-Content -LiteralPath $headerPath -Raw
        if ($headers -notmatch "(?im)^content-range:\s*bytes\s+$offset-$lastByte/$ExpectedBytes\s*$") { throw 'Range response has an unexpected Content-Range.' }
        $destinationStream = [IO.File]::Open($Destination, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $chunkStream = [IO.File]::OpenRead($chunkPath)
        try { $chunkStream.CopyTo($destinationStream) } finally { $chunkStream.Dispose(); $destinationStream.Dispose() }
        $offset = $lastByte + 1
        Write-Output "Downloaded $offset / $ExpectedBytes bytes"
    }
} else {
    & curl.exe --fail --location --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 30 --max-time 300 --continue-at - --silent --show-error --output $Destination $Uri
    if ($LASTEXITCODE -ne 0) { throw "Download failed with exit code $LASTEXITCODE : $Uri" }
}

$downloadHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
if ($downloadHash -ne $Sha256) {
    throw "SHA256 mismatch for $Destination. Expected $Sha256; got $downloadHash."
}
Write-Output "Verified SHA256: $downloadHash"
Write-Output "Saved: $Destination ($((Get-Item -LiteralPath $Destination).Length) bytes)"

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSourceSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedTargetSha256,
    [Parameter(Mandatory)][string]$BackupPath
)

$ErrorActionPreference = 'Stop'

function Get-ByteHash([byte[]]$Bytes) {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

$sourceFull = (Get-Item -LiteralPath $SourcePath).FullName
$targetFull = (Get-Item -LiteralPath $TargetPath).FullName
$backupFull = [System.IO.Path]::GetFullPath($BackupPath)
if ($sourceFull -ieq $targetFull -or $backupFull -ieq $sourceFull -or $backupFull -ieq $targetFull) {
    throw 'Source, existing target, and backup must be different paths.'
}
if ([System.IO.Path]::GetExtension($sourceFull) -ine '.docx' -or
    [System.IO.Path]::GetExtension($targetFull) -ine '.docx') {
    throw 'This helper accepts stored DOCX files only.'
}
if (Test-Path -LiteralPath $backupFull) { throw 'Backup already exists; choose a new local backup path.' }
if (-not (Test-Path -LiteralPath ([System.IO.Path]::GetDirectoryName($backupFull)) -PathType Container)) {
    throw 'Create the local backup directory before running this helper.'
}

$replacement = [System.IO.File]::ReadAllBytes($sourceFull)
$replacementHash = Get-ByteHash $replacement
if ($replacementHash -ine $ExpectedSourceSha256) { throw 'Source changed or wrong source selected; no target write performed.' }

Add-Type -AssemblyName System.IO.Compression
$packageStream = [System.IO.MemoryStream]::new($replacement, $false)
$package = $null
try {
    $package = [System.IO.Compression.ZipArchive]::new($packageStream, [System.IO.Compression.ZipArchiveMode]::Read)
    if ($null -eq $package.GetEntry('[Content_Types].xml') -or $null -eq $package.GetEntry('word/document.xml')) {
        throw 'Source does not contain the required DOCX package entries.'
    }
} finally {
    if ($null -ne $package) { $package.Dispose() }
    $packageStream.Dispose()
}

# Open the existing file; never delete or recreate it. Drive identity still needs cloud verification.
$targetStream = [System.IO.File]::Open($targetFull, [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$changed = $false
$original = $null
try {
    $snapshotStream = [System.IO.MemoryStream]::new()
    try { $targetStream.CopyTo($snapshotStream); $original = $snapshotStream.ToArray() }
    finally { $snapshotStream.Dispose() }
    $originalHash = Get-ByteHash $original
    if ($originalHash -ine $ExpectedTargetSha256) {
        throw 'Target changed since the cloud snapshot; no target write performed. Read and integrate the latest edits.'
    }
    $backupStream = [System.IO.File]::Open($backupFull, [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $backupStream.Write($original, 0, $original.Length); $backupStream.Flush($true) }
    finally { $backupStream.Dispose() }
    if ((Get-FileHash -LiteralPath $backupFull -Algorithm SHA256).Hash -ine $originalHash) {
        throw 'Backup verification failed; no target write performed.'
    }

    $targetStream.Position = 0
    $changed = $true
    $targetStream.Write($replacement, 0, $replacement.Length)
    $targetStream.SetLength($replacement.Length)
    $targetStream.Flush($true)
    $targetStream.Position = 0
    $verifyStream = [System.IO.MemoryStream]::new()
    try { $targetStream.CopyTo($verifyStream); $writtenHash = Get-ByteHash $verifyStream.ToArray() }
    finally { $verifyStream.Dispose() }
    if ($writtenHash -ine $replacementHash) { throw 'Local replacement verification failed.' }
} catch {
    $failure = $_
    if ($changed) {
        try {
            $targetStream.Position = 0
            $targetStream.Write($original, 0, $original.Length)
            $targetStream.SetLength($original.Length)
            $targetStream.Flush($true)
            $targetStream.Position = 0
            $recoveryStream = [System.IO.MemoryStream]::new()
            try { $targetStream.CopyTo($recoveryStream); $recoveredHash = Get-ByteHash $recoveryStream.ToArray() }
            finally { $recoveryStream.Dispose() }
            if ($recoveredHash -ine $originalHash) { throw 'Restored bytes differ from original.' }
        } catch {
            throw "Replacement and local recovery both failed. Preserve backup '$backupFull' and inspect the target before retrying. Recovery error: $($_.Exception.Message)"
        }
    }
    throw $failure
} finally { $targetStream.Dispose() }

[pscustomobject]@{
    TargetPath = $targetFull
    BackupPath = $backupFull
    BeforeSha256 = $originalHash
    AfterSha256 = $writtenHash
    Bytes = $replacement.Length
    LocalVerified = $true
    CloudVerified = $false
} | ConvertTo-Json

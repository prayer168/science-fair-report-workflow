$ErrorActionPreference = 'Stop'
$helper = (Join-Path $PSScriptRoot 'replace-docx-in-place.ps1')
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('shared-docx-test-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($testRoot)
Add-Type -AssemblyName System.IO.Compression
function New-Package([string]$Path, [int]$Length) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
    $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entryName in @('[Content_Types].xml','word/document.xml')) {
            $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
            $writer = [System.IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('<test>' + ('x' * $Length) + '</test>') } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Assert([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
$large = Join-Path $testRoot 'large.docx'
$small = Join-Path $testRoot 'small.docx'
$target = Join-Path $testRoot 'target.docx'
New-Package $large 15000
New-Package $small 15
[System.IO.File]::Copy($small, $target)
$beforeCreation = (Get-Item -LiteralPath $target).CreationTimeUtc
$smallHash = Hash $small
$largeHash = Hash $large
$backup1 = Join-Path $testRoot 'before-grow.docx'
$grown = & $helper -SourcePath $large -TargetPath $target -ExpectedSourceSha256 $largeHash -ExpectedTargetSha256 $smallHash -BackupPath $backup1 | ConvertFrom-Json
Assert ((Hash $target) -eq $largeHash) 'Growing replacement differs.'
Assert ((Hash $backup1) -eq $smallHash) 'Growing backup differs.'
Assert ($grown.LocalVerified -and -not $grown.CloudVerified) 'Helper must not claim cloud verification.'
Assert ((Get-Item -LiteralPath $target).CreationTimeUtc -eq $beforeCreation) 'Creation time changed.'
$backup2 = Join-Path $testRoot 'before-shrink.docx'
$null = & $helper -SourcePath $small -TargetPath $target -ExpectedSourceSha256 $smallHash -ExpectedTargetSha256 $largeHash -BackupPath $backup2
Assert ((Hash $target) -eq $smallHash) 'Shrinking replacement contains wrong bytes or trailing bytes.'
Assert ((Hash $backup2) -eq $largeHash) 'Shrinking backup differs.'

$checks = 2
foreach ($mode in @('stale-target','wrong-source','existing-backup','same-path','invalid-docx','locked-target')) {
    $backup = Join-Path $testRoot ($mode + '-backup.docx')
    $argsForHelper = @{SourcePath=$large; TargetPath=$target; ExpectedSourceSha256=$largeHash; ExpectedTargetSha256=$smallHash; BackupPath=$backup}
    $lock = $null
    switch ($mode) {
        'stale-target' { $argsForHelper.ExpectedTargetSha256 = '0' * 64 }
        'wrong-source' { $argsForHelper.ExpectedSourceSha256 = '0' * 64 }
        'existing-backup' { [System.IO.File]::WriteAllText($backup, 'existing backup') }
        'same-path' { $argsForHelper.SourcePath = $target; $argsForHelper.ExpectedSourceSha256 = $smallHash }
        'invalid-docx' {
            $invalid = Join-Path $testRoot 'invalid.docx'
            [System.IO.File]::WriteAllText($invalid, 'not a zip')
            $argsForHelper.SourcePath = $invalid; $argsForHelper.ExpectedSourceSha256 = Hash $invalid
        }
        'locked-target' { $lock = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
    }
    $rejected = $false
    try { $null = & $helper @argsForHelper } catch { $rejected = $true }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
    Assert $rejected ("Expected rejection: $mode")
    Assert ((Hash $target) -eq $smallHash) ("Target modified on rejected operation: $mode")
    if ($mode -eq 'existing-backup') {
        Assert ([System.IO.File]::ReadAllText($backup) -eq 'existing backup') 'Existing backup was overwritten.'
    } else { Assert (-not (Test-Path -LiteralPath $backup)) ("Unexpected backup after rejected operation: $mode") }
    $checks++
}
[pscustomobject]@{Passed=$checks; TestRoot=$testRoot; LiveDriveModified=$false} | ConvertTo-Json

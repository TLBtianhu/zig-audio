#Requires -Version 5.1
<#
.SYNOPSIS
    Download the official FLAC test vectors used by the FLAC decoder tests.

.DESCRIPTION
    Fetches the 13 subset files from ietf-wg-cellar/flac-test-files into
    .zig-cache/vectors/ (ignored by git), verifying each SHA-256. Existing files
    with the right hash are left alone; a bad hash is re-downloaded.

.EXAMPLE
    pwsh tools/fetch-vectors.ps1
    pwsh tools/fetch-vectors.ps1 -Destination C:\flac-vectors
#>
[CmdletBinding()]
param(
    [string]$Destination
)

$ErrorActionPreference = 'Stop'

if (-not $Destination) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $Destination = Join-Path (Join-Path $repoRoot '.zig-cache') 'vectors'
}
$Destination = [System.IO.Path]::GetFullPath($Destination)
$baseUrl = 'https://raw.githubusercontent.com/ietf-wg-cellar/flac-test-files/main/subset'

# SHA-256 values from the copies used during development. They are also a
# correctness check on the URL: if upstream changes, this script fails loudly
# instead of silently feeding different bytes to the decoder tests.
$vectors = @(
    @{ Name = '03 - blocksize 16.flac';                       Sha256 = '164D0747E8C4855407990182B784FCD7475DA228BF20A6CFF67E947C683959B3' },
    @{ Name = '12 - qlp precision 15 bit.flac';               Sha256 = 'D33731350269929542C6E0A788C1B9A27EB91DCB3A20F5F960B8569BE012C6FA' },
    @{ Name = '13 - qlp precision 2 bit.flac';                Sha256 = 'B60E113A6A3B97D7A3C48BE90913CED8C85F1EE332C6C5DD5A79B46CDC38108A' },
    @{ Name = '14 - wasted bits.flac';                        Sha256 = '58FA05681BD646168EA2A19BC9A6F4EE9D6DE295FD832C1F70DA1BDBF32D74CB' },
    @{ Name = '17 - all fixed orders.flac';                   Sha256 = 'D6F082CBBBCB03015F861B8FA30CF16708A62B85520905A126DA28DB29645FEB' },
    @{ Name = '22 - 12 bit per sample.flac';                  Sha256 = 'D9C385129C4253DA4C0DE34ED5B163B404523AA971773277B8B74EF92F7D4F44' },
    @{ Name = '23 - 8 bit per sample.flac';                   Sha256 = 'D72AD54E1D0EBE5D65B1B1ADDD13EE873D38C58CB3357774A1943CED2D984CF9' },
    @{ Name = '38 - 3 channels (3.0).flac';                   Sha256 = '44D14D0EFA374049FD9F56AAEE3A068A30045E62A571DF574C7B824AE596A3CF' },
    @{ Name = '41 - 6 channels (5.1).flac';                   Sha256 = 'C12650FDA54A384ABF017D4B931491DE043EAA7A815AE74C7A9B49D4087D6193' },
    @{ Name = '45 - no total number of samples set.flac';     Sha256 = '336A18EB7A78F7FC0AB34980348E2895BC3F82DB440A2430D9F92E996F889F9A' },
    @{ Name = '60 - mono audio.flac';                         Sha256 = '20539FBBD6AE28CEA2B2182A4C60C6C70CBB710A136199FC83200C4E5FA00B1C' },
    @{ Name = '61 - predictor overflow check, 16-bit.flac';   Sha256 = '9B15791A8B8CA14A6B9A2374ECF7C34BE25BC7B9E64FA600EB5F7608194B0B61' },
    @{ Name = '64 - rice partitions with escape code zero.flac'; Sha256 = '3AD0BF2E9B9C78CD04DEB0A8E133F5D088DB051E42CBF3FFB15E1B528F009CA6' }
)

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

$downloaded = 0
$cached = 0
$totalBytes = 0

foreach ($vector in $vectors) {
    $target = Join-Path $Destination $vector.Name

    if (Test-Path -LiteralPath $target) {
        $existing = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($existing -eq $vector.Sha256) {
            Write-Host "cached  $($vector.Name)"
            $cached++
            $totalBytes += (Get-Item -LiteralPath $target).Length
            continue
        }
        Write-Warning "hash mismatch for existing $($vector.Name); re-downloading"
        Remove-Item -LiteralPath $target -Force
    }

    $url = "$baseUrl/$([uri]::EscapeDataString($vector.Name))"
    $part = "$target.part"
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }

    Write-Host "fetch   $($vector.Name)"
    Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing

    $actual = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
    if ($actual -ne $vector.Sha256) {
        Remove-Item -LiteralPath $part -Force
        throw "SHA-256 mismatch for $($vector.Name): expected $($vector.Sha256), got $actual"
    }

    Move-Item -LiteralPath $part -Destination $target -Force
    $downloaded++
    $totalBytes += (Get-Item -LiteralPath $target).Length
}

Write-Host ("FLAC vectors ready: {0} files, {1:N1} MiB ({2} downloaded, {3} cached)" -f `
        $vectors.Count, ($totalBytes / 1MB), $downloaded, $cached)
Write-Host "Location: $Destination"

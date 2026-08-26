$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $root 'CodexRateWidget.ps1'
$source = Get-Content -LiteralPath $mainPath -Encoding UTF8 -Raw

foreach ($fragment in @(
    'function New-QuotaTrayBitmap',
    'function New-QuotaTrayIconResource',
    'A deliberately fixed half-full waterline',
    '[CodexQuotaOrb.TrayNative]::DestroyIcon',
    '$script:TrayIconResource.Dispose()'
)) {
    if ($source -notmatch [regex]::Escape($fragment)) {
        throw ('Missing tray-water-orb contract fragment: ' + $fragment)
    }
}

if ($source -match '\$notifyIcon\.Icon\s*=\s*\[System\.Drawing\.SystemIcons\]::Information') {
    throw 'The generic blue information icon must not remain as the tray icon.'
}

$previewPath = Join-Path ([IO.Path]::GetTempPath()) (
    'codex-quota-tray-' + [Guid]::NewGuid().ToString('N') + '.png'
)
try {
    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $mainPath `
        -QATrayIconPath $previewPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $previewPath -PathType Leaf)) {
        throw 'Tray icon QA render did not complete.'
    }

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($previewPath)
    try {
        if ($bitmap.Width -ne 32 -or $bitmap.Height -ne 32) {
            throw ('Tray icon must render at 32x32, got {0}x{1}.' -f $bitmap.Width, $bitmap.Height)
        }
        $upper = $bitmap.GetPixel(16, 10)
        $lower = $bitmap.GetPixel(16, 23)
        if ($lower.B -le $lower.R -or $lower.B -le $lower.G) {
            throw 'The lower half of the tray orb must remain visibly blue.'
        }
        if ($upper.ToArgb() -eq $lower.ToArgb()) {
            throw 'The tray orb must preserve a distinct half-full waterline.'
        }
    } finally {
        $bitmap.Dispose()
    }
} finally {
    if (Test-Path -LiteralPath $previewPath) {
        Remove-Item -LiteralPath $previewPath -Force
    }
}

Write-Output 'TRAY_ICON_CONTRACT_TESTS=PASS'

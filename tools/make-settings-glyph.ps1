# Lifts the IAyuGram plane out of the exported app-icon art as a white-on-transparent
# mask, then scales it to the point sizes the settings-row renderer expects.
# The plane is pure white over a mid-tone gradient, so per-pixel whiteness doubles as a
# clean alpha channel and no SVG rasteriser is needed on Windows.
Add-Type -AssemblyName System.Drawing

$src = "C:\Users\mbabi\Work\Illustrator\IAyuGram\exported\Gradient\Gradient-1024.png"
$outDir = "C:\Users\mbabi\AppData\Local\Temp\claude\C--Users-mbabi-Work-Programming-IAyuGram\13e77707-d751-48a2-a05c-44970174d4e3\scratchpad\glyph"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }

$bmp = [System.Drawing.Bitmap]::FromFile($src)
$w = $bmp.Width
$h = $bmp.Height
Write-Output "source ${w}x${h}"

$fmt = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
$rect = [System.Drawing.Rectangle]::new(0, 0, $w, $h)
$srcData = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
$len = $srcData.Stride * $h
$buf = [byte[]]::new($len)
[System.Runtime.InteropServices.Marshal]::Copy($srcData.Scan0, $buf, 0, $len)
$bmp.UnlockBits($srcData)

# BGRA in memory. Alpha ramps from 0 at `floor` whiteness to 255 at pure white, which keeps
# the plane's antialiased edge instead of hard-clipping it.
$floorW = 110.0
$span = 255.0 - $floorW
for ($i = 0; $i -lt $len; $i += 4) {
    $b = [int]$buf[$i]
    $g = [int]$buf[$i + 1]
    $r = [int]$buf[$i + 2]
    $m = $b
    if ($g -lt $m) { $m = $g }
    if ($r -lt $m) { $m = $r }
    $a = 0
    if ($m -gt $floorW) {
        $scaled = (([double]$m - $floorW) / $span) * 255.0
        $a = [int][math]::Round($scaled)
        if ($a -gt 255) { $a = 255 }
    }
    $buf[$i] = 255
    $buf[$i + 1] = 255
    $buf[$i + 2] = 255
    $buf[$i + 3] = [byte]$a
}

$mask = [System.Drawing.Bitmap]::new($w, $h, $fmt)
$dstData = $mask.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $fmt)
[System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $dstData.Scan0, $len)
$mask.UnlockBits($dstData)
$bmp.Dispose()

# 30pt tile: @2x = 60px, @3x = 90px. The plane keeps the position and scale it has in the
# app icon, so the settings row reads as the same logo rather than a re-cropped one.
foreach ($pair in @(@(60, "@2x"), @(90, "@3x"))) {
    $size = [int]$pair[0]
    $suffix = [string]$pair[1]
    $out = [System.Drawing.Bitmap]::new($size, $size, $fmt)
    $gfx = [System.Drawing.Graphics]::FromImage($out)
    $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gfx.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gfx.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $gfx.Clear([System.Drawing.Color]::Transparent)
    $destRect = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
    $gfx.DrawImage($mask, $destRect)
    $gfx.Dispose()
    $path = Join-Path $outDir "IAyuGramSettings$suffix.png"
    $out.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $out.Dispose()
    Write-Output "wrote $path (${size}px)"
}

$mask.Dispose()

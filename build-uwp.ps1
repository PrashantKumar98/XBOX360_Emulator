param(
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",
    [string]$Platform = "x64"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Xenia Canary Xbox UWP Build Pipeline  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$RepoRoot = $PSScriptRoot
$UwpProjectDir = Join-Path $RepoRoot "xenia-canary-uwp"
$VcxprojPath = Join-Path $UwpProjectDir "xenia-canary-uwp.vcxproj"
$AppPackagesDir = Join-Path $UwpProjectDir "AppPackages"
$PfxPath = Join-Path $UwpProjectDir "xenia-canary-uwp_TemporaryKey.pfx"

$Vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$Msbuild = $null
if (Test-Path $Vswhere) {
    $Msbuild = & $Vswhere -latest -products * -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
}
if (-not $Msbuild -or -not (Test-Path $Msbuild)) {
    $Fallback = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
    if (Test-Path $Fallback) {
        $Msbuild = $Fallback
    } else {
        throw "MSBuild.exe could not be located. Please ensure Visual Studio or Build Tools is installed."
    }
}
Write-Host "[1/5] Using MSBuild: $Msbuild" -ForegroundColor Green

$SdkBinRoot = "C:\Program Files (x86)\Windows Kits\10\bin"
$LatestSdkVer = Get-ChildItem -Path $SdkBinRoot -Directory | Where-Object { $_.Name -like "10.0.*" } | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name
if (-not $LatestSdkVer) {
    throw "Windows 10/11 SDK not found under $SdkBinRoot."
}
$SdkToolsDir = Join-Path $SdkBinRoot "$LatestSdkVer\x64"
$MakePri = Join-Path $SdkToolsDir "makepri.exe"
$MakeAppx = Join-Path $SdkToolsDir "makeappx.exe"
$SignTool = Join-Path $SdkToolsDir "signtool.exe"
$CppWinRT = Join-Path $SdkToolsDir "cppwinrt.exe"

Write-Host "[2/5] Using Windows SDK $LatestSdkVer tools from: $SdkToolsDir" -ForegroundColor Green

$GenFilesDir = Join-Path $UwpProjectDir "Generated Files"
$WinRtBaseHeader = Join-Path $GenFilesDir "winrt\base.h"
if (-not (Test-Path $WinRtBaseHeader)) {
    Write-Host "      Synchronizing C++/WinRT projection headers..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $GenFilesDir | Out-Null
    & $CppWinRT -input sdk+ -output $GenFilesDir -pch pch.h -optimize -overwrite
}

Write-Host "[3/5] Building xenia-canary-uwp.vcxproj ($Configuration|$Platform)..." -ForegroundColor Green
& $Msbuild $VcxprojPath /p:Configuration=$Configuration /p:Platform=$Platform /p:PlatformToolset=v145 /p:AppxPackageSigningEnabled=true /p:BuildProjectReferences=false /p:OutputPath="bin\$Platform\$Configuration\" /m
if ($LASTEXITCODE -ne 0) {
    throw "MSBuild build failed with exit code $LASTEXITCODE."
}

$LayoutDir = Join-Path $UwpProjectDir "$Platform\$Configuration\xenia-canary-uwp"
$ManifestTemplate = Join-Path $UwpProjectDir "Package.appxmanifest"
$AppxManifest = Join-Path $LayoutDir "AppxManifest.xml"

Write-Host "[4/5] Preparing AppX package layout..." -ForegroundColor Green
$ManifestXml = [System.IO.File]::ReadAllText($ManifestTemplate)
$ManifestXml = $ManifestXml.Replace('$targetnametoken$.exe', 'xeniacanary.exe')
[System.IO.File]::WriteAllText($AppxManifest, $ManifestXml)

$PriConfig = Join-Path $LayoutDir "priconfig.xml"
$PriOutput = Join-Path $LayoutDir "resources.pri"
& $MakePri createconfig /cf $PriConfig /dq en-US /o | Out-Null
& $MakePri new /pr $LayoutDir /cf $PriConfig /mn $AppxManifest /of $PriOutput /o | Out-Null
if (Test-Path $PriConfig) { Remove-Item -Force $PriConfig }

Write-Host "[5/5] Packaging and signing AppX container..." -ForegroundColor Green
if (-not (Test-Path $AppPackagesDir)) {
    New-Item -ItemType Directory -Force -Path $AppPackagesDir | Out-Null
}

[xml]$ParsedManifest = Get-Content $ManifestTemplate
$PackageVersion = $ParsedManifest.Package.Identity.Version
$AppxFilename = "xenia-canary-uwp_${PackageVersion}_${Platform}.appx"
$AppxPath = Join-Path $AppPackagesDir $AppxFilename

& $MakeAppx pack /v /h SHA256 /d $LayoutDir /p $AppxPath /o
if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx failed with exit code $LASTEXITCODE."
}

& $SignTool sign /fd SHA256 /a /f $PfxPath $AppxPath
if ($LASTEXITCODE -ne 0) {
    throw "SignTool failed with exit code $LASTEXITCODE."
}

Write-Host "`nBUILD SUCCESSFUL!" -ForegroundColor Green
Write-Host "AppX Package: $AppxPath" -ForegroundColor Cyan
Write-Host "Package Size: $((Get-Item $AppxPath).Length / 1MB | ForEach-Object { '{0:N2} MB' -f $_ })" -ForegroundColor Cyan

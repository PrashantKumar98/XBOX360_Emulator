param(
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",
    [string]$Platform = "x64",
    [string]$PlatformToolset = "",
    [string]$CertificatePath = "",
    [System.Security.SecureString]$CertificatePassword = $null,
    [switch]$SkipSigning,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Xenia Canary Xbox UWP Build Pipeline  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$RepoRoot = $PSScriptRoot
$UwpProjectDir = Join-Path $RepoRoot "xenia-canary-uwp"
$VcxprojPath = Join-Path $UwpProjectDir "xenia-canary-uwp.vcxproj"
$AppPackagesDir = Join-Path $UwpProjectDir "AppPackages"
$EngineLibDir = Join-Path $RepoRoot "build\bin\Windows\$Configuration"

# 1. Locate MSBuild
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
if (-not $PlatformToolset) {
    if ($env:PlatformToolset) {
        $PlatformToolset = $env:PlatformToolset
    } else {
        $Detected = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Microsoft Visual Studio\*\*\MSBuild\Microsoft\VC\*\Platforms\x64\PlatformToolsets\*", `
                                        "${env:ProgramFiles}\Microsoft Visual Studio\*\*\MSBuild\Microsoft\VC\*\Platforms\x64\PlatformToolsets\*" `
                                  -Directory -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name -Unique |
                    Where-Object { $_ -match "^v\d+$" } |
                    Sort-Object -Descending |
                    Select-Object -First 1
        if ($Detected) {
            $PlatformToolset = $Detected
        } else {
            $PlatformToolset = "v143"
        }
    }
}
Write-Host "[1/6] Using MSBuild: $Msbuild (PlatformToolset: $PlatformToolset)" -ForegroundColor Green

# 2. Locate Windows SDK Tools
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

foreach ($tool in @($MakePri, $MakeAppx, $SignTool, $CppWinRT)) {
    if (-not (Test-Path $tool)) {
        throw "Required SDK tool not found: $tool"
    }
}
Write-Host "[2/6] Using Windows SDK $LatestSdkVer tools from: $SdkToolsDir" -ForegroundColor Green

# 3. Synchronize C++/WinRT projection headers
$GenFilesDir = Join-Path $UwpProjectDir "Generated Files"
$WinRtBaseHeader = Join-Path $GenFilesDir "winrt\base.h"
if (-not (Test-Path $WinRtBaseHeader) -or $Clean) {
    Write-Host "[3/6] Synchronizing C++/WinRT projection headers..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $GenFilesDir | Out-Null
    & $CppWinRT -input sdk+ -output $GenFilesDir -pch pch.h -optimize -overwrite
    if ($LASTEXITCODE -ne 0) {
        throw "CppWinRT projection header generation failed with exit code $LASTEXITCODE."
    }
} else {
    Write-Host "[3/6] C++/WinRT projection headers up to date." -ForegroundColor Green
}

# 4. Dependency build & verification
Write-Host "[4/6] Building dependencies and xenia-canary-uwp.vcxproj ($Configuration|$Platform)..." -ForegroundColor Green

$MsbuildParams = @(
    $VcxprojPath,
    "/p:Configuration=$Configuration",
    "/p:Platform=$Platform"
)
if ($PlatformToolset) {
    $MsbuildParams += "/p:PlatformToolset=$PlatformToolset"
}

if ($Clean) {
    Write-Host "      Cleaning previous build outputs..." -ForegroundColor Yellow
    & $Msbuild @MsbuildParams /t:Clean /m
}

# Build xenia-canary-uwp with project references enabled so MSBuild validates & builds dependencies
& $Msbuild @MsbuildParams /p:AppxPackageSigningEnabled=false /p:BuildProjectReferences=true /p:OutputPath="bin\$Platform\$Configuration\" /m
if ($LASTEXITCODE -ne 0) {
    throw "MSBuild build failed with exit code $LASTEXITCODE."
}

# Verify that the primary executable was produced
$BuildOutputDir = Join-Path $UwpProjectDir "$Platform\$Configuration\xenia-canary-uwp"
$TargetExe = Join-Path $BuildOutputDir "xeniacanary.exe"
if (-not (Test-Path $TargetExe)) {
    throw "Target executable not found after build: $TargetExe"
}

# Explicitly validate all 30 engine static libraries referenced by xenia-canary-uwp.vcxproj
$RequiredLibs = @(
    # Core Engine Modules
    "xenia-base.lib", "xenia-core.lib", "xenia-cpu.lib", "xenia-cpu-backend-x64.lib",
    "xenia-kernel.lib", "xenia-patcher.lib", "xenia-debug-ui.lib",
    # Hardware Subsystems
    "xenia-gpu.lib", "xenia-gpu-d3d12.lib", "xenia-gpu-null.lib",
    "xenia-ui.lib", "xenia-ui-d3d12.lib",
    "xenia-apu.lib", "xenia-apu-xaudio2.lib", "xenia-apu-nop.lib",
    "xenia-hid.lib", "xenia-hid-xinput.lib", "xenia-hid-nop.lib",
    # Third-Party Dependencies
    "aes_128.lib", "capstone.lib", "fmt.lib", "dxbc.lib", "discord-rpc.lib",
    "glslang-spirv.lib", "imgui.lib", "libavcodec.lib", "libavutil.lib",
    "mspack.lib", "snappy.lib", "xxhash.lib"
)
foreach ($libName in $RequiredLibs) {
    $libPath = Join-Path $EngineLibDir $libName
    if (-not (Test-Path $libPath)) {
        throw "Required engine library missing: $libPath"
    }
}
Write-Host "      All 30 engine static libraries verified." -ForegroundColor Green

# 5. Clean staging directory to prevent stale files entering package
Write-Host "[5/6] Preparing clean staging layout for packaging..." -ForegroundColor Green
$StagingDir = Join-Path $UwpProjectDir "Staging\$Platform\$Configuration"
if (Test-Path $StagingDir) {
    Remove-Item -Recurse -Force $StagingDir
}
New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

# Copy only runtime-required files into staging
Copy-Item -Path $TargetExe -Destination (Join-Path $StagingDir "xeniacanary.exe") -Force

$AssetsSourceDir = Join-Path $UwpProjectDir "Assets"
$AssetsDestDir = Join-Path $StagingDir "Assets"
Copy-Item -Path $AssetsSourceDir -Destination $AssetsDestDir -Recurse -Force

# Generate transformed AppxManifest.xml
$ManifestTemplate = Join-Path $UwpProjectDir "Package.appxmanifest"
$StagedManifest = Join-Path $StagingDir "AppxManifest.xml"
$ManifestXml = [System.IO.File]::ReadAllText($ManifestTemplate)
$ManifestXml = $ManifestXml.Replace('$targetnametoken$.exe', 'xeniacanary.exe')
[System.IO.File]::WriteAllText($StagedManifest, $ManifestXml)

# Generate resources.pri via makepri inside staging directory
$PriConfig = Join-Path $StagingDir "priconfig.xml"
$PriOutput = Join-Path $StagingDir "resources.pri"

& $MakePri createconfig /cf $PriConfig /dq en-US /o | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "MakePri createconfig failed with exit code $LASTEXITCODE."
}

& $MakePri new /pr $StagingDir /cf $PriConfig /mn $StagedManifest /of $PriOutput /o | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "MakePri new failed with exit code $LASTEXITCODE."
}

if (Test-Path $PriConfig) {
    Remove-Item -Force $PriConfig
}

# 6. Packaging and Signing
Write-Host "[6/6] Packaging AppX container..." -ForegroundColor Green
if (-not (Test-Path $AppPackagesDir)) {
    New-Item -ItemType Directory -Force -Path $AppPackagesDir | Out-Null
}

[xml]$ParsedManifest = Get-Content $ManifestTemplate
$PackageVersion = $ParsedManifest.Package.Identity.Version
$AppxFilename = "xenia-canary-uwp_${PackageVersion}_${Platform}.appx"
$AppxPath = Join-Path $AppPackagesDir $AppxFilename

& $MakeAppx pack /v /h SHA256 /d $StagingDir /p $AppxPath /o
if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx failed with exit code $LASTEXITCODE."
}

if (-not $SkipSigning) {
    Write-Host "      Resolving signing credentials..." -ForegroundColor Green
    $ResolvedPfx = ""
    if ($CertificatePath -and (Test-Path $CertificatePath)) {
        $ResolvedPfx = $CertificatePath
    } elseif ($env:XENIA_SIGNING_CERT_PATH -and (Test-Path $env:XENIA_SIGNING_CERT_PATH)) {
        $ResolvedPfx = $env:XENIA_SIGNING_CERT_PATH
    } else {
        $LocalPfx = Join-Path $UwpProjectDir "xenia-canary-uwp_TemporaryKey.pfx"
        if (Test-Path $LocalPfx) {
            $ResolvedPfx = $LocalPfx
        } else {
            Write-Host "      No external certificate provided. Generating local self-signed test key..." -ForegroundColor Yellow
            $Cert = New-SelfSignedCertificate -Type Custom -Subject "CN=SirMangler" `
                -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 `
                -HashAlgorithm SHA256 -CertStoreLocation "Cert:\CurrentUser\My" `
                -NotAfter (Get-Date).AddYears(10) `
                -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")

            $EmptyPassword = New-Object System.Security.SecureString
            Export-PfxCertificate -Cert $Cert -FilePath $LocalPfx -Password $EmptyPassword -Force | Out-Null
            $PublicCer = Join-Path $UwpProjectDir "xenia-canary-uwp_TemporaryKey.cer"
            # Always overwrite/export the public .cer alongside the generated PFX to prevent mismatched certificates
            Export-Certificate -Cert $Cert -FilePath $PublicCer -Force | Out-Null
            Write-Host "      Exported matching public certificate: $PublicCer" -ForegroundColor Green
            $ResolvedPfx = $LocalPfx
        }
    }

    Write-Host "      Signing package with: $ResolvedPfx" -ForegroundColor Green
    if ($CertificatePassword) {
        $Bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertificatePassword)
        $PasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($Bstr)
        & $SignTool sign /fd SHA256 /a /f $ResolvedPfx /p $PasswordPlain $AppxPath
    } else {
        & $SignTool sign /fd SHA256 /a /f $ResolvedPfx $AppxPath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "SignTool failed with exit code $LASTEXITCODE."
    }
} else {
    Write-Host "      Signing skipped as requested (-SkipSigning)." -ForegroundColor Yellow
}

Write-Host "`nBUILD & PACKAGING SUCCESSFUL!" -ForegroundColor Green
Write-Host "AppX Package: $AppxPath" -ForegroundColor Cyan
Write-Host "Package Size: $((Get-Item $AppxPath).Length / 1MB | ForEach-Object { '{0:N2} MB' -f $_ })" -ForegroundColor Cyan

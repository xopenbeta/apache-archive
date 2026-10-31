#!/usr/bin/env pwsh
#
# Build a relocatable Apache httpd package for Windows x86_64.
#
# Must run from a Visual Studio 2022 x64 developer environment (the workflow
# uses ilammy/msvc-dev-cmd). Dependencies are built as DLLs with CMake and
# bundled into bin\, which matches the layout of the official Windows builds.
#
# The httpd CMake build is experimental upstream; see README.cmake in the
# httpd source tree.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$HttpdVersion = if ($env:HTTPD_VERSION) { $env:HTTPD_VERSION } else { "2.4.69" }
$AprVersion = if ($env:APR_VERSION) { $env:APR_VERSION } else { "1.7.6" }
$AprUtilVersion = if ($env:APR_UTIL_VERSION) { $env:APR_UTIL_VERSION } else { "1.6.5" }
$Pcre2Version = if ($env:PCRE2_VERSION) { $env:PCRE2_VERSION } else { "10.48" }
$OpensslVersion = if ($env:OPENSSL_VERSION) { $env:OPENSSL_VERSION } else { "3.5.9" }
$ZlibVersion = if ($env:ZLIB_VERSION) { $env:ZLIB_VERSION } else { "1.3.1" }
$ExpatVersion = if ($env:EXPAT_VERSION) { $env:EXPAT_VERSION } else { "2.9.0" }
$Nghttp2Version = if ($env:NGHTTP2_VERSION) { $env:NGHTTP2_VERSION } else { "1.70.0" }

$Port = if ($env:HTTPD_PORT) { $env:HTTPD_PORT } else { "8080" }
$SslPort = if ($env:HTTPD_SSL_PORT) { $env:HTTPD_SSL_PORT } else { "443" }

$Root = Split-Path -Parent $PSScriptRoot
$Work = Join-Path $Root "work"
$Deps = Join-Path $Root "deps"
$Stage = Join-Path $Root "stage"
$InstallDir = "httpd-$HttpdVersion-windows-x86_64"
$StageRoot = Join-Path $Stage $InstallDir
$Zip = Join-Path $Root "$InstallDir.zip"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message"
}

function Invoke-CommandLine {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$What
    )
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed (exit code $LASTEXITCODE)"
    }
}

function Get-Source {
    param([string]$Url, [string]$FileName, [string]$FallbackUrl = "")
    $out = Join-Path $Work $FileName
    if (Test-Path $out) {
        return $out
    }
    Write-Step "download $FileName"
    $tmp = "$out.part"
    & curl.exe -fSL --retry 3 --retry-delay 2 -o $tmp $Url
    if ($LASTEXITCODE -ne 0) {
        if (-not $FallbackUrl) {
            throw "download failed: $Url"
        }
        Write-Step "mirror failed, falling back to archive.apache.org"
        & curl.exe -fSL --retry 3 --retry-delay 2 -o $tmp $FallbackUrl
        if ($LASTEXITCODE -ne 0) {
            throw "download failed: $Url and $FallbackUrl"
        }
    }
    Move-Item -Force $tmp $out
    return $out
}

function Get-ApacheSource {
    param([string]$RelativePath, [string]$FileName)
    return Get-Source "https://dlcdn.apache.org/$RelativePath" $FileName "https://archive.apache.org/dist/$RelativePath"
}

function Expand-Source {
    param([string]$Archive, [string]$DirectoryName)
    $dir = Join-Path $Work $DirectoryName
    if (-not (Test-Path $dir)) {
        Write-Step "extract $DirectoryName"
        Invoke-CommandLine "tar.exe" @("-xf", $Archive, "-C", $Work) "extract $Archive"
    }
    return $dir
}

function Build-CMake {
    param(
        [string]$Source,
        [string]$BuildDir,
        [string[]]$Options,
        [string]$What
    )
    if (Test-Path $BuildDir) {
        Remove-Item -Recurse -Force $BuildDir
    }
    $cmakeArgs = @("-S", $Source, "-B", $BuildDir, "-G", "NMake Makefiles", "-DCMAKE_BUILD_TYPE=Release") + $Options
    Invoke-CommandLine "cmake" $cmakeArgs "configure $What"
    Invoke-CommandLine "cmake" @("--build", $BuildDir, "--target", "install") "install $What"
}

function Get-ExpatSource {
    $dir = Join-Path $Work "expat-$ExpatVersion"
    if ((Test-Path (Join-Path $dir "CMakeLists.txt"))) {
        return $dir
    }
    if ((Test-Path (Join-Path $dir "expat\CMakeLists.txt"))) {
        return (Join-Path $dir "expat")
    }
    throw "cannot find the Expat CMake source in $dir"
}

function Install-Dependencies {
    $vcpkgHint = "-DCMAKE_PREFIX_PATH=$Deps"

    # zlib ---------------------------------------------------------------
    $zlibSrc = Expand-Source (Join-Path $Work "zlib-$ZlibVersion.tar.gz") "zlib-$ZlibVersion"
    Build-CMake $zlibSrc (Join-Path $Work "build-zlib") @(
        "-DCMAKE_INSTALL_PREFIX=$Deps",
        "-DBUILD_SHARED_LIBS=ON",
        "-DZLIB_BUILD_SHARED=ON",
        "-DZLIB_BUILD_STATIC=ON"
    ) "zlib"

    # Expat (needed by APR-util) ----------------------------------------
    Expand-Source (Join-Path $Work "expat-$ExpatVersion.tar.gz") "expat-$ExpatVersion" | Out-Null
    Build-CMake (Get-ExpatSource) (Join-Path $Work "build-expat") @(
        "-DCMAKE_INSTALL_PREFIX=$Deps",
        "-DBUILD_SHARED_LIBS=ON",
        "-DEXPAT_BUILD_TOOLS=OFF",
        "-DEXPAT_BUILD_EXAMPLES=OFF",
        "-DEXPAT_BUILD_TESTS=OFF",
        "-DEXPAT_BUILD_DOCS=OFF"
    ) "Expat"

    # PCRE2 (must be a DLL: the httpd CMake build has no PCRE2 static
    # support) ----------------------------------------------------------
    $pcre2Src = Expand-Source (Join-Path $Work "pcre2-$Pcre2Version.tar.gz") "pcre2-$Pcre2Version"
    Build-CMake $pcre2Src (Join-Path $Work "build-pcre2") @(
        "-DCMAKE_INSTALL_PREFIX=$Deps",
        "-DBUILD_SHARED_LIBS=ON",
        "-DPCRE2_BUILD_PCRE2_8=ON",
        "-DPCRE2_SUPPORT_UNICODE=ON",
        "-DPCRE2_BUILD_TESTS=OFF",
        "-DPCRE2_BUILD_PCRE2GREP=OFF"
    ) "PCRE2"

    # nghttp2 (mod_http2) ----------------------------------------------
    $nghttp2Src = Expand-Source (Join-Path $Work "nghttp2-$Nghttp2Version.tar.gz") "nghttp2-$Nghttp2Version"
    Build-CMake $nghttp2Src (Join-Path $Work "build-nghttp2") @(
        "-DCMAKE_INSTALL_PREFIX=$Deps",
        "-DENABLE_LIB_ONLY=ON",
        "-DENABLE_SHARED_LIB=ON",
        "-DENABLE_STATIC_LIB=OFF",
        "-DENABLE_APP=OFF",
        "-DENABLE_EXAMPLES=OFF",
        "-DENABLE_H2LOAD=OFF"
    ) "nghttp2"

    # OpenSSL (DLLs) ----------------------------------------------------
    $opensslSrc = Expand-Source (Join-Path $Work "openssl-$OpensslVersion.tar.gz") "openssl-$OpensslVersion"
    Write-Step "build OpenSSL $OpensslVersion"
    Push-Location $opensslSrc
    try {
        $opensslPrefix = $Deps.Replace("\", "/")
        Invoke-CommandLine "perl" @(
            "Configure", "VC-WIN64A",
            "no-tests", "no-asm",
            "--prefix=$opensslPrefix", "--openssldir=C:/OpenSSL"
        ) "configure OpenSSL"
        Invoke-CommandLine "nmake" @() "build OpenSSL"
        Invoke-CommandLine "nmake" @("install_sw") "install OpenSSL"
    }
    finally {
        Pop-Location
    }

    # APR / APR-util ----------------------------------------------------
    $aprSrc = Expand-Source (Join-Path $Work "apr-$AprVersion.tar.gz") "apr-$AprVersion"
    Build-CMake $aprSrc (Join-Path $Work "build-apr") @(
        "-DCMAKE_INSTALL_PREFIX=$Deps",
        "-DAPR_INSTALL_PRIVATE_H=ON",
        "-DAPR_BUILD_TESTAPR=OFF"
    ) "APR"

    $aprUtilSrc = Expand-Source (Join-Path $Work "apr-util-$AprUtilVersion.tar.gz") "apr-util-$AprUtilVersion"
    Build-CMake $aprUtilSrc (Join-Path $Work "build-apr-util") @(
        "-DCMAKE_INSTALL_PREFIX=$Deps",
        $vcpkgHint,
        "-DAPR_INCLUDE_DIR=$Deps\include",
        "-DAPR_LIBRARIES=$Deps\lib\libapr-1.lib",
        "-DEXPAT_INCLUDE_DIR=$Deps\include",
        "-DEXPAT_LIBRARY=$Deps\lib\expat.lib",
        "-DAPU_HAVE_ODBC=OFF",
        "-DAPR_HAS_LDAP=OFF"
    ) "APR-util"
}

function Build-Httpd {
    $src = Expand-Source (Join-Path $Work "httpd-$HttpdVersion.tar.gz") "httpd-$HttpdVersion"
    Write-Step "configure httpd $HttpdVersion"

    $buildDir = Join-Path $Work "build-httpd"
    if (Test-Path $buildDir) {
        Remove-Item -Recurse -Force $buildDir
    }

    $aprLibs = "$Deps\lib\libapr-1.lib;$Deps\lib\libaprutil-1.lib"
    $cmakeArgs = @(
        "-S", $src,
        "-B", $buildDir,
        "-G", "NMake Makefiles",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_INSTALL_PREFIX=$StageRoot",
        "-DCMAKE_PREFIX_PATH=$Deps",
        "-DAPR_INCLUDE_DIR=$Deps\include",
        "-DAPR_LIBRARIES=$aprLibs",
        "-DOPENSSL_ROOT_DIR=$Deps",
        "-DOPENSSL_USE_STATIC_LIBS=OFF",
        "-DOPENSSL_INCLUDE_DIR=$Deps\include",
        "-DOPENSSL_SSL_LIBRARY=$Deps\lib\libssl.lib",
        "-DOPENSSL_CRYPTO_LIBRARY=$Deps\lib\libcrypto.lib",
        "-DZLIB_ROOT=$Deps",
        "-DZLIB_INCLUDE_DIR=$Deps\include",
        "-DZLIB_LIBRARY=$Deps\lib\zlib.lib",
        "-DPCRE2_INCLUDE_DIR=$Deps\include",
        "-DPCRE2_LIBRARY=$Deps\lib\pcre2-8.lib",
        "-DPCRE2_8BIT_LIBRARY=$Deps\lib\pcre2-8.lib",
        "-DPCRE2_DIR=$Deps\lib\cmake\pcre2",
        "-DNGHTTP2_INCLUDE_DIR=$Deps\include",
        "-DNGHTTP2_LIBRARIES=$Deps\lib\nghttp2.lib",
        "-DENABLE_MODULES=a",
        "-DENABLE_SSL=A",
        "-DENABLE_HTTP2=A",
        "-DPort=$Port",
        "-DSSLPort=$SslPort",
        "-DINSTALL_PDB=OFF"
    )

    Invoke-CommandLine "cmake" $cmakeArgs "configure httpd"
    Invoke-CommandLine "cmake" @("--build", $buildDir, "--target", "install") "install httpd"
}

function Install-Runtime {
    $bin = Join-Path $StageRoot "bin"

    $depsDlls = Get-ChildItem -Path (Join-Path $Deps "bin") -Filter "*.dll" -File -ErrorAction SilentlyContinue
    if (-not $depsDlls) {
        throw "no dependency DLLs were installed into $Deps\bin"
    }
    $depsDlls | Copy-Item -Destination $bin -Force

    $crtDir = $null
    if ($env:VCToolsRedistDir) {
        $candidate = Join-Path $env:VCToolsRedistDir "x64\Microsoft.VC143.CRT"
        if (Test-Path $candidate) {
            $crtDir = $candidate
        }
        else {
            $runtime = Get-ChildItem -Path $env:VCToolsRedistDir -Recurse -Filter "vcruntime140.dll" -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($runtime) {
                $crtDir = $runtime.DirectoryName
            }
        }
    }
    if ($crtDir) {
        Copy-Item -Path (Join-Path $crtDir "*.dll") -Destination $bin -Force
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $StageRoot "logs") | Out-Null
    # Zip writers may drop empty directories; keep logs\ in the archive.
    New-Item -ItemType File -Force -Path (Join-Path $StageRoot "logs\.keep") | Out-Null
}

function Set-RelocatableConf {
    $confRoot = Join-Path $StageRoot "conf"
    $prefixNative = $StageRoot
    $prefixPosix = $StageRoot.Replace("\", "/")

    Get-ChildItem -Path $confRoot -Recurse -Filter "*.conf" -File | ForEach-Object {
        $path = $_.FullName
        $text = Get-Content -Raw -LiteralPath $path
        $text = $text.Replace($prefixPosix, '${SRVROOT}')
        $text = $text.Replace($prefixNative, '${SRVROOT}')
        $text = [regex]::Replace($text, '(?m)^[ \t]*Define[ \t]+SRVROOT.*$', '# SRVROOT is provided at runtime by apachectl.cmd')
        Set-Content -LiteralPath $path -Value $text -NoNewline -Encoding ascii
    }

    $mainConf = Join-Path $confRoot "httpd.conf"
    if (-not (Select-String -LiteralPath $mainConf -Pattern '^ServerRoot' -Quiet)) {
        $text = "ServerRoot `"`${SRVROOT}`"`r`n" + (Get-Content -Raw -LiteralPath $mainConf)
        Set-Content -LiteralPath $mainConf -Value $text -NoNewline -Encoding ascii
    }
}

function Install-Launcher {
    $launcher = @'
@echo off
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "APACHE_ROOT=%ROOT:\=/%"
if not exist "%ROOT%\bin\httpd.exe" (
  echo apachectl: cannot find "%ROOT%\bin\httpd.exe" 1>&2
  exit /b 1
)
"%ROOT%\bin\httpd.exe" -d "%APACHE_ROOT%" -C "Define SRVROOT \"%APACHE_ROOT%\"" -f "%ROOT%\conf\httpd.conf" %*
exit /b %ERRORLEVEL%
'@

    $launcher = $launcher -replace "`r?`n", "`r`n"
    $path = Join-Path $StageRoot "bin\apachectl.cmd"
    Set-Content -LiteralPath $path -Value $launcher -NoNewline -Encoding ascii
}

function New-Package {
    if (Test-Path $Zip) {
        Remove-Item -Force $Zip
    }

    $sevenZip = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($sevenZip) {
        Push-Location $Stage
        try {
            Invoke-CommandLine $sevenZip.Source @("a", "-tzip", "-mx=9", $Zip, $InstallDir) "create zip"
        }
        finally {
            Pop-Location
        }
    }
    else {
        Compress-Archive -Path $StageRoot -DestinationPath $Zip -Force
    }

    $hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $name = Split-Path -Leaf $Zip
    Set-Content -LiteralPath "$Zip.sha256" -Value ("{0}  {1}" -f $hash, $name) -Encoding ascii
}

function Test-Package {
    Write-Step "verify $InstallDir"

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("httpd-verify-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Expand-Archive -LiteralPath $Zip -DestinationPath $tmp -Force
        $pkg = Join-Path $tmp $InstallDir
        $launcher = Join-Path $pkg "bin\apachectl.cmd"

        & $launcher -t
        if ($LASTEXITCODE -ne 0) {
            throw "configuration test failed"
        }

        $confText = Get-Content -Raw -LiteralPath (Join-Path $pkg "conf\httpd.conf")
        if ($confText -notmatch [regex]::Escape('ServerRoot "${SRVROOT}"')) {
            throw "conf\httpd.conf was not made relocatable"
        }
        if ($confText -match [regex]::Escape($StageRoot)) {
            throw "conf\httpd.conf still contains the staging path"
        }

        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$launcher`"") -WindowStyle Hidden -PassThru

        $body = $null
        for ($i = 0; $i -lt 30; $i++) {
            try {
                $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 2
                if ($response.StatusCode -eq 200) {
                    $body = $response.Content
                    break
                }
            }
            catch {
                Start-Sleep -Seconds 1
            }
        }

        Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }

        if ($null -eq $body) {
            $errorLog = Join-Path $pkg "logs\error.log"
            if (Test-Path $errorLog) {
                Get-Content -LiteralPath $errorLog -Tail 40 | Write-Host
            }
            throw "httpd did not answer on port $Port"
        }
        if ($body -notmatch "It works!") {
            throw "unexpected DocumentRoot response"
        }

        $modules = & $launcher -M 2>&1 | Out-String
        foreach ($name in @("ssl_module", "http2_module", "proxy_http2_module", "rewrite_module", "mpm_winnt_module")) {
            if ($modules -notmatch [regex]::Escape($name)) {
                throw "module $name is missing from httpd -M"
            }
        }

        $httpdExe = Join-Path $pkg "bin\httpd.exe"
        $dlls = Get-ChildItem -Path (Join-Path $pkg "bin") -Filter "*.dll" -File
        if (-not (Test-Path $httpdExe)) {
            throw "httpd.exe is missing"
        }
        if ($dlls.Count -lt 3) {
            throw "expected bundled runtime DLLs in bin\, found $($dlls.Count)"
        }
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    Write-Step "verification passed"
}

# ---------------------------------------------------------------------------

if (-not $env:VCToolsInstallDir -and -not $env:VCINSTALLDIR) {
    throw "run this script from a Visual Studio developer environment (VCToolsInstallDir/VCINSTALLDIR is not set)"
}

New-Item -ItemType Directory -Force -Path $Work, $Deps, $Stage | Out-Null
if (Test-Path $Stage) {
    Remove-Item -Recurse -Force $Stage
}
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

Write-Step "download sources"
Get-ApacheSource "httpd/httpd-$HttpdVersion.tar.gz" "httpd-$HttpdVersion.tar.gz" | Out-Null
Get-ApacheSource "apr/apr-$AprVersion.tar.gz" "apr-$AprVersion.tar.gz" | Out-Null
Get-ApacheSource "apr/apr-util-$AprUtilVersion.tar.gz" "apr-util-$AprUtilVersion.tar.gz" | Out-Null
Get-Source "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$Pcre2Version/pcre2-$Pcre2Version.tar.gz" "pcre2-$Pcre2Version.tar.gz" | Out-Null
Get-Source "https://github.com/openssl/openssl/releases/download/openssl-$OpensslVersion/openssl-$OpensslVersion.tar.gz" "openssl-$OpensslVersion.tar.gz" | Out-Null
Get-Source "https://github.com/madler/zlib/releases/download/v$ZlibVersion/zlib-$ZlibVersion.tar.gz" "zlib-$ZlibVersion.tar.gz" | Out-Null
$expatTag = "R_" + ($ExpatVersion -replace '\.', '_')
Get-Source "https://github.com/libexpat/libexpat/releases/download/$expatTag/expat-$ExpatVersion.tar.gz" "expat-$ExpatVersion.tar.gz" | Out-Null
Get-Source "https://github.com/nghttp2/nghttp2/releases/download/v$Nghttp2Version/nghttp2-$Nghttp2Version.tar.gz" "nghttp2-$Nghttp2Version.tar.gz" | Out-Null

Install-Dependencies
Build-Httpd
Install-Runtime
Set-RelocatableConf
Install-Launcher
New-Package
Test-Package

Write-Host ""
Write-Host "done: $Zip"

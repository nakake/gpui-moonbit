# Build driver for GPUI + MoonBit on Windows. Mirrors build.sh:
#   [0] regenerate ABI constants and C FFI bindings
#   [1a] moon check (fatal typecheck gate)
#   [1b] moon build (only a cold native-link failure is tolerated)
#   [2] extract app.dispatch's mangled symbol from the generated main.c
#       (x64 COFF has no ABI underscore: use the name verbatim, like ELF)
#   [3] cargo build gpui-sys, then capture its native-static-libs list
#   [4] regenerate cmd/main/moon.pkg from moon.pkg.windows and relink
#   [5] verify the callback definition/reference contract used by the final link
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$GSys = Join-Path $Root 'gpui-sys'
$MB   = Join-Path $Root 'moonbit-bindings'
$PkgFnSuffix = '3app8dispatch'   # package app, function dispatch (keep in sync with build.sh)

$env:Path = "$env:USERPROFILE\.moon\bin;$env:Path"
# Prefer English MSVC diagnostics when the installed toolchain honors VSLANG,
# and make localized diagnostics safe when it does not by switching the shared
# console and PowerShell's native-command pipeline to UTF-8.
$env:VSLANG = '1033'
$env:PreferredUILang = 'en-US'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
cmd /d /c "chcp 65001 >NUL"

# cl.exe must be on PATH for moon's native backend
if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
  $vs = & 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe' `
        -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
  if (-not $vs) { throw 'MSVC (VC.Tools) not found' }
  Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
  Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64' | Out-Null
}

function Write-MoonPkg([string]$libs) {
  $tmpl = Get-Content (Join-Path $MB 'cmd\main\moon.pkg.windows') -Raw
  $out  = $tmpl.Replace('@NATIVE_LIBS@', $libs)
  $dst  = Join-Path $MB 'cmd\main\moon.pkg'
  if (-not (Test-Path $dst) -or (Get-Content $dst -Raw) -ne $out) {
    Set-Content -NoNewline -Path $dst -Value $out
    Write-Host "==> wrote cmd\main\moon.pkg (windows)"
  }
}

Write-Host '==> [0/5] Regenerate ABI constants and C FFI bindings'
$abiPath = Join-Path $GSys 'abi.toml'
$abiLines = Get-Content $abiPath
$generated = New-Object System.Collections.Generic.List[string]
$generated.Add('// Auto-generated from gpui-sys/abi.toml. Do not edit manually.')
$section = ''
# Grammar: [section] headers or key = non-negative-integer, with whitespace/comments.
for ($i = 0; $i -lt $abiLines.Count; $i++) {
  $original = $abiLines[$i]
  $line = ($original -replace '\s*#.*$', '').Trim()
  if (-not $line) { continue }
  if ($line -match '^\[([A-Za-z_][A-Za-z0-9_]*)\]$') {
    $section = $Matches[1]
    continue
  }
  if ($section -eq 'callback') { continue }
  if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([0-9]+)$') {
    throw "invalid ABI constant at line $($i + 1): $original"
  }
  $name = $Matches[1]
  if ($name -eq 'abi_version') { $name = 'ABI_VERSION' }
  $generated.Add('')
  $generated.Add('///|')
  $generated.Add("pub const $name : Int = $($Matches[2])")
}
$abiConstants = Join-Path $MB 'abi_constants.mbt'
# UTF-8 without BOM and LF newlines matches awk output byte-for-byte.
[System.IO.File]::WriteAllText($abiConstants, (($generated -join "`n") + "`n"), $utf8NoBom)
Push-Location $MB
cmd /c "moon fmt abi_constants.mbt 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'moon fmt abi_constants.mbt failed' }
Push-Location (Join-Path $Root 'bindgen-moonbit')
cmd /c "cargo run -- `"$GSys\include\gpui_sys.h`" `"$MB\gpui-bindings-ffi.mbt`" 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'MoonBit bindgen failed' }
Push-Location $MB
cmd /c "moon fmt gpui-bindings-ffi.mbt 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'moon fmt gpui-bindings-ffi.mbt failed' }

Write-Host '==> [1a/5] MoonBit typecheck'
Push-Location $MB
cmd /c "moon check 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'MoonBit compilation failed' }

Write-Host '==> [1b/5] MoonBit build (only a missing native callback/library is tolerated)'
Write-MoonPkg ''
Push-Location $MB
$coldOutput = cmd /c "moon build 2>&1"
$ec = $LASTEXITCODE
$coldOutput | Out-Host
Pop-Location
if ($ec -ne 0) {
  $coldText = $coldOutput -join "`n"
  # MSVC reports a missing input lib as LNK1181 and an unresolved external as
  # LNK2019/1120 (locale-independent codes; messages are localized).
  if ($coldText -match '(?i)undefined (reference|symbol)|cannot find .*gpui_sys|library not found.*gpui_sys|3app8dispatch|LNK1104|LNK1181|LNK2019|LNK1120') {
    Write-Host '    (expected cold-link failure; continuing)'
  } else {
    throw 'MoonBit build failed for a non-link reason'
  }
}

Write-Host '==> [2/5] Extract the mangled symbol for app.dispatch'
$mainC = Join-Path $MB '_build\native\debug\build\cmd\main\main.c'
if (-not (Test-Path $mainC)) { throw "not found: $mainC; did MoonBit compile? (step 1 output above)" }
$symbols = @(Select-String -Path $mainC -Pattern "_M0FP[A-Za-z0-9_]*$PkgFnSuffix" -AllMatches |
       ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
       Sort-Object -Unique)
if ($symbols.Count -ne 1) { throw "expected exactly 1 app.dispatch symbol ending in $PkgFnSuffix, found $($symbols.Count)" }
$sym = $symbols[0]
$normalizedC = (Get-Content $mainC -Raw) -replace '\s+', ' '
$escapedSym = [regex]::Escape($sym)
$prototypeMatches = [regex]::Matches($normalizedC, "int32_t\s+$escapedSym\s*\(([^)]*)\)")
if ($prototypeMatches.Count -eq 0) { throw "could not find an int32_t prototype for $sym in main.c" }
$signatures = @($prototypeMatches | ForEach-Object {
  (($_.Groups[1].Value -replace '\s+', '') -replace 'int32_t[A-Za-z_][A-Za-z0-9_]*', 'int32_t')
} | Sort-Object -Unique)
if ($signatures.Count -ne 1 -or $signatures[0] -ne 'int32_t,int32_t,int32_t,int32_t') {
  throw "generated MoonBit callback must have four int32_t parameters; found: $($signatures -join '; ')"
}
Set-Content -NoNewline -Path (Join-Path $GSys 'mb_symbol.txt') -Value "$sym`n"
Write-Host "    symbol / link_name : $sym"
Write-Host '    signature : int32_t(int32_t, int32_t, int32_t, int32_t)'

Write-Host '==> [3/5] Build gpui-sys (cargo)'
# Moon's native backend unconditionally compiles and links with /MT. Build the
# Rust static library with the same static CRT instead of trying to override
# Moon with /MD (Moon appends /MT after user cc-flags, so /MT always wins).
if (-not $env:RUSTFLAGS) {
  $env:RUSTFLAGS = '-C target-feature=+crt-static'
} elseif ($env:RUSTFLAGS -notlike '*target-feature=+crt-static*') {
  $env:RUSTFLAGS = "$env:RUSTFLAGS -C target-feature=+crt-static"
}
Push-Location $GSys
cmd /c "cargo build 2>&1" | Out-Host
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'cargo build failed' }
$nativeLibs = (cmd /c "cargo rustc -- --print native-static-libs 2>&1" |
               Select-String 'native-static-libs:' | Select-Object -First 1).Line `
               -replace '.*native-static-libs:\s*', ''
Pop-Location
if (-not $nativeLibs) { throw 'could not capture native-static-libs' }
# /MT already selects libcmt. Do not pass Cargo's CRT default directive before
# Moon's trailing /link delimiter, and do not introduce a second CRT choice.
$nativeLibTokens = @($nativeLibs -split '\s+' | Where-Object {
  $_ -and $_ -notmatch '(?i)^/defaultlib:(libcmt|msvcrt)$'
})
$nativeLibs = $nativeLibTokens -join ' '
Write-Host "    native libs (static CRT): $nativeLibs"

# gpui's build.rs emits an extra static lib (gpui.lib) under target\debug\build\
# on Windows; add every build-script out dir that holds a .lib to LIB.
$extraDirs = @(Get-ChildItem (Join-Path $GSys 'target\debug\build') -Recurse -Filter '*.lib' -ErrorAction SilentlyContinue |
               ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
# windows-rs ships its import libs (windows.0.5x.0.lib) inside the cargo
# registry checkout; the linker needs those dirs on the search path too.
$winLibDirs = @(Get-ChildItem "$env:USERPROFILE\.cargo\registry\src" -Directory -ErrorAction SilentlyContinue |
                 ForEach-Object { Get-ChildItem $_.FullName -Directory -Filter 'windows_x86_64_msvc-*' -ErrorAction SilentlyContinue } |
                 ForEach-Object { Join-Path $_.FullName 'lib' } |
                 Where-Object { Test-Path $_ })
$projectLibDirs = @((Join-Path $GSys 'target\debug')) + $extraDirs + $winLibDirs
$allLibDirs = $projectLibDirs + @($env:LIB -split ';')
$env:LIB = ($allLibDirs | Where-Object { $_ } | Select-Object -Unique) -join ';'
Write-Host "    extra LIB dirs: $($projectLibDirs -join ';')"

Write-Host '==> [4/5] Final MoonBit build (real moon.pkg + forced relink)'
Write-MoonPkg $nativeLibs
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $MB '_build\native\debug\build\cmd\main\main.exe')
Push-Location $MB
cmd /c "moon build 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'final moon build failed' }

Write-Host '==> [5/5] Verify the callback definition/reference contract'
$exe = Join-Path $MB '_build\native\debug\build\cmd\main\main.exe'
if (-not (Test-Path $exe)) { throw "final executable not found at $exe" }
$mainObj = Join-Path $MB '_build\native\debug\build\cmd\main\main.obj'
if (-not (Test-Path $mainObj)) { throw "MoonBit object not found at $mainObj" }
$rustLib = Join-Path $GSys 'target\debug\gpui_sys.lib'
if (-not (Test-Path $rustLib)) { throw "Rust static library not found at $rustLib" }

# Linked PE executables normally omit their COFF symbol table, so checking
# dumpbin /SYMBOLS on main.exe produces a false zero. Verify instead that the
# MoonBit object defines the callback exactly once and the Rust archive refers
# to it exactly once. A successful final link above proves that reference was
# resolved into main.exe; duplicate definitions would make link.exe fail.
$definitionPattern = '^.*SECT[0-9]+.*External\s+\|\s+' + [regex]::Escape($sym) + '\s*$'
$definitions = @(& dumpbin /SYMBOLS $mainObj 2>&1 | Where-Object { $_ -match $definitionPattern })
if ($LASTEXITCODE -ne 0) { throw 'dumpbin /SYMBOLS main.obj failed' }
if ($definitions.Count -ne 1) { throw "expected exactly 1 definition of $sym in main.obj, found $($definitions.Count)" }

$referencePattern = '^.*UNDEF.*External\s+\|\s+' + [regex]::Escape($sym) + '\s*$'
$references = @(& dumpbin /SYMBOLS $rustLib 2>&1 | Where-Object { $_ -match $referencePattern })
if ($LASTEXITCODE -ne 0) { throw 'dumpbin /SYMBOLS gpui_sys.lib failed' }
if ($references.Count -ne 1) { throw "expected exactly 1 reference to $sym in gpui_sys.lib, found $($references.Count)" }
Write-Host "    Verified: main.obj defines $sym exactly once"
Write-Host "    Verified: gpui_sys.lib references $sym exactly once and main.exe linked"
Write-Host "Done. Run: $exe"

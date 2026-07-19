# Build driver for GPUI + MoonBit on Windows. Mirrors build.sh:
#   [0] regenerate ABI constants and C FFI bindings
#   [1a] moon check (fatal typecheck gate)
#   [1b] moon build (only a cold native-link failure is tolerated)
#   [2] extract app.dispatch's mangled symbol from the generated main.c
#       (x64 COFF has no ABI underscore: use the name verbatim, like ELF)
#   [3] cargo build gpui-sys, then capture its native-static-libs list
#   [4] regenerate cmd/main/moon.pkg from moon.pkg.windows and relink
#   [5] verify the callback is defined exactly once in the final executable
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$GSys = Join-Path $Root 'gpui-sys'
$MB   = Join-Path $Root 'moonbit-bindings'
$PkgFnSuffix = '3app8dispatch'   # …/app :: dispatch (keep in sync with build.sh)

$env:Path = "$env:USERPROFILE\.moon\bin;$env:Path"

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
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
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
  if ($coldText -match '(?i)undefined (reference|symbol)|cannot find .*gpui_sys|library not found.*gpui_sys|3app8dispatch|LNK1181|LNK2019|LNK1120') {
    Write-Host '    (expected cold-link failure — continuing)'
  } else {
    throw 'MoonBit build failed for a non-link reason'
  }
}

Write-Host '==> [2/5] Extract the mangled symbol for app.dispatch'
$mainC = Join-Path $MB '_build\native\debug\build\cmd\main\main.c'
if (-not (Test-Path $mainC)) { throw "not found: $mainC — did MoonBit compile? (step 1 output above)" }
$symbols = @(Select-String -Path $mainC -Pattern "_M0FP[A-Za-z0-9_]*$PkgFnSuffix" -AllMatches |
       ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
       Sort-Object -Unique)
if ($symbols.Count -ne 1) { throw "expected exactly 1 app.dispatch symbol (…$PkgFnSuffix), found $($symbols.Count)" }
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
Push-Location $GSys
cmd /c "cargo build 2>&1" | Out-Host
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'cargo build failed' }
$nativeLibs = (cmd /c "cargo rustc -- --print native-static-libs 2>&1" |
               Select-String 'native-static-libs:' | Select-Object -First 1).Line `
               -replace '.*native-static-libs:\s*', ''
Pop-Location
if (-not $nativeLibs) { throw 'could not capture native-static-libs' }
Write-Host "    native libs: $nativeLibs"

# gpui's build.rs emits an extra static lib (gpui.lib) under target\debug\build\
# on Windows; add every build-script out dir that holds a .lib to the search path.
$extraPaths = Get-ChildItem (Join-Path $GSys 'target\debug\build') -Recurse -Filter '*.lib' -ErrorAction SilentlyContinue |
              ForEach-Object { $_.DirectoryName } | Sort-Object -Unique |
              ForEach-Object { '/LIBPATH:' + ($_ -replace '\\', '/') }
# windows-rs ships its import libs (windows.0.5x.0.lib) inside the cargo
# registry checkout — the linker needs those dirs on the search path too.
$winLibPaths = Get-ChildItem "$env:USERPROFILE\.cargo\registry\src" -Directory -ErrorAction SilentlyContinue |
               ForEach-Object { Get-ChildItem $_.FullName -Directory -Filter 'windows_x86_64_msvc-*' -ErrorAction SilentlyContinue } |
               ForEach-Object { Join-Path $_.FullName 'lib' } |
               Where-Object { Test-Path $_ } |
               ForEach-Object { '/LIBPATH:' + ($_ -replace '\\', '/') }
$extraPaths = @($extraPaths) + @($winLibPaths)
$nativeLibs = ($extraPaths + $nativeLibs) -join ' '
if ($extraPaths) { Write-Host "    extra lib paths: $($extraPaths -join ' ')" }

# /MD keeps moon's cl compile on Rust's dynamic CRT (msvcrt), avoiding LNK4098 against LIBCMT.
Write-Host '==> [4/5] Final MoonBit build (real moon.pkg + forced relink)'
Write-MoonPkg $nativeLibs
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $MB '_build\native\debug\build\cmd\main\main.exe')
Push-Location $MB
cmd /c "moon build 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'final moon build failed' }

Write-Host '==> [5/5] Verify exactly one callback definition in the final binary'
$exe = Join-Path $MB '_build\native\debug\build\cmd\main\main.exe'
if (-not (Test-Path $exe)) { throw "final executable not found at $exe" }
$dumpbinOutput = & dumpbin /SYMBOLS $exe 2>&1
if ($LASTEXITCODE -ne 0) { throw 'dumpbin /SYMBOLS failed' }
# COFF definitions have a SECT<number> field; UNDEF externals are references only.
$definitionPattern = '^.*SECT[0-9]+.*External\s+\|\s+' + [regex]::Escape($sym) + '\s*$'
$definitions = @($dumpbinOutput | Where-Object { $_ -match $definitionPattern })
if ($definitions.Count -ne 1) { throw "expected exactly 1 definition of $sym in final binary, found $($definitions.Count)" }
Write-Host "    Verified: $sym is defined exactly once"
Write-Host "Done. Run: $exe"

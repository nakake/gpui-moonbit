# Build driver for GPUI + MoonBit on Windows. Mirrors build.sh:
#   [1] moon build (cold; final cl link may fail — ignored)
#   [2] extract app.dispatch's mangled symbol from the generated main.c
#       (x64 COFF has no ABI underscore: use the name verbatim, like ELF)
#   [3] cargo build gpui-sys, then capture its native-static-libs list
#   [4] regenerate cmd/main/moon.pkg from moon.pkg.windows and relink
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

Write-Host '==> [1/4] Compile MoonBit (cold link failure is expected and ignored)'
Write-MoonPkg ''
Push-Location $MB
cmd /c "moon build 2>&1" | Out-Host
Pop-Location

Write-Host '==> [2/4] Extract the mangled symbol for app.dispatch'
$mainC = Join-Path $MB '_build\native\debug\build\cmd\main\main.c'
if (-not (Test-Path $mainC)) { throw "not found: $mainC — did MoonBit compile? (step 1 output above)" }
$sym = Select-String -Path $mainC -Pattern "_M0FP[A-Za-z0-9_]*$PkgFnSuffix" -AllMatches |
       ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
       Sort-Object -Unique | Select-Object -First 1
if (-not $sym) { throw "could not find the app.dispatch mangled symbol (…$PkgFnSuffix) in main.c" }
Set-Content -NoNewline -Path (Join-Path $GSys 'mb_symbol.txt') -Value "$sym`n"
Write-Host "    symbol / link_name : $sym"

Write-Host '==> [3/4] Build gpui-sys (cargo)'
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
Write-Host '==> [4/4] Final MoonBit build (real moon.pkg + forced relink)'
Write-MoonPkg $nativeLibs
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $MB '_build\native\debug\build\cmd\main\main.exe')
Push-Location $MB
cmd /c "moon build 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'final moon build failed' }
Write-Host "Done. Run: $MB\_build\native\debug\build\cmd\main\main.exe"

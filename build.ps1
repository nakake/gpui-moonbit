# Build driver for GPUI + MoonBit on Windows. Mirrors build.sh:
#   [0] regenerate the C header, ABI constants, and C FFI bindings
#   [1] moon check (fatal typecheck gate)
#   [2] moon build — the prebuild script (moonbit-bindings/build.py) computes
#       the callback symbol, writes gpui-sys/mb_symbol.txt, cargo-builds
#       gpui-sys, and supplies the link flags via a LinkConfig on the `link`
#       package (RFC 0005); cmd/main and cmd/roundtrip import that package
#   [3] verify the callback link contract (definition/reference exactly once,
#       C prototype matches abi.toml `[callback] params`)
#   [4] run the headless round-trip test
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$GSys = Join-Path $Root 'gpui-sys'
$MB   = Join-Path $Root 'moonbit-bindings'

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

Write-Host "==> Preflight (Windows $env:PROCESSOR_ARCHITECTURE)"
foreach ($command in 'moon', 'cargo', 'rustc', 'cl', 'link', 'dumpbin', 'python') {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "required command not found: $command"
  }
}
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
  throw "unsupported Windows architecture: $env:PROCESSOR_ARCHITECTURE (supported: AMD64)"
}
if ($env:VSCMD_ARG_TGT_ARCH -and $env:VSCMD_ARG_TGT_ARCH -ne 'x64') {
  throw "MSVC is configured for $env:VSCMD_ARG_TGT_ARCH; run build.ps1 from an x64 developer shell"
}
$clBanner = (& cl 2>&1) -join "`n"
if ($clBanner -notmatch '(?i)\bfor x64\b') {
  throw 'MSVC compiler is not targeting x64; run build.ps1 from an x64 developer shell'
}
& moon --version
& cargo --version
& rustc --version
# RFC 0005 D1: build.py pins gpui-sys for the wrapper (registry) routes with a
# cargo caret requirement. The comparison lives in build.py (--check-pin, the
# single implementation both drivers share); it exits non-zero on drift.
cmd /c "python `"$MB\build.py`" --check-pin 2>&1" | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'gpui-sys version pin drift (see message above)' }
if (Get-Command rustup -ErrorAction SilentlyContinue) {
  & rustup show active-toolchain
}
$rustHostLine = @(& rustc -vV | Where-Object { $_ -match '^host:\s+' })
if ($rustHostLine.Count -ne 1) { throw 'could not determine the native Rust host target' }
$rustHost = $rustHostLine[0] -replace '^host:\s+', ''
if ($rustHost -ne 'x86_64-pc-windows-msvc') {
  throw "unsupported Rust host target: $rustHost (supported: x86_64-pc-windows-msvc)"
}
# The verification step below reads gpui_sys.lib out of the cargo target dir.
$cargoMetadata = (& cargo metadata --no-deps --format-version 1 --manifest-path (Join-Path $GSys 'Cargo.toml') |
                  Out-String | ConvertFrom-Json)
$cargoTargetRoot = [string]$cargoMetadata.target_directory
if (-not $cargoTargetRoot) { throw 'cargo metadata did not report target_directory' }
$rustTargetDir = Join-Path (Join-Path $cargoTargetRoot $rustHost) 'debug'
Write-Host "    Rust target: $rustHost"
Write-Host "    Rust library dir: $rustTargetDir"

# The pre-commit hook is opt-in: `core.hooksPath` is a local git setting that a
# clone does not inherit, so it is easy to never notice the hook exists (issue
# #82). Nudge, do not set it — silently rewriting someone's git config from a
# build script is worse than an unenforced hook. `git config --get` exits 1 when
# the key is unset, which PowerShell 7.4+ turns into a terminating error under
# $ErrorActionPreference = 'Stop', so the probe is wrapped and LASTEXITCODE is
# reset for the steps that read it.
if (Get-Command git -ErrorAction SilentlyContinue) {
  $hooksPath = ''
  try {
    $hooksPath = (& git -C $Root config --get core.hooksPath 2>$null | Select-Object -First 1)
  } catch {
    $hooksPath = ''
  }
  $global:LASTEXITCODE = 0
  if (-not $hooksPath) {
    Write-Host '    HINT: pre-commit hook not enabled. To enable it, run:'
    Write-Host '          git config core.hooksPath moonbit-bindings/.githooks'
  }
}

Write-Host '==> [0/4] Regenerate the C header, ABI constants, and C FFI bindings'
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
# Expected C parameter list for the MoonBit callback, derived from abi.toml so
# `[callback] params` stays the single source of truth (issue #76).
$callbackSection = ''
$callbackParams = ''
foreach ($abiLine in $abiLines) {
  $trimmed = ($abiLine -replace '\s*#.*$', '').Trim()
  if (-not $trimmed) { continue }
  if ($trimmed -match '^\[([A-Za-z_][A-Za-z0-9_]*)\]$') { $callbackSection = $Matches[1]; continue }
  if ($callbackSection -eq 'callback' -and $trimmed -match '^params\s*=\s*\[(.*)\]\s*$') {
    $types = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
    if ($types.Count -lt 1) { throw '[callback] params is empty in abi.toml' }
    foreach ($t in $types) {
      if ($t -ne 'i32') { throw "unsupported [callback] param type in abi.toml: $t" }
    }
    $callbackParams = (@('int32_t') * $types.Count) -join ','
    break
  }
}
if (-not $callbackParams) { throw 'could not derive [callback] params from abi.toml' }

# The MoonBit callback whose link contract step 3 verifies, derived from
# abi.toml so `[callback] name` stays the single source of truth (issue #76,
# RFC 0004 §3.5). build.py and gpui-sys/build.rs derive the full mangled
# symbol from the same fields.
$callbackSection = ''
$CallbackName = ''
foreach ($abiLine in $abiLines) {
  $trimmed = ($abiLine -replace '\s*#.*$', '').Trim()
  if (-not $trimmed) { continue }
  if ($trimmed -match '^\[([A-Za-z_][A-Za-z0-9_]*)\]$') { $callbackSection = $Matches[1]; continue }
  if ($callbackSection -eq 'callback' -and $trimmed -match '^name\s*=\s*"([^"]*)"\s*$') {
    $CallbackName = $Matches[1]
    if ($CallbackName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
      throw "invalid [callback] name in abi.toml: $CallbackName"
    }
    break
  }
}
if (-not $CallbackName) { throw 'could not derive [callback] name from abi.toml' }
$callbackSection = ''
$CallbackModule = ''
foreach ($abiLine in $abiLines) {
  $trimmed = ($abiLine -replace '\s*#.*$', '').Trim()
  if (-not $trimmed) { continue }
  if ($trimmed -match '^\[([A-Za-z_][A-Za-z0-9_]*)\]$') { $callbackSection = $Matches[1]; continue }
  if ($callbackSection -eq 'callback' -and $trimmed -match '^module\s*=\s*"([^"]*)"\s*$') {
    $CallbackModule = $Matches[1]
    break
  }
}
# Mangled prefix of the module path (component: _ -> __ then - -> _2d, each
# length-prefixed, count first). Used only to narrow link-failure diagnostics
# to this module's symbols; function-name independent by construction.
# Keep in sync with compute_callback_symbol() in moonbit-bindings/build.py
# (the authoritative copy; a drift here only widens the diagnostic list).
$ModulePrefix = ''
if ($CallbackModule) {
  $components = $CallbackModule -split '/'
  $parts = ($components | ForEach-Object {
    $esc = ($_ -replace '_', '__') -replace '-', '_2d'
    "$($esc.Length)$esc"
  }) -join ''
  $ModulePrefix = "_M0FP$($components.Count)$parts"
}

$abiConstants = Join-Path $MB 'abi_constants.mbt'
# UTF-8 without BOM and LF newlines matches awk output byte-for-byte.
[System.IO.File]::WriteAllText($abiConstants, (($generated -join "`n") + "`n"), $utf8NoBom)
Push-Location $MB
cmd /c "moon fmt abi_constants.mbt 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'moon fmt abi_constants.mbt failed' }
# The header must reflect any new Rust C export BEFORE bindgen reads it:
# bindgen's output gates `moon check`, which gates the `cargo build` that
# would otherwise be the only thing regenerating the header (issue #71).
# gen-header depends on cbindgen alone, so this is cheap (no gpui build).
Push-Location (Join-Path $Root 'gen-header')
cmd /c "cargo run -- `"$GSys`" `"$GSys\include\gpui_sys.h`" 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) { throw 'C header generation failed' }
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

Write-Host '==> [1/4] MoonBit typecheck'
Push-Location $MB
cmd /c "moon check 2>&1" | Out-Host
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) {
  Write-Host 'HINT: if you added a new Rust C export, the C header must be regenerated; run .\build.ps1 (it regenerates the header before bindgen).'
  throw 'MoonBit compilation failed'
}

Write-Host '==> [2/4] MoonBit build (build.py builds gpui-sys and supplies the link flags)'
# moon does not track the external gpui_sys.lib, so a gpui-sys-only change
# would NOT trigger a relink of the executables (it would silently keep stale
# exes). Remove the linked outputs so moon re-links against the fresh .lib.
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $MB '_build\native\debug\build\cmd\main\main.exe')
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $MB '_build\native\debug\build\cmd\roundtrip\roundtrip.exe')
Push-Location $MB
$finalOutput = cmd /c "moon build 2>&1"
$ec = $LASTEXITCODE
Pop-Location
if ($ec -ne 0) {
  $finalOutput | Out-Host
  $finalText = $finalOutput -join "`n"
  # MSVC reports a missing input lib as LNK1104/LNK1181 and an unresolved
  # external as LNK2019/LNK1120 (locale-independent codes).
  if ($finalText -match '(?i)LNK1104|LNK1181|LNK2019|LNK1120|undefined (reference|symbol)|_M0FP') {
    # Link failure on the callback symbol: the symbol gpui-sys referenced
    # (gpui-sys/mb_symbol.txt) does not match what the MoonBit toolchain
    # actually generated. Show the real candidates from the generated C so the
    # mismatch is diagnosable even if the mangling scheme itself changed
    # (a suffix-anchored scan would find nothing in that case).
    Write-Host 'ERROR: MoonBit native link failed.'
    $symbolFile = Join-Path $GSys 'mb_symbol.txt'
    if (Test-Path $symbolFile) {
      Write-Host "    expected callback symbol (gpui-sys/mb_symbol.txt): $((Get-Content $symbolFile -Raw).Trim())"
    }
    $unresolved = @($finalOutput | Where-Object { $_ -match '(?i)undefined (reference|symbol)|LNK2019|LNK1120' } |
      Select-String -Pattern '_M0FP[A-Za-z0-9_]+' -AllMatches |
      ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
      Sort-Object -Unique)
    if ($unresolved.Count -gt 0) {
      Write-Host '    unresolved symbols in the link output:'
      $unresolved | ForEach-Object { Write-Host "      $_" }
    }
    $candidates = @(Get-ChildItem (Join-Path $MB '_build\native\debug\build\cmd') -Recurse -Filter '*.c' -ErrorAction SilentlyContinue |
      Select-String -Pattern '_M0FP[A-Za-z0-9_]+' -AllMatches |
      ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
      Sort-Object -Unique)
    if ($candidates.Count -gt 0 -and $ModulePrefix) {
      $filtered = @($candidates | Where-Object { $_.StartsWith($ModulePrefix) })
      if ($filtered.Count -gt 0) { $candidates = $filtered }
    }
    if ($candidates.Count -gt 0) {
      Write-Host "    mangled symbols found in the generated C (module $CallbackModule):"
      $candidates | ForEach-Object { Write-Host "      $_" }
    }
    Write-Host 'HINT: if the expected symbol is stale, delete gpui-sys\mb_symbol.txt and re-run .\build.ps1 (build.py recomputes it).'
    Write-Host 'HINT: if the recomputed symbol still mismatches the candidates above, the toolchain''s mangling scheme changed; update compute_callback_symbol() in moonbit-bindings\build.py (gpui-sys\build.rs derives the same value).'
  }
  throw 'moon build failed'
}
Write-Host '    MoonBit build succeeded.'

Write-Host '==> [3/4] Verify the callback link contract'
$exe = Join-Path $MB '_build\native\debug\build\cmd\main\main.exe'
if (-not (Test-Path $exe)) { throw "final executable not found at $exe" }
# Verify the value actually in mb_symbol.txt, not a recomputation: the file is
# what gpui-sys/build.rs consumed, and keeping it authoritative preserves the
# manual-override escape hatch (write the file by hand, build.py leaves it).
$symbolFile = Join-Path $GSys 'mb_symbol.txt'
if (-not (Test-Path $symbolFile)) { throw "$symbolFile not found after moon build (build.py should have written it)" }
$sym = (Get-Content $symbolFile -Raw).Trim()
if (-not $sym) { throw "$symbolFile is empty" }
$rustLib = Join-Path $rustTargetDir 'gpui_sys.lib'
if (-not (Test-Path $rustLib)) { throw "Rust static library not found at $rustLib" }

# Linked PE executables normally omit their COFF symbol table, so checking
# dumpbin /SYMBOLS on main.exe produces a false zero. Verify instead on the
# inputs of the link: the Rust archive must refer to the callback exactly once
# (UNDEF), and the successful final link above proves that reference was
# resolved — by the MoonBit object when it survives the prebuild flow, whose
# single definition is then also checked directly.
$referencePattern = '^.*UNDEF.*External\s+\|\s+' + [regex]::Escape($sym) + '\s*$'
$references = @(& dumpbin /SYMBOLS $rustLib 2>&1 | Where-Object { $_ -match $referencePattern })
if ($LASTEXITCODE -ne 0) { throw 'dumpbin /SYMBOLS gpui_sys.lib failed' }
if ($references.Count -ne 1) { throw "expected exactly 1 reference to $sym ($CallbackName) in gpui_sys.lib, found $($references.Count)" }
Write-Host "    Verified: gpui_sys.lib references $sym exactly once and main.exe linked"

$mainObj = Join-Path $MB '_build\native\debug\build\cmd\main\main.obj'
if (Test-Path $mainObj) {
  $definitionPattern = '^.*SECT[0-9]+.*External\s+\|\s+' + [regex]::Escape($sym) + '\s*$'
  $definitions = @(& dumpbin /SYMBOLS $mainObj 2>&1 | Where-Object { $_ -match $definitionPattern })
  if ($LASTEXITCODE -ne 0) { throw 'dumpbin /SYMBOLS main.obj failed' }
  if ($definitions.Count -ne 1) { throw "expected exactly 1 definition of $sym ($CallbackName) in main.obj, found $($definitions.Count)" }
  Write-Host "    Verified: main.obj defines $sym exactly once"
} else {
  Write-Host '    main.obj not present under the prebuild flow; definition side is covered by the successful link'
}

# The mangled name does not encode types. Validate the actual generated C
# declaration (the prebuild flow keeps main.c around after a successful link).
$mainC = Join-Path $MB '_build\native\debug\build\cmd\main\main.c'
if (Test-Path $mainC) {
  $normalizedC = (Get-Content $mainC -Raw) -replace '\s+', ' '
  $escapedSym = [regex]::Escape($sym)
  $prototypeMatches = [regex]::Matches($normalizedC, "int32_t\s+$escapedSym\s*\(([^)]*)\)")
  if ($prototypeMatches.Count -eq 0) { throw "could not find an int32_t prototype for $sym in main.c" }
  $signatures = @($prototypeMatches | ForEach-Object {
    (($_.Groups[1].Value -replace '\s+', '') -replace 'int32_t[A-Za-z_][A-Za-z0-9_]*', 'int32_t')
  } | Sort-Object -Unique)
  if ($signatures.Count -ne 1 -or $signatures[0] -ne $callbackParams) {
    throw "generated MoonBit callback must be int32_t($($callbackParams -replace ',', ', ')); found: $($signatures -join '; ')"
  }
  Write-Host "    signature : int32_t($($callbackParams -replace ',', ', '))"
} else {
  Write-Host '    signature : skipped (generated main.c is unavailable)'
}

Write-Host '==> [4/4] Run headless round-trip test (issue #34)'
$rtExe = Join-Path $MB '_build\native\debug\build\cmd\roundtrip\roundtrip.exe'
if (-not (Test-Path $rtExe)) { throw "roundtrip executable not found at $rtExe" }
& $rtExe
if ($LASTEXITCODE -ne 0) { throw 'round-trip test failed' }
Write-Host "Done. Run: $exe"

# In CI, export the developer-shell LIB so a later `moon test` step that
# happens to relink can still resolve Windows SDK import libs (kernel32.lib
# etc.). Project libraries need no search path anymore: build.py's LinkConfig
# carries them as absolute paths.
if ($env:GITHUB_ENV) {
  Add-Content -Path $env:GITHUB_ENV -Value "LIB=$env:LIB"
}

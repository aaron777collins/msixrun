#!/usr/bin/env bash
# Test harness for msixrun. Stubs powershell.exe, explorer.exe, cygpath,
# wslpath and curl, then drives every path through the script.
# shellcheck disable=SC2015,SC2016  # the A && ok || bad idiom is intended; PowerShell text is matched literally
# Run: bash test/run.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MSIXRUN="$HERE/../msixrun"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0 fail=0 failed_names=()
cur=""

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); failed_names+=("$cur: $1"); echo "  FAIL [$cur] $1"; }

# assertions (use globals set by run_msixrun: $OUT, $RC, $T)
assert_rc()        { [ "$RC" -eq "$1" ] && ok || bad "expected exit $1, got $RC"; }
assert_rc_nonzero(){ [ "$RC" -ne 0 ] && ok || bad "expected a nonzero exit"; }
assert_out()       { printf '%s' "$OUT" | grep -qF -- "$1" && ok || bad "output lacks: $1"; }
assert_not_out()   { printf '%s' "$OUT" | grep -qF -- "$1" && bad "output has: $1" || ok; }
assert_step()      { grep -qx -- "$1" "$T/steps" && ok || bad "step not run: $1"; }
assert_no_step()   { grep -qx -- "$1" "$T/steps" && bad "step ran: $1" || ok; }
assert_steps()     { [ "$(tr '\n' ' ' <"$T/steps")" = "$1 " ] && ok || bad "steps were: $(tr '\n' ' ' <"$T/steps") wanted: $1"; }
assert_count()     { local n; n=$(grep -cx -- "$1" "$T/steps"); [ "$n" -eq "$2" ] && ok || bad "step $1 ran $n times, wanted $2"; }
assert_file_has()  { grep -qF -- "$2" "$1" && ok || bad "$1 lacks: $2"; }

# new_test <name>: fresh sandbox with stubs and a default scenario.
new_test() {
  cur="$1"; unset TTY_PATH
  echo "- $cur"
  T="$ROOT/$(printf '%s' "$cur" | tr -c 'A-Za-z0-9' '_')"
  rm -rf "$T"; mkdir -p "$T/bin" "$T/tmp"
  : >"$T/steps"
  printf 'NAME=Acme.App\nPUBLISHER=CN=Acme\n' >"$T/manifest.out"
  printf 'ok\n' >"$T/install.seq"
  printf 'STATUS=UnknownError\nSUBJECT=CN=Acme Ltd, O=Acme\nTHUMBPRINT=AABBCCDDEEFF00112233445566778899AABBCCDD\nNOTAFTER=2030-01-02\n' >"$T/signer.out"
  printf 'MSIXRUN_RESULT=ok\n' >"$T/trust.out"; echo 0 >"$T/trust.rc"
  printf 'DEVMODE=1\nALLOWUNSIGNED=1\n' >"$T/devmode.out"
  printf 'CONFLICT=0\n' >"$T/conflict.out"
  printf 'REMOVED=1\n' >"$T/remove.out"; echo 0 >"$T/remove.rc"
  printf 'Acme.App_8wekyb3d8bbwe!App\n' >"$T/launch.out"
  : >"$T/answers"
  make_stubs
  printf 'PK\n' >"$T/app.msix"
}

make_stubs() {
  cat >"$T/bin/powershell.exe" <<'STUB'
#!/usr/bin/env bash
script="${*: -1}"
step="$(printf '%s\n' "$script" | sed -n 's/^# step: //p' | head -n 1)"
if [ -z "$step" ]; then printf 'C:\\Temp\\\r\n'; exit 0; fi
echo "$step" >>"$T/steps"
n=$(grep -cx "$step" "$T/steps")
printf '%s\n' "$script" >"$T/script.$step.$n"
case "$step" in
  manifest) cat "$T/manifest.out"; [ ! -f "$T/manifest.rc" ] || exit "$(cat "$T/manifest.rc")" ;;
  install)
    line="$(sed -n "${n}p" "$T/install.seq")"; [ -n "$line" ] || line="$(tail -n 1 "$T/install.seq")"
    if [ "$line" = ok ]; then echo MSIXRUN_OK; exit 0; fi
    echo "MSIXRUN_HRESULT=0x80131500"
    echo "MSIXRUN_MESSAGE=Deployment failed with HRESULT: $line, stub failure"
    exit 1 ;;
  signer)   cat "$T/signer.out" ;;
  trust)    cat "$T/trust.out"; exit "$(cat "$T/trust.rc")" ;;
  devmode)  cat "$T/devmode.out" ;;
  conflict) cat "$T/conflict.out" ;;
  remove)   cat "$T/remove.out"; exit "$(cat "$T/remove.rc")" ;;
  launch)   cat "$T/launch.out"; [ ! -f "$T/launch.rc" ] || exit "$(cat "$T/launch.rc")" ;;
esac
exit 0
STUB
  cat >"$T/bin/explorer.exe" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/explorer.log"
exit 1
STUB
  cat >"$T/bin/cygpath" <<'STUB'
#!/usr/bin/env bash
# cygpath -w <path>
printf 'C:\\fake\\%s\n' "$(basename "$2")"
STUB
  cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
dest="" url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) dest="$2"; shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
echo "$url" >>"$T/curl.log"
echo "$dest" >>"$T/curl.dest"
[ ! -f "$T/curl.fail" ] || exit 22
printf 'PK\n' >"$dest"
STUB
  chmod +x "$T/bin/"*
}

# run_msixrun <args...>: runs with stubs first on PATH, answers from $T/answers.
run_msixrun() {
  OUT="$(cd "$T" && env PATH="$T/bin:$PATH" T="$T" TMPDIR="$T/tmp" MSIXRUN_TTY="${TTY_PATH-$T/answers}" bash "$MSIXRUN" "$@" 2>&1)"
  RC=$?
}
answers() { printf '%s\n' "$@" >"$T/answers"; }
no_tty()  { TTY_PATH="$T/does-not-exist"; }

UNTRUSTED='0x800B0109'

# ---------------------------------------------------------------- basics

new_test "help"
run_msixrun --help; assert_rc 0; assert_out "--trust"; assert_out "--yes"; assert_out "--no-launch"; assert_out "http(s) URL"
new_test "version"
run_msixrun --version; assert_rc 0; assert_out "msixrun 1.1.0"
new_test "no arguments prints usage and fails"
run_msixrun; assert_rc 1; assert_out "Usage:"
new_test "unknown option"
run_msixrun --bogus app.msix; assert_rc 1; assert_out "unknown option: --bogus"
new_test "two packages"
run_msixrun a.msix b.msix; assert_rc 1; assert_out "only one package"
new_test "file not found"
run_msixrun nope.msix; assert_rc 1; assert_out "file not found"
new_test "wrong extension"
printf 'x' >"$T/app.zip"; run_msixrun app.zip; assert_rc 1; assert_out "expected a .msix"
new_test "uppercase extension is accepted"
cp "$T/app.msix" "$T/UP.MSIX"; run_msixrun UP.MSIX --no-launch; assert_rc 0
new_test "powershell.exe missing"
rm "$T/bin/powershell.exe"
run_msixrun app.msix; if command -v powershell.exe >/dev/null 2>&1; then ok; else assert_rc 1; assert_out "powershell.exe not found"; fi
new_test "no cygpath and no wslpath"
rm "$T/bin/cygpath"
if command -v cygpath >/dev/null || command -v wslpath >/dev/null; then ok; else run_msixrun app.msix; assert_rc 1; assert_out "need cygpath"; fi

# ---------------------------------------------------------------- happy path

new_test "installs and launches"
run_msixrun app.msix
assert_rc 0; assert_out "Package: Acme.App"; assert_steps "manifest install launch"
assert_out 'Launching Acme.App_8wekyb3d8bbwe!App'
assert_file_has "$T/explorer.log" 'shell:AppsFolder\Acme.App_8wekyb3d8bbwe!App'
assert_file_has "$T/script.install.1" "\$pkg = 'C:\\fake\\app.msix'"
assert_file_has "$T/script.install.1" '$allowUnsigned = [bool]0'
new_test "--no-launch installs only"
run_msixrun app.msix --no-launch
assert_rc 0; assert_out "Installed Acme.App."; assert_no_step launch; [ ! -f "$T/explorer.log" ] && ok || bad "explorer ran"
new_test "launch failure after install is reported"
echo 1 >"$T/launch.rc"; run_msixrun app.msix
assert_rc 1; assert_out "could not find the app to launch"
new_test "launch info with odd characters is refused"
printf 'x y;calc!App\n' >"$T/launch.out"; run_msixrun app.msix
assert_rc 1; assert_out "could not resolve"; [ ! -f "$T/explorer.log" ] && ok || bad "explorer ran"
new_test "manifest read failure"
echo 1 >"$T/manifest.rc"; : >"$T/manifest.out"; run_msixrun app.msix
assert_rc 1; assert_out "could not read the package manifest"
new_test "empty package name"
: >"$T/manifest.out"; run_msixrun app.msix
assert_rc 1; assert_out "could not determine package name"
new_test "package name with shell or PowerShell metacharacters is refused"
printf 'NAME=Evil$(touch %s/pwned);x\nPUBLISHER=CN=X\n' "$T" >"$T/manifest.out"
run_msixrun app.msix
assert_rc 1; assert_out "unexpected characters"; [ ! -e "$T/pwned" ] && ok || bad "package-derived string was executed"
new_test "path with wildcard characters is copied to a plain name first"
cp "$T/app.msix" "$T/app[1]*?.msix"; run_msixrun 'app[1]*?.msix' --no-launch
assert_rc 0; assert_file_has "$T/script.install.1" 'C:\fake\app_1___.msix'
assert_file_has "$T/script.manifest.1" 'C:\fake\app_1___.msix'
[ -z "$(ls "$T/tmp")" ] && ok || bad "temp copy not cleaned up: $(ls "$T/tmp")"
new_test "path with a backtick is copied to a plain name first"
cp "$T/app.msix" "$T/app\`1.msix"; run_msixrun 'app`1.msix' --no-launch
assert_rc 0; assert_file_has "$T/script.install.1" 'C:\fake\app_1.msix'
[ -z "$(ls "$T/tmp")" ] && ok || bad "temp copy not cleaned up: $(ls "$T/tmp")"
new_test "path without wildcard characters is used in place"
run_msixrun app.msix --no-launch
assert_rc 0; assert_file_has "$T/script.install.1" "\$pkg = 'C:\\fake\\app.msix'"
[ -z "$(ls "$T/tmp")" ] && ok || bad "temp dir created needlessly"
new_test "path with single quotes is escaped for PowerShell"
cp "$T/app.msix" "$T/it's.msix"; run_msixrun "it's.msix" --no-launch
assert_rc 0; assert_file_has "$T/script.install.1" "C:\\fake\\it''s.msix"
new_test "path with curly quotes is escaped for PowerShell"
cp "$T/app.msix" "$T/a‘b.msix"; run_msixrun "a‘b.msix" --no-launch
assert_rc 0; assert_file_has "$T/script.install.1" "a‘‘b.msix"
new_test "generic install failure shows Windows' message"
printf '0x80070005\n' >"$T/install.seq"; run_msixrun app.msix
assert_rc 1; assert_out "install failed"; assert_out "0x80070005"; assert_no_step trust; assert_no_step launch

# ---------------------------------------------------------------- URL

new_test "url download then install"
run_msixrun https://example.com/dl/App_1.0.msix?token=abc --no-launch
assert_rc 0; assert_file_has "$T/curl.log" "https://example.com/dl/App_1.0.msix?token=abc"
assert_file_has "$T/curl.dest" "/App_1.0.msix"; assert_file_has "$T/script.install.1" 'C:\fake\App_1.0.msix'
[ -z "$(ls "$T/tmp")" ] && ok || bad "temp download not cleaned up: $(ls "$T/tmp")"
new_test "url without a package extension is saved as download.msix"
run_msixrun https://example.com/latest --no-launch
assert_rc 0; assert_file_has "$T/curl.dest" "/download.msix"
new_test "url with hostile name characters is sanitized"
run_msixrun 'https://example.com/a%20b$(x).msix' --no-launch
assert_rc 0; assert_file_has "$T/script.install.1" 'a_20b__x_.msix'
new_test "download failure"
touch "$T/curl.fail"; run_msixrun https://example.com/a.msix
assert_rc 1; assert_out "download failed"; assert_no_step manifest; [ -z "$(ls "$T/tmp")" ] && ok || bad "temp left behind"
new_test "url needs curl"
rm "$T/bin/curl"
if command -v curl >/dev/null; then ok; else run_msixrun https://example.com/a.msix; assert_rc 1; assert_out "curl is required"; fi
new_test "url under WSL downloads to the Windows temp directory"
rm "$T/bin/cygpath"
mkdir -p "$T/wintemp"
cat >"$T/bin/wslpath" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -u) echo "$T/wintemp" ;;
  -w) printf 'Z:\\wsl\\%s\n' "$(basename "$2")" ;;
esac
STUB
chmod +x "$T/bin/wslpath"
if command -v cygpath >/dev/null; then ok; else
  run_msixrun https://example.com/a.msix --no-launch
  assert_rc 0; assert_file_has "$T/curl.dest" "$T/wintemp/msixrun."; assert_file_has "$T/script.install.1" 'Z:\wsl\a.msix'
fi
new_test "local path under WSL uses wslpath"
rm "$T/bin/cygpath"
printf '#!/usr/bin/env bash\nprintf "Z:\\\\wsl\\\\%%s\\n" "$(basename "$2")"\n' >"$T/bin/wslpath"; chmod +x "$T/bin/wslpath"
if command -v cygpath >/dev/null; then ok; else run_msixrun app.msix --no-launch; assert_rc 0; assert_file_has "$T/script.install.1" 'Z:\wsl\app.msix'; fi

# ---------------------------------------------------------------- untrusted signer

new_test "untrusted signer, user answers y"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; answers y
run_msixrun app.msix
assert_rc 0
assert_out "Windows does not trust the publisher of this package. Trust CN=Acme Ltd, O=Acme and install? [y/N]"
assert_out "Signer:      CN=Acme Ltd, O=Acme"
assert_out "AABBCCDDEEFF00112233445566778899AABBCCDD (SHA-1)"
assert_out "Valid until: 2030-01-02"
assert_steps "manifest install signer trust install launch"
assert_file_has "$T/script.trust.1" "LocalMachine\\TrustedPeople"
assert_file_has "$T/script.trust.1" "-EncodedCommand"
assert_file_has "$T/script.trust.1" 'ToBase64String($cert.RawData)'
assert_file_has "$T/script.trust.1" '$c.Thumbprint -ne'
assert_file_has "$T/script.trust.1" "-Verb RunAs -Wait -PassThru"
assert_file_has "$T/script.trust.1" "\$pkg = 'C:\\fake\\app.msix'"
new_test "trust script writes no certificate file and imports no file by path"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; answers y; run_msixrun app.msix
for banned in Export-Certificate Import-Certificate .cer GetTempPath; do
  if grep -qF -- "$banned" "$T/script.trust.1"; then bad "trust script mentions $banned"; else ok; fi
done
new_test "trust script never touches the Root store"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; answers y; run_msixrun app.msix
if grep -qiE 'Cert:.LocalMachine.Root|-CertStoreLocation[^|]*Root|\\Root\b' "$T/script.trust.1"; then bad "script mentions the Root store"; else ok; fi
assert_file_has "$T/script.trust.1" "ExitCode -ne 0"
new_test "untrusted signer, uppercase Y and 'yes'"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; answers yes; run_msixrun app.msix; assert_rc 0
new_test "untrusted signer, user answers n"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; answers n
run_msixrun app.msix
assert_rc 1; assert_out "you chose not to trust"; assert_no_step trust; assert_count install 1
new_test "untrusted signer, empty answer means no"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; answers ""
run_msixrun app.msix
assert_rc 1; assert_no_step trust
new_test "untrusted signer, non-interactive without switch names --trust"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
run_msixrun app.msix
assert_rc 1; assert_out "--trust"; assert_no_step trust; assert_count install 1
new_test "untrusted signer with --trust skips the prompt"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
run_msixrun app.msix --trust
assert_rc 0; assert_out "(--trust)"; assert_step trust; assert_count install 2
new_test "untrusted signer with --yes skips the prompt"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
run_msixrun app.msix --yes
assert_rc 0; assert_out "(--yes)"; assert_step trust
new_test "untrusted signer with -y skips the prompt"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
run_msixrun app.msix -y --no-launch
assert_rc 0; assert_step trust
for code in 0x800B010A 0x800B0112 0x800B0004; do
  new_test "related trust error $code"
  printf '%s\nok\n' "$code" >"$T/install.seq"; no_tty
  run_msixrun app.msix --trust --no-launch; assert_rc 0; assert_step trust
done
new_test "trust error recognized from message text alone"
printf 'The root certificate of the signature in the app package must be trusted\nok\n' >"$T/install.seq"; no_tty
run_msixrun app.msix --trust --no-launch; assert_rc 0; assert_step trust
new_test "UAC declined"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; answers y
printf 'MSIXRUN_RESULT=declined\n' >"$T/trust.out"; echo 3 >"$T/trust.rc"
run_msixrun app.msix
assert_rc 1; assert_out "permission was declined"; assert_out "Nothing was changed"; assert_count install 1
new_test "elevated import fails"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
printf 'MSIXRUN_RESULT=failed\nMSIXRUN_MESSAGE=the elevated import exited with code 1\n' >"$T/trust.out"; echo 4 >"$T/trust.rc"
run_msixrun app.msix --trust
assert_rc 1; assert_out "could not trust the certificate"; assert_out "exited with code 1"; assert_count install 1
new_test "thumbprint not found in TrustedPeople afterwards"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
printf 'MSIXRUN_RESULT=unverified\n' >"$T/trust.out"; echo 5 >"$T/trust.rc"
run_msixrun app.msix --trust
assert_rc 1; assert_out "not in Trusted People"; assert_count install 1
for st in HashMismatch NotSigned Incompatible NotSupportedFileFormat; do
  new_test "signature status $st is not offered for trust"
  printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
  printf 'STATUS=%s\nSUBJECT=CN=Acme Ltd, O=Acme\nTHUMBPRINT=AABB\nNOTAFTER=2030-01-02\n' "$st" >"$T/signer.out"
  run_msixrun app.msix --yes
  assert_rc 1; assert_out "signature is not valid (status: $st)"; assert_no_step trust; assert_count install 1
done
new_test "signature status NotTrusted is offered for trust"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
printf 'STATUS=NotTrusted\nSUBJECT=CN=Acme Ltd, O=Acme\nTHUMBPRINT=AABB\nNOTAFTER=2030-01-02\n' >"$T/signer.out"
run_msixrun app.msix --trust --no-launch
assert_rc 0; assert_step trust
new_test "package with no signer certificate"
printf '%s\nok\n' "$UNTRUSTED" >"$T/install.seq"; no_tty
printf 'STATUS=NotSigned\n' >"$T/signer.out"
run_msixrun app.msix --trust
assert_rc 1; assert_out "could not read the signer certificate"; assert_no_step trust
new_test "trust succeeds but the retry fails again: no loop"
printf '%s\n%s\n%s\n' "$UNTRUSTED" "$UNTRUSTED" "$UNTRUSTED" >"$T/install.seq"; no_tty
run_msixrun app.msix --trust
assert_rc 1; assert_count install 2; assert_count trust 1; assert_out "install failed"

# ---------------------------------------------------------------- unsigned

new_test "unsigned, Developer Mode on, user says y: retry with AllowUnsigned"
printf '0x800B0100\nok\n' >"$T/install.seq"; answers y
run_msixrun app.msix --no-launch
assert_rc 0; assert_out "This package is not signed"; assert_steps "manifest install devmode install"
assert_file_has "$T/script.install.1" '$allowUnsigned = [bool]0'
assert_file_has "$T/script.install.2" '$allowUnsigned = [bool]1'
new_test "unsigned, user says n"
printf '0x800B0100\nok\n' >"$T/install.seq"; answers n
run_msixrun app.msix
assert_rc 1; assert_out "chose not to install an unsigned"; assert_count install 1
new_test "unsigned, non-interactive without --yes names --yes"
printf '0x800B0100\nok\n' >"$T/install.seq"; no_tty
run_msixrun app.msix
assert_rc 1; assert_out "--yes"; assert_count install 1
new_test "unsigned, --trust alone does not allow unsigned"
printf '0x800B0100\nok\n' >"$T/install.seq"; no_tty
run_msixrun app.msix --trust
assert_rc 1; assert_out "--yes"; assert_count install 1
new_test "unsigned with --yes"
printf '0x800B0100\nok\n' >"$T/install.seq"; no_tty
run_msixrun app.msix --yes --no-launch
assert_rc 0; assert_file_has "$T/script.install.2" '$allowUnsigned = [bool]1'
new_test "unsigned, Developer Mode off explains how to enable it"
printf '0x800B0100\nok\n' >"$T/install.seq"; printf 'DEVMODE=0\nALLOWUNSIGNED=1\n' >"$T/devmode.out"
run_msixrun app.msix
assert_rc 1; assert_out "Developer Mode is off"; assert_out "Windows 11: Settings > System > For developers"; assert_out "Windows 10: Settings > Update & Security > For developers"; assert_count install 1
new_test "unsigned, Developer Mode on but no -AllowUnsigned"
printf '0x800B0100\nok\n' >"$T/install.seq"; printf 'DEVMODE=1\nALLOWUNSIGNED=0\n' >"$T/devmode.out"
run_msixrun app.msix
assert_rc 1; assert_out "cannot install unsigned"; assert_count install 1
new_test "unsigned retry fails again: stops"
printf '0x800B0100\n0x800B0100\n' >"$T/install.seq"; no_tty
run_msixrun app.msix --yes
assert_rc 1; assert_count install 2; assert_count devmode 1

# ---------------------------------------------------------------- publisher conflict

new_test "older copy from another publisher, user says y"
printf '0x80073CFB\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; answers y
run_msixrun app.msix --no-launch
assert_rc 0
assert_out "An older Acme.App from a different publisher is installed. Remove it and install this one? Its local data will be removed. [y/N]"
assert_steps "manifest install conflict remove install"
new_test "older copy, 0x80073CF3 with conflict wording"
printf '0x80073CF3 the package conflicts with an installed one\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; answers y
run_msixrun app.msix --no-launch; assert_rc 0; assert_step remove
new_test "older copy, 0x80073CF3 saying a different publisher"
printf '0x80073CF3 installed from a different publisher\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; answers y
run_msixrun app.msix --no-launch; assert_rc 0; assert_step remove
new_test "bare 0x80073CF3 (a dependency failure) never removes an older copy, even with --yes"
printf '0x80073CF3\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
run_msixrun app.msix --yes --no-launch
assert_rc 1; assert_out "install failed"; assert_no_step conflict; assert_no_step remove; assert_not_out "Remove it"; assert_count install 1
new_test "0x80073CF3 with only Windows' generic 'dependency or conflict validation' text never removes"
printf '0x80073CF3 Package failed updates, dependency or conflict validation. depends on a framework that could not be found\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
run_msixrun app.msix --yes --no-launch
assert_rc 1; assert_no_step remove; assert_no_step conflict
new_test "unfamiliar error never offers to remove an older copy, even when one exists"
printf '0x80073D06\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; answers y
run_msixrun app.msix --no-launch
assert_rc 1; assert_out "install failed"; assert_no_step conflict; assert_no_step remove; assert_not_out "Remove it"
new_test "unfamiliar error with --yes never removes an older copy"
printf '0x80070070\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
run_msixrun app.msix --yes --no-launch
assert_rc 1; assert_no_step remove; assert_count install 1
new_test "trust succeeds, retry fails for another reason, older copy exists: nothing removed"
printf '%s\n0x80070070\n' "$UNTRUSTED" >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
run_msixrun app.msix --yes --no-launch
assert_rc 1; assert_step trust; assert_no_step remove; assert_out "install failed"
new_test "older copy, user says n"
printf '0x80073CFB\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; answers n
run_msixrun app.msix
assert_rc 1; assert_out "chose to keep the older Acme.App"; assert_no_step remove; assert_count install 1
new_test "older copy, non-interactive names --yes"
printf '0x80073CFB\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
run_msixrun app.msix
assert_rc 1; assert_out "--yes"; assert_no_step remove
new_test "older copy, --trust alone does not remove data"
printf '0x80073CFB\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
run_msixrun app.msix --trust
assert_rc 1; assert_no_step remove
new_test "older copy with --yes"
printf '0x80073CFB\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
run_msixrun app.msix --yes --no-launch
assert_rc 0; assert_step remove
new_test "conflict error but nothing from another publisher installed"
printf '0x80073CFB\n' >"$T/install.seq"
run_msixrun app.msix
assert_rc 1; assert_out "install failed"; assert_no_step remove
new_test "removal fails"
printf '0x80073CFB\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
printf 'MSIXRUN_MESSAGE=in use\n' >"$T/remove.out"; echo 1 >"$T/remove.rc"
run_msixrun app.msix --yes
assert_rc 1; assert_out "could not remove the older Acme.App: in use"; assert_count install 1
new_test "untrusted then older copy: both fixed in order"
printf '%s\n0x80073CFB\nok\n' "$UNTRUSTED" >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; answers y y
run_msixrun app.msix --no-launch
assert_rc 0; assert_steps "manifest install signer trust install conflict remove install"

# ---------------------------------------------------------------- script shape

new_test "the elevated step starts powershell.exe by full path"
printf '%s\n' "$UNTRUSTED" >"$T/install.seq"; printf 'ok\n' >>"$T/install.seq"; no_tty
run_msixrun app.msix --trust --no-launch
assert_rc 0; assert_file_has "$T/script.trust.1" "[IO.Path]::Combine(\$root, 'System32\\WindowsPowerShell\\v1.0\\powershell.exe')"
if grep -qF -- 'Start-Process -FilePath powershell.exe' "$T/script.trust.1"; then bad "bare powershell.exe in trust step"; else ok; fi
new_test "package-derived strings are never spliced into PowerShell"
printf 'NAME=Acme.App\nPUBLISHER=CN=Evil'"'"'; calc; #\n' >"$T/manifest.out"
printf '0x80073CFB\nok\n' >"$T/install.seq"; printf 'CONFLICT=1\n' >"$T/conflict.out"; no_tty
run_msixrun app.msix --yes
assert_rc 0
if grep -rlF "calc" "$T"/script.* >/dev/null 2>&1; then bad "publisher text reached a PowerShell script"; else ok; fi
new_test "snippets use no double quotes (safe across the Windows command line)"
run_msixrun app.msix
bad_dq=0; for f in "$T"/script.*; do
  # the first line is the $pkg assignment; the rest is fixed snippet text
  if sed '1,2d' "$f" | grep -q '"'; then bad_dq=1; echo "    double quote in $f"; fi
done
[ "$bad_dq" -eq 0 ] && ok || bad "double quote in a snippet"

echo
echo "passed: $pass  failed: $fail"
if [ "$fail" -ne 0 ]; then printf 'FAILED: %s\n' "${failed_names[@]}"; exit 1; fi

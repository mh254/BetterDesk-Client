#!/bin/bash
# Fügt eine Datei in ein bestehendes RPM ein, ohne Metadaten zu verlieren.
#
#   ./49-rpm-lizenz.sh <paket.rpm> <quelldatei> <zielpfad-im-paket>
#
# Ein RPM lässt sich nicht wie ein deb mit "dpkg-deb -R/-b" neu schnüren.
# Der Weg führt über rpm2cpio (Inhalt auspacken) und rpmbuild mit einer Spec,
# die Name, Version, Requires und Scriptlets aus dem Original übernimmt.
# Ohne das würden Abhängigkeiten und systemctl-Aufrufe verloren gehen und das
# Paket beim Kunden nicht mehr installierbar sein.
set -eu

src="$(realpath "${1:?RPM fehlt}")"
datei="$(realpath "${2:?Quelldatei fehlt}")"
ziel="${3:?Zielpfad fehlt}"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

q() { rpm -qp --qf "$1" "$src" 2>/dev/null; }

name=$(q '%{NAME}'); version=$(q '%{VERSION}'); release=$(q '%{RELEASE}')
arch=$(q '%{ARCH}'); summary=$(q '%{SUMMARY}'); lizenz=$(q '%{LICENSE}')
gruppe=$(q '%{GROUP}'); url=$(q '%{URL}'); beschreibung=$(q '%{DESCRIPTION}')

mkdir -p "$W/root" "$W/top/BUILD" "$W/top/BUILDROOT" "$W/top/RPMS" "$W/top/SPECS" "$W/top/SRPMS"
( cd "$W/root" && rpm2cpio "$src" | cpio -idm --quiet )

mkdir -p "$W/root$(dirname "$ziel")"
cp "$datei" "$W/root$ziel"

spec="$W/top/SPECS/$name.spec"
{
    echo "Name: $name"
    echo "Version: $version"
    echo "Release: $release"
    echo "Summary: $summary"
    echo "License: $lizenz"
    [ -n "$gruppe" ] && echo "Group: $gruppe"
    [ -n "$url" ] && echo "URL: $url"
    echo "AutoReqProv: no"
    echo ""
    rpm -qpR "$src" 2>/dev/null | grep -v '^rpmlib(' | sort -u | sed 's/^/Requires: /' || true
    echo ""
    echo "%description"
    echo "$beschreibung"
    echo ""
    for tag in PREIN POSTIN PREUN POSTUN; do
        text=$(q "%{$tag}")
        [ -z "$text" ] && continue
        case "$tag" in
            PREIN)  abschnitt="pre" ;;
            POSTIN) abschnitt="post" ;;
            PREUN)  abschnitt="preun" ;;
            POSTUN) abschnitt="postun" ;;
        esac
        printf '%%%s\n%s\n\n' "$abschnitt" "$text"
    done
    echo "%install"
    echo "cp -a \"$W/root/.\" \"%{buildroot}/\""
    echo ""
    echo "%files"
    echo "%defattr(-,root,root,-)"
    # Die Dateiliste wird aus dem Original übernommen: Verzeichnisse als %dir,
    # Config-Dateien als %config(noreplace). Selbst geraten würde /usr/share als
    # %dir landen und beim Installieren mit dem Basissystem kollidieren.
    rpm -qp --qf '[%{FILEMODES:perms}|%{FILEFLAGS:fflags}|%{FILENAMES}\n]' "$src" 2>/dev/null \
    | while IFS='|' read -r perms flags pfad; do
        [ -z "$pfad" ] && continue
        case "$perms" in
            d*) echo "%dir $pfad" ;;
            *)
                case "$flags" in
                    c*) echo "%config(noreplace) $pfad" ;;
                    *)  echo "$pfad" ;;
                esac
                ;;
        esac
    done
    echo "$ziel"
} > "$spec"

# --target ist Pflicht: ein aarch64-RPM laesst sich auf einem x86_64-Runner sonst
# nicht bauen ("error: No compatible architectures found for build").
if ! rpmbuild --define "_topdir $W/top" --define "_build_id_links none" \
        --target "$arch" -bb "$spec" > "$W/rpmbuild.log" 2>&1; then
    echo "FEHLER: rpmbuild ist gescheitert:" >&2
    tail -15 "$W/rpmbuild.log" >&2
    exit 1
fi

neu=$(find "$W/top/RPMS" -name '*.rpm' | head -1)
[ -n "$neu" ] || { echo "FEHLER: rpmbuild hat kein Paket erzeugt" >&2; exit 1; }

cp "$neu" "$src"
echo "  RPM neu gebaut: $(basename "$src")"
echo "  Dateien:  $(rpm -qpl "$src" | wc -l)"
echo "  Requires: $(rpm -qpR "$src" | wc -l)"
echo "  Scriptlets: $(rpm -qp --scripts "$src" 2>/dev/null | grep -c 'scriptlet')"

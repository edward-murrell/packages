#!/usr/bin/env bash
# Builds the static, signed repository in site/ from the packages in incoming/:
#   site/deb/   APT repository, one suite per release codename (see SUITES)
#   site/rpm/N/ RPM repository per release (N = $releasever: 9, 10, 44, ...)
#   site/key.gpg, site/key.asc, site/setup.sh, site/index.html
#
# Routing rules (the contract with the project release workflows):
#   .deb  Version ends in +<codename> (optionally .N, e.g. 1.2.0+noble or
#         1.2.0-1+noble.1)  -> that suite only. No suffix -> every suite
#         (for static, distro-independent builds such as Go).
#   .rpm  Release contains a dist tag .elN or .fcN -> rpm/N only. No dist tag ->
#         every rpm/N folder that exists.
#
# Requirements: gpg, apt-ftparchive (apt-utils), createrepo_c, rpmsign (rpm), nfpm, xz
# Signing: uses SIGNING_KEY_ID if set, otherwise the first secret key in the keyring.
#          Set GPG_PASSPHRASE if the key has a passphrase.
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true
# Let pinentry prompt on the terminal when run by hand; on CI there is no tty.
if [ -t 0 ]; then GPG_TTY=$(tty); export GPG_TTY; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../repo.conf
source "$ROOT/repo.conf"
INCOMING="${INCOMING:-$ROOT/incoming}"
SITE="${SITE:-$ROOT/site}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

for tool in gpg apt-ftparchive createrepo_c rpmsign nfpm dpkg-deb xz; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
mkdir -p "$INCOMING"

# ---------------------------------------------------------------- signing key
KEY_ID="${SIGNING_KEY_ID:-$(gpg --list-secret-keys --with-colons 2>/dev/null \
                            | awk -F: '$1=="fpr"{print $10; exit}')}"
[ -n "$KEY_ID" ] || die "no secret key found; import your signing key first"
GPG=(gpg --batch --yes --local-user "$KEY_ID" --digest-algo SHA256)
RPMSIGN_EXTRA=()
if [ -n "${GPG_PASSPHRASE:-}" ]; then
  printf '%s' "$GPG_PASSPHRASE" > "$WORK/pass"
  GPG+=(--pinentry-mode loopback --passphrase-file "$WORK/pass")
  RPMSIGN_EXTRA=(--define "_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file $WORK/pass")
fi
echo "Signing with key $KEY_ID"

rm -rf "$SITE"
mkdir -p "$SITE/deb" "$SITE/rpm"
gpg --export --export-options export-minimal "$KEY_ID" > "$SITE/key.gpg"
gpg --armor --export --export-options export-minimal "$KEY_ID" > "$SITE/key.asc"
touch "$SITE/.nojekyll"

# ------------------------------------------------- setup (keyring) packages
# <id>-archive-keyring (one per suite, since the source list names the suite)
# and <id>-release (one noarch rpm; the .repo file uses $releasever). They are
# in the repo too, so key/URL changes reach users as normal updates.
S="$WORK/setup"
mkdir -p "$S/out"
cp "$SITE/key.gpg" "$S/keyring.gpg"
cp "$SITE/key.asc" "$S/RPM-GPG-KEY"
for suite in $SUITES; do
  cat > "$S/$suite.sources" <<EOF
Types: deb
URIs: $BASE_URL/deb
Suites: $suite
Components: $COMPONENT
Signed-By: /usr/share/keyrings/$REPO_ID-archive-keyring.gpg
EOF
  cat > "$S/deb-$suite.yaml" <<EOF
name: $REPO_ID-archive-keyring
arch: all
platform: linux
version: $SETUP_PKG_VERSION+$suite
version_schema: none
maintainer: $MAINTAINER
section: misc
priority: optional
description: APT signing key and source list for $REPO_LABEL
homepage: $BASE_URL
contents:
  - src: $S/keyring.gpg
    dst: /usr/share/keyrings/$REPO_ID-archive-keyring.gpg
    file_info: {mode: 0644}
  - src: $S/$suite.sources
    dst: /etc/apt/sources.list.d/$REPO_ID.sources
    type: config
    file_info: {mode: 0644}
EOF
  nfpm pkg --packager deb --config "$S/deb-$suite.yaml" --target "$S/out/" >/dev/null
done
cat > "$S/yum.repo" <<EOF
[$REPO_ID]
name=$REPO_LABEL
baseurl=$BASE_URL/rpm/\$releasever
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-$REPO_ID
metadata_expire=6h
EOF
cat > "$S/rpm.yaml" <<EOF
name: $REPO_ID-release
arch: all
platform: linux
version: $SETUP_PKG_VERSION
maintainer: $MAINTAINER
description: Repository configuration and signing key for $REPO_LABEL
homepage: $BASE_URL
license: Public Domain
contents:
  - src: $S/RPM-GPG-KEY
    dst: /etc/pki/rpm-gpg/RPM-GPG-KEY-$REPO_ID
    file_info: {mode: 0644}
  - src: $S/yum.repo
    dst: /etc/yum.repos.d/$REPO_ID.repo
    type: config|noreplace
    file_info: {mode: 0644}
EOF
nfpm pkg --packager rpm --config "$S/rpm.yaml" --target "$S/out/" >/dev/null
SETUP_RPM_NAME=$(basename "$(ls "$S"/out/*.rpm)")

# Package list for the landing page: name, version, where, description, project
PKGLIST="$WORK/pkglist.tsv"; : > "$PKGLIST"
# owner/repo a downloaded file came from (fetch-releases.sh stores it under
# incoming/<owner>__<repo>/<tag>/); empty for anything else.
project_of() {
  case "$1" in
    "$INCOMING"/*/*) local d=${1#"$INCOMING"/}; d=${d%%/*}; [[ $d == *__* ]] && echo "${d/__//}" ;;
  esac
}
pretty_suite() {
  case "$1" in
    jammy) echo "Ubuntu 22.04 / Mint 21" ;;   noble)  echo "Ubuntu 24.04 / Mint 22" ;;
    bookworm) echo "Debian 12 / LMDE 6" ;;    trixie) echo "Debian 13 / LMDE 7" ;;
    *) echo "$1" ;;
  esac
}

# ------------------------------------------------------------- APT repository
deb_count=0
while IFS= read -r -d '' f; do
  name=$(dpkg-deb -f "$f" Package)
  ver=$(dpkg-deb -f "$f" Version)
  arch=$(dpkg-deb -f "$f" Architecture)
  if ! in_list "$arch" "$ARCHES all"; then
    warn "skipping $(basename "$f"): architecture '$arch' not in ARCHES"; continue
  fi
  if [[ $ver =~ \+([a-z]+)(\.[0-9]+)?$ ]] && in_list "${BASH_REMATCH[1]}" "$SUITES"; then
    target="${BASH_REMATCH[1]}"
  elif [[ $ver =~ \+([a-z]+)(\.[0-9]+)?$ ]] && [[ ${BASH_REMATCH[1]} =~ ^(jammy|noble|resolute|focal|bullseye|bookworm|trixie|forky)$ ]]; then
    warn "skipping $(basename "$f"): suite '${BASH_REMATCH[1]}' is not in SUITES"; continue
  else
    target="all"                                  # distro-independent package
  fi
  prefix=${name:0:1}; [[ $name == lib?* ]] && prefix=${name:0:4}
  dir="$SITE/deb/pool/$target/$prefix/$name"
  dest="$dir/${name}_${ver#*:}_${arch}.deb"
  mkdir -p "$dir"
  if [ -e "$dest" ] && ! cmp -s "$f" "$dest"; then
    die "two different files claim to be $name $ver ($arch): $f"
  fi
  cp "$f" "$dest"
  deb_count=$((deb_count + 1))
  if [ "$name" != "$REPO_ID-archive-keyring" ]; then
    up=${ver#*:}; up=${up%+*}; up=${up%-[0-9]*}
    if [ "$target" = all ]; then where="all Debian-family releases"; else where=$(pretty_suite "$target"); fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$up" "$where" "$(dpkg-deb -f "$f" Description | head -n1)" \
      "$(project_of "$f")" >> "$PKGLIST"
  fi
done < <(find "$INCOMING" "$S/out" -type f -name '*.deb' ! -name '*-dbgsym_*' -print0)

(
  cd "$SITE/deb"
  for suite in $SUITES; do
    for a in $ARCHES; do
      d="dists/$suite/$COMPONENT/binary-$a"
      mkdir -p "$d"
      : > "$d/Packages"
      for p in "pool/$suite" "pool/all"; do
        [ -d "$p" ] && apt-ftparchive --arch "$a" packages "$p" >> "$d/Packages"
      done
      gzip -9knf "$d/Packages"
      xz -kf "$d/Packages"
    done
    apt-ftparchive \
      -o APT::FTPArchive::Release::Origin="$REPO_LABEL" \
      -o APT::FTPArchive::Release::Label="$REPO_LABEL" \
      -o APT::FTPArchive::Release::Suite="$suite" \
      -o APT::FTPArchive::Release::Codename="$suite" \
      -o APT::FTPArchive::Release::Architectures="$ARCHES" \
      -o APT::FTPArchive::Release::Components="$COMPONENT" \
      -o APT::FTPArchive::Release::Description="$REPO_LABEL ($suite)" \
      release "dists/$suite" > "$WORK/Release"
    mv "$WORK/Release" "dists/$suite/Release"
    "${GPG[@]}" --clearsign -o "dists/$suite/InRelease" "dists/$suite/Release"
    "${GPG[@]}" --armor --detach-sign -o "dists/$suite/Release.gpg" "dists/$suite/Release"
    # Fixed-name keyring package for first-time setup
    cp "$(find "pool/$suite" -name "$REPO_ID-archive-keyring_*.deb" | head -n1)" \
       "$REPO_ID-archive-keyring_$suite.deb"
  done
)

# ------------------------------------------------------------- RPM repository
# Sign everything once in a staging folder, then sort into rpm/<releasever>/.
STAGE="$WORK/rpms"; mkdir -p "$STAGE"
rpm_count=0
declare -A RPM_PROJECT=()
while IFS= read -r -d '' f; do
  dest="$STAGE/$(basename "$f")"
  if [ -e "$dest" ] && ! cmp -s "$f" "$dest"; then die "two different files named $(basename "$f")"; fi
  cp "$f" "$dest"
  RPM_PROJECT["$(basename "$f")"]=$(project_of "$f")
  rpm_count=$((rpm_count + 1))
done < <(find "$INCOMING" "$S/out" -type f -name '*.rpm' ! -name '*.src.rpm' \
              ! -name '*-debuginfo-*' ! -name '*-debugsource-*' -print0)

rpmsign --addsign \
  --define "_gpg_name $KEY_ID" \
  --define "_gpg_digest_algo sha256" \
  "${RPMSIGN_EXTRA[@]}" \
  "$STAGE"/*.rpm >/dev/null 2> >(grep -v 'GPG_TTY' >&2)

declare -A COMMON=()
for f in "$STAGE"/*.rpm; do
  rel=$(rpm -qp --qf '%{RELEASE}' "$f" 2>/dev/null)
  if [[ $rel =~ \.(el|fc)([0-9]+) ]]; then
    n=${BASH_REMATCH[2]}
    mkdir -p "$SITE/rpm/$n/packages"
    cp "$f" "$SITE/rpm/$n/packages/"
    name=$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null)
    if [ "${BASH_REMATCH[1]}" = el ]; then where="EL $n (RHEL, Alma, Rocky)"; else where="Fedora $n"; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(rpm -qp --qf '%{VERSION}' "$f" 2>/dev/null)" "$where" \
      "$(rpm -qp --qf '%{SUMMARY}' "$f" 2>/dev/null)" "${RPM_PROJECT[$(basename "$f")]:-}" >> "$PKGLIST"
  else
    COMMON["$f"]=1                                # no dist tag: goes everywhere
  fi
done
RPM_RELEASES=$(find "$SITE/rpm" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -n | tr '\n' ' ')
[ -n "$RPM_RELEASES" ] || warn "no RPMs with an .elN/.fcN dist tag yet; RPM repo is empty"
for n in $RPM_RELEASES; do
  for f in "${!COMMON[@]}"; do cp "$f" "$SITE/rpm/$n/packages/"; done
  createrepo_c --quiet --general-compress-type=gz "$SITE/rpm/$n"
  "${GPG[@]}" --armor --detach-sign -o "$SITE/rpm/$n/repodata/repomd.xml.asc" "$SITE/rpm/$n/repodata/repomd.xml"
done
cp "$STAGE/$SETUP_RPM_NAME" "$SITE/rpm/$REPO_ID-release.rpm"

# ------------------------------------------------------- setup.sh + index.html
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
ROWS=$(sort -t$'\t' -k1,1 -k2,2V "$PKGLIST" | html_escape | awk -F'\t' '
  { if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 }
    ver[$1] = $2; desc[$1] = $4; if ($5 != "") proj[$1] = $5
    if (index(";" where[$1] ";", ";" $3 ";") == 0) where[$1] = where[$1] (where[$1] == "" ? "" : ";") $3 }
  END { for (i = 1; i <= n; i++) { k = order[i]; w = where[k]; gsub(";", "<br>", w)
        name = "<code>" k "</code>"
        if (k in proj) name = "<a href=\"https://github.com/" proj[k] "\">" name "</a>"
        printf "      <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", name, ver[k], w, desc[k] } }')
[ -n "$ROWS" ] || ROWS='      <tr><td colspan="4">No packages published yet.</td></tr>'

SUPPORTED=""
for suite in $SUITES; do SUPPORTED+="$(pretty_suite "$suite"), "; done
for n in $RPM_RELEASES; do
  if [ "$n" -lt 20 ]; then SUPPORTED+="EL $n, "; else SUPPORTED+="Fedora $n, "; fi
done
SUPPORTED=${SUPPORTED%, }

render() {
  local text
  text=$(<"$1")
  text=${text//@REPO_ID@/$REPO_ID}
  text=${text//@REPO_LABEL@/$REPO_LABEL}
  text=${text//@BASE_URL@/$BASE_URL}
  text=${text//@SUITES@/$SUITES}
  text=${text//@COMPONENT@/$COMPONENT}
  text=${text//@SUPPORTED@/$SUPPORTED}
  text=${text//@PACKAGE_ROWS@/$ROWS}
  printf '%s\n' "$text"
}
render "$ROOT/setup/setup.sh.in"   > "$SITE/setup.sh"
render "$ROOT/setup/index.html.in" > "$SITE/index.html"

echo "Built $SITE: $deb_count .deb and $rpm_count .rpm files (including setup packages)."
echo "APT suites: $SUITES   RPM releases: ${RPM_RELEASES:-none}"

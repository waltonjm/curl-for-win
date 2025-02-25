#!/bin/sh

# Copyright 2015-present Viktor Szakats. See LICENSE.md

# shellcheck disable=SC3040
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

# TODO:
#   - Enable Control Flow Guard (once FLOSS toolchains support it)
#      LLVM/CLANG: -ehcontguard (requires LLVM 13.0.0)
#   - LLVM
#      -mretpoline
#      -mspeculative-load-hardening / -mllvm -x86-speculative-load-hardening (high overhead)
#   - GCC -mindirect-branch -mfunction-return -mindirect-branch-register
#   - Add ARM64 builds? (once FLOSS toolchains support it)
#   - Drop x86 (Intel 32-bit) builds?
#   - Drop FTP support?
#   - Drop brotli support?
#   - Use Universal CRT?
#   - Switch to LibreSSL or rustls or Schannel?

# Tools:
#                compiler build
#                -------- -----------
#   zlib.sh      clang    cmake
#   brotli.sh    clang    cmake
#   libgsasl.sh  clang    autotools
#   libidn2.sh   clang    autotools
#   nghttp2.sh   clang    cmake
#   nghttp3.sh   clang    cmake
#   openssl.sh   clang    proprietary
#   ngtcp2.sh    gcc      autotools    TODO: move to cmake and clang (could not detect openssl, and even configure needs a manual patch)
#   libssh2.sh   clang    make         TODO: move to cmake
#   curl.sh      clang    make         TODO: move to cmake

cd "$(dirname "$0")"

LC_ALL=C
LC_MESSAGES=C
LANG=C
export GREP_OPTIONS=
export ZIPOPT=
export ZIP=

readonly _LOG='logurl.txt'
if [ -n "${APPVEYOR_ACCOUNT_NAME:-}" ]; then
  # https://www.appveyor.com/docs/environment-variables/
  _LOGURL="${APPVEYOR_URL}/project/${APPVEYOR_ACCOUNT_NAME}/${APPVEYOR_PROJECT_SLUG}/build/${APPVEYOR_BUILD_VERSION}/job/${APPVEYOR_JOB_ID}"
# _LOGURL="${APPVEYOR_URL}/api/buildjobs/${APPVEYOR_JOB_ID}/log"
elif [ -n "${GITHUB_RUN_ID:-}" ]; then
  # https://docs.github.com/actions/reference/environment-variables
  _LOGURL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
elif [ -n "${CI_JOB_ID:-}" ]; then
  # https://docs.gitlab.com/ce/ci/variables/index.html
  _LOGURL="${CI_SERVER_URL}/${CI_PROJECT_PATH}/-/jobs/${CI_JOB_ID}/raw"
else
  _LOGURL=''
fi
echo "${_LOGURL}" | tee "${_LOG}"

export _BRANCH="${APPVEYOR_REPO_BRANCH:-}${CI_COMMIT_REF_NAME:-}${GITHUB_REF:-}${GIT_BRANCH:-}"
[ -n "${_BRANCH}" ] || _BRANCH="$(git symbolic-ref --short --quiet HEAD)"
[ -n "${_BRANCH}" ] || _BRANCH='main'
export _URL=''
command -v git >/dev/null 2>&1 && _URL="$(git ls-remote --get-url | sed 's|.git$||')"
[ -n "${_URL}" ] || _URL="https://github.com/${APPVEYOR_REPO_NAME:-}${GITHUB_REPOSITORY:-}"

# Detect host OS
export _OS
case "$(uname)" in
  *_NT*)   _OS='win';;
  Linux*)  _OS='linux';;
  Darwin*) _OS='mac';;
  *BSD)    _OS='bsd';;
  *)       _OS='unrecognized';;
esac

# Form suffix for alternate builds
export _FLAV=''
if [ "${_BRANCH#*nano*}" != "${_BRANCH}" ]; then
  _FLAV='-nano'
elif [ "${_BRANCH#*micro*}" != "${_BRANCH}" ]; then
  _FLAV='-micro'
elif [ "${_BRANCH#*mini*}" != "${_BRANCH}" ]; then
  _FLAV='-mini'
fi

# For 'configure'-based builds.
# This is more or less guesswork and this warning remains:
#    `configure: WARNING: using cross tools not prefixed with host triplet`
# Even with `_CCPREFIX` provided.
if [ "${_OS}" != 'win' ]; then
  # https://clang.llvm.org/docs/CrossCompilation.html
  export _CROSS_HOST
  case "${_OS}" in
    win)   _CROSS_HOST='x86_64-pc-mingw32';;
    linux) _CROSS_HOST='x86_64-pc-linux';;  # x86_64-pc-linux-gnu
    mac)   _CROSS_HOST='x86_64-apple-darwin';;
    bsd)   _CROSS_HOST='x86_64-pc-bsd';;
  esac
fi

export PUBLISH_PROD_FROM
if [ "${APPVEYOR_REPO_PROVIDER:-}" = 'gitHub' ] || \
   [ -n "${GITHUB_RUN_ID:-}" ]; then
  PUBLISH_PROD_FROM='linux'
else
  PUBLISH_PROD_FROM=''
fi

export _BLD='build.txt'

rm -f ./*-*-mingw*.*
rm -f hashes.txt
rm -f "${_BLD}"

. ./_versions.sh

# Revision suffix used in package filenames
export _REV="${_REVN}"; [ -z "${_REV}" ] || _REV="_${_REV}"

# Download sources
./_dl.sh

# Decrypt package signing key
SIGN_PKG_KEY='sign-pkg.gpg.asc'
if [ -s "${SIGN_PKG_KEY}" ] && \
   [ -n "${SIGN_PKG_KEY_ID:-}" ] && \
   [ -n "${SIGN_PKG_GPG_PASS:+1}" ]; then
  gpg --batch --yes --no-tty --quiet \
    --pinentry-mode loopback --passphrase-fd 0 \
    --decrypt "${SIGN_PKG_KEY}" 2>/dev/null <<EOF | \
  gpg --batch --quiet --import
${SIGN_PKG_GPG_PASS}
EOF
fi

# decrypt code signing key
export SIGN_CODE_KEY; SIGN_CODE_KEY="$(realpath '.')/sign-code.p12"
if [ -s "${SIGN_CODE_KEY}.asc" ] && \
   [ -n "${SIGN_CODE_GPG_PASS:+1}" ]; then
  install -m 600 /dev/null "${SIGN_CODE_KEY}"
  gpg --batch --yes --no-tty --quiet \
    --pinentry-mode loopback --passphrase-fd 0 \
    --decrypt "${SIGN_CODE_KEY}.asc" 2>/dev/null >> "${SIGN_CODE_KEY}" <<EOF || true
${SIGN_CODE_GPG_PASS}
EOF
fi

if [ -s "${SIGN_CODE_KEY}" ]; then
  # build osslsigncode
  ./osslsigncode.sh "${OSSLSIGNCODE_VER_}"
  ls -l "$(dirname "$0")/osslsigncode-local"*
  "$(dirname "$0")/osslsigncode-local" --version
fi

if [ "${CC}" = 'mingw-clang' ]; then
  echo ".clang$("clang${_CCSUFFIX}" --version | grep -o -a -E ' [0-9]*\.[0-9]*[\.][0-9]*')" >> "${_BLD}"
fi

ver=''
case "${_OS}" in
  mac)
    ver="$(brew info --json=v2 --formula mingw-w64 | jq --raw-output '.formulae[] | select(.name == "mingw-w64") | .versions.stable')";;
  linux)
    [ -n "${ver}" ] || ver="$(dpkg   --status       mingw-w64-common)"
    [ -n "${ver}" ] || ver="$(rpm    --query        mingw64-crt)"
    [ -n "${ver}" ] || ver="$(pacman --query --info mingw-w64-crt)"
    [ -n "${ver}" ] && ver="$(printf '%s' "${ver}" | grep -a '^Version' | grep -a -m 1 -o -E '[0-9.-]+')"
    ;;
esac
[ -n "${ver}" ] && echo ".mingw-w64 ${ver}" >> "${_BLD}"

_ori_path="${PATH}"

build_single_target() {
  export _CPU="$1"

  export _TRIPLET=
  export _SYSROOT=
  export _CCPREFIX=
  export _MAKE='make'
  export _WINE=''

  export _OPTM=
  [ "${_CPU}" = 'x86' ] && _OPTM='-m32'
  [ "${_CPU}" = 'x64' ] && _OPTM='-m64'

  [ "${_CPU}" = 'x86' ]   && _machine='i686'
  [ "${_CPU}" = 'x64' ]   && _machine='x86_64'
  [ "${_CPU}" = 'arm64' ] && _machine="${_CPU}"

  export _PKGSUFFIX
  [ "${_CPU}" = 'x86' ] && _PKGSUFFIX="-win32-mingw"
  [ "${_CPU}" = 'x64' ] && _PKGSUFFIX="-win64-mingw"

  if [ "${_OS}" = 'win' ]; then
    export PATH
    [ "${_CPU}" = 'x86' ] && PATH="/mingw32/bin:${_ori_path}"
    [ "${_CPU}" = 'x64' ] && PATH="/mingw64/bin:${_ori_path}"
    export _MAKE='mingw32-make'

    # Install required component
    pip3 --version
    pip3 --disable-pip-version-check --no-cache-dir install --user pefile
  else
    if [ "${CC}" = 'mingw-clang' ] && [ "${_OS}" = 'mac' ]; then
      export PATH="/usr/local/opt/llvm/bin:${_ori_path}"
    fi
    _TRIPLET="${_machine}-w64-mingw32"
    # Prefixes do not work with MSYS2/mingw-w64, because `ar`, `nm` and
    # `runlib` are missing from them. They are accessible either _without_
    # one, or as prefix + `gcc-ar`, `gcc-nm`, `gcc-runlib`.
    _CCPREFIX="${_TRIPLET}-"
    # mingw-w64 sysroots
    if [ "${_OS}" = 'mac' ]; then
      _SYSROOT="/usr/local/opt/mingw-w64/toolchain-${_machine}"
    else
      _SYSROOT="/usr/${_TRIPLET}"
    fi
    if [ "${_OS}" = 'mac' ]; then
      if [ "${_CPU}" = 'x64' ] && \
         [ "$(uname -m)" = 'x86_64' ] && \
         [ "$(sysctl -i -n sysctl.proc_translated)" != '1' ]; then
        _WINE='wine64'
      else
        _WINE='echo'
      fi
    else
      _WINE='wine'
    fi
  fi

  export _CCVER
  if [ "${CC}" = 'mingw-clang' ]; then
    # We do not use old mingw toolchain versions when building with clang,
    # so this is safe:
    _CCVER='99'
  else
    _CCVER="$(printf '%02d' \
      "$("${_CCPREFIX}gcc" -dumpversion | grep -a -o -E '^[0-9]+')")"
  fi

  echo ".gcc-mingw-w64-${_machine} $("${_CCPREFIX}gcc" -dumpversion)" >> "${_BLD}"
  echo ".binutils-mingw-w64-${_machine} $("${_CCPREFIX}ar" V | grep -o -a -E '[0-9]+\.[0-9]+(\.[0-9]+)?')" >> "${_BLD}"

  time ./zlib.sh         "${ZLIB_VER_}"
  time ./brotli.sh     "${BROTLI_VER_}"
  time ./libgsasl.sh "${LIBGSASL_VER_}"
  time ./libidn2.sh   "${LIBIDN2_VER_}"
  time ./nghttp2.sh   "${NGHTTP2_VER_}"
  time ./nghttp3.sh   "${NGHTTP3_VER_}"
  time ./openssl.sh   "${OPENSSL_VER_}"
  time ./ngtcp2.sh     "${NGTCP2_VER_}"
  time ./libssh2.sh   "${LIBSSH2_VER_}"
  time ./curl.sh         "${CURL_VER_}"
}

# Build binaries
build_single_target x64
if [ "${_BRANCH#*x64only*}" = "${_BRANCH}" ]; then
# build_single_target arm64
  build_single_target x86
fi

case "${_OS}" in
  mac)   rm -f -P "${SIGN_CODE_KEY}";;
  linux) [ -w "${SIGN_CODE_KEY}" ] && srm "${SIGN_CODE_KEY}";;
esac
rm -f "${SIGN_CODE_KEY}"

# Upload/deploy binaries
. ./_ul.sh

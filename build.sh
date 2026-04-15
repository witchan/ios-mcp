#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${ROOT_DIR}/packages"
mkdir -p "$OUTPUT_DIR"

latest_package_after() {
  local stamp_file="$1"
  find "${ROOT_DIR}/packages" -maxdepth 1 -type f -name '*.deb' -newer "${stamp_file}" -print | sort | tail -n 1
}

choose_scheme() {
  while true; do
    print ""
    print "请选择构建方案:"
    print "  1) rootful"
    print "  2) rootless"
    print "  3) roothide"
    read 'choice?输入编号: '

    case "$choice" in
      1|rootful|ROOTFUL)
        BUILD_SCHEME=""
        BUILD_SCHEME_LABEL="rootful"
        return
        ;;
      2|rootless|ROOTLESS)
        BUILD_SCHEME="rootless"
        BUILD_SCHEME_LABEL="rootless"
        return
        ;;
      3|roothide|ROOTHIDE)
        BUILD_SCHEME="roothide"
        BUILD_SCHEME_LABEL="roothide"
        return
        ;;
      *)
        print "无效输入，请重新选择。"
        ;;
    esac
  done
}

choose_package_type() {
  while true; do
    print ""
    print "请选择包类型:"
    print "  1) 正式包"
    print "  2) 测试包"
    read 'choice?输入编号: '

    case "$choice" in
      1|release|final)
        BUILD_ARGS=(FINALPACKAGE=1 DEBUG=0 STRIP=1)
        BUILD_TYPE_LABEL="release"
        return
        ;;
      2|debug|test)
        BUILD_ARGS=(DEBUG=1 STRIP=0)
        BUILD_TYPE_LABEL="debug"
        return
        ;;
      *)
        print "无效输入，请重新选择。"
        ;;
    esac
  done
}

build_subprojects() {
  print ""
  print "==> 编译子项目..."
  local scheme_env=()
  if [[ -n "$BUILD_SCHEME" ]]; then
    scheme_env=(THEOS_PACKAGE_SCHEME="$BUILD_SCHEME")
  fi
  (cd AppSync && make "${scheme_env[@]}" clean && make "${scheme_env[@]}")
  (cd AppSync/appinst && make "${scheme_env[@]}" clean && make "${scheme_env[@]}")
  (cd mcp-roothelper && make "${scheme_env[@]}" clean && make "${scheme_env[@]}")
  (cd mcp-ldid && make "${scheme_env[@]}" clean && make "${scheme_env[@]}")
  (cd mcp-root && make "${scheme_env[@]}" clean && make "${scheme_env[@]}")
}

build_selected_package() {
  local stamp_file deb
  stamp_file="$(mktemp)"
  touch "$stamp_file"

  print ""
  print "==> 开始构建: ${BUILD_SCHEME_LABEL} / ${BUILD_TYPE_LABEL}"
  make clean >/dev/null
  build_subprojects
  if [[ "$BUILD_TYPE_LABEL" == "debug" ]]; then
    mkdir -p .theos/obj/debug/arm64 .theos/obj/debug/arm64e
  fi
  if [[ -n "$BUILD_SCHEME" ]]; then
    make "${BUILD_ARGS[@]}" THEOS_PACKAGE_SCHEME="$BUILD_SCHEME" package
  else
    env -u THEOS_PACKAGE_SCHEME make "${BUILD_ARGS[@]}" package
  fi

  deb="$(latest_package_after "$stamp_file")"
  rm -f "$stamp_file"

  if [[ -z "$deb" ]]; then
    print -u2 "未在 ${ROOT_DIR}/packages 中找到本次构建产物。"
    exit 1
  fi

  print ""
  print "构建完成:"
  print "  ${deb}"
}

choose_scheme
choose_package_type
build_selected_package

#!/bin/sh

if [ -n "${STAGING_DIR_HOST:-}" ] && [ -x "$STAGING_DIR_HOST/bin/g++" ]; then
	HOSTCXX="$STAGING_DIR_HOST/bin/g++"
elif HOSTCXX=$(command -v g++ 2>/dev/null); then
	:
elif HOSTCXX=$(command -v c++ 2>/dev/null); then
	:
else
	echo n
	exit 0
fi

cat << EOF | "$HOSTCXX" -c -x c++ -o /dev/null - >/dev/null 2>&1
#if __clang__
  #if __clang_major__ < $3
    #error "clang too old"
  #endif
#else
  #if __GNUC__ < $1 || (__GNUC__ == $1 && (__GNUC_MINOR__ < $2))
    #error "gcc too old"
  #endif
#endif
EOF
[ $? -eq 0 ] && echo y || echo n

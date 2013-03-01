#! /usr/bin/env sh
#
# Copyright (c) 2013 Antti Kantee <pooka@iki.fi>
#
# Permission to use, copy, modify, and/or distribute this software for
# any purpose with or without fee is hereby granted, provided that the
# above copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

#
# This script will build rump kernel components and the hypervisor
# on a non-NetBSD host and hopefully leave you with a usable installation.
# This is a slightly preliminary version.
#

# defaults
OBJDIR=./obj
DESTDIR=./rump
SRCDIR=.
JNUM=4

# NetBSD source version requirement
NBSRC_DATE=20130301
NBSRC_SUB=0


#
# support routines
#

# the parrot routine
die ()
{

	echo '>> ERROR:' >&2
	echo ">> $*" >&2
	exit 1
}

helpme ()
{

	exec 1>&2
	echo "Usage: $0 [-h] [-d destdir] [-o objdir] [-s srcdir] [-j num]"
	printf "\t-d: location for headers/libs.  default: PWD/rump\n"
	printf "\t-o: location for build-time files.  default: PWD/obj\n"
	printf "\t-T: location for tools+rumpmake.  default: PWD/obj/tooldir\n"
	printf "\t-s: location of source tree.  default: PWD\n"
	printf "\n"
	printf "\t-j: value of -j specified to make.  default: ${JNUM}\n"
	printf "\t-q: quiet build, less compiler output.  default: noisy\n"
	printf "\t-r: release build (no -g, DIAGNOSTIC, etc.).  default: no\n"
	printf "\t-D: increase debugginess.  default: ok 99%% of the time\n"
	exit 1
}

#
# toolchain creation helper routines
#

appendmkconf ()
{
	[ ! -z "${1}" ] && echo "${2}${3}=${1}" >> "${BRTOOLDIR}/mk.conf"
}

#
# Not all platforms have  the same set of crt files.  for some
# reason unbeknownst to me, if the file does not exist,
# at least gcc --print-file-name just echoes the input parameter.
# Try to detect this and tell the NetBSD makefiles that the crtfile
# in question should be left empty.
chkcrt ()
{
	tst=`cc --print-file-name=${1}.o`
	up=`echo ${1} | tr [a-z] [A-Z]`
	[ -z "${tst%${1}.o}" ] && echo "_GCC_CRT${up}=" >>"${BRTOOLDIR}/mk.conf"
}

#
# Create tools and wrappers.  This can be skipped with -P.
# Giving -P implies you know what you're doing.  It's useful for
# 1) iteration speed on a slow-ish host
# 2) making manual modification to the tools for testing and avoiding
#    the script nuke them on the next iteration
#
# external toolchain links are created in the format that
# build.sh expects.
#
# TODO?: don't hardcore this based on PATH
# TODO2: cpp missing
maketools ()
{
	local TOOLS='ar as ld nm objcopy objdump ranlib size strip'
	local CC

	# XXX: why can't all cc's that are gcc actually tell me
	#      that they're gcc with cc --version?!?
	if cc --version | grep -q 'Free Software Foundation'; then
		CC=gcc
	elif cc --version | grep -q clang; then
		CC=clang
		LLVM='-V HAVE_LLVM=1'
	else
		die Unsupported cc "(`which cc`)"
	fi

	#
	# Check for GNU ld (as invoked by cc, since that's how the
	# NetBSD Makefiles invoke it)
	if ! cc -Wl,--version 2>&1 | grep -q 'GNU ld' ; then
		die "GNU ld required (by NetBSD Makefiles)"
	fi

	#
	# Perform some toolchain feature tests to determine what options
	# we need to use for building.
	#

	cd ${OBJDIR}
	#
	# Try to test if cc supports -Wno-unused-but-set-variable.
	# This is a bit tricky since apparently gcc doesn't tell it
	# doesn't support it unless there is some other error to complain
	# about as well.  So we try compiling a broken source file...
	echo 'no you_shall_not_compile' > broken.c
	${CC} -Wno-unused-but-set-variable broken.c > broken.out 2>&1
	if ! grep -q Wno-unused-but-set-variable broken.out ; then
		W_UNUSED_BUT_SET=-Wno-unused-but-set-variable
	fi
	rm -f broken.c broken.out

	#
	# Check if the linker supports all the features of the rump kernel
	# component ldscript used for linking shared libraries.
	# If not, build only static rump kernel components.
	echo 'SECTIONS { } INSERT AFTER .data' > ldscript.test
	echo 'int main(void) {return 0;}' > test.c
	if ! cc test.c -Wl,-T ldscript.test; then
		HASPIC='-V NOPIC=1'
	fi
	rm -f test.c a.out ldscript.test

	#
	# Create external toolchain wrappers.
	mkdir -p ${BRTOOLDIR}/bin || die "cannot create ${BRTOOLDIR}/bin"
	for x in ${CC} ${TOOLS}; do
		# ok, it's not really --netbsd, but let's make-believe!
		tname=${BRTOOLDIR}/bin/${mach_arch}--netbsd${toolabi}-${x}
		[ -f ${tname} ] && continue

		printf '#!/bin/sh\nexec %s $*\n' ${x} > ${tname}
		chmod 755 ${tname}
	done

	cat > "${BRTOOLDIR}/mk.conf" << EOF
NOGCCERROR=1
BUILDRUMP_CPPFLAGS=-I${DESTDIR}/include
CPPFLAGS+=\${BUILDRUMP_CPPFLAGS}
LIBDO.pthread=_external
RUMPKERN_UNDEF=${RUMPKERN_UNDEF}
INSTPRIV=-U
CFLAGS+=\${BUILDRUMP_CFLAGS}
AFLAGS+=\${BUILDRUMP_AFLAGS}
EOF

	appendmkconf "${W_UNUSED_BUT_SET}" "CFLAGS" +
	appendmkconf "${EXTRA_LDFLAGS}" "LDFLAGS" +
	appendmkconf "${EXTRA_CFLAGS}" "BUILDRUMP_CFLAGS"
	appendmkconf "${EXTRA_AFLAGS}" "BUILDRUMP_AFLAGS"
	appendmkconf "${RUMP_DIAGNOSTIC}" "RUMP_DIAGNOSTIC"
	appendmkconf "${RUMP_DEBUG}" "RUMP_DEBUG"
	appendmkconf "${RUMP_LOCKDEBUG}" "RUMP_LOCKDEBUG"
	appendmkconf "${DBG}" "DBG"

	chkcrt begins
	chkcrt ends
	chkcrt i
	chkcrt n

	# Run build.sh.  Use some defaults.
	# The html pages would be nice, but result in too many broken
	# links, since they assume the whole NetBSD man page set to be present.
	cd ${SRCDIR}
	${binsh} build.sh -m ${machine} -u \
	    -D ${OBJDIR}/dest -w ${RUMPMAKE} \
	    -T ${BRTOOLDIR} -j ${JNUM} ${LLVM} ${BEQUIET} ${HASPIC} \
	    -V EXTERNAL_TOOLCHAIN=${BRTOOLDIR} -V TOOLCHAIN_MISSING=yes \
	    -V TOOLS_BUILDRUMP=yes \
	    -V MKGROFF=no \
	    -V MKARZERO=no \
	    -V NOPROFILE=1 \
	    -V NOLINT=1 \
	    -V USE_SSP=no \
	    -V MKHTML=no -V MKCATPAGES=yes \
	    -V SHLIBINSTALLDIR=/usr/lib \
	    -V TOPRUMP="${SRCDIR}/sys/rump" \
	    -V MAKECONF="${BRTOOLDIR}/mk.conf" \
	    -V MAKEOBJDIR="\${.CURDIR:C,^(${SRCDIR}|${BRDIR}),${OBJDIR},}" \
	  tools
	[ $? -ne 0 ] && die build.sh tools failed
}


#
# BEGIN SCRIPT
#

DBG='-O2 -g'
ANYHOSTISGOOD=false
NOISE=2
debugginess=0
BRDIR=$(dirname $0)

while getopts 'd:DhHj:o:qrs:T:' opt; do
	case "$opt" in
	j)
		JNUM=${OPTARG}
		;;
	d)
		DESTDIR=${OPTARG}
		;;
	D)
		[ ! -z "${RUMP_DIAGNOSTIC}" ]&& die Cannot specify releasy debug

		debugginess=$((debugginess+1))
		[ ${debugginess} -gt 0 ] && DBG='-O0 -g'
		[ ${debugginess} -gt 1 ] && RUMP_DEBUG=1
		[ ${debugginess} -gt 2 ] && RUMP_LOCKDEBUG=1
		;;
	H)
		ANYHOSTISGOOD=true
		;;
	q)
		# build.sh handles value going negative
		NOISE=$((NOISE-1))
		;;
	o)
		OBJDIR=${OPTARG}
		;;
	r)
		[ ${debugginess} -gt 0 ] && die Cannot specify debbuggy release
		RUMP_DIAGNOSTIC=no
		DBG=''
		;;
	s)
		SRCDIR=${OPTARG}
		;;
	T)
		BRTOOLDIR=${OPTARG}
		;;
	-)
		break
		;;
	h|\?)
		helpme
		;;
	esac
done
shift $((${OPTIND} - 1))
BEQUIET="-N${NOISE}"
[ -z "${BRTOOLDIR}" ] && BRTOOLDIR=${OBJDIR}/tooldir

#
# Determine what which parts we should execute.  Default: all
#
allcmds="tools build install tests"

if [ $# -eq 0 ]; then
	for cmd in ${allcmds}; do
		eval do${cmd}=true
	done
else
	for cmd in ${allcmds}; do
		eval do${cmd}=false
	done

	for arg in $*; do
		while true ; do
			for cmd in ${allcmds}; do
				if [ "${arg}" = "${cmd}" ]; then
					eval do${cmd}=true
					break 2
				fi
			done
			die "Invalid arg $arg"
		done
	done
fi

[ ! -f "${SRCDIR}/build.sh" ] && \
    die \"${SRCDIR}\" is not a NetBSD source tree.  try -h

mkdir -p ${OBJDIR} || die cannot create ${OBJDIR}
mkdir -p ${DESTDIR} || die cannot create ${DESTDIR}
mkdir -p ${BRTOOLDIR} || die "cannot create ${BRTOOLDIR} (tooldir)"

abspath ()
{

	local curdir=`pwd -P`
	eval cd \${${1}}
	eval ${1}=`pwd -P`
	cd ${curdir}
}

# resolve critical directories
abspath DESTDIR
abspath OBJDIR
abspath SRCDIR
abspath BRTOOLDIR
abspath BRDIR

# source test routines, to be run after build
. ${BRDIR}/tests/testrump.sh

# check if NetBSD src is new enough
oIFS="${IFS}"
IFS=':'
exec 3>&2 2>/dev/null
ver="`sed -n 's/^BUILDRUMP=//p' < ${SRCDIR}/sys/rump/VERSION`"
exec 2>&3 3>&-
set ${ver} 0
[ "1${1}" -lt "1${NBSRC_DATE}" \
  -o \( "1${1}" -eq "1${NBSRC_DATE}" -a "1${2}" -lt "1${NBSRC_SUB}" \) ] \
    && die "Update of NetBSD source tree to ${NBSRC_DATE}:${NBSRC_SUB} required"
IFS="${oIFS}"

hostos=`uname -s`
binsh=sh
case ${hostos} in
"DragonFly")
	RUMPKERN_UNDEF='-U__DragonFly__'
	;;
"FreeBSD")
	RUMPKERN_UNDEF='-U__FreeBSD__'
	;;
"Linux")
	RUMPKERN_UNDEF='-Ulinux -U__linux -U__linux__ -U__gnu_linux__'
	EXTRA_RUMPUSER='-ldl'
	EXTRA_RUMPCLIENT='-lpthread -ldl'
	;;
"NetBSD")
	# what do you expect? ;)
	;;
"SunOS")
	RUMPKERN_UNDEF='-U__sun__ -U__sun -Usun'
	EXTRA_RUMPUSER='-lsocket -lrt -ldl'
	EXTRA_RUMPCLIENT='-lsocket -ldl'
	binsh=/usr/xpg4/bin/sh

	# do some random test to check for gnu foolchain
	if ! ar --version 2>/dev/null | grep -q 'GNU ar' ; then
		die Need GNU toolchain in PATH, `which ar` is not
	fi
	;;
"CYGWIN_NT"*)
	HASPIC='-V NOPIC=1'
	host_notsupp='yes'
	;;
*)
	host_notsupp='yes'
	;;
esac

if [ "${host_notsupp}" = 'yes' ]; then
	${ANYHOSTISGOOD} || die unsupported host OS: ${hostos}
fi

mach_arch=`uname -m`
case ${mach_arch} in
"amd64")
	machine="amd64"
	mach_arch="x86_64"
	;;
"x86_64")
	machine="amd64"
	;;
"armv6l")
	machine="evbarm"
	mach_arch="arm"
	toolabi="elf"
	# XXX: assume at least armv6k due to armv6 inaccuracy in NetBSD
	EXTRA_CFLAGS='-march=armv6k'
	EXTRA_AFLAGS='-march=armv6k'
	;;
"i386"|"i686")
	machine="i386"
	mach_arch="i486"
	toolabi="elf"
	;;
"sun4v")
	machine="sparc64"
	mach_arch="sparc64"
	# assume gcc.  i'm not going to start trying to
	# remember what the magic incantation for sunpro was
	EXTRA_CFLAGS='-m64'
	EXTRA_LDFLAGS='-m64'
	EXTRA_AFLAGS='-m64'
	;;
esac
[ -z "${machine}" ] && die script does not know machine \"${mach_arch}\"

RUMPMAKE="${BRTOOLDIR}/rumpmake"
${dotools} && maketools

# this helper makes sure we get some output with the
# NetBSD noisybuild stuff (-q to this script)
makedirtarget ()
{

	printf 'iwantitall:\n\t@${MAKEDIRTARGET} %s %s\n' $1 $2 | \
	    ${RUMPMAKE} -f ${SRCDIR}/share/mk/bsd.own.mk -f - -j ${JNUM} \
	      iwantitall
	[ $? -eq 0 ] || die "makedirtarget $1 $2"
}

setupdest ()
{

	# set up $dest via symlinks.  this is easier than trying to teach
	# the NetBSD build system that we're not interested in an extra
	# level of "usr"
	mkdir -p ${DESTDIR}/include/rump || die create ${DESTDIR}/include/rump
	mkdir -p ${DESTDIR}/lib || die create ${DESTDIR}/lib
	mkdir -p ${DESTDIR}/man || die create ${DESTDIR}/man
	mkdir -p ${OBJDIR}/dest/usr/share/man \
	    || die create ${OBJDIR}/dest/usr/share/man
	ln -sf ${DESTDIR}/include ${OBJDIR}/dest/usr/include
	ln -sf ${DESTDIR}/lib ${OBJDIR}/dest/usr/lib
	for man in cat man ; do 
		for x in 1 2 3 4 5 6 7 8 9 ; do
			ln -sf ${DESTDIR}/man \
			    ${OBJDIR}/dest/usr/share/man/${man}${x}
		done
	done
}

#
# Now it's time to build.  This takes 4 passes, just like when
# building NetBSD the regular way.  The passes are:
# 1) obj
# 2) includes
# 3) dependall
# 4) install
#

${dobuild} && targets="obj includes dependall"
${doinstall} && setupdest
${doinstall} && targets="${targets} install"

ALLDIRS="lib/librumpuser lib/librumpclient
    lib/librump lib/librumpdev lib/librumpnet lib/librumpvfs
    sys/rump/dev sys/rump/fs sys/rump/kern sys/rump/net sys/rump/include
    ${BRDIR}/brlib"
[ "`uname`" = "Linux" ] && ALLDIRS="${ALLDIRS} sys/rump/kern/lib/libsys_linux"

cd ${SRCDIR}
for target in ${targets}; do
	for dir in ${ALLDIRS}; do
		makedirtarget ${dir} ${target}
	done
done

# run tests from testrump.sh we sourced earlier
${dotests} && alltests

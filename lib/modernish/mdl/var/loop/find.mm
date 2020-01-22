#! /module/for/moderni/sh
\command unalias _loop_find_setIter _loop_find_translateDepth _loopgen_find 2>/dev/null

# modernish var/loop/find
#
# This powerful iteration generator turns the POSIX 'find' command into a shell
# loop, safely integrating both 'find' and 'xargs' functionality into the shell.
#
# Usage:
#
# LOOP find [ <options> ] <varname> in <path> ... [ <find-expression> ]; DO
#	<commands>
# DONE
#
# LOOP find [ <options> ] --xargs in <path> ... [ <find-expression> ]; DO
#	<commands>
# DONE
#
# The <find-expression> is passed on to your local 'find' command. One new
# primary is added: -iterate, which causes the shell to iterate through the
# loop based on the results of the <find-expression>. This -iterate primary
# is appended if not present (instead of -print in conventional 'find' usage).
# The -iterate primary can also be explicitly used any number of times in the
# expression just like -print.
#
# Using '--xargs' instead of a variable name supplies simple xargs-like
# functionality. Instead of one iteration per found item, as many items as
# possible per iteration are stored into the positional parameters (PPs), so
# the shell can access them in the usual way using "$@" and such. Note that the
# --xargs option therefore overwrites the current PPs.
#    On shells with KSHARRAY, another form '--xargs=VARNAME' is supported,
# which stores the results in the array named VARNAME instead.
#    Modernish clears the PPs or the array upon completion of the loop, but if
# the loop exits before completion (e.g. 'break'), the last chunk of positional
# parameters or array elements will survive the loop.
#
# '--split', '--glob' and '--fglob' options are available as in 'LOOP for'.
# Using these options with pathname expansion globally active is a fatal error.
# These operations apply to the <path> arguments only, and NOT to any
# patterns in the <find-expression>.
#
# A number of popular GNU and BSD 'find' expression operands are translated
# to portable equivalents. See the code (step 4) for details.
# Portable scripts should otherwise only use options and primaries supported
# by POSIX, so ignore your local 'man find' page and consult this instead:
# http://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#
# --- begin license ---
# Copyright (c) 2019 Martijn Dekker <martijn@inlv.org>, Groningen, Netherlands
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
# --- end license ---

# -----

use var/loop

# Initialisation

# ... If a directory, name or path to a 'find' utility to prefer was given, sanitise it.
unset -v _loop_2
if let "$# == 2"; then
	if is -L dir "$2" && not str end "$2" '/'; then
		set -- "$1" "$2/"
		_loop_2=found
	elif can exec "$2" || { _loop_2=$(use sys/cmd/extern; extern -v -- "$2") && set -- "$1" "${_loop_2}"; }; then
		_loop_2=found
	fi
	if not str empty "${_loop_2-}" && _loop_2=$(chdir -f -- "${2%/*}" && putln "$PWD/${2##*/}X"); then
		set -- "$1" "${_loop_2%X}"
		unset -v _loop_2
	else
		_loop_2="$1: warning: preferred utility name or path '$2' not found"  # delay warning
		set -- "$1"
	fi
elif let "$# > 2"; then
	putln "$1: excess arguments"
	return 1
fi

# ... Find a POSIX-compliant 'find', one with '-path' and '{} +'.
#     http://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#     This *should* be the default 'find' on all systems in 2019, but:
#	- Solaris <= 11.3 'find' doesn't have -path
#	- Busybox <= 1.30.0 'find' doesn't combine '{} +' with parentheses
#	- Busybox 1.22.x 'find' treats '{} +' as equivalent to '{} \;' !!!
#     All that is blocked below.
push IFS -f; IFS=; set -f
unset -v _loop_find_myUtil
_loop_dirdone=:
IFS=':'; for _loop_dir in ${2:+${2%/*}} $DEFPATH $PATH; do IFS=
	str begin ${_loop_dir} '/' || continue
	str in ${_loop_dirdone} :${_loop_dir}: && continue
	for _loop_util in ${2:+${2##*/}} find bsdfind gfind gnufind sfind; do
		if can exec ${_loop_dir}/${_loop_util} \
		&& _loop_err=$(set +x
			PATH=$DEFPATH POSIXLY_CORRECT=y exec 2>&1 ${_loop_dir}/${_loop_util} /dev/null /dev/null \
			\( -exec $MSH_SHELL -c 'echo "$@"' $ME {} + \) -o \( -path /dev/null -depth -xdev \) -print) \
		&& str eq ${_loop_err} "/dev/null /dev/null"
		then
			_loop_find_myUtil=${_loop_dir}/${_loop_util}
			break 2
		fi
	done
	_loop_dirdone=${_loop_dirdone}${_loop_dir}:
done
unset -v _loop_dirdone _loop_dir _loop_util _loop_err
pop IFS -f
if isset _loop_2; then	# display delayed warning with current result
	putln "${_loop_2}${_loop_find_myUtil:+; using '${_loop_find_myUtil}'}"
	unset -v _loop_2
elif let "$# == 2"; then
	if is -L dir "$2"; then
		if not is -L samefile "$2" "${_loop_find_myUtil%/*}"; then
			putln "$1: warning: no compliant utility found in '$2'${_loop_find_myUtil:+; using '${_loop_find_myUtil}'}"
		fi
	elif not is -L samefile "$2" "${_loop_find_myUtil}"; then
		putln "$1: warning: '$2' was found non-compliant${_loop_find_myUtil:+; using '${_loop_find_myUtil}'}"
	fi
fi
if not isset _loop_find_myUtil; then
	putln "$1: fatal: cannot find a POSIX-compliant 'find' utility"
	return 1
fi
shellquote _loop_find_myUtil	# because it will be eval'ed
readonly _loop_find_myUtil

# ... Make sure the KSHARRAY feature test result is cached for _loopgen_find().

thisshellhas KSHARRAY

# -----

# The loop parser and iteration generator function.
#
# REMINDER: loop generators are always launched in 'safe mode', with no global split or glob. Settings
# are "IFS=''; set -fCu". So, variable expansions here usually don't need to be quoted.
#    The same does *NOT* apply to commands output >&8 by loop generators for evaluation in the main shell!
# Any program may use these, so they need to work for any value of these settings. Quote everything.
#
# NOTE: --split/--glob/--fglob options (as in 'LOOP for') subject the pathname arguments
# to field splitting and pathname expansion, but *not* any patterns in the expression.

_loopgen_find() {
	export POSIXLY_CORRECT=y _loop_PATH=$DEFPATH _loop_AUX=$MSH_AUX/var/loop
	_loop_status=0  # default exit status

	# 1. Parse options.
	_loop_find=${_loop_find_myUtil}
	unset -v _loop_xargs _loop_V _loop_glob _loop_split
	while str begin ${1-} '-'; do
		case $1 in
		( --xargs )
			export _loop_xargs= ;;
		( --xargs=* )
			thisshellhas KSHARRAY || _loop_die "--xargs=<array> requires a shell with KSHARRAY"
			export _loop_xargs=${1#--xargs=}
			_loop_checkvarname ${_loop_xargs} ;;
		( --split )
			_loop_split= ;;
		( --split= )
			unset -v _loop_split ;;
		( --split=* )
			_loop_split=${1#--split=} ;;
		( --glob )
			_loop_glob= ;;
		( --fglob )
			_loop_glob=f ;;
		( -- )	shift; break ;;
		# Nonstandard options requiring arguments (BSD find '-f') and multi-letter options cannot
		# be supported, as we don't have knowledge of the local 'find' implementation's options.
		( -f )	_loop_die "invalid option: $1" ;;
		(-??*)	break ;;
		# Other non-combined single-letter option: pass it on to the 'find' utility.
		( * )	shellquote _loop_opt=$1
			_loop_find="${_loop_find} ${_loop_opt}" ;;
		esac
		shift
	done
	if isset _loop_split || isset _loop_glob; then
		put >&8 'if ! isset -f || ! isset IFS || ! str empty "$IFS"; then' \
				"die 'LOOP find:" \
					"${_loop_split+--split }${_loop_glob+--${_loop_glob}glob }without safe mode';" \
			'fi; ' \
		|| die "LOOP find: internal error: cannot write safe mode check"
	fi

	# 2. Parse variable name.
	if not isset _loop_xargs; then
		let $# || _loop_die "variable name or --xargs expected"
		_loop_checkvarname $1
		export _loop_V=$1
		shift
	fi

	# 3. Parse 'in' and path names.
	#    Apply split and glob/fglob if requested.
	case $# in
	( 0 )	set -- . ;;
	( * )	case $1 in
		( -* | \( | ! )
			set -- . "$@" ;;  # Start of expression: default to '.' as path
		( in )	shift ;;
		( * )	_loop_die "'in PATH ...' or expression expected" ;;
		esac ;;
	esac
	unset -v _loop_paths
	while let $# && not str begin $1 '-' && not str eq $1 '(' && not str eq $1 '!'; do
		not isset _loop_paths && _loop_paths=
		unset -v _loop_A
		case ${_loop_glob+s} in
		( s )	set +f ;;
		esac
		case ${_loop_split+s},${_loop_split-} in
		( s, )	_loop_reallyunsetIFS ;;  # default split
		( s,* )	IFS=${_loop_split} ;;
		esac
		for _loop_A in $1; do IFS=''; set -f
			if not is present ${_loop_A}; then
				str empty ${_loop_A} && _loop_die "empty path"
				case ${_loop_glob-NO} in
				( '' )	shellquote -f _loop_A
					putln "LOOP find: warning: no such path: ${_loop_A}" >&2
					_loop_status=103
					continue ;;
				( f )	shellquote -f _loop_A
					_loop_die "no such path: ${_loop_A}" ;;
				esac
			fi
			case ${_loop_glob+G},${_loop_A} in
			( G,-* | G,+* | G,\( | G,! )
				# Avoid accidental parsing as option/operand in various commands.
				_loop_A=./${_loop_A} ;;
			esac
			case ${_loop_split+S},${_loop_A} in
			( S,-* | S,\( | S,! )
				# With split and no glob, die if a split path would be parsed as a primary.
				# Allowing the above glob workaround for split only would make --split
				# inconsistent with --split in the var/loop/for and var/local modules.
				shellquote -f _loop_A
				_loop_die "split path ${_loop_A} begins with '-' or is '(' or '!'; prepend './'" ;;
			esac
			shellquote _loop_A
			_loop_paths=${_loop_paths}${_loop_paths:+ }${_loop_A}
		done
		isset _loop_A || _loop_die "empty path"
		shift
	done
	if not isset _loop_paths; then
		_loop_die "at least one path required after 'in'"
	fi
	#    If no patterns match, we could exit here. But we want to make sure to
	#    die() on syntax error first, so the exit is delayed until step 6 below.

	# 4. Parse, translate and validate primaries.
	#    The 'find' utility exits with the same status 1 on *any* issue, leaving us with no way
	#    to distinguish between a minor warning and something fatal like a syntax error. This is
	#    unacceptable in the modernish design philosophy; we *must* die on bad syntax. Since 'find'
	#    utilities differ in what they accept, we must invoke a separate 'find' to validate primaries.
	_loop_find_setIter
	unset -v _loop_have_iter _loop_mindepth _loop_maxdepth
	_loop_prims=
	while let $#; do
		case $1 in
		# Translate modernish primaries
		( -iterate )
			_loop_prims="${_loop_prims} ${_loop_iter}"
			_loop_have_iter=y ;;
		( -ask )
			_loop_find_setIter -i
			case ${2-'-none'} in
			( -* | \( | ! )
				_loop_Q='"{}"?' ;;
			( * )	_loop_Q=$2; shift ;;
			esac
			shellquote _loop_Q
			_loop_prims=${_loop_prims}' -exec $MSH_SHELL $MSH_AUX/var/loop/find-ask.sh '${_loop_Q}' {} \;' ;;
		# Translate some commonly used GNU & BSD operators to portable POSIX equivalents
		( -or )
			_loop_prims="${_loop_prims} -o" ;;
		( -and )
			_loop_prims="${_loop_prims} -a" ;;
		( -not )
			_loop_prims="${_loop_prims} !" ;;
		# ... by definition, any findable file has at least one link, so this should work:
		( -true )
			_loop_prims="${_loop_prims} -links +0" ;;
		( -false )
			_loop_prims="${_loop_prims} -links 0" ;;
		# ... defer these, as they are options that always apply to the entire expression:
		( -mindepth | -maxdepth )
			str isint "${2-}" && let "(_loop_${1#-} = $2) >= 0" \
			|| _loop_die "$1: ${2+'$2': }non-negative integer required"
			case ${_loop_prims} in
			( *\ -[oa] | *' !' | *' \(' )  # avoid syntax error: add "-true"
				_loop_prims="${_loop_prims} -links +0" ;;
			esac
			shift ;;
		( -depth )
			if str isint "${2-}"; then
				# ... BSD-style '-depth n' is a real primary, not a global option
				case $2 in
				( -* )	# e.g. -depth -5 == max depth 4 == ! -path ORIGPATH/*/*/*/*/*
					_loop_find_translateDepth $(( -($2) ))
					_loop_prims="${_loop_prims} ! $REPLY" ;;
				( +* )	# e.g. -depth +2 == min depth 3 == -path ORIGPATH/*/*/*
					_loop_find_translateDepth $(( ($2) + 1 ))
					_loop_prims="${_loop_prims} $REPLY" ;;
				( * )	# -depth n == min depth n, max depth n
					_loop_find_translateDepth $(( $2 ))
					_loop_prims="${_loop_prims} $REPLY"
					_loop_find_translateDepth $(( $2 + 1 ))
					_loop_prims="${_loop_prims} ! $REPLY" ;;
				esac
				shift
			else
				# POSIX '-depth'
				_loop_prims="${_loop_prims} $1"
			fi ;;
		# Pass through arbitrary -exec*/-ok* arguments to avoid translating them.
		( -exec | -execdir | -ok | -okdir )
			str begin $1 -ok && _loop_find_setIter -i
			_loop_prims="${_loop_prims} $1"
			while let "$# > 1"; do
				shift
				shellquote _loop_A=$1
				_loop_prims="${_loop_prims} ${_loop_A}"
				if str eq $1 ';' || str eq "$1 ${2-}" '{} +'; then
					break
				fi
			done ;;
		# Pass through POSIX standard prims that require an argument.
		( -name | -path | -perm | -type | -links | -user | -group | -size | -[acm]time | -newer )
			_loop_prims="${_loop_prims} $1"
			let "$# > 1" && shift && shellquote _loop_A=$1 && _loop_prims="${_loop_prims} ${_loop_A}" ;;
		# Pass through POSIX standard ops/prims with no argument.
		( -o | -a | -nouser | -nogroup | -xdev | -prune | -print )
			_loop_prims="${_loop_prims} $1" ;;
		# Pass through a non-standard primary. Determine if it needs arguments in order to avoid translating them.
		( -* )	unset -v _loop_2 _loop_3
			if shellquote _loop_1=$1 \
			&& _loop_err=$(set +x; eval "exec ${_loop_find} /dev/null -prune -o -print ${_loop_1}" 2>&1)
			then	# OK without argument
				_loop_prims="${_loop_prims} ${_loop_1}"
			elif let "$# > 1" && shellquote _loop_2=$2 \
			&& _loop_err=$(set +x; eval "exec ${_loop_find} /dev/null -prune -o -print ${_loop_1} ${_loop_2}" 2>&1)
			then	# OK with one argument
				_loop_prims="${_loop_prims} ${_loop_1} ${_loop_2}"
				shift
			elif let "$# > 2" && shellquote _loop_3=$3 \
			&& _loop_err=$(set +x; eval "exec ${_loop_find} \
							/dev/null -prune -o -print ${_loop_1} ${_loop_2} ${_loop_3}" 2>&1)
			then	# OK with two arguments (e.g. -fprintf)
				_loop_prims="${_loop_prims} ${_loop_1} ${_loop_2} ${_loop_3}"
				shift 2
			elif str empty ${_loop_err}; then
				_loop_die "unknown error from ${_loop_find_myUtil} on primary ${_loop_1}"
			else
				_loop_die ${_loop_err#*find: }
			fi ;;
		# Everything else is passed on as is
		( * )	shellquote _loop_A=$1
			_loop_prims="${_loop_prims} ${_loop_A}" ;;
		esac
		shift
	done
	if not str empty ${_loop_prims}; then
		# Validate the entire expression.
		_loop_err=$(set +x; eval "exec ${_loop_find} /dev/null -prune -o -print ${_loop_prims}" 2>&1) \
		|| if str empty ${_loop_err}; then
			_loop_die "unknown error from ${_loop_find_myUtil} upon validation"
		else
			_loop_die ${_loop_err#*find: }
		fi
		# Parenthesise it to make sure it gets treated as a unit.
		_loop_prims="\\( ${_loop_prims} \\)"
	fi
	if not isset _loop_have_iter; then
		# Add the translated -iterate.
		_loop_prims="${_loop_prims} ${_loop_iter}"
	fi

	# 5. If we don't have path names, exit now.
	if str empty ${_loop_paths}; then
		putln "! _loop_E=${_loop_status}" >&8 \
		|| die "LOOP find: internal error: cannot write exit status on no path names"
		exit
	fi

	# 4.1 (deferred). Translate -mindepth and -maxdepth to POSIX.
	if isset _loop_mindepth; then
		_loop_find_translateDepth ${_loop_mindepth}
		_loop_prims="$REPLY ${_loop_prims}"
	fi
	if isset _loop_maxdepth; then
		_loop_find_translateDepth $((_loop_maxdepth + 1))
		_loop_prims="$REPLY -prune -o ${_loop_prims}"
	fi

	# 6. Run the 'find' utility.
	#    Pass on FD 8 with 8>&8 (ksh93 needs this) so the -exec'ed find.sh can write iteration commands.
	if isset _loop_DEBUG; then
		# Eval and re-quote debug output so we don't show unexpanded variables like $MSH_SHELL.
		( eval "set -- ${_loop_find} ${_loop_paths} ${_loop_prims}"
		  shellquoteparams
		  put "[DEBUG] $@ 8>&8$CCn" )
	fi
	eval "${_loop_find} ${_loop_paths} ${_loop_prims} 8>&8"
	_loop_status=$(( _loop_status > $? ? _loop_status : $? ))
	if let '_loop_status > 125'; then
		# Use cold hard 'die' and not '_loop_die': don't rely on our pipe for system errors
		case ${_loop_status} in
		( 126 )	die "LOOP find: system error: ${_loop_find_myUtil} could not be executed" ;;
		( 127 )	die "LOOP find: system error: ${_loop_find_myUtil} was not found" ;;
		( $SIGPIPESTATUS )
			;;	# ok: loop exit due to 'break', etc.
		( * )	REPLY=$(command kill -l ${_loop_status} 2>/dev/null) \
			&& not str isint ${REPLY:-0} && REPLY=${REPLY#[Ss][Ii][Gg]} \
			&& case $REPLY in
			( [Tt][Ee][Rr][Mm] )	# if SIGPIPE is ignored, allow SIGTERM
				thisshellhas WRN_NOSIGPIPE \
				|| die "LOOP find: system error: ${_loop_find_myUtil} killed by SIGTERM" ;;
			( * )	 die "LOOP find: system error: ${_loop_find_myUtil} killed by SIG$REPLY" ;;
			esac || die "LOOP find: system error: ${_loop_find_myUtil} failed with status ${_loop_status}" ;;
		esac
	fi

	# 7. Get the main shell to complete the loop with the remembered exit status.
	#    If we have --xargs, first clear the PPs or unset the array.
	if isset _loop_xargs; then
		if str empty ${_loop_xargs}; then
			put "set --; " >&8 2>/dev/null || exit
		else
			put "unset -v ${_loop_xargs}; " >&8 2>/dev/null || exit
		fi
	fi
	putln "! _loop_E=${_loop_status}" >&8 2>/dev/null
}

# Internal helper function to determine what translation of -iterate to use.
# -i designates version for interactive use: one file name per invocation.
_loop_find_setIter() {
	if str eq ${1-} -i && is onterminal stdin; then
		if isset _loop_xargs; then
			_loop_iter='-exec $MSH_SHELL $MSH_AUX/var/loop/find-ok.sh {} +'
		else
			_loop_iter='-exec $MSH_SHELL $MSH_AUX/var/loop/find-ok.sh {} \;'
		fi
	else
		_loop_iter='-exec $MSH_SHELL $MSH_AUX/var/loop/find.sh {} +'
	fi
}

# Internal helper function for translating mindepth and maxdepth to POSIX.
# Translates a depth to a $path/*/*/... pattern for every given path.
_loop_find_translateDepth() {
	_loop_ptrn=''
	_loop_i=0
	while let "(_loop_i += 1) <= $1"; do
		_loop_ptrn=${_loop_ptrn}/*
	done
	eval "set -- ${_loop_paths}"
	case $# in
	( 0 )	_loop_die "internal error in _loop_find_translateDepth()" ;;
	( 1 )	shellquote _loop_path=${1}${_loop_ptrn}
		REPLY="-path ${_loop_path}" ;;
	( * )	REPLY=''
		for _loop_path do
			shellquote _loop_path=${_loop_path}${_loop_ptrn}
			REPLY="${REPLY:+$REPLY -o }-path ${_loop_path}"
		done
		REPLY="\\( $REPLY \\)" ;;
	esac
}

if thisshellhas ROFUNC; then
	readonly -f _loopgen_find _loop_find_setIter _loop_find_translateDepth
fi

#!/bin/bash
# cake-autorate_lib.sh -- common functions for use by cake-autorate.sh
# This file is part of cake-autorate.

__set_e=0
if [[ ! ${-} =~ e ]]; then
    set -e
    __set_e=1
fi

# redirect stderr to log_msg and exit cake-autorate
intercept_stderr() 
{
	exec 2> >(
		while read -r error
		do
			log_msg "ERROR" "${error}"
			log_msg "ERROR" "Exiting cake-autorate now."
			kill -INT $$
			break
		done
	)
}

# Debug command wrapper
# Inspired by cmd_wrapper of sqm-script
debug_cmd()
{
	# Usage: debug_cmd debug_msg err_silence cmd arg1 arg2, etc.

	# Error messages are output as log_msg ERROR messages
	# Or set error_silence=1 to output errors as log_msg DEBUG messages

	local debug_msg=${1}
	local err_silence=${2}
	local cmd=${3}

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	shift 3

	local args=("${@}")

	local caller_id
	local err_type

	local ret
	local stderr

	err_type="ERROR"

	if ((err_silence)); then
		err_type="DEBUG"
	fi

	stderr=$(${cmd} "${args[@]}" 2>&1)
	ret=${?}

	caller_id=$(caller)

	if ((ret==0)); then
		log_msg "DEBUG" "debug_cmd: err_silence=${err_silence}; debug_msg=${debug_msg}; caller_id=${caller_id}; command=${cmd} ${args[*]}; result=SUCCESS"
	else
		[[ "${err_type}" == "DEBUG" && "${debug}" == "0" ]] && return # if debug disabled, then skip on DEBUG but not on ERROR

		log_msg "${err_type}" "debug_cmd: err_silence=${err_silence}; debug_msg=${debug_msg}; caller_id=${caller_id}; command=${cmd} ${args[*]}; result=FAILURE (${ret})"
		log_msg "${err_type}" "debug_cmd: LAST ERROR (${stderr})"

		frame=1
		while caller_output=$(caller "${frame}")
		do
			log_msg "${err_type}" "debug_cmd: CALL CHAIN: ${caller_output}"
			((++frame))
		done
	fi
}

exec {__sleep_fd}<> <(:) || true

sleep_s()
{
	# calling external sleep binary is slow
	# bash does have a loadable sleep
	# but read's timeout can more portably be exploited and this is apparently even faster anyway

	local sleep_duration_s=${1} # (seconds, e.g. 0.5, 1 or 1.5)
	read -r -t "${sleep_duration_s}" -u "${__sleep_fd}" || : &
	wait "${!}"
}

sleep_us()
{
	local sleep_duration_us=${1} # (microseconds)

	sleep_duration_s=000000${sleep_duration_us}
	sleep_duration_s=$((10#${sleep_duration_s::-6})).${sleep_duration_s: -6}
	sleep_s "${sleep_duration_s}"
}

sleep_remaining_tick_time()
{
	# sleeps until the end of the tick duration

	local t_start_us=${1} # (microseconds)
	local tick_duration_us=${2} # (microseconds)

	# shellcheck disable=SC2154
	sleep_duration_us=$(( t_start_us + tick_duration_us - ${EPOCHREALTIME/./} ))

	if (( sleep_duration_us > 0 )); then
		sleep_us "${sleep_duration_us}"
	fi
}

randomize_array()
{
	local -n array=${1}

	subset=("${array[@]}")
	array=()
	for ((set=${#subset[@]}; set>0; set--))
	do
		idx=$((RANDOM%set))
		array+=("${subset[idx]}")
		unset "subset[idx]"
		subset=("${subset[@]}")
	done
}

lock()
{
	local path=${1}

	while true; do
		( set -o noclobber; echo "$$" > "${path:?}" ) 2> /dev/null && return 0
		sleep_us 100000
	done
}

unlock()
{
	local path=${1}

	rm -f "${path:?}"
}

_proc_man_set_key()
{
	local key=${1}
	local value=${2}

	lock "${PROC_STATE_FILE_LOCK:?}"
	trap 'unlock "${PROC_STATE_FILE_LOCK:?}"' RETURN

	local entered=0
	while read -r line; do
		if [[ ${line} =~ ^${key}= ]]; then
			printf '%s\n' "${key}=${value}"
			entered=1
		else
			printf '%s\n' "${line}"
		fi
	done < "${PROC_STATE_FILE:?}" > "${PROC_STATE_FILE:?}.tmp"
	if (( entered == 0 )); then
		printf '%s\n' "${key}=${value}" >> "${PROC_STATE_FILE:?}.tmp"
	fi
	mv "${PROC_STATE_FILE:?}.tmp" "${PROC_STATE_FILE:?}"
	return 0
}

_proc_man_get_key_value()
{
	local key=${1}

	lock "${PROC_STATE_FILE_LOCK:?}"
	trap 'unlock "${PROC_STATE_FILE_LOCK:?}"' RETURN

	while read -r line; do
		if [[ ${line} =~ ^${key}= ]]; then
			printf '%s\n' "${line#*=}"
			return 0
		fi
	done < "${PROC_STATE_FILE:?}"
	return 1
}

proc_man()
{
	local action=${1}
	local name=${2}
	shift 2

	if [[ ! -f "${PROC_STATE_FILE:?}" ]]; then
		true > "${PROC_STATE_FILE:?}"
	fi

	# shellcheck disable=SC2311
	case "${action}" in
		"start")
			pid=$(_proc_man_get_key_value "${name}")
			if (( pid && pid > 0 )) && kill -0 "${pid}" 2> /dev/null; then
				return 1;
			fi

			"${@}" &
			local pid=${!}
			_proc_man_set_key "${name}" "${pid}"
			;;
		"stop")
			local pid
			pid=$(_proc_man_get_key_value "${name}")
			if ! (( pid && pid > 0 )); then
				return 0;
			fi

			kill "${pid}" 2> /dev/null || true

			# wait for process to die
			killed=0
			for ((i=0; i<10; i++));
			do
				if kill -0 "${pid}" 2> /dev/null; then
					sleep_us 100000
				else
					killed=1
					break
				fi
			done

			# if process still alive, kill it with fire
			if (( killed == 0 )); then
				kill -9 "${pid}" 2> /dev/null || true
			fi

			_proc_man_set_key "${name}" "-1" "${PROC_STATE_FILE:?}"
			;;
		"status")
			local pid
			pid=$(_proc_man_get_key_value "${name}")
			if (( pid && pid > 0 )); then
				if kill -0 "${pid}" 2> /dev/null; then
					printf '%s\n' "running"
				else
					printf '%s\n' "dead"
				fi
			else
				printf '%s\n' "stopped"
			fi
			;;
		"wait")
			local pid
			pid=$(_proc_man_get_key_value "${name}")
			if (( pid && pid > 0 )); then
				wait "${pid}" && return 0
			fi

			return 1
			;;
		"signal")
			shift 3

			local pid
			pid=$(_proc_man_get_key_value "${name}")
			if (( pid && pid > 0 )); then
				kill -s "${1}" "${pid}" 2>/dev/null && return 0
			fi

			return 1
			;;
		*)
			printf '%s\n' "unknown action: ${action}" >&2
			return 1
			;;
	esac

	return 0
}

proc_man_start()
{
	proc_man start "${@}"
}

proc_man_stop()
{
	proc_man stop "${@}"
}

proc_man_status()
{
	proc_man status "${@}"
}

proc_man_wait()
{
	proc_man wait "${@}"
}

proc_man_signal()
{
	proc_man signal "${@}"
}

if (( __set_e == 1 )); then
    set +e
fi
unset __set_e

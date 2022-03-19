#!/bin/bash

# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and OWD/RTT
# requires packages: bash, iputils-ping and coreutils-sleep

# Author: @Lynx (OpenWrt forum)
# Inspiration taken from: @moeller0 (OpenWrt forum)

# Possible performance improvement
export LC_ALL=C
export TZ=UTC

trap cleanup_and_killall INT TERM EXIT

cleanup_and_killall()
{
	echo "Killing all background processes and cleaning up /tmp files."
	# Resume pingers in case they are sleeping so they can be killed off
	kill -CONT -- ${ping_pids[@]}
	trap - INT && trap - TERM && trap - EXIT && kill $sleep_pid && kill -- ${ping_pids[@]} && kill -- ${monitor_pids[@]}
	[ -d "/tmp/CAKE-autorate" ] && rm -r "/tmp/CAKE-autorate"
	exit
}

install_dir="/root/CAKE-autorate/"

. $install_dir"config.sh"

# test if stdout is a tty (terminal)
[[ ! -t 1 ]] &&	exec &> /tmp/cake-autorate.log

get_next_shaper_rate() 
{

    	local cur_rate=$1
	local load=$2
	local cur_min_rate=$3
	local cur_base_rate=$4
	local cur_max_rate=$5
	local load_condition=$6
	local t_next_rate=$7
	local -n t_last_bufferbloat=$8
	local -n t_last_decay=$9
    	local -n next_rate=${10}

	local cur_rate_decayed_down
 	local cur_rate_decayed_up

	case $load_condition in

 		# in case of supra-threshold OWD spikes decrease the rate providing not inside bufferbloat refractory period
		bufferbloat)
			if (( $t_next_rate > ($t_last_bufferbloat+(10**3)*$bufferbloat_refractory_period) )); then
        			next_rate=$(( ($rx_load*$cur_rate*$rate_adjust_bufferbloat)/100000 ))
				t_last_bufferbloat=${EPOCHREALTIME/./}
			else
				next_rate=$cur_rate
			fi
			;;
           	# ... otherwise determine whether to increase or decrease the rate in dependence on load
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		high_load)	
			if (( $t_next_rate > ($t_last_bufferbloat+(10**3)*$bufferbloat_refractory_period) )); then
                		next_rate=$(( ($cur_rate*$rate_adjust_load_high)/1000 ))
			
			else
				next_rate=$cur_rate
			fi
			;;
		# low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		low_load)
			if (($t_next_rate > ($t_last_decay+(10**3)*$decay_refractory_period) )); then
		
	                	cur_rate_decayed_down=$(( ($cur_rate*$rate_adjust_load_low)/1000 ))
        	        	cur_rate_decayed_up=$(( ((2000-$rate_adjust_load_low)*$cur_rate)/1000 ))

                		# gently decrease to steady state rate
	                	if (($cur_rate_decayed_down > $cur_base_rate)); then
        	                	next_rate=$cur_rate_decayed_down
                		# gently increase to steady state rate
	                	elif (($cur_rate_decayed_up < $cur_base_rate)); then
        	                	next_rate=$cur_rate_decayed_up
                		# steady state has been reached
	               		else
					next_rate=$cur_base_rate
				fi
				t_last_decay=${EPOCHREALTIME/./}
			else
				next_rate=$cur_rate
			fi
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        if (($next_rate < $cur_min_rate)); then
            next_rate=$cur_min_rate;
        fi

        if (($next_rate > $cur_max_rate)); then
            next_rate=$cur_max_rate;
        fi

}

# update download and upload rates for CAKE
update_loads()
{
        read -r cur_rx_bytes < "$rx_bytes_path"
        read -r cur_tx_bytes < "$tx_bytes_path"
        t_cur_bytes=${EPOCHREALTIME/./}

        rx_load=$(( ( (8*10**5*($cur_rx_bytes - $prev_rx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_dl_rate  ))
        tx_load=$(( ( (8*10**5*($cur_tx_bytes - $prev_tx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_ul_rate  ))

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes

}

# ping reflector, maintain baseline and output deltas to a common fifo
monitor_reflector_path() 
{
	local reflector=$1

	[[ $(ping -q -c 10 -i 0.1 $reflector | tail -1) =~ ([0-9.]+)/ ]];

	rtt_baseline=$(printf %.0f\\n "${BASH_REMATCH[1]}e3")

	while read -r  timestamp _ _ _ reflector seq_rtt
	do
		
		[[ $seq_rtt =~ time=+([0-9.]*)[[:space:]]+ms+ ]]; rtt=${BASH_REMATCH[1]}
		
		# If output line of ping does not contain any RTT then skip onto the next one
		[ -z "$rtt" ] && continue

		[[ $seq_rtt =~ icmp_seq=([0-9]*) ]]; seq=${BASH_REMATCH[1]}

		reflector=${reflector//:/}

		rtt=$(printf %.0f\\n "${rtt}e3")

		rtt_delta=$(( $rtt-$rtt_baseline ))

		if (( $rtt_delta >= 0 )); then
			rtt_baseline=$(( ( (1000-$alpha_baseline_increase)*$rtt_baseline+$alpha_baseline_increase*$rtt )/1000 ))
		else
			rtt_baseline=$(( ( (1000-$alpha_baseline_decrease)*$rtt_baseline+$alpha_baseline_decrease*$rtt )/1000 ))
		fi

		echo $timestamp $reflector $seq $rtt_baseline $rtt $rtt_delta > /tmp/CAKE-autorate/ping_fifo
	done< <(ping -D -i $reflector_ping_interval $reflector & echo $! >/tmp/CAKE-autorate/${reflector}_ping_pid)
}

sleep_remaining_tick_time()
{
	local t_start=$1 # (microseconds)
	local t_end=$2 # (microseconds)
	local tick_duration=$3 # (microseconds)

	sleep_duration=$(( $tick_duration - $t_end + $t_start))
        # echo $(($sleep_duration/(10**6)))
        if (($sleep_duration > 0 )); then
                sleep $sleep_duration"e-6"
        fi
}


# Initialize variables

# Convert human readable parameters to values that work with integer arithmetic
alpha_baseline_increase=$(printf %.0f\\n "${alpha_baseline_increase}e3")
alpha_baseline_decrease=$(printf %.0f\\n "${alpha_baseline_decrease}e3")   
rate_adjust_bufferbloat=$(printf %.0f\\n "${rate_adjust_bufferbloat}e3")
rate_adjust_load_high=$(printf %.0f\\n "${rate_adjust_load_high}e3")
rate_adjust_load_low=$(printf %.0f\\n "${rate_adjust_load_low}e3")
high_load_thr=$(printf %.0f\\n "${high_load_thr}e2")

cur_ul_rate=$base_ul_rate
cur_dl_rate=$base_dl_rate

last_ul_rate=$cur_ul_rate
last_dl_rate=$cur_dl_rate

tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit

prev_tx_bytes=$(cat $tx_bytes_path)
prev_rx_bytes=$(cat $rx_bytes_path)
t_prev_bytes=${EPOCHREALTIME/./}

t_start=${EPOCHREALTIME/./}
t_end=${EPOCHREALTIME/./}
t_prev_ul_rate_set=$t_prev_bytes
t_prev_dl_rate_set=$t_prev_bytes
t_ul_last_bufferbloat=$t_prev_bytes
t_ul_last_decay=$t_prev_bytes
t_dl_last_bufferbloat=$t_prev_bytes
t_dl_last_decay=$t_prev_bytes 

t_sustained_base_rate=0
ping_sleep=0

delays=( $(printf ' 0%.0s' $(seq $bufferbloat_detection_window)) )

[ ! -d "/tmp/CAKE-autorate" ] && mkdir "/tmp/CAKE-autorate"

mkfifo /tmp/CAKE-autorate/ping_fifo

sleep inf > /tmp/CAKE-autorate/ping_fifo&

sleep_pid=$!

for reflector in "${reflectors[@]}"
do
	t_start=${EPOCHREALTIME/./}
	monitor_reflector_path $reflector&
	monitor_pids+=($!)	
	t_end=${EPOCHREALTIME/./}
	# Space out pings by ping interval / number of reflectors
	sleep_remaining_tick_time $t_start $t_end $(( (10**3)*$(printf %.0f\\n "${reflector_ping_interval}e3")/ $no_reflectors ))
done

# Allow sufficient time for the ping_pids to get written out
sleep 1

for reflector in "${reflectors[@]}"
do
	read ping_pid < /tmp/CAKE-autorate/${reflector}_ping_pid
	ping_pids+=($ping_pid)
done

while true
do
	while read -r timestamp reflector seq rtt_baseline rtt rtt_delta
	do 
		t_start=${EPOCHREALTIME/./}
		((($t_start - "${timestamp//[[\[\].]}")>500000)) && echo "WARNING: encountered response from [" $reflector "] that is > 500ms old. Skipping." && continue

		unset 'delays[0]'
	
		if (($rtt_delta > (1000*$delay_thr))); then 
			delays+=(1)
		else 
			delays+=(0)
		fi	

		delays=(${delays[*]})

		update_loads

		dl_load_condition="low_load"
		(($rx_load > $high_load_thr)) && dl_load_condition="high_load"

		ul_load_condition="low_load"
		(($tx_load > $high_load_thr)) && ul_load_condition="high_load"
	
		sum_delays=$(IFS=+; echo "$((${delays[*]}))")

		(($sum_delays>$bufferbloat_detection_thr)) && ul_load_condition="bufferbloat" && dl_load_condition="bufferbloat"

		get_next_shaper_rate $cur_dl_rate $rx_load $min_dl_rate $base_dl_rate $max_dl_rate $dl_load_condition $t_start t_dl_last_bufferbloat t_dl_last_decay cur_dl_rate
		get_next_shaper_rate $cur_ul_rate $tx_load $min_ul_rate $base_ul_rate $max_ul_rate $ul_load_condition $t_start t_ul_last_bufferbloat t_ul_last_decay cur_ul_rate

		(($output_processing_stats)) && echo $EPOCHREALTIME $rx_load $tx_load $cur_dl_rate $cur_ul_rate $timestamp $reflector $seq $rtt_baseline $rtt $rtt_delta $dl_load_condition $ul_load_condition

       		# fire up tc if there are rates to change
		if (( $cur_dl_rate != $last_dl_rate)); then
       			(($output_cake_changes)) && echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
       			tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
			t_prev_dl_rate_set=${EPOCHREALTIME/./}
		fi
       		if (( $cur_ul_rate != $last_ul_rate )); then
         		(($output_cake_changes)) && echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
       			tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
			t_prev_ul_rate_set=${EPOCHREALTIME/./}
		fi
		
		# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
		if (( $cur_ul_rate == $base_ul_rate && $last_ul_rate == $base_ul_rate && $cur_dl_rate == $base_dl_rate && $last_dl_rate == $base_dl_rate )); then
			((t_sustained_base_rate+=$((${EPOCHREALTIME/./}-$t_end))))
			(($t_sustained_base_rate>(10**6*$sustained_base_rate_sleep_thr))) && break
		else
			# reset timer
			t_sustained_base_rate=0
		fi

		# remember the last rates
       		last_dl_rate=$cur_dl_rate
       		last_ul_rate=$cur_ul_rate

		t_end=${EPOCHREALTIME/./}

	done</tmp/CAKE-autorate/ping_fifo

	# we broke out of processing loop, so conservatively set hard minimums and wait until there is a load increase again
	cur_dl_rate=$min_dl_rate
        tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
	cur_ul_rate=$min_ul_rate
        tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
	# remember the last rates
	last_ul_rate=$cur_ul_rate
	last_dl_rate=$cur_dl_rate

	# Pause ping processes
	kill -STOP $ping_pids

	# wait until load increases again
	while true
	do
		t_start=${EPOCHREALTIME/./}	
		update_loads
		(($rx_load>$high_load_thr || $tx_load>$high_load_thr)) && break 
		t_end=${EPOCHREALTIME/./}
		sleep $(($t_end-$t_start))"e-6"
	done

	# Continue ping processes
	kill -CONT $ping_pids
done

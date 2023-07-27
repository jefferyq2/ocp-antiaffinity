#!/bin/bash

# set -x

declare -a zones
declare -a hosts
declare -a roles
declare -a labels

CONFIG_PATH=${CONFIG_PATH:='/config/cluster.yaml'}
NAMESPACE=${NAMESPACE:='vmware-topology'}

load_vars() {
	cluster_name=$(oc get infrastructure cluster -o jsonpath='{ .status.infrastructureName }' | cut -d '-' -f1)

	govc_fqdn=$(oc get secret vsphere-creds -n ${NAMESPACE} -o jsonpath='{ .data }' | jq -r 'keys[0]' | rev | cut -d '.' -f2- | rev)
	export GOVC_PASSWORD=$(oc get secret vsphere-creds -n ${NAMESPACE} -o jsonpath='{ .data }' | jq -r '. | with_entries (select(.key|contains("password"))) | flatten | .[0]' | base64 -d)
	export GOVC_USERNAME=$(oc get secret vsphere-creds -n ${NAMESPACE} -o jsonpath='{ .data }' | jq -r '. | with_entries (select(.key|contains("username"))) | flatten | .[0]' | base64 -d)
	export GOVC_URL="https://${govc_fqdn}/sdk"
	export GOVC_TLS_CA_CERTS="/certificates/ca.crt"
	export GOVMOMI_HOME="/tmp"

	readarray -t zones < <(yq '.zones[].name' ${CONFIG_PATH})
	for zone in "${zones[@]}"
	do
		declare -n host_ref="hosts_$zone"
		filter=".zones.[] | select(.name == \"${zone}\") | .hosts | join(\" \")"
		host_ref=$(yq "${filter}" ${CONFIG_PATH})
	done
	readarray -t roles < <(yq '.roles[].name' ${CONFIG_PATH})
	readarray -t labels < <(yq '.roles[].label' ${CONFIG_PATH})
	region=$(yq '.region' ${CONFIG_PATH})
}

debug_node_struture() {
	for role in ${roles[@]}
	do
		declare -n role_ref="nodes_$role"
		echo -n "Nodes by role ${!role_ref} :"
		for node in ${role_ref[@]}
		do
			echo -n " ${node}"
		done
		echo
		for zone in ${zones[@]}
		do
			declare -n zone_ref="nodes_${role}_${zone}"
			echo "Nodes by role and zone ${!zone_ref} - ${zone_ref[*]}"
		done
		echo "Array ${!role_ref} : ${role_ref[*]}"
	done
}

get_nodes() {
	for role_counter in ${!roles[@]}
	do
		declare -n ref="nodes_${roles[${role_counter}]}"
		ref=$(oc get nodes --selector=${labels[${role_counter}]} -o json)
		readarray -t ref < <(echo ${ref} | jq -r '.items[] | .metadata.name')
		# echo "DEBUG GET_NODES : ${!ref} ${labels[${role_counter}]} ${role_counter} ${ref[*]}"
	done
}

create_vm_zone_lists () {
	for role in ${roles[@]}
	do
		declare -n role_ref="nodes_$role"
		for node_counter in ${!role_ref[@]}
		do
			zone_counter=$(( ($node_counter % ${#zones[@]}) ))
			zone=${zones[${zone_counter}]}
			declare -n zone_ref="nodes_${role}_${zone}"
			zone_ref+=("${role_ref[${node_counter}]}")
			# echo "DEBUG: ZONE_LIST ${!role_ref} ${!zone_ref} $node_counter / $zone_counter ${role_ref[${node_counter}]} / ${zone_ref[*]}"
		done
	done
}

create_host_groups() {
	for zone in ${zones[@]}
	do
		declare -n host_ref="hosts_${zone}"
		name="${cluster_name}_${zone}_hosts"
		vms=${host_ref[*]}
		result=$(govc cluster.group.ls -name ${name} -json=true &> /dev/null)
		if [ $? == 0 ]
		then
			echo "Adding hostgroup ${name} with ${vms} / ${zone_counter}"
			result=$(govc cluster.group.change -name ${name} ${vms})
		else
			echo "Creating hostgroup ${name} with ${vms}"
			result=$(govc cluster.group.create -name ${name} -host ${vms})
		fi
	done
}

create_vm_groups () {
	for role in ${roles[@]}
	do
		declare -n role_ref="nodes_$role"
		for zone in ${zones[@]}
		do
			declare -n zone_ref="nodes_${role}_${zone}"
			vms="${zone_ref[*]}"
			hostgroup="${cluster_name}_${zone}_hosts"
			name="${cluster_name}_${zone}_${role}"
			cluster_group_hosts=$(govc cluster.group.ls -name ${name} &> /dev/null)
			if [ $? == 0 ]
			then
				if [[ -n ${vms} ]]
				then
					echo "Adding vmgroup ${name} with ${vms}"
					result=$(govc cluster.group.change -name ${name} ${vms})
				else
					echo "Removing vmgroup ${name}"
					results=$(govc cluster.group.remove -name ${name})
				fi
			else
				if [[ -n ${vms} ]]
				then
					echo "Changing vmgroup ${name} with ${vms}"
					result=$(govc cluster.group.create -name ${name} -vm ${vms})
				fi
			fi
			for node in ${zone_ref[@]}
			do
				echo "Adding Node topology label ${zone} and enforcing DRS for node ${node}"
				result=$(oc label node ${node} topology.kubernetes.io/zone=${zone} --overwrite)
				result=$(oc label node ${node} topology.kubernetes.io/region=${region} --overwrite)
				result=$(govc cluster.override.change -vm ${node} -drs-enabled -drs-mode fullyAutomated)
			done
		done
	done
}

create_rules () {
	for role in ${roles[@]}
	do
		for zone in ${zones[@]}
		do
			hostgroup="${cluster_name}_${zone}_hosts"
			name="${cluster_name}_${zone}_${role}"
			declare -n zone_ref="nodes_${role}_${zone}"
			vms="${zone_ref[*]}"
			result=$(govc cluster.rule.ls -name ${name} -json=true &> /dev/null)
			if [ $? == 0 ]
			then
				if [[ -n ${vms} ]]
				then
					echo "Changing rule ${name}"
					result=$(govc cluster.rule.change -name ${name} -enable -mandatory -vm-group=${name} -host-affine-group=${hostgroup})
				else
					echo "Removing rule ${name}"
					result=$(govc cluster.rule.remove -name ${name})
				fi
			else
				if [[ -n ${vms} ]]
				then
					echo "Adding rule ${name}"
					result=$(govc cluster.rule.create -name ${name} -enable -mandatory -vm-host -vm-group=${name} -host-affine-group=${hostgroup})
				fi
			fi
		done
	done
}

main () {
	load_vars
 	get_nodes
 	create_vm_zone_lists
 	debug_node_struture
 	create_host_groups
 	create_vm_groups
  	create_rules
}

main
exit 0

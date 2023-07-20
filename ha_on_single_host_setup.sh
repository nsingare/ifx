#!/bin/ksh
#  DESCRIPTION : Create HA cluster
#=========================================================================
# FUNCTIONS
#=========================================================================
# FUNCTION  InitVars
#  Initialize variables
#-------------------------------------------------------------------------
#set -x
InitVars ()
{
	StatCmd=$INFORMIXDIR/bin/onstat
	StartCmd=$INFORMIXDIR/bin/oninit
	HOME_DIR=$HOME
	SERVERNUM=70
	PORTNUM=70700
}
CreateOnconfig ()
{
	echo "-------------------------------------------------------------------"
	for HA_ALIAS in pri hdr rss sds
	do
		echo "Prepare instance: ${HA_ALIAS}"
		echo "-----------------------"
		echo "${HA_ALIAS}"
		DATA_DIR=${HOME_DIR}/${HA_ALIAS}
		mkdir -p ${DATA_DIR}
		ONCONFIG=onconfig.$HA_ALIAS
		SERVERNUM=$(($SERVERNUM + 1))
		PORTNUM=$(($PORTNUM + 1))
		cp -p $INFORMIXDIR/etc/onconfig.std $INFORMIXDIR/etc/$ONCONFIG
		grep -q -w "^${HA_ALIAS}" $INFORMIXDIR/etc/sqlhosts || echo "$HA_ALIAS onsoctcp localhost $PORTNUM" >>$INFORMIXDIR/etc/sqlhosts
		sed -i "s/DBSERVERNAME.*/DBSERVERNAME $HA_ALIAS /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/SERVERNUM.*/SERVERNUM $SERVERNUM /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/HA_ALIAS.*/HA_ALIAS $HA_ALIAS/g " ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/REMOTE_SERVER_CFG.*/REMOTE_SERVER_CFG authfile.$HA_ALIAS/g " ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/ROOTPATH.*/ROOTPATH rootdbs /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/MSGPATH.*/MSGPATH $HA_ALIAS.log /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/FULL_DISK_INIT.*/FULL_DISK_INIT 1 /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/LOG_INDEX_BUILDS.*/LOG_INDEX_BUILDS 1 /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/TEMPTAB_NOLOG.*/TEMPTAB_NOLOG 1 /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/ENABLE_SNAPSHOT_COPY.*/ENABLE_SNAPSHOT_COPY 1 /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/CDR_AUTO_DISCOVER.*/CDR_AUTO_DISCOVER 1 /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/LTAPEDEV.*/LTAPEDEV \/dev\/null /g"  ${INFORMIXDIR}/etc/$ONCONFIG
		#sed -i "s/VPCLASS cpu/VPCLASS cpu=2/g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/SDS_PAGING.*/SDS_PAGING ifx_sds_paging1_$HA_ALIAS,sds_paging2_$HA_ALIAS /g" ${INFORMIXDIR}/etc/$ONCONFIG
		sed -i "s/SDS_TEMPDBS.*/SDS_TEMPDBS ifx_sds_tmpdbs_$HA_ALIAS,ifx_sds_tmpdbs_$HA_ALIAS,4,0,50M /g" ${INFORMIXDIR}/etc/$ONCONFIG
		if [ "$HA_ALIAS" = "sds" ]
		then
			sed -i "s/SDS_ENABLE.*/SDS_ENABLE 1 /g" ${INFORMIXDIR}/etc/$ONCONFIG
		fi
		chown informix:informix ${INFORMIXDIR}/etc/$ONCONFIG
		#mkdir -p ${DATA_DIR}/dbspaces
		rm -rf ${DATA_DIR}/rootdbs
		touch ${DATA_DIR}/rootdbs
		touch ${DATA_DIR}/${HA_ALIAS}.log
		touch "${INFORMIXDIR}/etc/authfile.$HA_ALIAS"
		chown -R informix:informix ${DATA_DIR}
		chmod 660 ${DATA_DIR}/rootdbs
		chmod 660 "${INFORMIXDIR}/etc/authfile.$HA_ALIAS"
		echo "localhost" >${INFORMIXDIR}/etc/authfile.$HA_ALIAS
		echo "$HA_ALIAS" >>${INFORMIXDIR}/etc/authfile.$HA_ALIAS
		setStr="
		#!/bin/bash
		export INFORMIXDIR=${INFORMIXDIR}
		export PATH=\"\${INFORMIXDIR}/bin:\${PATH}\"
		export INFORMIXSERVER=\"${HA_ALIAS}\"
		export HA_ALIAS=\"${HA_ALIAS}\"
		#export INFORMIXSQLHOSTS=\"${INFORMIXSQLHOSTS}\"
		export INFORMIXSQLHOSTS=\"${INFORMIXDIR}/etc/sqlhosts\"
		export ONCONFIG=\"onconfig.${HA_ALIAS}\"
		export LD_LIBRARY_PATH=\"${INFORMIXDIR}/lib:${INFORMIXDIR}/lib/esql:${LD_LIBRARY_PATH}\"
		cd ${HOME_DIR}/${HA_ALIAS}
		"
		echo "${setStr}" > ${HOME_DIR}/set_env.$HA_ALIAS.sh
	done
}
#-------------------------------------------------------------------------
# FUNCTION  StartInstances
#  Initialize the 3 Instances for the ER class
#-------------------------------------------------------------------------
StartInstances ()
{
	#-------------------------------------------------------------------------
	# Create the 3 instances pri hdr rss
	#-------------------------------------------------------------------------
	echo "-------------------------------------------------------------------"
	echo "Start Primary Instances"
	echo "-----------------------"
	#for Instance in pri hdr rss
	for Instance in pri
	do
		INFORMIXSERVER=${Instance}
		ONCONFIG=onconfig.$Instance
		export INFORMIXSERVER ONCONFIG
		. ${HOME_DIR}/set_env.$Instance.sh

		echo "\nStarting Instance $Instance. Please wait...."
		$StartCmd -iy
		sleep 5
		$StatCmd - > /dev/null
		if [ "$?" = "5" ]
		then
			echo "Instance $Instance Initialized."
		else
			echo "Instance $Instance Failed To Initialize."
		fi
		wait4online
	done
}
# Wait for server to be online
#-------------------------------------------------------------------------
wait4online()
{
	retry=0
	wait4online_status=0
	instance_status="STATUS: sqlexec=Checking ... Sysmater=Checking ... Sysadmin=Checking "
	while [ 1 ]
	do
		sleep 5
		retry=$(expr $retry + 1)
		onstat - > /dev/null
		server_state=$?
		#Offline mode
		if [ $server_state -eq 255 ]
		then
			wait4online_status=1
			printf "ERROR: wait4online() Server is in Offline mode\n"
			break
		fi
		#Check if sqlexec connectivity is enabled or not.
		onstat -g ntd|grep sqlexec|grep yes > /dev/null
		exit_status=$?
		if [ $exit_status -eq 0 ]
		then
			instance_status="STATUS: sqlexec=COMPLETE ... Sysmater=Checking ... Sysadmin=Checking "
			#su informix -c "${INFORMIXDIR}/bin/dbaccess sysadmin - <<EOF
			${INFORMIXDIR}/bin/dbaccess sysmaster - <<EOF1 > /dev/null 2>&1
			unload to check.TMP
			select count(*) from sysdatabases where name = 'sysadmin'
EOF1
			rc=$?
			if [ $? -eq 0 ]
			then
				count=`cat check.TMP|grep -c "1"`
				if [ $count -eq 1 ]
				then
					instance_status="STATUS: sqlexec=COMPLETE ... Sysmater=COMPLETE ... Sysadmin=Checking "
					sleep 1
					${INFORMIXDIR}/bin/dbaccess sysadmin - <<EOF2 > /dev/null 2>&1
EOF2
					rc=$?
					if [ $? -eq 0 ]
					then
						instance_status="STATUS: sqlexec=COMPLETE ... Sysmater=COMPLETE ... Sysadmin=COMPLETE "
						wait4online_status=0
						current_status=`onstat - | grep -i informix`
						printf "Check STATUS(${retry}): ${current_status} \n"
						printf "${instance_status}\n"
						printf "Informix server is On-Line \n"
						break
					fi
				fi
			fi
			rm -f check.TMP
		fi
		if [ $retry -eq 60 ]
		then
			wait4online_status=1
			printf "ERROR: wait4online() Timed-out waiting for server to allow client connections\n"
			break
		fi
		current_status=`onstat - | grep -i informix`
		printf "Check STATUS(${retry}): ${current_status} \n"
		printf "${instance_status}\n"
	done
}
# Setup HDR
#-------------------------------------------------------------------------
SetupHDR ()
{
	echo "-------------------------------------------------------------------"
	echo "Setting up HDR"
	echo "--------------------"
	. ${HOME_DIR}/set_env.hdr.sh
	echo "Informixserver: ${INFORMIXSERVER}"
	ifxclone -S pri -I localhost -P 70701 -t hdr -i localhost -p 70702 -k -L -T -d HDR
	sleep 5
	wait4online
	#onstat -g cluster
}

# Setup RSS
#-------------------------------------------------------------------------
SetupRSS ()
{

	echo "-------------------------------------------------------------------"
	echo "Setting up RSS"
	echo "--------------------"
	. ${HOME_DIR}/set_env.rss.sh
	echo "Informixserver: ${INFORMIXSERVER}"
	ifxclone -S pri -I localhost -P 70701 -t rss -i localhost -p 70703 -k -L -T -d RSS
	sleep 5
	wait4online
	#onstat -g cluster
}

# Setup SDS
#-------------------------------------------------------------------------
SetupSDS ()
{
	echo "-------------------------------------------------------------------"
	echo "Setting up SDS"
	echo "--------------------"
	. ${HOME_DIR}/set_env.sds.sh
	rm -rf ./rootdbs
	ln -s ${HOME_DIR}/pri/rootdbs rootdbs
	echo "Informixserver: ${INFORMIXSERVER}"
	ifxclone -S pri -I localhost -P 70701 -t sds -i localhost -p 70704 -k -L -T -d SDS
	sleep 5
	wait4online
	#onstat -g cluster
}

ShowHelp ()
{
	echo "-------------------------------------------------------------------"
	echo "Accessing HA Cluster"
	echo "------------------------------------"
	echo "1. To set PRIMARY server environemnt"
	echo " . /home/informix/set_env.pri.sh"
	echo " "
	echo "2. To set HDR server environemnt"
	echo " . /home/informix/set_env.hdr.sh"
	echo " "
	echo "3. To set RSS server environemnt"
	echo " . /home/informix/set_env.rss.sh"
	echo " "
	echo "4. To set SDS server environemnt"
	echo " . /home/informix/set_env.sds.sh"
	echo " "
}


# Main
#-------------------------------------------------------------------------

InitVars
CreateOnconfig
StartInstances
SetupHDR
SetupRSS
SetupSDS
ShowHelp

#!/bin/bash
# This script enables kdump on HANA Large Instances(Type 1/2)

ExitIfFailed()
{
    if [ "$1" != 0 ]; then
        echo "$2 ! Exiting !!!!"
        exit 1
    fi
}

ExitIfLunNotFound()
{
    echo "Failed to identify dedicated lun for kdump"
    exit 1
}

# operating system supported by this script
supported_os=(
    "SLES"
    "SLES_SAP"
)

# operating system versions supported by this script
supported_version=( "12-SP2"
    "12-SP3"
    "12-SP4"
    "12-SP5"
    "15-SP1"
    "15-SP2"
)

# scan the added lun and mount that to /var/crash
# A race condition requires that rescan-scsi-bus.sh be run twice
# if logical units are mapped for the first time. During the first scan,
# rescan-scsi-bus.sh only adds LUN0; all other logical units are added in the second scan.
# refer https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/5/html/online_storage_reconfiguration_guide/rescan-scsi-bus
for i in {0..1}
do
    rescan-scsi-bus.sh
    ExitIfFailed $? "Unable to scan lun"
done

# sg_scan -i command will give mapping for the devices
# output look like
# /dev/sg32: scsi17 channel=0 id=3 lun=3
#    NETAPP    LUN C-Mode        9600 [rmb=0 cmdq=1 pqual=0 pdev=0x0]
# where lun=3 is the lun id
# so in order to fetch the dedicated kdump lun which is attached to lun_id=3
# we need to parse the SAN id and then map that id to device id in os
# in above example SAN id is /dev/sg32
san_disk=$(sg_scan -i | grep lun=3 | awk 'FNR==1'| egrep -o "^[ ]{0,}\/dev\/[a-z0-9]*")
if [[ "$san_disk" == "" ]]; then
    ExitIfLunNotFound
fi

# get the actual device using san_disk id
# sg_map -sd show mapping to disk
# output of sg_map -sd is like:
# /dev/sg1  /dev/sda
# /dev/sg2  /dev/sdb
device=$(sg_map -sd | grep $san_disk | egrep -o "[ ]{1,}\/dev\/[a-z0-9]*"| sed -e 's/^[[:space:]]*//')
if [[ "$device" == "" ]]; then
    ExitIfLunNotFound
fi

# now use udevadm info --query=all --name /dev/id
# to get the mapper id

id=$(udevadm info --query=all --name $device | grep "ID_SERIAL=" | egrep -o "[a-z0-9]{1,}")
if [[ "$id" == "" ]]; then
    ExitIfLunNotFound
fi

lun_dev_mapper="/dev/mapper/$id"

# format a disk
mkfs.xfs -f $lun_dev_mapper
ExitIfFailed $? "Unable format kdump dedicated lun"

# add entry in the /etc/fstab to mount the kdump lun
# on reboot
echo "$lun_dev_mapper /var/crash xfs defaults 0 0" >> /etc/fstab
ExitIfFailed $? "Unable to add lun mount entry in /etc/fstab"

# mount the kdump dedicated lun
mount $lun_dev_mapper /var/crash
ExitIfFailed $? "Unable to mount kdump dedicated lun"

# get OS name and OS version
# /etc/os-release file has this information
# in the form of key value pair so these can be
# imported in shell varible
eval $(cat /etc/os-release | sed -e s"@: @=@")

# check if the os and version is supported by this script
supported="false"
for i in "${supported_os[@]}"; do
    if [[ "$NAME" == "$i" ]]; then
        for j in "${supported_version[@]}"; do
            if [[ "$VERSION" == "$j" ]]; then
                supported="true"
                break
            fi
        done
        break
    fi
done
if [[ "$supported" == "false" ]]; then
    echo "This script does not support current OS $NAME, VERSION $VERSION. Please raise request to support this OS and Version"
    exit 1
fi

# check if the kexec-tool is enabled
rpm -q kexec-tools
ExitIfFailed $? "kxec-tools required to enable kdump, please install"

# check if the GRUB_CMDLINE_LINUX_DEFAULT parameter exist in /etc/default/grub file
# missing command line options will be appended to GRUB_CMDLINE_LINUX_DEFAULT
egrep "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub
if [[ "$?" == "1" ]]; then # in this case append the parameter to the file
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\"" >> /etc/default/grub
    ExitIfFailed $? "Enable to add GRUB_CMDLINE_LINUX_DEFAULT parameter in /etc/default/grub"
fi

AddNumaSettingInKdumpConfFile()
{
    source /etc/sysconfig/kdump
    # check if the KDUMP_COMMANDLINE_APPEND env contains numa=off setting
    echo $KDUMP_COMMANDLINE_APPEND | grep "numa=off"
    if [[ "$?" == "1" ]]; then # numa=off setting does not exist
        KDUMP_COMMANDLINE_APPEND="\"$KDUMP_COMMANDLINE_APPEND numa=off\""
        sed -i "s#^KDUMP_COMMANDLINE_APPEND=\".*\"#KDUMP_COMMANDLINE_APPEND=$KDUMP_COMMANDLINE_APPEND#gI" /etc/sysconfig/kdump
    fi
}

ReplaceParamsInGrubFile()
{
    # get low and high value reported by kdumptool calibrate
    # kdumptool calibrate reports key value pair
    # so these can be imported in shell environment
    eval $(kdumptool calibrate | sed -e s"@: @=@")
    ExitIfFailed $? "Failed to run kdumptool calibrate command"

    # get system memory in TB
    mem=$(free --tera | awk 'FNR == 2 {print $2}')
    ExitIfFailed $? "Failed to get memory using free command"

    # high memory to use for kdump is calculated according to system
    # if the total memory of a system is greater than 1TB
    # then the high value to use is (High From kdumptool * RAM in TB + LUNS / 2)
    high_to_use=$High
    if [ $mem -gt 1 ]; then
        high_to_use=$(($High*$mem))
    fi

    # Add LUNS/2 to high_to_use
    high_to_use=$(($high_to_use + $(($(lsblk | grep disk | wc -l)/2))))

    # remove high and low value in /etc/default/grub
    sed -i "s/crashkernel=[0-9]*[MG],high//gI" /etc/default/grub
    sed -i "s/crashkernel=[0-9]*[MG],low//gI" /etc/default/grub

    # commandline parameters which must be present in order to make sure
    # that kdump works
    commandline_params=(
        "splash=verbose"
        "mce=ignore_ce"
        "nomodeset"
        "numa_balancing=disable"
        "transparent_hugepage=never"
        "intel_idle.max_cstate=1"
        "processor.max_cstate=1"
        "quiet"
        "showopts"
        "rw"
    )

    # load /etc/default/grub value in env variables to append crashkernel high, low value
    source /etc/default/grub
    for i in "${commandline_params[@]}"; do
        grep $i /proc/cmdline
        if [[ "$?" == "1" ]]; then # this option is not present in cmdline
            GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT $i"
        fi
    done

    # append crashkernel high,low value to GRUB_CMDLINE_LINUX_DEFAULT
    GRUB_CMDLINE_LINUX_DEFAULT="\"$GRUB_CMDLINE_LINUX_DEFAULT crashkernel=$high_to_use\M,high crashkernel=$Low\M,low\""

    # replace GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub with new value
    # using seperator # because / can already exist in GRUB_CMDLINE_LINUX_DEFAULT then sed command will not work
    sed -i "s#^GRUB_CMDLINE_LINUX_DEFAULT=.*#GRUB_CMDLINE_LINUX_DEFAULT=$GRUB_CMDLINE_LINUX_DEFAULT#gI" /etc/default/grub
    ExitIfFailed $? "Enable to change parameters in /etc/default/grub"
}

# there can be 4 cases for crashkernel parameter in /pro/cmdline
# Case 1: extended kernel parameter for crashkernel
# Case 2: crashkernel parameter specify using high, low value
# Case 3: crashkernel parameter specify using only high value
# Case 4: crashkernel entry does not exist

# in Case 1 parameter can be used at it is.
# in Case 2,3,4 replace these parameter
grep "crashkernel=16G-4096G:512M,4096G-16384G:1G,16384G-32768G:2G,32768G-:3G@4G" /proc/cmdline
if [[ "$?" == "1" ]]; then # can be case 2,3,4
    # case 2,3,4
    ReplaceParamsInGrubFile
fi

# numa=off setting in kdump configuraiton file if it's
# not present already
AddNumaSettingInKdumpConfFile

# set KDUMP_SAVEDIR to file:///var/crash in /etc/sysconfig/kdump
sed -i "s#^KDUMP_SAVEDIR=\".*\"#KDUMP_SAVEDIR=\"file:\/\/\/var\/crash\"#gI" /etc/sysconfig/kdump

# set KDUMP_DUMPLEVEL to 31(recommended)
sed -i "s/^KDUMP_DUMPLEVEL=[0-9]*/KDUMP_DUMPLEVEL=31/gI" /etc/sysconfig/kdump

# set kernel.sysrq to 184(recommended)
# remove kernel.syrq entry if exist in /etc/sysctl.conf
sed -i "s/^kernel.sysrq=[0-9]*//gI" /etc/sysctl.conf
echo "kernel.sysrq=184" >> /etc/sysctl.conf
ExitIfFailed $? "Failed to set kernel.sysrq value to 184"

# update the changes in /boot/grub2/grub.cfg so that after reboot these changes reflect in /proc/cmdline
grub2-mkconfig -o /boot/grub2/grub.cfg
ExitIfFailed $? "Unable to update /boot/grub2/grub.cfg"

# stop kdump service
systemctl stop kdump.service
ExitIfFailed $? "Failed to stop kdump service"

# create new kdump initrd
mkdumprd -f
ExitIfFailed $? "Unable to create kdump initrd"

# enable kdump service so that on system reboot kdump service is automatically start
systemctl enable kdump.service
ExitIfFailed $? "Error in enabling kdump service"

echo "KDUMP is successfully enabled, please reboot the system to apply the change"
exit 0
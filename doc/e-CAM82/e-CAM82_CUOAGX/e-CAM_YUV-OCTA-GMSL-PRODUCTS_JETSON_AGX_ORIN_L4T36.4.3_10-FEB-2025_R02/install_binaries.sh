#!/bin/bash
#   Copyright (c) 2016-2019, e-con Systems India Pvt. Ltd. All rights reserved.
#
#   Script to update the Kernel Binaries and packages required in target board
#

#!/bin/bash
#LOG_LOCATION=/home/nvidia/logs/

TOTAL_ARGUMENT=$#
PRO_NAME=$1
init ()
{
	exec > >(tee  binary_installation_log.txt) 2>&1
	trap chk_exit_status ERR EXIT
	set -eu
	MAX_PLATFORMS=3 # Current platforms supported: XAVIER, ORIN, XAVIER NX
	PLATFORMS=()
	echo "============================================="
	echo " Running E-CON Installation Script "
	echo " DATE : $(date)         "
	echo "============================================="

	if [ $TOTAL_ARGUMENT == 0 ]; then
		echo -e "\033[1;31mExpecting an argument"
		echo -e "\033[0;m"
		exit 1
	fi

	if [ $PRO_NAME -ne 31 ] && [ $PRO_NAME -ne 25 ] && [ $PRO_NAME -ne 81 ]; then
		echo -e "\033[1;31mInvalid argument... This Package Support only 25, 31 and 81"
		echo -e "\033[0;m"
		exit 1
	fi

	retry=3
	while [ $retry -ne 0 ];
	do
		if [ $PRO_NAME == 31 ]; then
			echo -e "\nThis Package Supports the Below mentioned Lenses"
			echo "1. Boowan Narrow Angle Lens"
			echo "2. Boowan Wide Angle Lens"

       			read -rp "Enter the Lens which you are using :" current_lens

			if [ $current_lens -ne 1  ] && [ $current_lens -ne 2 ]; then
				echo -e "Invalid Option...\nEnter 1 for Boowan Narrow Angle or 2 for Boowan Wide Angle...."
				((retry--))
				if [ $retry == 0 ]; then
					echo "Max Invalid Attemps Reached...Try Running the package Again...."
					exit 1
				fi
					continue
			fi
		elif [ $PRO_NAME == 81 ]; then
			echo -e "\nThis Package Supports the Below mentioned Varients"
			echo "1. Four Camera Support"
			echo "2. Eight Camera Support"

       			read -rp "Enter the option to choose which varient are you using :" num_cam

			if [ $num_cam -ne 1  ] && [ $num_cam -ne 2 ]; then
				echo -e "Invalid Option...\nEnter 1 for Boowan Narrow Angle or 2 for Boowan Wide Angle...."
				((retry--))
				if [ $retry == 0 ]; then
					echo "Max Invalid Attemps Reached...Try Running the package Again...."
					exit 1
				fi
					continue
			fi
		fi
		break
	done
}

chk_exit_status ()
{
	ERR_CODE=$?
	if [ $ERR_CODE -ne 0 ]; then
		echo "Installation failed on ${FUNCNAME[1]} function at line no $(echo $(caller) | cut -d' ' -f1) with error code $ERR_CODE";
		exit 1;
	fi
}
print_release_details ()
{
	i=1;
	RELEASE_PKG_NAME="$(echo $file_name | cut -d":" -f1)";
	L4T_VERSION="$(echo $RELEASE_PKG_NAME | cut -d"_" -f3)";
	JETPACK_VER="$(echo $RELEASE_PKG_NAME | cut -d"_" -f4)";
	JETSON_PLATFORM="$(echo $RELEASE_PKG_NAME | cut -d"_" -f5)";
	while [ $i -le $MAX_PLATFORMS ]
	do
		i=`expr $i + 1`;
		CUR_PLATFORM=$(echo $JETSON_PLATFORM | cut -d"-" -f$i);
		if [ "$CUR_PLATFORM" != "" ]
		then
			PLATFORMS+=(jetson-${CUR_PLATFORM,,});
		fi
	done
	unset i;
	NO_OF_PLATFORMS=${#PLATFORMS[@]};
	RELEASE_VERSION="$(echo $RELEASE_PKG_NAME | cut -d"_" -f6 | cut -d"." -f1)";
	echo " Release Package Details :
	Release Package Name is $RELEASE_PKG_NAME
	L4T Version is $L4T_VERSION
	Jetpack Version is $JETPACK_VER
	Jetson Platforms: ${PLATFORMS[*]}
	Release Version is $RELEASE_VERSION"
}
prerequisites ()
{
	# 1. Confirm root permission to execute script
	if [[ $EUID -ne 0 ]] ; then
		echo "Kindly relaunch the script with root user privilege";
		exit 1;
	else
		echo "Running this script as root";
		echo "continue ......";
	fi

	# 2. Check integrity using md5sum
	if [ ! -e $PWD/release_integrity.md5 ] ; then
		echo "Release checksum file missing ...";
		echo "Exitting ......";
		exit 1;
	fi
	file_name=$(md5sum -c release_integrity.md5);
	if [ ! -e $PWD/$(echo $file_name | cut -d":" -f1) ] ; then
		echo "Release Package file missing ...";
		echo "Exitting ......";
		exit 1;
	fi

	# Function to print release package information
	print_release_details

	# Read L4T version onboard
	if [ -e /etc/nv_tegra_release ] ; then
		JETSON_L4T_STRING=$(cat /etc/nv_tegra_release | head -n 1 | cut -d',' -f1-2 | awk ' {print $2,$5} ' | sed 's/ /./g' | sed 's/'R'/L4T/g');
	else
		JETSON_L4T_STRING="L4T$(dpkg-query --showformat='${Version}' --show nvidia-l4t-core | cut -d'-' -f1)"
	fi

	if [ -e /etc/nv_boot_control.conf ] ; then
		CURRENT_PLATFORM_CHIPID=$(cat /etc/nv_boot_control.conf | grep "TEGRA_CHIPID" | cut -d" " -f2);
	else
		echo "/etc/nv_boot_control.conf File Missing , Exitting";
		exit 1;
	fi
	if  [ $CURRENT_PLATFORM_CHIPID == "0x23" ] ; then
		CURRENT_PLATFORM="jetson-orin";
	elif [ $CURRENT_PLATFORM_CHIPID == "0x19" ] ; then
		if [ ! -e /proc/device-tree/model ] ; then
			echo "/proc/device-tree/model File Missing , Exitting shell script";
			exit 1;
		fi
		model=$(tr -d '\0' </proc/device-tree/model);
		if [[ ${model,,} =~ "nx" ]] ; then
			CURRENT_PLATFORM="jetson-xaviernx";
		else
			CURRENT_PLATFORM="jetson-xavier";
		fi
	
	else
		echo "$CURRENT_PLATFORM is not supported";
		echo "Exitting";
		exit 1;
	fi

	# 3. Confirm L4T version and Platform details of current board , where script is running
	if [ $(uname -m) != "aarch64" ] ; then
		echo "Machine architecture mismatched, Exiting release package installation process";
		exit 1;
	else
		echo "Machine architecture matched";
	fi

	L4T_MAJOR=$(echo $L4T_VERSION | cut -d'.' -f1)
	JETSON_L4T_MAJOR=$(echo $JETSON_L4T_STRING | cut -d'.' -f1)
	if [ "$L4T_MAJOR" != "$JETSON_L4T_MAJOR" ] ; then
		echo "Device L4T version $JETSON_L4T_STRING mismatched with release package L4T version $L4T_VERSION , Exiting release package installation process";
		exit 1;
	else
		echo "L4T Version matched (minor/patch difference allowed: $L4T_VERSION vs $JETSON_L4T_STRING)";
	fi

	for i in ${PLATFORMS[@]}
	do
		if [  "$i" == "$CURRENT_PLATFORM" ] ; then
			echo "Jetson Platform matched $i";
			JETSON_PLATFORM=$i;
			return 0;
		fi
	done

	echo "Device platform $CURRENT_PLATFORM mismatched with release package. Exiting release package installation process";
	exit 1;
}

update_kernel () {
	echo "Created folder for Image backup";
	mkdir -p $HOME/Images_Backup;
	# Update kernel based on the platform decided
	if [ $JETSON_PLATFORM == "jetson-orin" ]; then
		echo "Taking backup of Kernel Image";
		cp /boot/Image $HOME/Images_Backup/;
		echo "Copying Image to device";
		cp $EXTRACTED_PATH/Kernel/Image /boot/;
		if [ $(md5sum /boot/Image | cut -d " " -f1) == $(md5sum $EXTRACTED_PATH/Kernel/Image | cut -d " " -f1) ] ; then
			echo "Kernel image updated successfully";
		else
			echo "Kernel image updated failed";
			echo "Exitting";
			exit 1;
		fi
	else
		echo "Jetson Platform is not AGX ORIN";
		echo "Exitting";
		exit 1;
	fi
}

update_devicetree () {
	# Update device tree based on the platform decided
	echo "Extracting device tree name and dtb block device to flash"
	# TBD : Have to handle multiple DTB's scenario
	if  [ $JETSON_PLATFORM == "jetson-orin" ] ; then
		echo "Copying DTB Overlay to /boot folder"
			
		if [ $PRO_NAME == "31" ] && [ $current_lens == "1" ] ; then
			echo "Copying STURDeCAM31 NARROW ANGLE DTBO & Firmware ";
			sudo cp $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_isx031_narrow_angle.dtbo /boot/ -f
			sudo cp $EXTRACTED_PATH/firmware/isx031_cam_fw_boowan_narrow.bin /usr/lib/firmware -f
			sudo cp $EXTRACTED_PATH/firmware/ISX031_STURDeCAM31_0.1.1.3.bin /usr/lib/firmware -f

		elif [ $PRO_NAME == "31" ] && [ $current_lens == "2" ] ; then
			echo "Copying STURDeCAM31 WIDE ANGLE DTBO & Firmware ";
			sudo cp $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_isx031_wide_angle.dtbo /boot/ -f
			sudo cp $EXTRACTED_PATH/firmware/isx031_cam_fw_boowan_wide.bin /usr/lib/firmware -f
			sudo cp $EXTRACTED_PATH/firmware/ISX031_STURDeCAM31_0.1.2.1.bin /usr/lib/firmware -f

		elif [ $PRO_NAME == "81" ] && [ $num_cam == "1" ] ; then
			echo "Copying STURDeCAM81 FOUR CAM DTBO & Firmware ";
			sudo cp $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_ar0821_four_lane_four_cam.dtbo  /boot/ -f
			sudo cp $EXTRACTED_PATH/firmware/ar0821_cam_fw.bin /usr/lib/firmware -f

		elif [ $PRO_NAME == "81" ] && [ $num_cam == "2" ] ; then
			echo "Copying STURDeCAM81 EIGHT CAM DTBO & Firmware ";
			sudo cp $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_ar0821_four_lane.dtbo /boot/ -f
			sudo cp $EXTRACTED_PATH/firmware/ar0821_cam_fw.bin /usr/lib/firmware -f
		
		elif [ $PRO_NAME == "25" ] ; then
			echo "Copying STURDeCAM25 CAM DTBO & Firmware ";			
			sudo cp $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_ar0234_four_lane.dtbo /boot/ -f
			sudo cp $EXTRACTED_PATH/firmware/ar0234_cam_fw.bin /usr/lib/firmware -f
		
		else
			echo "Error in DTBO & Firmware copy Invalid Product!!!";
			exit 1;
		fi

	elif [ $JETSON_PLATFORM == "jetson-xavier" ] ; then
		#DTB_NAME=$(basename $(find $PWD/$EXTRACTED_PATH/Kernel/ -iname kernel_tegra194-p2888*));
		#DTB_DEVICE=$(readlink -f /dev/disk/by-partlabel/kernel-dtb);
		sudo cp /boot/dtb/kernel_tegra194-p2888-0001-p2822-0000.dtb $HOME/Images_Backup/kernel_tegra194-p2888-0001-p2822-0000.dtb
		echo "Copying device-tree to /boot/dtb/ folder"
		sudo cp $PWD/misc/tegra194-p2888-0001-p2822-0000-* /boot/dtb/kernel_tegra194-p2888-0001-p2822-0000.dtb -f
	elif [ $JETSON_PLATFORM == "jetson-xaviernx" ] ; then
		DTB_NAME=$(basename $(find $PWD/$EXTRACTED_PATH/Kernel/ -iname tegra194-p3668*));
		DTB_DEVICE=$(readlink -f /dev/disk/by-partlabel/kernel-dtb);
		DTB_DEVICE_B=$(readlink -f /dev/disk/by-partlabel/kernel-dtb_b);
	fi
	echo "Checking md5sum for dtbo file";
	if [ $JETSON_PLATFORM == "jetson-orin" ] ; then
		if [ $PRO_NAME == "31" ] && [ $current_lens == "1" ] ; then
			echo " checking md5sum of dtbo ";
			if [ $(md5sum $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_isx031_narrow_angle.dtbo | cut -d " " -f1) == $(md5sum /boot/tegra234-p3737-camera-overlay_ecam_isx031_narrow_angle.dtbo | cut -d " " -f1) ] ; then
				fdtdump /boot/tegra234-p3737-camera-overlay_ecam_isx031_narrow_angle.dtbo > $HOME/as
				sudo /opt/nvidia/jetson-io/config-by-hardware.py -n 2="$(echo $(cat $HOME/as |  grep -i "overlay-name") | cut -d '"' -f2 )";
				echo "Kernel dtbo updated successfully";
			else
				echo "DTBO checksum Failed";
				echo "Exiting";
				exit 1;
			fi
			
		elif [ $PRO_NAME == "31" ] && [ $current_lens == "2" ] ; then
			echo " checking md5sum of dtbo ";
			if [ $(md5sum $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_isx031_wide_angle.dtbo  | cut -d " " -f1) == $(md5sum /boot/tegra234-p3737-camera-overlay_ecam_isx031_wide_angle.dtbo  | cut -d " " -f1) ] ; then
				sudo fdtdump /boot/tegra234-p3737-camera-overlay_ecam_isx031_wide_angle.dtbo  > $HOME/as
				sudo /opt/nvidia/jetson-io/config-by-hardware.py -n 2="$(echo $(cat $HOME/as |  grep -i "overlay-name") | cut -d '"' -f2 )";
				echo "Kernel dtbo updated successfully";
			else
				echo "DTBO checksum Failed";
				echo "Exiting";
				exit 1;
			fi
		
		elif [ $PRO_NAME == "81" ] && [ $num_cam == "1" ] ; then
			echo " checking md5sum of dtbo ";
			if [ $(md5sum $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_ar0821_four_lane_four_cam.dtbo  | cut -d " " -f1) == $(md5sum /boot/tegra234-p3737-camera-overlay_ecam_ar0821_four_lane_four_cam.dtbo  | cut -d " " -f1) ] ; then
				fdtdump /boot/tegra234-p3737-camera-overlay_ecam_ar0821_four_lane_four_cam.dtbo  > $HOME/as
				sudo /opt/nvidia/jetson-io/config-by-hardware.py -n 2="$(echo $(cat $HOME/as |  grep -i "overlay-name") | cut -d '"' -f2 )";
				echo "Kernel dtbo updated successfully";
			else
				echo "DTBO checksum Failed";
				echo "Exiting";
				exit 1;
			fi
				
		elif [ $PRO_NAME == "81" ] && [ $num_cam == "2" ] ; then
			echo " checking md5sum of dtbo ";
			if [ $(md5sum $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_ar0821_four_lane.dtbo  | cut -d " " -f1) == $(md5sum /boot/tegra234-p3737-camera-overlay_ecam_ar0821_four_lane.dtbo  | cut -d " " -f1) ] ; then
				fdtdump /boot/tegra234-p3737-camera-overlay_ecam_ar0821_four_lane.dtbo  > $HOME/as
				sudo /opt/nvidia/jetson-io/config-by-hardware.py -n 2="$(echo $(cat $HOME/as |  grep -i "overlay-name") | cut -d '"' -f2 )";
				echo "Kernel dtbo updated successfully";
			else
				echo "DTBO checksum Failed";
				echo "Exiting";
				exit 1;
			fi	
		elif [ $PRO_NAME == "25" ] ; then
			echo " checking md5sum of dtbo ";
			if [ $(md5sum $EXTRACTED_PATH/Kernel/tegra234-p3737-camera-overlay_ecam_ar0234_four_lane.dtbo  | cut -d " " -f1) == $(md5sum /boot/tegra234-p3737-camera-overlay_ecam_ar0234_four_lane.dtbo  | cut -d " " -f1) ] ; then
				fdtdump /boot/tegra234-p3737-camera-overlay_ecam_ar0234_four_lane.dtbo  > $HOME/as
				sudo /opt/nvidia/jetson-io/config-by-hardware.py -n 2="$(echo $(cat $HOME/as |  grep -i "overlay-name") | cut -d '"' -f2 )";
				echo "Kernel dtbo updated successfully";
			else
				echo "DTBO checksum Failed";
				echo "Exiting";
				exit 1;
			fi	
		else
			echo "Error in DTBO copy Invalid Product!!!";
			exit 1;
		fi

	elif [ $JETSON_PLATFORM == "jetson-xavier" ] ; then
		if [ $(md5sum $PWD/misc/tegra194-p2888-0001-p2822-0000-* | cut -d " " -f1) == $(md5sum /boot/dtb/kernel_tegra194-p2888-0001-p2822-0000.dtb | cut -d " " -f1) ] ; then
			echo "Kernel dtb updated successfully";
		else
			echo "DTB checksum Failed";
			echo "Exiting";
			exit 1;
		fi
	fi

	echo "Device Tree updated successfully";
}
update_modules () {
	JP_VER=$(echo $JETPACK_VER | cut -c 3-7 )
	if [ $JP_VER == "6.2.0" ] ;then
		KERNEL_VER=$(uname -r)
		mkdir -p /lib/modules/${KERNEL_VER}/updates/drivers/media/i2c
		mkdir -p /lib/modules/${KERNEL_VER}/updates/drivers/media/platform/tegra/camera
		mkdir -p /lib/modules/${KERNEL_VER}/updates/drivers/platform/tegra/rtcpu
		sudo cp $EXTRACTED_PATH/Kernel/max96712.ko /lib/modules/${KERNEL_VER}/updates/drivers/media/i2c
		sudo cp $EXTRACTED_PATH/Kernel/mcu_pwm.ko /lib/modules/${KERNEL_VER}/updates
		sudo cp $EXTRACTED_PATH/Kernel/ecam_gmsl_yuv_common.ko /lib/modules/${KERNEL_VER}/updates
		sudo cp $EXTRACTED_PATH/Kernel/tegra-camera.ko /lib/modules/${KERNEL_VER}/updates/drivers/media/platform/tegra/camera
		sudo cp $EXTRACTED_PATH/Kernel/tegra-camera-rtcpu.ko /lib/modules/${KERNEL_VER}/updates/drivers/platform/tegra/rtcpu
	elif (($(echo "$JP_VER < 4.6" | bc -q ))) ;then
		sudo tar -xpmf $EXTRACTED_PATH/Kernel/kernel_supplements.tar.bz2 -C /
	else
		sudo tar -xpmf $EXTRACTED_PATH/Kernel/kernel_supplements.tar.bz2 -C /usr
	fi
	echo "Modules updated successfully";
}
application_installation ()
{
	if [ -d $EXTRACTED_PATH/Application/Binaries/eCAM_argus_camera/ ] ; then
		ISP_PRD="yes";
	else
		ISP_PRD="no";
	fi

	# 1. Install deb packages
	if [ -d $EXTRACTED_PATH/Application/Dependency/ ] ; then
		echo "Install Debian Packages";
		if [ $ISP_PRD == "no" ]; then
			rm -f /var/lib/dpkg/lock*
			sudo dpkg --remove --force-all libjack-jackd2-0:arm64
		fi
		pushd $EXTRACTED_PATH/Application/Dependency/
		rm -f /var/lib/dpkg/lock*
		sudo dpkg -i --force-all *.deb
		echo " Application dependency Installed Successfully"
		popd

		# Installing wmctrl to lauch e-multicam application in JP6
		rm -r val/lib/apt/lists/lock -f
		sudo apt-get update -y
		sudo apt --fix-broken install -y
		sudo apt-get install -y nvidia-l4t-gstreamer
		sudo apt-get install -y wmctrl	
	fi
	
	# 2. Copy Application Binaries to rootfs
	if [ $ISP_PRD == "yes" ] ; then
		echo "Installing eCAM_argus_camera Application Binary for ISP camera";
		cp $EXTRACTED_PATH/Application/Binaries/eCAM_argus_camera/* /usr/local/bin/

		if [ -d $EXTRACTED_PATH/Application/Binaries/eCAM_Argus_MultiCamera/ ] ; then
			echo "Installing eCAM_Argus_MultiCamera Application Binary for ISP camera";
			cp $EXTRACTED_PATH/Application/Binaries/eCAM_Argus_MultiCamera/* /usr/local/bin/
		fi
	else
		echo "Installing ecam_tk1_guvcview Application for non-isp cameras";
		pushd $EXTRACTED_PATH/Application/Binaries/ecam_tk1_guvcview/aarch64
		sudo ./install-sh
		# Remove older configuration files for guvcview
		rm -rf $HOME/.config/guvcview/
		echo 'export PATH=$PATH:/usr/local/ecam_tk1/bin' >> $HOME/.bashrc
		export PATH=$PATH:/usr/local/ecam_tk1/bin
		popd
		if [ -d $EXTRACTED_PATH/Application/Binaries/e-multicam/ ] ; then
			echo "Installing e-multicam Application for non-isp cameras";
			cp $EXTRACTED_PATH/Application/Binaries/e-multicam/e-multicam.elf /usr/local/bin/
		fi
	fi
}

package_extraction () {

	if [ -e $RELEASE_PKG_NAME ] ; then
		EXTRACTED_PATH=$(echo $RELEASE_PKG_NAME | cut -d"." -f-5);
		if [ -d $EXTRACTED_PATH ] ; then
			echo "Delete already extracted package and redo package extraction";
			rm -rf $EXTRACTED_PATH
		fi
		echo "Extracting release package"
		tar -xmf $RELEASE_PKG_NAME
	fi

	if [ $JETSON_PLATFORM == "jetson-orin" ] || [ $JETSON_PLATFORM == "jetson-xavier" ] || [ $JETSON_PLATFORM == "jetson-xaviernx" ];then
		EXTRACTED_PATH=$EXTRACTED_PATH/AGX_ORIN
	fi
}

misc_installation () {
	echo "Updating misc files";
	echo 'export LD_PRELOAD=/usr/lib/aarch64-linux-gnu/nvidia/libnvjpeg.so' >> ~/.bashrc
	export LD_PRELOAD=/usr/lib/aarch64-linux-gnu/nvidia/libnvjpeg.so
	if [ $ISP_PRD = "yes" ] ; then
		if [ -e $EXTRACTED_PATH/misc/camera_overrides_$JETSON_PLATFORM.isp ] ; then
			echo "Copy ISP settings to rootfs /var/nvidia/nvcam/settings ";
			cp $EXTRACTED_PATH/misc/camera_overrides_$JETSON_PLATFORM.isp /var/nvidia/nvcam/settings/camera_overrides.isp;
			echo "permissions and ownerships as recommended by nvidia for isp_settings file";
			chmod 664 /var/nvidia/nvcam/settings/camera_overrides.isp;
			chown root:root /var/nvidia/nvcam/settings/camera_overrides.isp;
		else
			echo "ISP overrides file missing. Exiting";
			exit 1;
		fi

		if [ -e $EXTRACTED_PATH/misc/libnvscf.so ] ; then
			echo "Update nvscf library ";
			cp $EXTRACTED_PATH/misc/libnvscf.so /usr/lib/aarch64-linux-gnu/tegra/libnvscf.so;
			echo "permissions and ownerships as recommended by nvidia for library file";
			chmod 755 /usr/lib/aarch64-linux-gnu/tegra/libnvscf.so;
			chown root:root /usr/lib/aarch64-linux-gnu/tegra/libnvscf.so;
		fi

		if [ -e $EXTRACTED_PATH/misc/max-isp-vi-clks.sh ] ; then
			echo "Copy max-isp-vi-clks.sh script for isp camera"
			cp $EXTRACTED_PATH/misc/max-isp-vi-clks.sh $HOME/ -f
			chmod +x $HOME/max-isp-vi-clks.sh
			cp $PWD/misc/max-isp-vi-clks.sh /etc/systemd/max-isp-vi-clks.sh
			cp $PWD/misc/nvmaxclocks.service /etc/systemd/system/nvmaxclocks.service
			chown root:root  /etc/systemd/system/nvmaxclocks.service
			sleep 1
			systemctl daemon-reload
			systemctl enable nvmaxclocks.service
			systemctl start nvmaxclocks.service
		fi
	else
		if [ $JETSON_PLATFORM == "jetson-xavier" ] ; then
			if [ -e $EXTRACTED_PATH/misc/xorg.conf.t194_ref ] ; then
				echo "Copying updated xorg.conf.t194_ref file";
				cp $EXTRACTED_PATH/misc/xorg.conf.t194_ref /etc/X11/;
			fi
		fi
	fi
	if [ -e $EXTRACTED_PATH/misc/modules ] ; then
		echo "copying updated /etc/modules file for e-con camera driver onboot load process";
		cp $EXTRACTED_PATH/misc/modules /etc/modules -f;
	fi

	if [ -e $EXTRACTED_PATH/misc/v4l2-compliance ] ; then
		echo "copying Nvidia v4l2-compliance file.";
		cp $EXTRACTED_PATH/misc/v4l2-compliance /usr/local/bin/;
	fi

	echo " Updated misc files successfully";

}
device_reboot() {
	if [ -f "$HOME/as" ]; then
		sudo rm $HOME/as
	fi
	sudo depmod -a

	echo "Sync 'ing : writing cached data to disk";
	sync;
	echo "Going to reboot the device ....";
	sleep 5;
	echo "Rebooting the device .....";
	reboot;

}

usage() {
	echo -e "usage: $0 [options]..."
    	echo -e "update kernel, DTB, modules and install binary packages\n"
    	echo -e "-d\t-\tDTB overwrite (optional)\n"
}

if [ $# -lt 2 ]
then
	init
	#1. Sanity check
   	prerequisites
    	#2. Release package extraction
    	package_extraction
    	#3. Kernel Binaries Installation
    	#update_kernel
    	update_devicetree
    	update_modules
    	#4. Application Binaries Installation
    	application_installation;
    	#5. Miscellenaous file upgrades for e-con cameras
    	misc_installation;
    	#6. Rebooting device to boot with installed binaries
    	device_reboot
    	exit 0
fi

while getopts 'd?h' opt
do
    case $opt in
        
        d)
		init
		#1. Sanity check
	   	prerequisites
	    	#2. Release package extraction
	    	package_extraction
	    	#3. Kernel Binaries Installation
	    	update_devicetree
	    	#4. Rebooting device to boot with changed DTB
	    	device_reboot

	    ;;
	h|?) usage; exit 2 ;;
    esac
done

shift "$((OPTIND - 1))"

# Copyright (c) 2015 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.

# This file is a part of the Armbian build script
# https://github.com/armbian/build/

# Functions:
# install_common
# install_distribution_specific
# post_debootstrap_tweaks

install_common()
{
	display_alert "Applying common tweaks" "" "info"

	# add dummy fstab entry to make mkinitramfs happy
	echo "/dev/mmcblk0p1 / $ROOTFS_TYPE defaults 0 1" >> $SDCARD/etc/fstab

	# create modules file
	if [[ $BRANCH == dev && -n $MODULES_DEV ]]; then
		tr ' ' '\n' <<< "$MODULES_DEV" > $SDCARD/etc/modules
	elif [[ $BRANCH == next || $BRANCH == dev ]]; then
		tr ' ' '\n' <<< "$MODULES_NEXT" > $SDCARD/etc/modules
	else
		tr ' ' '\n' <<< "$MODULES" > $SDCARD/etc/modules
	fi

	# create blacklist files
	if [[ $BRANCH == dev && -n $MODULES_BLACKLIST_DEV ]]; then
		tr ' ' '\n' <<< "$MODULES_BLACKLIST_DEV" | sed -e 's/^/blacklist /' > $SDCARD/etc/modprobe.d/blacklist-${BOARD}.conf
	elif [[ ($BRANCH == next || $BRANCH == dev) && -n $MODULES_BLACKLIST_NEXT ]]; then
		tr ' ' '\n' <<< "$MODULES_BLACKLIST_NEXT" | sed -e 's/^/blacklist /' > $SDCARD/etc/modprobe.d/blacklist-${BOARD}.conf
	elif [[ $BRANCH == default && -n $MODULES_BLACKLIST ]]; then
		tr ' ' '\n' <<< "$MODULES_BLACKLIST" | sed -e 's/^/blacklist /' > $SDCARD/etc/modprobe.d/blacklist-${BOARD}.conf
	fi

	# remove default interfaces file if present
	# before installing board support package
	rm -f $SDCARD/etc/network/interfaces

	mkdir -p $SDCARD/selinux

	# console fix due to Debian bug
	sed -e 's/CHARMAP=".*"/CHARMAP="'$CONSOLE_CHAR'"/g' -i $SDCARD/etc/default/console-setup

	# change time zone data
	echo $TZDATA > $SDCARD/etc/timezone
	chroot $SDCARD /bin/bash -c "dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1"

	# set root password
	chroot $SDCARD /bin/bash -c "(echo $ROOTPWD;echo $ROOTPWD;) | passwd root >/dev/null 2>&1"
	# force change root password at first login
	chroot $SDCARD /bin/bash -c "chage -d 0 root"

	# display welcome message at first root login
	touch $SDCARD/root/.not_logged_in_yet

	# NOTE: this needs to be executed before family_tweaks
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}
	cp $SRC/config/bootscripts/$bootscript_src $SDCARD/boot/$bootscript_dst

	[[ -n $BOOTENV_FILE && -f $SRC/config/bootenv/$BOOTENV_FILE ]] && \
		cp $SRC/config/bootenv/$BOOTENV_FILE $SDCARD/boot/armbianEnv.txt

	# TODO: modify $bootscript_dst or armbianEnv.txt to make NFS boot universal
	# instead of copying sunxi-specific template
	if [[ $ROOTFS_TYPE == nfs ]]; then
		display_alert "Copying NFS boot script template"
		if [[ -f $SRC/userpatches/nfs-boot.cmd ]]; then
			cp $SRC/userpatches/nfs-boot.cmd $SDCARD/boot/boot.cmd
		else
			cp $SRC/config/templates/nfs-boot.cmd.template $SDCARD/boot/boot.cmd
		fi
	fi

	[[ -n $OVERLAY_PREFIX && -f $SDCARD/boot/armbianEnv.txt ]] && \
		echo "overlay_prefix=$OVERLAY_PREFIX" >> $SDCARD/boot/armbianEnv.txt

	# initial date for fake-hwclock
	date -u '+%Y-%m-%d %H:%M:%S' > $SDCARD/etc/fake-hwclock.data

	echo $HOST > $SDCARD/etc/hostname

	# set hostname in hosts file
	cat <<-EOF > $SDCARD/etc/hosts
	127.0.0.1   localhost $HOST
	::1         localhost $HOST ip6-localhost ip6-loopback
	fe00::0     ip6-localnet
	ff00::0     ip6-mcastprefix
	ff02::1     ip6-allnodes
	ff02::2     ip6-allrouters
	EOF

	display_alert "Installing kernel" "$CHOSEN_KERNEL" "info"
	chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1

	display_alert "Installing u-boot" "$CHOSEN_UBOOT" "info"
	chroot $SDCARD /bin/bash -c "DEVICE=/dev/null dpkg -i /tmp/debs/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1

	display_alert "Installing headers" "${CHOSEN_KERNEL/image/headers}" "info"
	chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/${CHOSEN_KERNEL/image/headers}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1

	# install firmware
	#if [[ -f $SDCARD/tmp/debs/${CHOSEN_KERNEL/image/firmware-image}_${REVISION}_${ARCH}.deb ]]; then
	#	display_alert "Installing firmware" "${CHOSEN_KERNEL/image/firmware-image}" "info"
	#	chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/${CHOSEN_KERNEL/image/firmware-image}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1
	#fi

	if [[ -f $SDCARD/tmp/debs/armbian-firmware_${REVISION}_${ARCH}.deb ]]; then
		display_alert "Installing generic firmware" "armbian-firmware" "info"
		chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/armbian-firmware_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1
	fi

	if [[ -f $SDCARD/tmp/debs/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb ]]; then
		display_alert "Installing DTB" "${CHOSEN_KERNEL/image/dtb}" "info"
		chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1
	fi

	# install board support package
	display_alert "Installing board support package" "$BOARD" "info"
	chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/$RELEASE/${CHOSEN_ROOTFS}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1

	# freeze armbian packages
	if [[ $BSPFREEZE == "yes" ]]; then
		display_alert "Freeze armbian packages" "$BOARD" "info"
		if [[ "$BRANCH" != "default" ]]; then MINIBRANCH="-"$BRANCH; fi
		chroot $SDCARD /bin/bash -c "apt-mark hold ${CHOSEN_KERNEL} ${CHOSEN_KERNEL/image/headers} \
		linux-u-boot-${BOARD}-${BRANCH} linux-dtb${MINIBRANCH}-${LINUXFAMILY}" >> $DEST/debug/install.log 2>&1
	fi

	# copy boot splash images
	cp $SRC/packages/blobs/splash/armbian-u-boot.bmp $SDCARD/boot/boot.bmp
	cp $SRC/packages/blobs/splash/armbian-desktop.png $SDCARD/boot/boot-desktop.png

	# execute $LINUXFAMILY-specific tweaks
	[[ $(type -t family_tweaks) == function ]] && family_tweaks

	# enable additional services
	chroot $SDCARD /bin/bash -c "systemctl --no-reload enable firstrun.service resize2fs.service armhwinfo.service log2ram.service >/dev/null 2>&1"

	# copy "first run automated config, optional user configured"
 	cp $SRC/config/armbian_first_run.txt $SDCARD/boot/armbian_first_run.txt

	# switch to beta repository at this stage if building nightly images
	[[ $IMAGE_TYPE == nightly ]] && echo "deb http://beta.armbian.com $RELEASE main utils ${RELEASE}-desktop" > $SDCARD/etc/apt/sources.list.d/armbian.list

	# disable low-level kernel messages for non betas
	# TODO: enable only for desktop builds?
	if [[ -z $BETA ]]; then
		sed -i "s/^#kernel.printk*/kernel.printk/" $SDCARD/etc/sysctl.conf
	fi

	# enable getty on serial console
	chroot $SDCARD /bin/bash -c "systemctl --no-reload enable serial-getty@$SERIALCON.service >/dev/null 2>&1"

	[[ $LINUXFAMILY == sun*i ]] && mkdir -p $SDCARD/boot/overlay-user

	# to prevent creating swap file on NFS (needs specific kernel options)
	# and f2fs/btrfs (not recommended or needs specific kernel options)
	[[ $ROOTFS_TYPE != ext4 ]] && touch $SDCARD/var/swap

	# install initial asound.state if defined
	mkdir -p $SDCARD/var/lib/alsa/
	[[ -n $ASOUND_STATE ]] && cp $SRC/config/$ASOUND_STATE $SDCARD/var/lib/alsa/asound.state

	# save initial armbian-release state
	cp $SDCARD/etc/armbian-release $SDCARD/etc/armbian-image-release

	# premit root login via SSH for the first boot
	sed -i 's/#\?PermitRootLogin .*/PermitRootLogin yes/' $SDCARD/etc/ssh/sshd_config
}

install_distribution_specific()
{
	display_alert "Applying distribution specific tweaks for" "$RELEASE" "info"
	case $RELEASE in
	jessie)
		;;

	xenial)
		# remove legal info from Ubuntu
		[[ -f $SDCARD/etc/legal ]] && rm $SDCARD/etc/legal

		# disable not working on unneeded services
		# ureadahead needs kernel tracing options that AFAIK are present only in mainline
		chroot $SDCARD /bin/bash -c "systemctl --no-reload mask ondemand.service ureadahead.service setserial.service etc-setserial.service >/dev/null 2>&1"
		;;

	stretch)
		# remove doubled uname from motd
		[[ -f $SDCARD/etc/update-motd.d/10-uname ]] && rm $SDCARD/etc/update-motd.d/10-uname
		;;
	esac
}

post_debootstrap_tweaks()
{
	# remove service start blockers and QEMU binary
	rm -f $SDCARD/sbin/initctl $SDCARD/sbin/start-stop-daemon
	chroot $SDCARD /bin/bash -c "dpkg-divert --quiet --local --rename --remove /sbin/initctl"
	chroot $SDCARD /bin/bash -c "dpkg-divert --quiet --local --rename --remove /sbin/start-stop-daemon"
	rm -f $SDCARD/usr/sbin/policy-rc.d $SDCARD/usr/bin/$QEMU_BINARY

	# reenable resolvconf managed resolv.conf
	ln -sf /run/resolvconf/resolv.conf $SDCARD/etc/resolv.conf
}

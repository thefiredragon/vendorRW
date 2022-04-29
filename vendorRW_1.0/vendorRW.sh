#!/system/bin/sh

# global variables
app="vendorRW"
version="1.0"

mnttmppath=/vendortmp
mntvpath=/vendor
LOC="/data/local/tmp/"$app"_"$version
logDir="$LOC/log";pDumpDir="$LOC/nosuper";sDumpDir="$LOC/img"
mkdir -p $logDir $pDumpDir $sDumpDir
currentSlot=0
lpdumpPath="$logDir/lpdump.txt"
stvendor="$sDumpDir/vendor.img"
tmpimage="$sDumpDir/vendor_fixed.bin"
superFixedPath="$sDumpDir/super_fixed.bin"
toolsdir="$LOC/tools"

ui_print " --------------------------------------------------\n"
ui_print "| VendorRW automated script by thefiredragon,     |\n"
ui_print "| Ian Macdonald and Afaneh                        |\n"
ui_print "| This script only support f2fs filesystems       |\n"
ui_print "|-------------------------------------------------|\n"
ui_print "|-------------------------------------------------|\n"
ui_print "| Prepairing new vendor image                     |\n"
ui_print " --------------------------------------------------\n\n"

echo " "
ui_print "$app: Please format your data partition before running this script\n"
echo " "
ui_print "$app: Start in 10 seconds...\n"
sleep 10

# find vendor block-device
ui_print "$app: Mount vendor\n"
mount | grep vendor > /dev/null 2>&1 || mount /vendor ;
vblockdev=$(df -t f2fs | grep "/vendor" | cut -DF1)

os=$(getprop ro.build.version.release)
major=${os%%.*}
bl=$(getprop ro.boot.bootloader)
dp=$(getprop ro.boot.dynamic_partitions)
vendorPath=`ls -l /dev/block/mapper/vendor 2>/dev/null | awk '{print $NF}'`
blkid=$($toolsdir/toybox blkid $vendorPath | egrep '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' -o)


# Firmware version starts at either 8th or 9th character, depending on length
# of bootloader string (12 or 13).
#
fw=${bl:$((${#bl} - 4)):4}

# Device is first 5 characters of bootloader string.
#
device=${bl:0:$((${#bl} - 8))}
mft=$(getprop ro.product.manufacturer)


if [ -z "$vblockdev" ]; then
  ui_print "$app: Vendor partition is not f2fs.\n\n"
  fatal=true
elif [ $major -lt 9 ]; then
  ui_print "$app: This software is incompatible with Android\n\n" $major
  fatal=true
fi
if [ -n "$fatal" ]; then
  ui_print "$app: Installation aborted.\n\n"
  exit 1
fi

#ui_print "$app: Detected a $device device with a $fw bootloader.\n"
ui_print "$app: The environment appears to be Android $major.\n\n"

## make sure partitions are unmounted
umount $mntvpath > /dev/null 2>&1
umount $mnttmppath > /dev/null 2>&1

ui_print "$app: Dumped UUID from $vendorPath UUID=$blkid \n\n"
ui_print "$app: Create new vendor image without write protection...\n"

## Create a new rw f2fs image and allocate more space for copy, looks like compression is not working.
## Temp image is much larger instead of the original one, so we need later to create a new super img to resize all partitions accurately.
## Also we need to find a way to shrink the filesystem and image to save space 
truncate -s 2600M $tmpimage || { echo 'create image failed' ; exit 1; }
make_f2fs -l vendor -O extra_attr,inode_checksum,sb_checksum,compression -U $blkid $tmpimage -f > /dev/null 2>&1  || { echo 'create image failed' ; exit 1; }

ui_print "$app: Mounting vendor images...\n"

mount $mntvpath
mkdir -p $mnttmppath
mount -o compress_algorithm=lz4,active_logs=2 $tmpimage $mnttmppath
chattr -R +c $mnttmppath

ui_print "$app: Sync vendor to new image...\n"

cp -rp $mntvpath/* $mnttmppath || { echo 'sync failed' ; exit 1; }

ui_print "$app: Unmounting and check new vendor image...\n"

umount $mntvpath
umount $mnttmppath
#resize.f2fs $tmpimage > /dev/null 2>&1 || { echo 'resize failed' ; exit 1; }
fsck.f2fs -f $tmpimage > /dev/null 2>&1  || { echo 'fsck failed' ; exit 1; }

echo " "
ui_print "$app: Created new vendor image $tmpimage\n"
echo " "


ui_print " --------------------------------------------------\n"
ui_print "| Creating new super image...                     |\n"
ui_print " --------------------------------------------------\n\n"

setGlobalVars(){
    superPath=`ls -l /dev/block/by-name/super 2>/dev/null | awk '{print $NF}'`
    if [ -n "$superPath" ]; then
        sDumpTarget=$sDumpDir"/super_original.bin"
        superFixedPath=$sDumpDir"/super_fixed.bin"
    else
        ui_print "$app: Error: Failed to dump file to: %s\n\n"
        exit 1
    fi
}

dumpFile(){
    setGlobalVars
    cleanUp "$pDumpDir/*.img"
        ui_print "$app: Dumping super partition to:  $sDumpTarget\n"
        ui_print "$app: Please wait patiently...\n\n"
        if ( dd if=$superPath of=$sDumpTarget 2>&1 ); then
            ui_print "$app: Successfully dumped super partition to: $sDumpTarget\n"
        else
            ui_print "$app: Error: failed to find super partition\n\n"; exit 1
        fi    
}


lpUnpack(){
    setGlobalVars
    ui_print "$app: Unpacking embedded partitions from $sDumpTarget\n"
    cleanUp "$sDumpDir/*.img"
    if ( $toolsdir/lpunpack --slot=$currentSlot $sDumpTarget $sDumpDir ); then
        if ( ! ls -1 $sDumpDir/*.img>/dev/null ); then
            ui_print "$app: Unable to locate extracted partitions. Please try again.\n\n"
            exit 1
        else
            ui_print "$app: Nested partitions were successfully extracted from super\n\n"
        fi
    fi
}

countGroups(){
    for i in `tac $lpdumpPath | grep -F -m 3 "Name:" -B 1 | awk '!/^-/ {n=$(NF-1); getline; print n "|" $NF}'`; do
        grpSize=${i//|*}
        grpName=${i//*|}
        if [[ "$grpName" == "default" ]]; then
            break
        fi
        if [[ "$grpName" != *"cow"* && "$grpSize" != 0 ]]; then echo -n "--group $grpName:$grpSize ">>$myArgsPath; fi #else cow=1
    done
}

getCurrentSize(){
    currentSize=$(wc -c < $1)
    currentSizeMB=$(echo $currentSize | awk '{print int($1 / 1024 / 1024)}')
    currentSizeBlocks=$(echo $currentSize | awk '{print int($1 / 512)}')
    if [ -z "$2" ]; then
        ui_print "$app: Current size of $fiName in bytes: $currentSize\n"
        ui_print "$app: Current size of $fiName in MB: $currentSizeMB\n"
        ui_print "$app: Current size of $fiName in 512-byte sectors: $currentSizeBlocks\n\n"
    fi
}

makeSuper(){
    #superFixedPath=$sDumpDir"/super_fixed.bin"
    myArgsPath="$logDir/myargs.txt"
    slotCount=$(grep -F -m 1 "slot" $lpdumpPath | awk '{print $NF}')
    echo -n "--metadata-size 65536 --super-name super --sparse --metadata-slots $slotCount ">$myArgsPath
    superSize=$(grep -F -m 1 "Size:" $lpdumpPath | awk '{print $2}')
    echo -n "--device super:$superSize ">>$myArgsPath
    countGroups
    imgCount=$(ls $sDumpDir | grep -c ".img" | awk '{print $1 * 2}')
    for o in `grep -E -m $imgCount "Name:|Group:" $lpdumpPath | awk '{ n = $NF ; getline ; print n "|" $NF }'`; do
        imgName=${o//|*}
        groupName=${o//*|}
        fName="$sDumpDir/$imgName.img"
        getCurrentSize $fName 1
        if [[ "$currentSize" > 0 && "$groupName" != *"cow"* ]]; then
            echo -n "--partition $imgName:none:$currentSize:$groupName ">>$myArgsPath
            echo -n "--image $imgName=$fName ">>$myArgsPath
        fi
    done
    echo -n "--output $superFixedPath">>$myArgsPath
    ui_print "$app: Joining all extracted images back into one single super image...\n"
    ui_print "$app: Please wait and ignore the invalid sparse warnings...\n\n"
    myArgs=$(cat "$logDir/myargs.txt")
    if ( $toolsdir/lpmake $myArgs 2>&1 ); then
        #rm -f $myArgsPath
        ui_print "$app: Successfully created patched super image @realpath $superFixedPath\n"
    else
        ret=$?
        dmesg > $logDir/dmesg.txt
        ui_print "$app: Error! failed to create super_fixed.img file. Error code: $ret\n"
        exit 1
    fi
}

patchVendor(){
    ui_print "$app: Replacing vendor image $stvendor\n"
    rm $stvendor
    cp -v $tmpimage $stvendor > /dev/null 2>&1
}

cleanUp(){
    for file in $1; do
        rm -f $file
    done
}

flash(){
    echo " "
    ui_print " --------------------------------------------------\n"
    ui_print "| Flashing new super image...                     |\n"
    ui_print " --------------------------------------------------\n\n"
    setGlobalVars
    ui_print "$app: Flashing $superFixedPath to $superPath\n"
    ui_print "$app: Don't interrupt this process or you risk brick! Please wait...\n"
    if ( ! $toolsdir/simg2img $superFixedPath $superPath ); then
        ui_print "$app: There was a problem flashing image to partition. Please try again\n\n"
        exit 1
    else
        ui_print "$app: Successfully flashed $superFixedPath to $superPath\n" 
        ui_print "$app: Please reboot recovery\n"
        ui_print "$app: After reboot run multidisabler\n\n"
        sleep 10

    fi
    ui_print "=================================================\n\n"
}

$toolsdir/lpdump --slot=$currentSlot > $lpdumpPath
dumpFile  | tee "$logDir/dump.txt"
lpUnpack  | tee "$logDir/lpunpack.txt"
patchVendor | tee "$logDir/lpunpack.txt"
makeSuper | tee "$logDir/makeSuper.txt"
flash     | tee "$logDir/flash.txt"
## vendorRW 
vendorRW disable write protection f2fs ro partitions.


## How it works

```sh
vendorRW create a new vendor image without write protection.
All partitions need to be dumped to resize vendor size.
At the moment I cant get compression working, so we need to resize the partitions and create a new super image.
f2fs support ro flags which cant be removed.
```

## Install

```
TWRP
format data
flash vendorRW_1.0.zip
dont interrupt the this process or you need to flash stock image via odin

after reboot try multidisabler to remove samsungs protection
```

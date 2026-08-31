# scripts
scripts



sudo ./setupAfterInstall.sh 

We trust you have received the usual lecture from the local System
Administrator. It usually boils down to these three things:

    #1) Respect the privacy of others.
    #2) Think before you type.
    #3) With great power comes great responsibility.

For security reasons, the password you type will not be visible.

[sudo] password for sveto: 
    Root:       /dev/mapper/cryptroot[/@]
    Snapshots:  /dev/mapper/cryptroot[/@snapshots]
    Boot FS:    ext4
    EFI FS:     vfat
    Home:       /dev/mapper/cryptroot[/@home]

[+] Detecting the LUKS2 device...

[ERROR] Could not determine the LUKS backing device.
[sveto@monarch scripts]$ lsblk
NAME          MAJ:MIN RM  SIZE RO TYPE  MOUNTPOINTS
sr0            11:0    1 1024M  1 rom   
vda           254:0    0   30G  0 disk  
├─vda1        254:1    0    1G  0 part  /efi
├─vda2        254:2    0    2G  0 part  /boot
└─vda3        254:3    0   27G  0 part  
  └─cryptroot 253:0    0   27G  0 crypt /.snapshots
                                        /home
                                        /

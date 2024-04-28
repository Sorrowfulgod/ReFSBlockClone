# ReFSBlockClone
Clone files using ReFS block cloning. Volume must be formatted in ReFS and files must reside on same volume.

For example:
.\Clone-FileViaBlockClone.ps1 -InFile "\\\\sofs\vm\Windows XP SP3-flat.vmdk" -OutFile \\\\sofs\vm\test.vmdk

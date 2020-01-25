# ReFSBlockClone
Clone files using ReFS block cloning. Volume must be formatted in Server 2016 ReFS and files must reside on same volume. Size of source file must be round of logical cluster size, else cloning will fail

For example:
.\Clone-FileViaBlockClone.ps1 -InFile "\\\\sofs\vm\Windows XP SP3-flat.vmdk" -OutFile \\\\sofs\vm\test.vmdk

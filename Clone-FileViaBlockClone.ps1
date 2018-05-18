<#
.NOTES
    Copyright (c) Sergey Gruzdov. All rights reserved.
    
    .SYNOPSIS
        Clone files using ReFS block cloning

    .DESCRIPTION
        Clone files using ReFS block cloning. Volume must be formatted in Server 2016 ReFS and files must reside on same volume

    .PARAMETER $InFile
        Source file to be cloned

    .PARAMETER $OutFile
        Destination file
#>

param(
    [ValidateNotNullOrEmpty()]
    $InFile,

    [ValidateNotNullOrEmpty()]
    $OutFile
)

$FILE_SUPPORTS_BLOCK_REFCOUNTING = 0x08000000
$GENERIC_READ = 0x80000000L
$GENERIC_WRITE = 0x40000000L
$DELETE = 0x00010000L
$FILE_SHARE_READ = 0x00000001
$OPEN_EXISTING = 3
$CREATE_NEW = 1
$INVALID_HANDLE_VALUE = -1
$SIZEOF_FSCTL_GET_INTEGRITY_INFORMATION_BUFFER = 16
$SIZEOF_FSCTL_SET_INTEGRITY_INFORMATION_BUFFER = 8
$SIZEOF_FILE_END_OF_FILE_INFO = 8
$SIZEOF_FILE_DISPOSITION_INFO = 1
$SIZEOF_DUPLICATE_EXTENTS_DATA = 32
$FSCTL_GET_INTEGRITY_INFORMATION = 0x9027C
$FSCTL_SET_INTEGRITY_INFORMATION = 0x9C280
$FSCTL_DUPLICATE_EXTENTS_TO_FILE = 0x98344
$FileEndOfFileInfo = 6
$FileDispositionInfo = 4

$StructsDefinition = @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

namespace CloneStructs
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FSCTL_GET_INTEGRITY_INFORMATION_BUFFER
    {
        public ushort ChecksumAlgorithm;
        public ushort Reserved;
        public uint Flags;
        public uint ChecksumChunkSizeInBytes;
        public uint ClusterSizeInBytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FSCTL_SET_INTEGRITY_INFORMATION_BUFFER 
    {
        public ushort   ChecksumAlgorithm;
        public ushort   Reserved;
        public uint Flags;
    }
    
    [StructLayout(LayoutKind.Sequential)]
    public struct FILE_DISPOSITION_INFO
    {
        public bool DeleteFile;
    }

    public struct FILE_END_OF_FILE_INFO 
    {
        public ulong EndOfFile;
    }

    public struct DUPLICATE_EXTENTS_DATA 
    {
        public IntPtr FileHandle;
        public ulong SourceFileOffset;
        public ulong TargetFileOffset;
        public ulong ByteCount;
    }
}
'@

$MethodDefinitions = @’
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFileW(
    string lpFileName,
    ulong dwDesiredAccess,
    ulong dwShareMode,
    IntPtr lpSecurityAttributes,
    ulong dwCreationDisposition,
    ulong dwFlagsAndAttributes,
    IntPtr hTemplateFile
    );

[DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
public static extern bool CloseHandle(IntPtr hObject);

[DllImport("kernel32.dll")]
public static extern ulong GetLastError();

[DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
public static extern bool GetVolumeInformationByHandleW(
    IntPtr hFile,
    IntPtr lpVolumeNameBuffer,
    ulong nVolumeNameSize,
    IntPtr lpVolumeSerialNumber,
    IntPtr lpMaximumComponentLength,
    out ulong lpFileSystemFlags,
    IntPtr lpFileSystemNameBuffer,
    ulong nFileSystemNameSize);

[DllImport("kernel32.dll")]
public static extern bool GetFileSizeEx(IntPtr hFile, out ulong lpFileSize);

[DllImport("kernel32.dll")]
public static extern bool DeleteFileW(string lpFileName);

[DllImport("kernel32.dll")]
public static extern bool DeviceIoControl(
    IntPtr hDevice,
    ulong dwIoControlCode,
    IntPtr lpInBuffer,
    ulong nInBufferSize,
    IntPtr lpOutBuffer,
    ulong nOutBufferSize,
    out ulong lpBytesReturned,
    IntPtr lpOverlapped
    );

[DllImport("kernel32.dll")]
public static extern bool SetFileInformationByHandle(
    IntPtr hFile,
    int FileInformationClass,
    IntPtr lpFileInformation,
    ulong dwBufferSize
    );
‘@

Write-Host "Clone file using ReFS Block Clone. Written by Sergey Gruzdov (egel@egel.su)"
Write-Host "Cloning '$InFile' to '$OutFile'"

$startTime = Get-Date
$status = $true
$hInFile = $INVALID_HANDLE_VALUE
$hOutFile = $INVALID_HANDLE_VALUE
$dwRet = 0
try
{
    $Methods = Add-Type -MemberDefinition $MethodDefinitions -Name 'Methods' -Namespace 'Win32' -PassThru
    Add-Type -TypeDefinition $StructsDefinition

    $hInFile = $Methods::CreateFileW($InFile, $GENERIC_READ, $FILE_SHARE_READ, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
    if ($hInFile -eq $INVALID_HANDLE_VALUE)
    {
        throw "Unable open file '$InFile'"
    }

    $dwVolumeFlags = 0
	if (! $($Methods::GetVolumeInformationByHandleW($hInFile, [IntPtr]::Zero, 0, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$dwVolumeFlags, [IntPtr]::Zero, 0)))
    {
        throw "Unable to get volume information for source file"
    }
    
	if (!($dwVolumeFlags -band $FILE_SUPPORTS_BLOCK_REFCOUNTING))
	{
		throw "Volume not supported block cloning!"
	}
    

    $SourceFileSize = 0
    if (!$($Methods::GetFileSizeEx($hInFile, [ref]$SourceFileSize)))
    {
        throw "Unable to get size of source file '$InFile'"
    }

	$hOutFile = $Methods::CreateFileW($OutFile, $GENERIC_READ -bor $GENERIC_WRITE -bor $DELETE, 0, [IntPtr]::Zero, $CREATE_NEW, 0, $hInFile)
	if ($hOutFile -eq $INVALID_HANDLE_VALUE)
	{
	    throw "Unable to create output file '$OutFile'"
	}

    $disposeInfo = New-Object CloneStructs.FILE_DISPOSITION_INFO
    $disposeInfo.DeleteFile = $true
    $ptrInfo = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($SIZEOF_FILE_DISPOSITION_INFO)
    [System.Runtime.InteropServices.Marshal]::StructureToPtr($disposeInfo, $ptrInfo, $false)
    $result = $Methods::SetFileInformationByHandle($hOutFile, $FileDispositionInfo, $ptrInfo, $SIZEOF_FILE_DISPOSITION_INFO)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptrInfo)
	if (!$result)
	{
        throw "Unable to set file disposition"
    }

    $endOfOutFileInfo = New-Object CloneStructs.FILE_END_OF_FILE_INFO
    $endOfOutFileInfo.EndOfFile = $SourceFileSize
    $ptrInfo = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($SIZEOF_FILE_END_OF_FILE_INFO)
    [System.Runtime.InteropServices.Marshal]::StructureToPtr($endOfOutFileInfo, $ptrInfo, $false)
    $result = $Methods::SetFileInformationByHandle($hOutFile, $FileEndOfFileInfo, $ptrInfo, $SIZEOF_FILE_END_OF_FILE_INFO)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptrInfo)
	if (!$result)
	{
        throw "Unable to set end of output file"
    }
    
    $sourceFileIntegrity = New-Object CloneStructs.FSCTL_GET_INTEGRITY_INFORMATION_BUFFER
    $type = $sourceFileIntegrity.GetType()
    $ptrInfo = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($SIZEOF_FSCTL_GET_INTEGRITY_INFORMATION_BUFFER)
    if (!$($Methods::DeviceIoControl($hInFile, $FSCTL_GET_INTEGRITY_INFORMATION, [IntPtr]::Zero, 0, $ptrInfo, $SIZEOF_FSCTL_GET_INTEGRITY_INFORMATION_BUFFER, [ref]$dwRet, [IntPtr]::Zero)))
	{
	    throw "Unable get intergrity of input file"
	}
    $sourceFileIntegrity = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptrInfo,[System.Type]$type)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptrInfo)

    $tragetFileIntegrity = New-Object CloneStructs.FSCTL_SET_INTEGRITY_INFORMATION_BUFFER
    $tragetFileIntegrity.ChecksumAlgorithm = $sourceFileIntegrity.ChecksumAlgorithm
    $tragetFileIntegrity.Reserved = $sourceFileIntegrity.Reserved
    $tragetFileIntegrity.Flags = $sourceFileIntegrity.Flags
    $ptrInfo = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($SIZEOF_FSCTL_SET_INTEGRITY_INFORMATION_BUFFER);
    [System.Runtime.InteropServices.Marshal]::StructureToPtr($tragetFileIntegrity, $ptrInfo, $true)
    $result = $Methods::DeviceIoControl($hOutFile, $FSCTL_SET_INTEGRITY_INFORMATION, $ptrInfo, $SIZEOF_FSCTL_SET_INTEGRITY_INFORMATION_BUFFER, [IntPtr]::Zero, 0, [ref]$dwRet, [IntPtr]::Zero)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptrInfo)
    if (!$result)
	{
	    throw "Unable to set intergrity of output file"
	}
    #

    $ByteCount = 1Gb

    $ptrInfo = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($SIZEOF_DUPLICATE_EXTENTS_DATA);
    $dupExtent = New-Object CloneStructs.DUPLICATE_EXTENTS_DATA
    $dupExtent.FileHandle = $hInFile
    $dupExtent.ByteCount = $ByteCount
    $FileOffset = 0
    

    while ($FileOffset -le $SourceFileSize)
    {
	    $dupExtent.SourceFileOffset = $FileOffset
		$dupExtent.TargetFileOffset = $FileOffset

        if ($FileOffset + $ByteCount -gt $SourceFileSize)
        {
            $dupExtent.ByteCount = $SourceFileSize - $FileOffset
        }

        [System.Runtime.InteropServices.Marshal]::StructureToPtr($dupExtent, $ptrInfo, $false)
        if (!$($Methods::DeviceIoControl($hOutFile, $FSCTL_DUPLICATE_EXTENTS_TO_FILE, $ptrInfo, $SIZEOF_DUPLICATE_EXTENTS_DATA, [IntPtr]::Zero, 0, [ref]$dwRet, [IntPtr]::Zero)))
        {
            throw $("DeviceIoControl failed at offset: {0}", $FileOffset)
        }

        $FileOffset += $ByteCount
    }
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptrInfo)


    # clear disposition flag, so file dont delete on close
    $disposeInfo.DeleteFile = $false
    $ptrInfo = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($SIZEOF_FILE_DISPOSITION_INFO)
    [System.Runtime.InteropServices.Marshal]::StructureToPtr($disposeInfo, $ptrInfo, $false)
    $result = $Methods::SetFileInformationByHandle($hOutFile, $FileDispositionInfo, $ptrInfo, $SIZEOF_FILE_DISPOSITION_INFO)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptrInfo)
	if (!$result)
	{
        throw "Unable to set file disposition"
    }

	$endTime = Get-Date
	$elapsed = $endTime - $startTime

	Write-Host "Completed in $($elapsed.Seconds).$($elapsed.Milliseconds) second(s)"
}
catch
{
	$code = -1
	if ($Methods -ne $null)
	{
		$code = $Methods::GetLastError()
	}

    Write-Host $("$($_): Error {0:X}" -f $code)
    $status = $false
}
finally
{
    if ($hInFile -ne $INVALID_HANDLE_VALUE)
    {
        [void]$Methods::CloseHandle($hInFile)
    }
    if ($hOutFile -ne $INVALID_HANDLE_VALUE)
    {
        [void]$Methods::CloseHandle($hOutFile)
    }
}